"""Offline integrity checks. No Codex process or model requests are started."""
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import queue
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import uuid
import runner


def snapshot(used=10, weekly=5, cash='100.000', reset=None):
    future=int(time.time())+1000 if reset is None else reset
    return {'observed_at':datetime.now(timezone.utc).isoformat(),'ordinaryUsageAllowed':True,
        'pools':{'codex':{'primary':{'usedPercent':used,'resetsAt':future,'windowDurationMins':300},
            'secondary':{'usedPercent':weekly,'resetsAt':future+604800,'windowDurationMins':10080},
            'credits':{'balance':cash},'rateLimitReachedType':None,'spendControlReached':False}}}


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parents[2]/'work'/'offline-app-checks'
        root.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=root)
        runner.DATA=Path(self.temp.name)
        runner.STATE={}
        runner.STOP=False
        runner.EXPECTED_PARENT=0
        runner.CONNECTION={'pending':[],'queue':queue.Queue()}
        runner.NETWORK={}

    def tearDown(self):
        self.temp.cleanup()

    def test_window_reset_invalidates_measurement(self):
        before=snapshot(reset=int(time.time())-1)
        after=snapshot(0,0,reset=int(time.time())+300)
        _,valid=runner.quota_delta(before,after)
        self.assertFalse(valid)

    def test_one_second_future_reset_jitter_preserves_measurement(self):
        for shift in [-1, 1]:
            before=snapshot(23,15);after=copy.deepcopy(before)
            after['pools']['codex']['primary']['resetsAt']+=shift
            delta,valid=runner.quota_delta(before,after)
            self.assertTrue(valid)
            self.assertTrue(delta['codex']['primary']['reset_timestamp_jitter'])
            self.assertEqual(delta['codex']['primary']['delta_pp'],0)
            # A real counter decrease must still stop, even with only 1s shift.
            after['pools']['codex']['primary']['usedPercent']=22
            self.assertFalse(runner.quota_delta(before,after)[1])

    def test_small_timestamp_shift_cannot_cross_a_passed_boundary(self):
        before=snapshot(23,15,reset=int(time.time())-2)
        after=copy.deepcopy(before);after['pools']['codex']['primary']['resetsAt']+=1
        self.assertFalse(runner.quota_delta(before,after)[1])

    def test_settlement_accepts_timestamp_jitter_but_rejects_real_reset(self):
        reference=snapshot(10);one=copy.deepcopy(reference);two=copy.deepcopy(reference)
        one['pools']['codex']['primary']['resetsAt']+=1
        with patch.object(runner,'limits',side_effect=[one,two,one]),patch.object(runner.time,'sleep'):
            _,stable,reads=runner.settle(reference,seconds=0)
        self.assertTrue(stable);self.assertEqual(len(reads),3)
        changed=copy.deepcopy(reference);changed['pools']['codex']['primary']['resetsAt']+=18000
        with patch.object(runner,'limits',return_value=changed),patch.object(runner.time,'sleep'):
            _,stable,reads=runner.settle(reference,seconds=0)
        self.assertFalse(stable);self.assertEqual(len(reads),1)

    def test_completed_parallel_round_is_not_invalidated_by_one_second_jitter(self):
        self.setup_fake();after=copy.deepcopy(self.baseline)
        after['pools']['codex']['primary']['resetsAt']+=1
        with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=[self.baseline,after]):
            rows=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],1,{'attempts':[]},self.baseline)
        self.assertTrue(rows[0]['valid'])
        self.assertIsNone(rows[0]['round_error'])

    def test_initial_empty_window_anchor_is_not_reset(self):
        before=snapshot(0,0)
        after=snapshot(1,0,reset=before['pools']['codex']['primary']['resetsAt']+9)
        delta,valid=runner.quota_delta(before,after)
        self.assertTrue(valid)
        self.assertTrue(delta['codex']['primary']['anchor_initialized'])
        self.assertEqual(delta['codex']['primary']['delta_pp'],1)

    def test_unused_reserve_moving_timestamp_does_not_invalidate(self):
        a=snapshot();b=copy.deepcopy(a)
        a['pools']['reserve']={'primary':{'usedPercent':0,'resetsAt':2000000000}}
        b['pools']['reserve']={'primary':{'usedPercent':0,'resetsAt':2000000010}}
        self.assertTrue(runner.quota_delta(a,b)[1])

    def test_counter_decrease_is_not_negative_cost(self):
        a=snapshot(10);b=copy.deepcopy(a);b['pools']['codex']['primary']['usedPercent']=9
        self.assertFalse(runner.quota_delta(a,b)[1])

    def test_insufficient_or_unknown_allowance_blocks_start(self):
        self.assertIsNotNone(runner.gate(snapshot(85)))
        self.assertIsNotNone(runner.gate(snapshot(10,90)))
        a=snapshot();a['pools']['codex']['credits']=None
        self.assertIsNotNone(runner.gate(a))
        a=snapshot();a['ordinaryUsageAllowed']=False
        self.assertIsNotNone(runner.gate(a))

    def test_running_round_continues_past_start_threshold(self):
        self.setup_fake();baseline=snapshot(83);during=snapshot(86);after=snapshot(87)
        future=baseline['pools']['codex']['primary']['resetsAt']
        for value in [during,after]:
            value['pools']['codex']['primary']['resetsAt']=future
            value['pools']['codex']['secondary']['resetsAt']=baseline['pools']['codex']['secondary']['resetsAt']
        with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=[during,after]):
            row=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],3,{'attempts':[]},baseline)[0]
        self.assertTrue(row['valid'])
        self.assertEqual(row['status'],'completed')
        self.assertEqual(sum(method=='turn/start' for method,_ in self.calls),1)

    def test_running_round_still_stops_at_emergency_boundary(self):
        self.setup_fake();baseline=snapshot(83);near_limit=snapshot(95)
        near_limit['pools']['codex']['primary']['resetsAt']=baseline['pools']['codex']['primary']['resetsAt']
        near_limit['pools']['codex']['secondary']['resetsAt']=baseline['pools']['codex']['secondary']['resetsAt']
        with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',return_value=near_limit):
            row=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],3,{'attempts':[]},baseline)[0]
        self.assertFalse(row['valid'])
        self.assertEqual(row['status'],'not_started')
        self.assertEqual(sum(method=='turn/start' for method,_ in self.calls),0)

    def test_config_requires_isolation_and_exact_high(self):
        config={'models':[runner.SUITE['models'][0]],'tasks':['T1'],'repeats':1,
            'effort':'high','service_tier':'default','isolation_confirmed':True,
            'measurement_strategy':'complete_model_batch','execution_mode':'parallel_tasks_per_round'}
        runner.validate_config(config)
        for key,value in [('effort','medium'),('isolation_confirmed',False),('repeats',0)]:
            bad=dict(config);bad[key]=value
            with self.assertRaises(RuntimeError):runner.validate_config(bad)
    def test_failed_turn_preserves_original_429_reason(self):
        self.setup_fake();tasks={}
        def request(method,params=None,**kwargs):
            if method=='thread/start':
                result=self.fake_rpc(method,params,**kwargs)
                tasks[result['thread']['id']]='T3' if '-T3-' in params['cwd'] else 'T1'
                return result
            if method!='turn/start' or tasks[params['threadId']]=='T1':
                return self.fake_rpc(method,params,**kwargs)
            self.calls.append((method,params));identity=uuid.uuid4().hex
            thread=params['threadId'];stamp=time.monotonic()
            error={'message':'exceeded retry limit, last status: 429 Too Many Requests',
                   'codexErrorInfo':{'responseTooManyFailedAttempts':{'httpStatusCode':429}}}
            for offset,(event,data) in enumerate([
                    ('error',{'error':error,'threadId':thread}),
                    ('turn/completed',{'turn':{'id':identity,'status':'failed','error':error},'threadId':thread})]):
                runner.CONNECTION['queue'].put((stamp+.01*offset,{'method':event,'params':data}))
            return {'turn':{'id':identity}}
        with patch.object(runner,'rpc',side_effect=request), \
             patch.object(runner,'limits',return_value=self.baseline):
            rows=runner.execute_round([runner.SUITE['tasks'][0],runner.SUITE['tasks'][2]],
                                      runner.SUITE['models'][0],2,{'attempts':[]},self.baseline)
        row=next(r for r in rows if r['task']=='T3')
        self.assertEqual(row['status'],'failed')
        self.assertIn('429 Too Many Requests',row['round_error'])
        self.assertIn('「'+runner.SUITE['tasks'][2]['name']+'」失败',row['round_error'])
        self.assertNotIn('T3 失败',row['round_error'])

    def test_manual_proxy_replaces_inherited_conflicts_and_auth_is_not_saved(self):
        with patch.dict(runner.os.environ, {'HTTPS_PROXY':'http://old:9000',
                'https_proxy':'http://other:8000','WSS_PROXY':'http://old:9000'}, clear=True):
            env,report=runner.proxy_environment({'mode':'manual','url':'socks5h://127.0.0.1:7897'})
        for key in ['HTTP_PROXY','HTTPS_PROXY','ALL_PROXY']:
            self.assertEqual(env[key],env[key.lower()])
            self.assertEqual(env[key],'socks5h://127.0.0.1:7897')
        self.assertNotIn('WSS_PROXY',env)
        self.assertEqual(report['source'],'手动设置')
        for value in ['', 'http://127.0.0.1', 'http://127.0.0.1:0', 'http://127.0.0.1:70000',
                      'http://user:secret@127.0.0.1:7897', 'https://127.0.0.1:7897/path']:
            with self.assertRaises(RuntimeError):runner.proxy_environment({'mode':'manual','url':value})

    def test_auto_system_proxy_has_priority_and_copies_exception_rules(self):
        system='''<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 7897
  HTTPSEnable : 1
  HTTPSProxy : 127.0.0.1
  HTTPSPort : 7898
  ExceptionsList : <array> {
    0 : localhost
    1 : *.local
  }
}'''
        with patch.dict(runner.os.environ,{'HTTPS_PROXY':'http://old:8000'},clear=True), \
             patch.object(runner.subprocess,'check_output',return_value=system):
            env,report=runner.proxy_environment({'mode':'auto'})
        self.assertEqual(env['HTTPS_PROXY'],'http://127.0.0.1:7898')
        self.assertEqual(env['NO_PROXY'],'localhost,*.local')
        self.assertNotIn('ALL_PROXY',env)
        self.assertEqual(report['source'],'系统代理')

    def test_auto_empty_system_falls_back_to_inherited_and_redacts_credentials(self):
        with patch.dict(runner.os.environ,{'https_proxy':'http://user:private@127.0.0.1:7897'},clear=True), \
             patch.object(runner.subprocess,'check_output',return_value='<dictionary> {}'):
            env,report=runner.proxy_environment({'mode':'auto'})
        self.assertIn('private',env['HTTPS_PROXY'])
        self.assertNotIn('private',json.dumps(report))
        self.assertNotIn('user',json.dumps(report))
        self.assertIn('回退',report['source'])

    def test_pac_does_not_silently_fall_back_to_another_route(self):
        with patch.object(runner.subprocess,'check_output',return_value='ProxyAutoConfigEnable : 1'):
            with self.assertRaisesRegex(RuntimeError,'PAC'):runner.proxy_environment({'mode':'auto'})

    def test_direct_removes_all_proxy_case_variants(self):
        with patch.dict(runner.os.environ,{'HTTPS_PROXY':'http://old:7897','all_proxy':'socks5h://old:7897',
                'NO_PROXY':'chatgpt.com','wss_proxy':'http://old:7897','KEEP':'yes'},clear=True):
            env,report=runner.proxy_environment({'mode':'direct'})
        self.assertEqual(env,{'KEEP':'yes'})
        self.assertEqual(report['cli_proxy_environment'],{})

    def test_unreachable_proxy_stops_without_remote_probe(self):
        env,report=runner.proxy_environment({'mode':'manual','url':'http://127.0.0.1:7897'})
        with patch.object(runner.socket,'create_connection',side_effect=ConnectionRefusedError()), \
             patch.object(runner.subprocess,'run') as curl:
            self.assertFalse(runner.check_proxy_transport(env,report))
        curl.assert_not_called()
        self.assertFalse(report['proxy_ports'][0]['reachable'])

    def test_connect_tunnel_and_auth_error_do_not_claim_websocket_verified(self):
        env,report=runner.proxy_environment({'mode':'manual','url':'http://127.0.0.1:7897'})
        env['CODEX_CA_CERTIFICATE']='/fake/private-root.pem'
        with patch.object(runner.socket,'create_connection'), \
             patch.object(runner.subprocess,'run',return_value=SimpleNamespace(
                 stdout='401 200 0.432 127.0.0.1',returncode=0)) as curl:
            self.assertTrue(runner.check_proxy_transport(env,report))
        self.assertEqual(report['websocket_probe']['connect_status'],200)
        self.assertFalse(report['websocket_probe']['upgrade_accepted'])
        self.assertFalse(report['authenticated_websocket_verified'])
        args=curl.call_args.args[0]
        self.assertEqual(args[1],'--disable')
        self.assertEqual(args[args.index('--cacert')+1],'/fake/private-root.pem')
        self.assertEqual(args[args.index('--proxy')+1],'http://127.0.0.1:7897')
        self.assertFalse(any('Authorization' in x for x in args))
        self.assertFalse(any('Bearer' in x for x in args))

    def test_no_proxy_bypass_is_visible_in_connection_log(self):
        env,report=runner.proxy_environment({'mode':'manual','url':'http://127.0.0.1:7897'})
        with patch.object(runner.socket,'create_connection'), \
             patch.object(runner.subprocess,'run',return_value=SimpleNamespace(
                 stdout='403 0 0.100 1.2.3.4',returncode=0)):
            runner.check_proxy_transport(env,report)
        self.assertIn('NO_PROXY',report['messages'][-3])

    def test_cli_receives_selected_proxy_and_cannot_fall_back_to_system_settings(self):
        with patch.object(runner,'check_proxy_transport',return_value=True), \
             patch.object(runner.subprocess,'Popen') as launch, \
             patch.object(runner.threading,'Thread'), \
             patch.object(runner,'rpc',return_value={'account':{'type':'chatgpt'}}):
            launch.return_value.pid=12345
            runner.connect('/fake/codex',{'mode':'manual','url':'http://127.0.0.1:7897'})
        args=launch.call_args.args[0]
        self.assertIn('features.respect_system_proxy=false',args)
        self.assertIn('features.system_proxy_fallback=false',args)
        self.assertEqual(launch.call_args.kwargs['env']['HTTPS_PROXY'],'http://127.0.0.1:7897')
        report=json.loads((runner.DATA/'network-diagnostics.json').read_text())
        self.assertEqual(report['cli_pid'],12345)
        self.assertTrue(report['cli_environment_injected'])

    def fake_rpc(self,method,params=None,**kwargs):
        self.calls.append((method,params))
        if method=='thread/start':
            self.folders.append(params['cwd'])
            return {'thread':{'id':uuid.uuid4().hex},'model':params['model'],
                'reasoningEffort':'high',
                'serviceTier':'priority' if params['serviceTier']=='fast' else 'default'}
        if method=='turn/start':
            turn=uuid.uuid4().hex
            thread=params['threadId'];inbox=runner.CONNECTION['queue'];stamp=time.monotonic()
            events=[('item/started',{'item':{'id':'answer','type':'agentMessage','phase':'final_answer'}}),
                ('item/reasoning/summaryTextDelta',{'delta':'private reasoning must not be exported'}),
                ('item/agentMessage/delta',{'itemId':'answer','delta':'offline fixture answer'}),
                ('thread/tokenUsage/updated',{'tokenUsage':{'total':{'inputTokens':12,'outputTokens':3}}}),
                ('item/completed',{'item':{'id':'answer','type':'agentMessage','phase':'final_answer','text':'offline fixture answer'}}),
                ('turn/completed',{'turn':{'id':turn,'status':'completed'}})]
            for index,(event,data) in enumerate(events):
                data['threadId']=thread
                inbox.put((stamp+.01*index,{'method':event,'params':data}))
            return {'turn':{'id':turn}}
        if method=='model/list':
            return {'data':[{'model':m,'supportedReasoningEfforts':[
                {'reasoningEffort':e} for e in ['low','medium','high']]} for m in runner.SUITE['models']]}
        return {}

    def setup_fake(self):
        self.calls=[];self.folders=[]
        self.baseline=snapshot()

    def test_retries_use_new_context_and_workspace(self):
        self.setup_fake();session={'attempts':[]};task=runner.SUITE['tasks'][0]
        with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',return_value=self.baseline), \
             patch.object(runner,'settle',return_value=(self.baseline,True,[self.baseline])):
            one=runner.execute_round([task],runner.SUITE['models'][0],1,session,self.baseline)[0]
            two=runner.execute_round([task],runner.SUITE['models'][0],1,session,self.baseline)[0]
        self.assertNotEqual(one['thread_id'],two['thread_id'])
        self.assertNotEqual(self.folders[0],self.folders[1])
        self.assertEqual(one['tokens']['total']['inputTokens'],12)
        self.assertTrue(one['valid'])
        events=(runner.DATA/'events.jsonl').read_text()
        self.assertNotIn('private reasoning',events)
        self.assertFalse(any(method in ['thread/resume','thread/fork'] for method,_ in self.calls))

    def test_credit_change_invalidates_attempt(self):
        self.setup_fake();changed=copy.deepcopy(self.baseline)
        changed['pools']['codex']['credits']['balance']='99.000'
        with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=[self.baseline,changed]), \
             patch.object(runner,'settle',return_value=(changed,False,[changed])):
            result=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],1,{'attempts':[]},self.baseline)[0]
        self.assertFalse(result['valid'])
        self.assertFalse(result['credit_balance_unchanged'])

    def test_immediate_stop_is_invalid_and_interrupt_is_sent(self):
        self.setup_fake();self.sent=[];started=[]
        def request(method,params=None,**kwargs):
            value=self.fake_rpc(method,params,**kwargs)
            if method=='turn/start':started.append(True)
            return value
        with patch.object(runner,'rpc',side_effect=request), \
             patch.object(runner,'send',side_effect=lambda method,p:self.sent.append(method)), \
             patch.object(runner,'control',side_effect=lambda:'stop' if started else None), \
             patch.object(runner,'limits',return_value=self.baseline):
            result=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],1,{'attempts':[]},self.baseline)[0]
        self.assertIn('turn/interrupt',self.sent)
        self.assertFalse(result['valid'])

    def test_resume_preserves_abandoned_attempt_and_restarts_job(self):
        self.setup_fake()
        config={'models':[runner.SUITE['models'][0]],'tasks':['T1'],'repeats':1,
            'effort':'high','service_tier':'default','isolation_confirmed':True,
            'measurement_strategy':'complete_model_batch','execution_mode':'parallel_tasks_per_round'}
        fingerprint=hashlib.sha256(json.dumps(config,sort_keys=True).encode()).hexdigest()
        runner.write_json(runner.DATA/'config.json',config)
        runner.write_json(runner.DATA/'session.json',{'schema_version':3,'started_at':runner.now(),'config':config,
            'config_hash':fingerprint,'attempts':[],'groups':[],
            'suite_sha256':hashlib.sha256((runner.HERE/'suite.json').read_bytes()).hexdigest(),
            'current_group':{'attempt_ids':[],'complete':False}})
        runner.write_json(runner.DATA/'current-attempt.json',{'attempt_id':'old','model':config['models'][0],
            'task':'T1','repeat':1,'valid':False,'thread_id':'old-thread'})
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',return_value=self.baseline), \
             patch.object(runner,'settle',return_value=(self.baseline,True,[self.baseline])):
            runner.run(str(runner.DATA/'config.json'),True)
        result=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual(len(result['attempts']),2)
        self.assertFalse(result['attempts'][0]['valid'])
        self.assertTrue(result['attempts'][1]['valid'])
        self.assertNotEqual(result['attempts'][1]['thread_id'],'old-thread')
        self.assertEqual(len(result['groups']),2)

    def batch_config(self,models):
        return {'models':models,'tasks':['T1','T2','T3','T4'],'repeats':3,
            'effort':'high','service_tier':'default','isolation_confirmed':True,
            'measurement_strategy':'complete_model_batch','execution_mode':'parallel_tasks_per_round'}

    def fake_execute_round(self,tasks,model,repeat,session,before,tier='default',effort='high'):
        results=[]
        for task in tasks:
            self.job_calls.append((model,repeat,task['id']))
            self.current['pools']['codex']['primary']['usedPercent']+=1
            result={'attempt_id':uuid.uuid4().hex,'model':model,'task':task['id'],'service_tier':tier,
                'effort':effort,
                'repeat':repeat,'valid':True,'status':'completed','round_after':copy.deepcopy(self.current),
                'interrupted_reason':None,'quota_scope':'model_batch_only'}
            session['attempts'].append(result);results.append(result)
        return results

    def test_model_runs_all_twelve_jobs_before_switching_and_uses_batch_delta(self):
        self.setup_fake();self.job_calls=[];self.current=copy.deepcopy(self.baseline)
        config=self.batch_config(runner.SUITE['models'][:2])
        runner.write_json(runner.DATA/'config.json',config)
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)), \
             patch.object(runner,'settle',side_effect=lambda *a,**k:(copy.deepcopy(self.current),True,[copy.deepcopy(self.current)])), \
             patch.object(runner,'execute_round',side_effect=self.fake_execute_round):
            runner.run(str(runner.DATA/'config.json'),False)
        expected=[(m,r,t) for m in config['models'] for r in [1,2,3] for t in config['tasks']]
        self.assertEqual(self.job_calls,expected)
        session=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual(len(session['groups']),2)
        self.assertTrue(all(g['valid'] and g['complete'] and g['expected_samples']==12 for g in session['groups']))
        self.assertEqual([g['quota_delta']['codex']['primary']['delta_pp'] for g in session['groups']],[12,12])

    def test_mixed_four_rounds_settle_each_tier_and_resume_only_incomplete_tier(self):
        self.setup_fake();self.job_calls=[];self.current=copy.deepcopy(self.baseline)
        config=self.batch_config([runner.SUITE['models'][0]])
        config.update(repeats=4,service_tier='mixed')
        file=runner.DATA/'config.json';runner.write_json(file,config)
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)), \
             patch.object(runner,'settle',side_effect=lambda *a,**k:(copy.deepcopy(self.current),True,[copy.deepcopy(self.current)])), \
             patch.object(runner,'execute_round',side_effect=self.fake_execute_round):
            runner.run(str(file),False)
        session=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual([(g['service_tier'],g['expected_samples'],g['quota_delta']['codex']['primary']['delta_pp'])
                          for g in session['groups']],[('default',8,8),('fast',8,8)])
        self.assertEqual([a['service_tier'] for a in session['attempts']],['default']*8+['fast']*8)
        self.assertEqual(len(self.job_calls),16)
        # Simulate an interrupted Fast batch while preserving a completed Standard batch.
        session.pop('finished_at');session.pop('final_snapshot')
        session['groups'][1]['complete']=False;session['groups'][1]['valid']=False
        runner.write_json(runner.DATA/'session.json',session)
        self.job_calls=[]
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)), \
             patch.object(runner,'settle',side_effect=lambda *a,**k:(copy.deepcopy(self.current),True,[copy.deepcopy(self.current)])), \
             patch.object(runner,'execute_round',side_effect=self.fake_execute_round):
            runner.run(str(file),True)
        resumed=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual([(r,t) for _,r,t in self.job_calls],
                         [(r,t) for r in [3,4] for t in config['tasks']])
        self.assertEqual(sum(a['valid'] for a in resumed['attempts']),16)
        self.assertEqual([g['service_tier'] for g in resumed['groups'] if g['valid']],['default','fast'])

    def test_fast_round_sets_tier_on_thread_and_turn(self):
        self.setup_fake()
        with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',return_value=self.baseline):
            row=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],3,
                                     {'attempts':[]},self.baseline,'fast')[0]
        self.assertTrue(row['valid'])
        self.assertEqual(row['service_tier'],'fast')
        self.assertEqual(row['reported_service_tier'],'priority')
        self.assertEqual([p['serviceTier'] for m,p in self.calls if m=='thread/start'],['fast'])
        self.assertEqual([p['serviceTierForTurn'] for m,p in self.calls if m=='turn/start'],['fast'])

    def test_sol_light_and_luna_medium_are_sent_on_turns(self):
        self.setup_fake()
        for model,effort in [(runner.SUITE['models'][0],'low'),('gpt-6-luna','medium')]:
            with patch.object(runner,'rpc',side_effect=self.fake_rpc), \
                 patch.object(runner,'limits',return_value=self.baseline):
                row=runner.execute_round([runner.SUITE['tasks'][0]],model,1,
                                         {'attempts':[]},self.baseline,'default',effort)[0]
            self.assertTrue(row['valid'])
            self.assertEqual(row['effort'],effort)
        self.assertEqual([p['effort'] for m,p in self.calls if m=='turn/start'],['low','medium'])

    def test_mixed_plan_assigns_effort_by_model(self):
        self.setup_fake();self.job_calls=[];self.current=copy.deepcopy(self.baseline)
        config=self.batch_config([runner.SUITE['models'][0],'gpt-6-luna'])
        config.update(repeats=2,effort='sol_low_luna_medium',service_tier='mixed')
        file=runner.DATA/'config.json';runner.write_json(file,config)
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)), \
             patch.object(runner,'settle',side_effect=lambda *a,**k:(copy.deepcopy(self.current),True,[copy.deepcopy(self.current)])), \
             patch.object(runner,'execute_round',side_effect=self.fake_execute_round):
            runner.run(str(file),False)
        session=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual([(g['model'],g['service_tier']) for g in session['groups']],
                         [(config['models'][0],'default'),(config['models'][0],'fast'),
                          ('gpt-6-luna','default'),('gpt-6-luna','fast')])
        self.assertEqual({a['effort'] for a in session['attempts'] if a['model'].endswith('-sol')},{'low'})
        self.assertEqual({a['effort'] for a in session['attempts'] if a['model'].endswith('-luna')},{'medium'})

    def test_initial_threshold_is_not_reapplied_between_models(self):
        self.setup_fake();self.job_calls=[];self.current=snapshot(83)
        config=self.batch_config(runner.SUITE['models'][:2]);config['repeats']=1
        file=runner.DATA/'config.json';runner.write_json(file,config)
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)), \
             patch.object(runner,'settle',side_effect=lambda *a,**k:(copy.deepcopy(self.current),True,[copy.deepcopy(self.current)])), \
             patch.object(runner,'execute_round',side_effect=self.fake_execute_round):
            runner.run(str(file),False)
        result=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual([(g['model'],g['before']['pools']['codex']['primary']['usedPercent'])
                          for g in result['groups']],[(config['models'][0],83),(config['models'][1],87)])
        self.assertTrue(all(g['complete'] and g['valid'] for g in result['groups']))
        self.assertEqual(len(self.job_calls),8)

    def test_paused_partial_model_restarts_all_twelve_and_preserves_invalid_attempts(self):
        self.setup_fake();self.job_calls=[];self.current=copy.deepcopy(self.baseline)
        config=self.batch_config([runner.SUITE['models'][0]])
        file=runner.DATA/'config.json';runner.write_json(file,config)
        common=[patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc),
                patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)),
                patch.object(runner,'settle',return_value=(self.baseline,True,[self.baseline])),
                patch.object(runner,'execute_round',side_effect=self.fake_execute_round)]
        from contextlib import ExitStack
        with ExitStack() as stack:
            for p in common:stack.enter_context(p)
            stack.enter_context(patch.object(runner,'control',side_effect=lambda:'pause' if len(self.job_calls)>=4 else None))
            with self.assertRaises(RuntimeError):runner.run(str(file),False)
        old=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual(len(old['attempts']),4)
        self.assertTrue(all(not a['valid'] for a in old['attempts']))
        self.assertFalse(old['groups'][0]['complete'])
        baseline=copy.deepcopy(self.current)
        with patch.object(runner,'connect'),patch.object(runner,'rpc',side_effect=self.fake_rpc), \
             patch.object(runner,'limits',side_effect=lambda:copy.deepcopy(self.current)), \
             patch.object(runner,'settle',return_value=(self.current,True,[self.current])), \
             patch.object(runner,'execute_round',side_effect=self.fake_execute_round):
            runner.run(str(file),True)
        result=json.loads((runner.DATA/'session.json').read_text())
        self.assertEqual(len(result['attempts']),16)
        self.assertEqual(sum(a['valid'] for a in result['attempts']),12)
        self.assertEqual(self.job_calls[4:],[(config['models'][0],r,t) for r in [1,2,3] for t in config['tasks']])
        self.assertEqual(len(result['groups'][-1]['attempt_ids']),12)

    def test_no_reset_redemption_or_api_key_login(self):
        text=Path(runner.__file__).read_text()
        self.assertNotIn('account/rateLimitResetCredit/consume',text)
        self.assertNotIn('account/login/start',text)

    def test_quota_network_failure_retries_then_returns_live_snapshot(self):
        raw={'ordinaryUsageAllowed':True,'rateLimitsByLimitId':snapshot()['pools']}
        with patch.object(runner,'rpc',side_effect=[RuntimeError('error sending request'),RuntimeError('temporary timeout'),raw]) as rpc, \
             patch.object(runner.time,'sleep'):
            result=runner.limits()
        self.assertEqual(runner.counts(result)['five_hour'],10)
        self.assertEqual(rpc.call_count,3)
        self.assertTrue(all(call.args[0]=='account/rateLimits/read' for call in rpc.call_args_list))

    def test_persistent_quota_failure_is_bounded_and_pauses(self):
        with patch.object(runner,'rpc',side_effect=RuntimeError('network unavailable')) as rpc, \
             patch.object(runner.time,'sleep'):
            with self.assertRaisesRegex(RuntimeError,'已安全暂停'):runner.limits()
        self.assertEqual(rpc.call_count,5)

    def test_user_can_stop_during_quota_retry(self):
        with patch.object(runner,'rpc',side_effect=RuntimeError('network unavailable')) as rpc, \
             patch.object(runner,'control',side_effect=[None,'stop']), \
             patch.object(runner.time,'sleep'):
            with self.assertRaisesRegex(RuntimeError,'用户立即停止'):runner.limits()
        self.assertEqual(rpc.call_count,1)

    def test_transient_quota_failure_does_not_duplicate_model_turn(self):
        self.setup_fake();reads=[]
        raw={'ordinaryUsageAllowed':True,'rateLimitsByLimitId':self.baseline['pools']}
        def request(method,params=None,**kwargs):
            if method=='account/rateLimits/read':
                reads.append(method)
                if len(reads)<3:raise RuntimeError('error sending request')
                return raw
            return self.fake_rpc(method,params,**kwargs)
        with patch.object(runner,'rpc',side_effect=request),patch.object(runner.time,'sleep'), \
             patch.object(runner,'settle',return_value=(self.baseline,True,[self.baseline])):
            result=runner.execute_round([runner.SUITE['tasks'][0]],runner.SUITE['models'][0],1,{'attempts':[]},self.baseline)[0]
        self.assertTrue(result['valid'])
        self.assertEqual(len(reads),4)
        self.assertEqual(sum(method=='turn/start' for method,_ in self.calls),1)

    def test_four_turns_are_started_before_processing_and_keep_outputs_separate(self):
        self.setup_fake();started=[]
        def request(method,params=None,**kwargs):
            if method!='turn/start':return self.fake_rpc(method,params,**kwargs)
            self.calls.append((method,params));turn=uuid.uuid4().hex
            started.append((params['threadId'],turn))
            if len(started)==4:
                stamp=time.monotonic()
                for index,(thread,identity) in reversed(list(enumerate(started))):
                    content='answer-'+str(index)
                    events=[('item/started',{'item':{'id':'same-id','type':'agentMessage','phase':'final_answer'}}),
                        ('item/agentMessage/delta',{'itemId':'same-id','delta':content}),
                        ('thread/tokenUsage/updated',{'tokenUsage':{'total':{'inputTokens':100+index,'outputTokens':10+index}}}),
                        ('item/completed',{'item':{'id':'same-id','type':'agentMessage','phase':'final_answer','text':content}}),
                        ('turn/completed',{'turn':{'id':identity,'status':'completed'}})]
                    for number,(name,data) in enumerate(events):
                        data['threadId']=thread
                        runner.CONNECTION['queue'].put((stamp+.01*number,{'method':name,'params':data}))
            return {'turn':{'id':turn}}
        import subprocess
        completed=subprocess.CompletedProcess([],0,stdout='',stderr='Ran 9 tests\nOK')
        with patch.object(runner,'rpc',side_effect=request), \
             patch.object(runner,'limits',return_value=self.baseline) as limits, \
             patch.object(runner.subprocess,'run',return_value=completed):
            session={'attempts':[]}
            rows=runner.execute_round(runner.SUITE['tasks'],runner.SUITE['models'][0],1,session,self.baseline)
        self.assertEqual(len(started),4)
        self.assertTrue(all(row['valid'] for row in rows))
        self.assertEqual([row['response'] for row in rows],['answer-0','answer-1','answer-2','answer-3'])
        self.assertEqual([row['tokens']['total']['inputTokens'] for row in rows],[100,101,102,103])
        self.assertEqual(len(set(self.folders)),4)
        self.assertEqual(limits.call_count,2)
        self.assertTrue(all('quota_delta' not in row and row['quota_scope']=='model_batch_only' for row in rows))
        self.assertFalse((runner.DATA/'current-attempts.json').exists())

    def test_stop_interrupts_every_inflight_task_in_parallel_round(self):
        self.setup_fake();starts=[];interrupts=[]
        def request(method,params=None,**kwargs):
            value=self.fake_rpc(method,params,**kwargs)
            if method=='turn/start':starts.append(params['threadId'])
            return value
        import subprocess
        result=subprocess.CompletedProcess([],0,stdout='',stderr='')
        with patch.object(runner,'rpc',side_effect=request), \
             patch.object(runner,'send',side_effect=lambda method,p:interrupts.append((method,p['threadId']))), \
             patch.object(runner,'control',side_effect=lambda:'stop' if len(starts)==4 else None), \
             patch.object(runner,'limits',return_value=self.baseline), \
             patch.object(runner.subprocess,'run',return_value=result):
            rows=runner.execute_round(runner.SUITE['tasks'],runner.SUITE['models'][0],1,{'attempts':[]},self.baseline)
        self.assertEqual({thread for method,thread in interrupts if method=='turn/interrupt'},set(starts))
        self.assertFalse(any(row['valid'] for row in rows))


if __name__=='__main__':
    unittest.main()
