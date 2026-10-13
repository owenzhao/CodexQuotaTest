"""Local benchmark execution and data logging. No AI controller or conclusions."""
import argparse
import copy
import fcntl
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import tomllib
import uuid
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
SUITE = json.loads((HERE / 'suite.json').read_text())
CONNECTION = {}
STATE = {}
DATA = None
STOP = False
EXPECTED_PARENT = 0
NETWORK = {}


def proxy_environment(settings=None):
    """Resolve one explicit CLI environment; never change global proxy settings."""
    settings = settings or {'mode': 'inherit'}
    mode = settings.get('mode', 'auto')
    if mode not in ['auto', 'manual', 'inherit', 'direct']:
        raise RuntimeError('代理模式无效。')
    inherited = {k: os.environ.get(k.lower(), os.environ.get(k, ''))
                 for k in ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY']}
    env = {k: v for k, v in os.environ.items() if k.lower() not in
           ['http_proxy', 'https_proxy', 'all_proxy', 'no_proxy', 'wss_proxy', 'ws_proxy']}
    system = {}
    if mode == 'auto':
        text = subprocess.check_output(['/usr/sbin/scutil', '--proxy'], text=True, timeout=5)
        for key in ['HTTPEnable', 'HTTPProxy', 'HTTPPort', 'HTTPSEnable', 'HTTPSProxy',
                    'HTTPSPort', 'SOCKSEnable', 'SOCKSProxy', 'SOCKSPort',
                    'ProxyAutoConfigEnable', 'ProxyAutoDiscoveryEnable', 'ExcludeSimpleHostnames']:
            match = re.search(r'^\s*' + key + r'\s*:\s*(.*?)\s*$', text, re.M)
            if match:
                system[key] = match.group(1)
        exceptions = re.search(r'ExceptionsList\s*:\s*<array>\s*\{([^}]*)\}', text, re.S)
        system['exceptions'] = re.findall(r'\d+\s*:\s*(\S+)', exceptions.group(1)) if exceptions else []
        if system.get('ProxyAutoConfigEnable') == '1' or system.get('ProxyAutoDiscoveryEnable') == '1':
            raise RuntimeError('系统使用PAC或自动发现代理；此版不解析动态规则，请选择手动代理。')
    values = {}
    source = {'inherit': '应用启动环境', 'direct': '明确直连', 'manual': '手动设置', 'auto': '系统代理'}[mode]
    if mode == 'manual':
        address = settings.get('url', '').strip()
        if not address:
            raise RuntimeError('请填写手动代理地址。')
        parsed = urlsplit(address)
        if parsed.username is not None or parsed.password is not None:
            raise RuntimeError('手动代理地址不支持用户名或密码，请使用本机无认证代理端口。')
        values = dict.fromkeys(['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'], address)
        values['NO_PROXY'] = 'localhost,127.0.0.1,::1'
    elif mode == 'inherit':
        values = inherited
    elif mode == 'auto':
        for prefix, key, scheme in [('HTTP', 'HTTP_PROXY', 'http'), ('HTTPS', 'HTTPS_PROXY', 'http'),
                                    ('SOCKS', 'ALL_PROXY', 'socks5h')]:
            if system.get(prefix + 'Enable') == '1':
                host = system.get(prefix + 'Proxy', '')
                if ':' in host and not host.startswith('['):
                    host = '[' + host + ']'
                values[key] = f'{scheme}://{host}:{system.get(prefix + "Port", "")}'
        if values:
            values['NO_PROXY'] = ','.join(system['exceptions'])
        else:
            values = inherited
            source = '系统未设置代理；回退到应用启动环境'
    safe = {}
    for key, value in values.items():
        if not value:
            continue
        if key != 'NO_PROXY':
            try:
                u = urlsplit(value)
                if u.scheme not in ['http', 'https', 'socks5', 'socks5h'] or not u.hostname or not u.port \
                        or u.path not in ['', '/'] or u.query or u.fragment:
                    raise ValueError()
                host = '[' + u.hostname + ']' if ':' in u.hostname else u.hostname
                safe[key] = f'{u.scheme}://{host}:{u.port}'
            except ValueError:
                raise RuntimeError(f'{key}必须为带端口的HTTP/HTTPS/SOCKS5代理地址。') from None
        else:
            safe[key] = value
        env[key] = env[key.lower()] = value
    # Model traffic is determined by this environment, not by a persisted system-proxy flag.
    report = {'checked_at': now(), 'mode': mode, 'source': source, 'system_proxy': system,
              'cli_proxy_environment': safe, 'messages': [f'代理来源：{source}',
              '注入CLI：' + ('；'.join(f'{k}={v}' for k, v in safe.items()) or '无代理变量（直连）')],
              'authenticated_websocket_verified': False, 'model_inference_performed': False}
    if system.get('ExcludeSimpleHostnames') == '1':
        report['messages'].append('系统“排除简单主机名”规则未转换；OpenAI完整域名不属于简单主机名。')
    return env, report


def check_proxy_transport(env, report):
    """Check endpoints and an unauthenticated upgrade, outside measured model turns."""
    endpoints = set()
    for key in ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY']:
        value = env.get(key)
        if value:
            u = urlsplit(value)
            endpoints.add((u.hostname, u.port))
    report['proxy_ports'] = []
    for host, port in sorted(endpoints):
        try:
            with socket.create_connection((host, port), timeout=3):
                pass
            item = {'host': host, 'port': port, 'reachable': True}
        except OSError as error:
            item = {'host': host, 'port': port, 'reachable': False, 'error_type': type(error).__name__}
        report['proxy_ports'].append(item)
        report['messages'].append(f'代理端口 {host}:{port}：' + ('可达' if item['reachable'] else '不可达'))
    if any(not item['reachable'] for item in report['proxy_ports']):
        report['messages'].append('代理端口不可达，未启动Codex。')
        return False
    selected = env.get('HTTPS_PROXY') or env.get('ALL_PROXY')
    safe = report['cli_proxy_environment']
    report['probe_proxy'] = safe.get('HTTPS_PROXY') or safe.get('ALL_PROXY')
    report['messages'].append('HTTPS探测配置：' + (report['probe_proxy'] or '直连'))
    # Force the same selected URL even when curl's own proxy precedence differs.
    args = ['/usr/bin/curl', '--disable', '--silent', '--show-error', '--http1.1',
            '--connect-timeout', '5', '--max-time', '12', '--output', '/dev/null',
            '--write-out', '%{http_code} %{http_connect} %{time_total} %{remote_ip}',
            '--proxy', selected or '', '--noproxy', env.get('NO_PROXY', ''),
            '--header', 'Connection: Upgrade', '--header', 'Upgrade: websocket',
            '--header', 'Sec-WebSocket-Version: 13',
            '--header', 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
            'https://chatgpt.com/backend-api/codex/responses']
    if env.get('CODEX_CA_CERTIFICATE') or env.get('SSL_CERT_FILE'):
        args[2:2] = ['--cacert', env.get('CODEX_CA_CERTIFICATE') or env['SSL_CERT_FILE']]
    try:
        reply = subprocess.run(args, env=env, capture_output=True, text=True, timeout=15)
        fields = reply.stdout.split()
        code = int(fields[0]) if len(fields) >= 3 else 0
        tunnel = int(fields[1]) if len(fields) >= 3 else 0
        report['websocket_probe'] = {'exit_code': reply.returncode, 'http_status': code,
            'connect_status': tunnel, 'seconds': float(fields[2]) if len(fields) >= 3 else None,
            'remote_ip': fields[3] if len(fields) >= 4 else None,
            'credentials_sent': False, 'upgrade_accepted': code == 101}
        if tunnel:
            report['messages'].append(f'HTTP代理CONNECT隧道：{tunnel}')
        elif code and selected and urlsplit(selected).scheme in ['http', 'https']:
            report['messages'].append('HTTP代理未建立CONNECT隧道；可能被NO_PROXY绕过，探测没有证明使用了所选代理。')
        if code == 101:
            report['messages'].append('匿名WebSocket升级成功；正式登录会话仍需实际任务确认。')
        elif code:
            report['messages'].append(f'握手探测收到HTTP {code}；不代表正式WebSocket可用（本探测不发送登录凭据）。')
        else:
            report['messages'].append(f'握手探测未收到HTTP响应（curl退出码{reply.returncode}）。')
    except (OSError, subprocess.TimeoutExpired):
        report['websocket_probe'] = {'error': '连接探测未完成', 'credentials_sent': False}
        report['messages'].append('握手探测未完成；不能确认HTTPS/WebSocket通路。')
    report['messages'].append('curl探测只验证其自身路径；CLI实际选路与正式WebSocket兼容性未证实。')
    return True


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.replace(path)


def status(phase, message, **extra):
    STATE.update(phase=phase, message=message, updated_at=now(), **extra)
    if DATA:
        write_json(DATA / 'status.json', STATE)
    print(json.dumps(STATE, ensure_ascii=False), flush=True)


def locate_codex():
    candidates = [shutil.which('codex'),
        '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
        '/Applications/Codex.app/Contents/Resources/codex',
        '/opt/homebrew/bin/codex', '/usr/local/bin/codex']
    for path in candidates:
        if path and Path(path).is_file() and os.access(path, os.X_OK):
            return str(Path(path).resolve())
    raise RuntimeError('未找到 Codex CLI。请先确认桌面应用或 Codex CLI 已安装。')


def connect(executable=None, proxy=None, effort='high'):
    global CONNECTION, NETWORK
    env, NETWORK = proxy_environment(proxy)
    reachable = check_proxy_transport(env, NETWORK)
    if DATA:
        write_json(DATA / 'network-diagnostics.json', NETWORK)
    status('settling', '代理检测已记录；尚未调用模型。', network=NETWORK)
    if not reachable:
        raise RuntimeError('代理端口不可达，请修改代理设置后重新检查环境。')
    binary = executable or locate_codex()
    cmd = [binary, 'app-server', '--stdio', '-c', f'model_reasoning_effort="{effort}"',
           '-c', 'service_tier="default"', '-c', 'forced_login_method="chatgpt"',
           '-c', 'model_provider="openai"',
           '-c', 'web_search="disabled"', '-c', 'features.memories=false',
           '-c', 'features.multi_agent=false', '-c', 'features.plugins=false',
           '-c', 'features.apps=false', '-c', 'features.browser_use=false',
           '-c', 'features.computer_use=false', '-c', 'features.skip_host_skill_discovery=true',
           '-c', 'project_doc_max_bytes=0', '-c', 'features.respect_system_proxy=false',
           '-c', 'features.system_proxy_fallback=false']
    # Disable user-configured MCPs for this process only; never modify config.toml.
    config_home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    config_file = config_home / 'config.toml'
    if config_file.exists():
        config = tomllib.loads(config_file.read_text())
        for name in config.get('mcp_servers', {}):
            cmd.extend(['-c', 'mcp_servers.' + name + '.enabled=false'])
    errors = open(DATA / 'runner-errors.txt', 'a') if DATA else subprocess.DEVNULL
    process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=errors, text=True, bufsize=1, start_new_session=True, env=env)
    NETWORK.update(cli_path=binary, cli_pid=process.pid, cli_environment_injected=True,
                   cli_system_proxy_flags={'respect_system_proxy':False,'system_proxy_fallback':False})
    if DATA:
        write_json(DATA / 'network-diagnostics.json', NETWORK)
    CONNECTION = {'process': process, 'queue': queue.Queue(), 'pending': [], 'seq': 0,
                  'stderr': errors, 'binary': binary}
    inbox = CONNECTION['queue']
    def read():
        for line in process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            inbox.put((time.monotonic(), message))
        inbox.put((time.monotonic(), {'closed': True}))
    threading.Thread(target=read, daemon=True).start()
    rpc('initialize', {'clientInfo': {'name': 'local_quota_benchmark_app', 'version': '1.0'},
        'capabilities': {'experimentalApi': True}})
    process.stdin.write('{"method":"initialized"}\n')
    process.stdin.flush()
    account = rpc('account/read', {'refreshToken': False})
    if (account.get('account') or {}).get('type') != 'chatgpt':
        raise RuntimeError('需要 ChatGPT 登录。应用不使用 API Key，也不会切换为 API 计费。')
    return binary


def disconnect():
    process = CONNECTION.get('process')
    if process:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
    output = CONNECTION.get('stderr')
    if hasattr(output, 'close'):
        output.close()


def send(method, params=None):
    CONNECTION['seq'] += 1
    identity = CONNECTION['seq']
    message = {'id': identity, 'method': method}
    if params is not None:
        message['params'] = params
    pipe = CONNECTION['process'].stdin
    pipe.write(json.dumps(message) + '\n')
    pipe.flush()
    return identity


def rpc(method, params=None, timeout=30):
    identity = send(method, params)
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if method == 'account/rateLimits/read' and control() == 'stop':
            raise RuntimeError('用户立即停止')
        try:
            stamped = CONNECTION['queue'].get(timeout=min(1, max(.01, end-time.monotonic())))
        except queue.Empty:
            continue
        message = stamped[1]
        if message.get('closed'):
            raise RuntimeError('Codex 本地连接已关闭。')
        if message.get('id') == identity:
            if 'error' in message:
                raise RuntimeError(f'{method}: {message["error"].get("message", "请求失败")}')
            return message.get('result', {})
        CONNECTION['pending'].append(stamped)
    raise RuntimeError(f'本地请求超时：{method}')


def limits():
    deadline=time.monotonic()+45
    for attempt in range(5):
        if control() == 'stop':
            raise RuntimeError('用户立即停止')
        try:
            raw=rpc('account/rateLimits/read', {'supportsLunaReserve':False,
                'excludeResetCreditDetails':True}, timeout=max(.1,min(15,deadline-time.monotonic())))
            break
        except RuntimeError as error:
            if str(error)=='用户立即停止' or '本地连接已关闭' in str(error):
                raise
            if DATA:
                with open(DATA/'quota-read-errors.jsonl','a') as stream:
                    stream.write(json.dumps({'at':now(),'attempt':attempt+1,'error':str(error)},ensure_ascii=False)+'\n')
            if attempt==4 or time.monotonic()>=deadline:
                raise RuntimeError('额度读取连续失败，自动重试仍未恢复，已安全暂停。请检查网络后重测未完成模型。') from error
            status('retrying',f'额度读取暂时失败，自动重试 {attempt+1}/4；不会重新启动任务。')
            delay=min(2**attempt,max(0,deadline-time.monotonic()))
            for _ in range(int(delay*10)):
                if control()=='stop':raise RuntimeError('用户立即停止')
                time.sleep(.1)
    # Account ID, card identifiers and authentication material are not exported.
    pools = raw.get('rateLimitsByLimitId') or {'codex': raw.get('rateLimits', {})}
    keep = ['limitId', 'limitName', 'normalModelSlug', 'primary', 'secondary',
            'credits', 'spendControlReached', 'rateLimitReachedType', 'planType']
    return {'observed_at': now(), 'ordinaryUsageAllowed': raw.get('ordinaryUsageAllowed'),
        'pools': {name: {key: pool.get(key) for key in keep} for name, pool in pools.items()}}


def balance(snapshot):
    credits = snapshot['pools'].get('codex', {}).get('credits') or {}
    value = credits.get('balance')
    return Decimal(value) if value is not None else None


def counts(snapshot):
    pool = snapshot['pools'].get('codex', {})
    return {'five_hour': (pool.get('primary') or {}).get('usedPercent'),
            'weekly': (pool.get('secondary') or {}).get('usedPercent')}


def gate(snapshot, during=False):
    main = snapshot['pools'].get('codex', {})
    values = counts(snapshot)
    if any(values[k] is None for k in ['five_hour', 'weekly']) or balance(snapshot) is None:
        return '无法核对额度或积分余额，已暂停。'
    if snapshot.get('ordinaryUsageAllowed') is False or main.get('rateLimitReachedType'):
        return '订阅额度已不可用，已暂停。'
    if main.get('spendControlReached'):
        return '账户用量限制已触发，已暂停。'
    if values['five_hour'] >= (95 if during else 85) or values['weekly'] >= (98 if during else 90):
        return '额度接近边界，已暂停；请在额度恢复后手动继续。'
    return None


def quota_delta(before, after):
    result = {}
    valid = True
    ended = datetime.fromisoformat(after['observed_at']).timestamp()
    for name, pool in before['pools'].items():
        other = after['pools'].get(name, {})
        result[name] = {}
        for window in ['primary', 'secondary']:
            a, b = pool.get(window), other.get(window)
            if not a or not b:
                continue
            changed = a.get('resetsAt') != b.get('resetsAt')
            delta = b['usedPercent'] - a['usedPercent']
            # Empty windows can acquire a start anchor when first charged. This
            # is distinguishable from a scheduled reset falling inside the run.
            initialized = changed and a['usedPercent'] == 0 and delta >= 0 and \
                min(a.get('resetsAt') or 0, b.get('resetsAt') or 0) > ended
            # The interface can round the same future reset boundary a second
            # differently. Never tolerate a passed boundary or a counter drop.
            jitter = changed and delta >= 0 and a.get('resetsAt') is not None and \
                b.get('resetsAt') is not None and abs(a['resetsAt'] - b['resetsAt']) <= 1 and \
                min(a['resetsAt'], b['resetsAt']) > ended and \
                a.get('windowDurationMins') == b.get('windowDurationMins')
            unused = name != 'codex' and a['usedPercent'] == b['usedPercent'] == 0
            compatible = delta >= 0 and (not changed or initialized or jitter or unused)
            result[name][window] = {'delta_pp': delta,
                'window_minutes': a.get('windowDurationMins'), 'comparable': compatible,
                'anchor_initialized': initialized, 'reset_timestamp_jitter': jitter, 'before': a, 'after': b}
            if name == 'codex' or delta != 0:
                valid = valid and compatible
    return result, valid


def stable_key(snapshot):
    return (str(balance(snapshot)), tuple(sorted((name, key, window['usedPercent'],
        window.get('windowDurationMins'))
        for name, pool in snapshot['pools'].items()
        for key in ['primary', 'secondary'] if (window := pool.get(key)))))


def settle(reference=None, seconds=15, maximum=60):
    started = time.monotonic()
    previous = None
    equal = 0
    reads = []
    while time.monotonic() - started < maximum:
        current = limits()
        reads.append(current)
        if reference is not None and (balance(reference) != balance(current) or
                                      not quota_delta(reference, current)[1]):
            return current, False, reads
        key = stable_key(current)
        equal = equal + 1 if key == previous else 1
        previous = key
        if equal >= 3 and time.monotonic() - started >= seconds:
            return current, True, reads
        time.sleep(3)
    return current, False, reads


def probe(proxy=None):
    binary = connect(proxy=proxy)
    catalog = rpc('model/list', {'limit': 100, 'includeHidden': True})
    available = {row['model']: [x['reasoningEffort'] for x in row['supportedReasoningEfforts']]
                 for row in catalog.get('data', [])}
    snapshot = limits()
    NETWORK['account_rate_limits_read_success'] = True
    answer = {'cli_path': binary, 'cli_version': subprocess.check_output([binary, '--version'],
        text=True).strip(), 'login': 'ChatGPT', 'models': available,
        'limits': snapshot, 'network': NETWORK, 'checked_at': now(), 'model_inference_performed': False}
    NETWORK['messages'].append('CLI账户额度读取成功（未调用模型；不证明模型WebSocket可用）。')
    write_json(DATA / 'network-diagnostics.json', NETWORK)
    write_json(DATA / 'environment.json', answer)
    status('ready', '环境检查完成；尚未调用模型。', environment=answer)
    return answer


def fixture(folder, task):
    folder.mkdir(parents=True)
    if task == 'T2':
        (folder / 'meter.py').write_text(SUITE['source'])
        (folder / 'test_meter.py').write_text(SUITE['tests'])


def control():
    if STOP:
        return 'stop'
    if EXPECTED_PARENT and os.getppid() != EXPECTED_PARENT:
        return 'stop'
    file = DATA / 'control.json'
    if file.exists():
        try:
            return json.loads(file.read_text()).get('action')
        except (ValueError, OSError):
            return None


def log_event(method, params, elapsed):
    # Preserve timing and tool evidence, never private reasoning event payloads.
    allowed = {'item/started', 'item/completed', 'item/agentMessage/delta',
        'thread/tokenUsage/updated', 'turn/started', 'turn/completed', 'error'}
    if method not in allowed:
        return
    item = params.get('item', {})
    if item.get('type') in ['reasoning', 'compaction']:
        return
    with open(DATA / 'events.jsonl', 'a') as stream:
        stream.write(json.dumps({'at': now(), 'elapsed_seconds': round(elapsed, 4),
            'method': method, 'params': params}, ensure_ascii=False) + '\n')


def execute_round(tasks, model, repeat, session, baseline, tier='default', effort='high'):
    """Start all tasks, multiplex their events, then join the whole round."""
    states = {}
    round_id = uuid.uuid4().hex
    inflight = DATA / 'current-attempts.json'
    records = []
    before = baseline
    fault = None

    def persist():
        write_json(inflight, {'round_id': round_id, 'attempts': records})

    def cancel_all(reason):
        for state in states.values():
            record = state['record']
            if not state['finished'] and record.get('turn_id') and state['cancelled_at'] is None:
                record['interrupted_reason'] = record['interrupted_reason'] or reason
                send('turn/interrupt', {'threadId': record['thread_id'], 'turnId': record['turn_id']})
                state['cancelled_at'] = time.monotonic()

    try:
        # Create separate workspaces and contexts before sending any paid prompts.
        for task in tasks:
            folder = DATA / 'workspaces' / (f'R{repeat}-{task["id"]}-{model}-' + uuid.uuid4().hex[:8])
            fixture(folder, task['id'])
            params = {'model': model, 'allowProviderModelFallback': False, 'serviceTier': tier,
                'cwd': str(folder), 'approvalPolicy': 'never',
                'sandbox': 'workspace-write' if task['id']=='T2' else 'read-only',
                'baseInstructions': SUITE['base_instructions'], 'ephemeral': True,
                'developerInstructions': 'Use only the supplied task and current directory. '
                    f'No memories, subagents, skills or external services. Reasoning effort is {effort}.'}
            if task['id']!='T2': params.update(environments=[], selectedCapabilityRoots=[])
            thread = rpc('thread/start', params)
            accepted_tiers = ['fast', 'priority'] if tier == 'fast' else ['default']
            if thread.get('model')!=model or thread.get('serviceTier') not in accepted_tiers:
                raise RuntimeError('模型或速度模式不一致，已暂停。')
            record = {'attempt_id': uuid.uuid4().hex, 'label':f'R{repeat}-{task["id"]}-{model}',
                'task':task['id'], 'task_name':task['name'], 'model':model, 'repeat':repeat,
                'thread_id':thread['thread']['id'], 'effort':effort, 'service_tier':tier,
                'reported_service_tier':thread['serviceTier'],
                'round_id':round_id, 'concurrent_tasks':len(tasks),
                'quota_scope':'model_tier_batch_only' if session.get('config',{}).get('service_tier')=='mixed' else 'model_batch_only',
                'prompt_sha256':hashlib.sha256(task['prompt'].encode()).hexdigest(),
                'valid':False, 'response':'', 'tool_calls':0, 'interrupted_reason':None,
                'status':'not_started', 'turn_start_sent':False}
            records.append(record)
            states[record['thread_id']] = {'record':record, 'task':task, 'folder':folder,
                'started':None, 'phases':{}, 'texts':{}, 'finished':None, 'cancelled_at':None,
                'first_visible':None, 'first_answer':None}
        before=limits()
        if balance(before)!=balance(baseline) or not quota_delta(baseline,before)[1]:
            raise RuntimeError('整模型批次的积分余额或额度窗口已变化，已暂停。')
        reason=gate(before, during=True)
        if reason: raise RuntimeError(reason)
        CONNECTION['pending'].clear()
        for state in states.values():
            if control()=='stop': raise RuntimeError('用户立即停止')
            record=state['record'];task=state['task']
            record.update(before=before, started_at=now(), status='running', turn_start_sent=True)
            state['started']=time.monotonic()
            persist()
            params={'threadId':record['thread_id'],'model':model,'effort':effort,
                'serviceTierForTurn':tier,'input':[{'type':'text','text':task['prompt']}]}
            if task['id']!='T2': params['environments']=[]
            result=rpc('turn/start',params)
            record['turn_id']=result['turn']['id']
        persist()
        status('running',f'{model} · 第{repeat}轮 · {tier} · {len(tasks)}项并行执行',
            current_model=model,current_task=f'本轮{len(tasks)}项并行',repeat=repeat,
            active_tasks=len(tasks),elapsed_seconds=0)
        next_poll=time.monotonic()+5
        missing_tokens_at=None
        while True:
            done=all(s['finished'] for s in states.values())
            tokens_ready=all((s['record'].get('tokens') or {}).get('total',{}).get('inputTokens',0)>0 and
                (s['record'].get('tokens') or {}).get('total',{}).get('outputTokens',0)>0 for s in states.values())
            if done and (tokens_ready or fault): break
            if done and missing_tokens_at is None: missing_tokens_at=time.monotonic()
            if missing_tokens_at and time.monotonic()-missing_tokens_at>20:
                fault='回合已结束，但未收到完整token用量，已暂停。';break
            try:
                stamped=CONNECTION['pending'].pop(0) if CONNECTION['pending'] else CONNECTION['queue'].get(timeout=.5)
            except queue.Empty: stamped=None
            if stamped:
                received,message=stamped
                if message.get('closed'): raise RuntimeError('Codex 本地连接已关闭。')
                method=message.get('method','');p=message.get('params',{})
                state=states.get(p.get('threadId'))
                if state is not None:
                    record=state['record'];elapsed=max(0,received-state['started'])
                    log_event(method,p,elapsed)
                    if method=='turn/started':
                        record.setdefault('turn_id',p.get('turn',{}).get('id'))
                    elif method in ['item/started','item/completed']:
                        item=p.get('item',{})
                        if item.get('type')=='agentMessage':
                            identity=item['id'];state['phases'][identity]=item.get('phase')
                            if method=='item/completed':state['texts'][identity]=item.get('text','')
                            if item.get('text'):
                                if state['first_visible'] is None:state['first_visible']=elapsed
                                if item.get('phase')=='final_answer' and state['first_answer'] is None:state['first_answer']=elapsed
                        elif method=='item/started' and item.get('type') in ['commandExecution','fileChange','mcpToolCall','dynamicToolCall']:
                            record['tool_calls']+=1
                    elif method=='item/agentMessage/delta' and p.get('delta'):
                        identity=p['itemId'];state['texts'][identity]=state['texts'].get(identity,'')+p['delta']
                        if state['first_visible'] is None:state['first_visible']=elapsed
                        if state['phases'].get(identity)=='final_answer' and state['first_answer'] is None:state['first_answer']=elapsed
                    elif method=='thread/tokenUsage/updated':record['tokens']=p.get('tokenUsage')
                    elif method=='turn/completed' and p.get('turn',{}).get('id')==record.get('turn_id'):
                        state['finished']=p['turn'];record['elapsed_seconds']=round(elapsed,4)
                        record.update(status=p['turn'].get('status'),ended_at=now())
                        if record['status']!='completed':
                            detail=(p['turn'].get('error') or {}).get('message')
                            fault=record['interrupted_reason'] or (
                                f'{model} 第{repeat}轮「{record["task_name"]}」失败：{detail}' if detail else
                                '本轮有任务未完成，已停止其他在途任务。')
                    elif method=='error':record.setdefault('errors',[]).append(p)
                elif method=='error':fault='收到无法归属到任务的执行错误，整轮已暂停。'
                if 'id' in message and 'method' in message:
                    pipe=CONNECTION['process'].stdin
                    pipe.write(json.dumps({'id':message['id'],'result':{'decision':'decline'}})+'\n');pipe.flush()
            if control()=='stop':fault=fault or '用户立即停止'
            if any(s['started'] and not s['finished'] and time.monotonic()-s['started']>600 for s in states.values()):
                fault=fault or '本轮有任务超过十分钟，已停止所有在途任务。'
            if fault:cancel_all(fault)
            if any(s['cancelled_at'] and not s['finished'] and time.monotonic()-s['cancelled_at']>20 for s in states.values()):
                raise RuntimeError('停止确认超时，整轮作废。')
            if not done and time.monotonic()>=next_poll and not fault:
                current=limits()
                reason='积分余额发生变化，已停止整轮。' if balance(current)!=balance(before) else gate(current,True)
                if not quota_delta(baseline,current)[1]:reason=reason or '额度窗口变化，已停止整轮。'
                if reason:fault=reason;cancel_all(reason)
                active=sum(not s['finished'] for s in states.values())
                for state in states.values():
                    if not state['finished']:state['record']['elapsed_seconds']=round(time.monotonic()-state['started'],1)
                persist()
                status('running',f'{model} · 第{repeat}轮 · {tier} · {active}项进行中，{len(tasks)-active}项已结束',
                    current_model=model,current_task=f'本轮{len(tasks)}项并行',repeat=repeat,
                    active_tasks=active,limits=current)
                next_poll=time.monotonic()+5
        after=limits() if not fault else None
    except Exception as error:
        fault=fault or str(error)
        try:cancel_all(fault)
        except (OSError,RuntimeError):pass
        after=None
    if after is None:
        # Do not synthesize a final meter reading when the transport is unavailable.
        comparable=False;unchanged=None
    else:
        comparable=quota_delta(baseline,after)[1]
        unchanged=balance(before)==balance(after)
        if not comparable and not fault:
            fault='额度窗口变化或读数回退，无法连续比较，已暂停；当前模型整批需重测。'
    answers=DATA/'answers';answers.mkdir(exist_ok=True)
    for state in states.values():
        record=state['record'];task=state['task'];texts=state['texts']
        final_ids=[i for i,phase in state['phases'].items() if phase=='final_answer']
        record.update(first_visible_seconds=state['first_visible'],first_answer_seconds=state['first_answer'],
            response='\n\n'.join(texts[i] for i in final_ids or texts if texts.get(i)))
        if not state['finished']:
            record.update(status='interrupted' if record['turn_start_sent'] else 'not_started',
                interrupted_reason=fault or '本轮未完成')
        record['round_after']=after
        record['round_error']=fault
        record['credit_balance_unchanged']=unchanged
        record['valid']=record['status']=='completed' and bool(record['response']) and bool(record.get('tokens')) and \
            not record['interrupted_reason'] and not fault and comparable and unchanged
        if task['id']=='T2' and record['status']=='completed':
            test=subprocess.run([sys.executable,'-m','unittest','-v'],cwd=state['folder'],
                text=True,capture_output=True,timeout=20)
            record['checks']={'test_exit_code':test.returncode,'test_output':test.stdout+test.stderr,
                'test_file_unchanged':(state['folder']/'test_meter.py').read_text()==SUITE['tests'],
                'modified_source':(state['folder']/'meter.py').read_text()}
        elif task['id']=='T3' and record['status']=='completed':
            body=record['response'].strip()
            if body.startswith('```'):body=body.split('\n',1)[1].rsplit('```',1)[0].strip()
            try:
                record['checks']={'reported_keys':sorted(x['key'] for x in json.loads(body)['issues']),
                    'expected_keys':SUITE['expected_string_keys']}
            except (ValueError,KeyError,TypeError) as error:record['checks']={'parse_error':str(error)}
        (answers/(record['attempt_id']+'.md')).write_text(record['response'])
        session['attempts'].append(record)
        try:rpc('thread/unsubscribe',{'threadId':record['thread_id']},timeout=5)
        except RuntimeError:pass
    write_json(DATA/'session.json',session)
    inflight.unlink(missing_ok=True)
    return records


def validate_config(config):
    models=config.get('models', [])
    tasks=config.get('tasks', [])
    if not models or len(models)!=len(set(models)) or any(x not in SUITE['models'] for x in models):
        raise RuntimeError('模型选择无效。')
    if not tasks or len(tasks)!=len(set(tasks)) or any(x not in [t['id'] for t in SUITE['tasks']] for x in tasks):
        raise RuntimeError('任务选择无效。')
    if not isinstance(config.get('repeats'), int) or not 1<=config['repeats']<=20:
        raise RuntimeError('重复次数必须为 1～20。')
    if config.get('effort') not in ['high','sol_low_luna_medium'] or config.get('service_tier') not in ['default','mixed']:
        raise RuntimeError('思考档位或速度模式无效。')
    if config['service_tier']=='mixed' and config['repeats']%2:
        raise RuntimeError('Standard/Fast 对比需要偶数轮，两种模式各占一半。')
    if config.get('isolation_confirmed') is not True:
        raise RuntimeError('请先确认测试期间不使用同账户的其他 Codex/Work 任务。')
    if config.get('measurement_strategy') != 'complete_model_batch':
        raise RuntimeError('请选择新版本的整模型批次计划。')
    if config.get('execution_mode') != 'parallel_tasks_per_round':
        raise RuntimeError('串行测试记录不能续接到每轮并行模式，请开始新测试。')


def run(config_file, resume):
    config=json.loads(Path(config_file).read_text())
    validate_config(config)
    (DATA/'control.json').unlink(missing_ok=True)
    connect(proxy=config.get('proxy'),effort='low' if config['effort']=='sol_low_luna_medium' else 'high')
    catalog=rpc('model/list', {'limit':100, 'includeHidden':True})
    for model in config['models']:
        row=next((x for x in catalog['data'] if x['model']==model), None)
        effort=('low' if model.endswith('-sol') else 'medium') if config['effort']=='sol_low_luna_medium' else 'high'
        if not row or effort not in [x['reasoningEffort'] for x in row['supportedReasoningEfforts']]:
            raise RuntimeError(f'{model} 未在当前模型目录中声明支持 {effort}，已暂停。')
        tiers=row.get('serviceTiers',[])
        if config['service_tier']=='mixed' and tiers and not any(
                item.get('id') in ['fast','priority'] for item in tiers):
            raise RuntimeError(f'{model} 未在当前模型目录中声明支持 Fast，尚未开始测试。')
    file=DATA/'session.json'
    fingerprint=hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    if resume:
        session=json.loads(file.read_text())
        if session.get('schema_version') != 3:
            raise RuntimeError('旧串行日志不能续接到并行模式，请开始新测试。')
        if session['config_hash']!=fingerprint:
            raise RuntimeError('继续测试时不能修改原始测试计划。')
        if session['suite_sha256']!=hashlib.sha256((HERE/'suite.json').read_bytes()).hexdigest():
            raise RuntimeError('测试材料已经变化，不能继续旧记录；请创建新测试。')
        if session.get('current_group'):
            session['current_group']['complete']=False
            session['current_group']['valid']=False
            session['groups'].append(session.pop('current_group'))
        inflight=DATA/'current-attempt.json'
        if inflight.exists():
            abandoned=json.loads(inflight.read_text())
            abandoned.update(valid=False, status='interrupted', interrupted_reason=abandoned.get('interrupted_reason') or '上次进程中断；从新会话和原始文件重做。')
            session['attempts'].append(abandoned)
            write_json(file,session)
            inflight.unlink()
        parallel_file=DATA/'current-attempts.json'
        if parallel_file.exists():
            saved=json.loads(parallel_file.read_text())
            known={a['attempt_id'] for a in session['attempts']}
            for abandoned in saved.get('attempts',[]):
                if abandoned['attempt_id'] not in known:
                    abandoned.update(valid=False,status='interrupted',
                        interrupted_reason=abandoned.get('interrupted_reason') or '上次并行轮次中断；整模型批次需重测。')
                    session['attempts'].append(abandoned)
            write_json(file,session);parallel_file.unlink()
        completed_ids={identity for g in session['groups'] if g.get('complete') and g.get('valid')
            for identity in g['attempt_ids']}
        for attempt in session['attempts']:
            if attempt['attempt_id'] not in completed_ids:
                attempt['individual_measurement_valid']=attempt.get('individual_measurement_valid',attempt.get('valid',False))
                attempt['valid']=False
                attempt['excluded_reason']='模型整批未完成；保留原始记录，继续时重跑该模型全部任务。'
        write_json(file,session)
    else:
        if file.exists():
            raise RuntimeError('该日志目录已有测试数据；请创建新测试或继续原测试。')
        session={'schema_version':3, 'started_at':now(), 'config':config, 'config_hash':fingerprint,
            'suite_sha256':hashlib.sha256((HERE/'suite.json').read_bytes()).hexdigest(),
            'suite':SUITE, 'attempts':[], 'groups':[], 'measurement_policy':{
                'no_ai_controller':True,'account_global_quota':True,'other_usage_must_be_paused':True,
                'measurement_strategy':'complete_model_batch',
                'quota_basis':'one start/end difference per model and service tier batch',
                'execution_mode':'parallel_tasks_per_round','concurrency':len(config['tasks']),
                'round_barrier':True,'one_shared_quota_monitor':True,
                'incomplete_model_batch_restarted':True,
                'no_automatic_credit_purchase':True,'no_reset_card_consumption':True,
                'quota_polling_is_not_a_server_side_credit_block':True}}
        write_json(file,session)
    total=len(config['models'])*len(config['tasks'])*config['repeats']
    completed=lambda:sum(a.get('valid',False) for a in session['attempts'])
    status('settling', '正在检查独立测量的起始额度。', completed=completed(), total=total)
    before, stable, reads=settle()
    if not stable:
        raise RuntimeError('起始额度读数未稳定；请检查同账户其他任务是否已暂停。')
    reason=gate(before)
    if reason:
        raise RuntimeError(reason)
    NETWORK['account_rate_limits_read_success'] = True
    write_json(DATA / 'network-diagnostics.json', NETWORK)
    session.setdefault('starts',[]).append({'at':now(),'snapshot':before,'idle_reads':reads,
        'network':copy.deepcopy(NETWORK)})
    write_json(file,session)
    half=config['repeats']//2
    tiers=[('default',range(1,half+1)),('fast',range(half+1,config['repeats']+1))] \
        if config['service_tier']=='mixed' else [('default',range(1,config['repeats']+1))]
    for model in config['models']:
        effort=('low' if model.endswith('-sol') else 'medium') if config['effort']=='sol_low_luna_medium' else 'high'
        for tier,rounds in tiers:
            if any(g.get('complete') and g.get('valid') and g['model']==model and
                   g.get('service_tier','default')==tier for g in session['groups']):
                continue
            if control() in ['pause','stop']:
                raise RuntimeError('已暂停；继续时只重跑未完成的速度模式批次。')
            jobs=[(repeat,task) for repeat in rounds
                  for task in SUITE['tasks'] if task['id'] in config['tasks']]
            group_start=limits()
            if balance(group_start)!=balance(before):
                raise RuntimeError('积分余额在测试间隔内变化，已暂停。')
            reason=gate(group_start, during=True)
            if reason:
                raise RuntimeError(reason)
            group={'batch_id':uuid.uuid4().hex,'model':model,'service_tier':tier,
                'repeats':len(rounds),'expected_samples':len(jobs),'before':group_start,
                'attempt_ids':[],'started_at':now(),
                'planned_jobs':[{'task':t['id'],'repeat':r} for r,t in jobs],
                'complete':False,'valid':False,'rounds':[]}
            session['current_group']=group
            write_json(file,session)
            try:
                for repeat in rounds:
                    if control() in ['pause','stop']:
                        raise RuntimeError('已暂停；当前速度模式批次未完成，继续时从头重跑该批次。')
                    tasks=[task for task in SUITE['tasks'] if task['id'] in config['tasks']]
                    status('running',f'{model} · 第{repeat}轮 · {tier} · 准备{len(tasks)}项并行',completed=completed(),
                        total=total,current_model=model,current_task=f'{tier} · 本轮{len(tasks)}项并行',repeat=repeat)
                    round_start=now()
                    records=execute_round(tasks,model,repeat,session,group_start,tier,effort)
                    for record in records:
                        record['batch_id']=group['batch_id'];group['attempt_ids'].append(record['attempt_id'])
                    group['rounds'].append({'repeat':repeat,'started_at':round_start,'ended_at':now(),
                        'attempt_ids':[record['attempt_id'] for record in records],
                        'concurrent_tasks':len(tasks),'all_finished':all(record['status']=='completed' for record in records)})
                    write_json(file,session)
                    if len(records)!=len(tasks) or not all(record['valid'] for record in records):
                        reason=next((record.get('round_error') for record in records
                                     if record['status']=='failed' and record.get('round_error')),None)
                        reason=reason or next((record['interrupted_reason'] for record in records
                                               if record['interrupted_reason']),None)
                        raise RuntimeError(reason or '本轮有任务或用量记录不完整，已暂停；当前速度模式批次需重测。')
                    status('running',f'第{repeat}轮全部结束并保存；准备下一轮。',
                        completed=completed(),total=total,elapsed_seconds=0,active_tasks=0)
                status('settling',f'{model} · {tier} 全部轮次已结束，正在读取整批最终额度。',active_tasks=0)
                group_after,stable,reads=settle(group_start)
                group['after']=group_after;group['settlement_reads']=reads;group['settled']=stable
                group['quota_delta'],comparable=quota_delta(group_start,group_after)
                group['complete']=len(group['attempt_ids'])==len(jobs)
                group['valid']=group['complete'] and stable and comparable and balance(group_after)==balance(group_start)
                write_json(file,session)
                if not group['valid']:raise RuntimeError('速度模式批次的最终额度无法稳定比较，已暂停。')
            except Exception:
                group['complete']=False;group['valid']=False
                for attempt in session['attempts']:
                    if attempt['attempt_id'] in group['attempt_ids']:
                        attempt['individual_measurement_valid']=attempt.get('valid',False)
                        attempt['valid']=False
                        attempt['excluded_reason']='速度模式批次未完成；保留记录，继续时重跑该批次全部任务。'
                session['groups'].append(group);session.pop('current_group',None);write_json(file,session)
                raise
            session['groups'].append(group);session.pop('current_group',None);write_json(file,session)
    session['finished_at']=now()
    session['final_snapshot']=limits()
    write_json(file,session)
    write_json(DATA/'manifest.json', {'schema_version':3,'started_at':session['started_at'],
        'finished_at':session['finished_at'],'samples':completed(),'total':total,
        'config':config,'data_files':['session.json','events.jsonl','answers/','network-diagnostics.json'],
        'conclusions_generated':False})
    status('completed','测试完成。请导出数据日志，交给分析者形成结论。',completed=completed(),total=total)


def main():
    global DATA,STOP,EXPECTED_PARENT
    parser=argparse.ArgumentParser()
    parser.add_argument('command', choices=['probe','run'])
    parser.add_argument('--data-dir', required=True)
    parser.add_argument('--config')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--parent-pid', type=int, default=0)
    parser.add_argument('--proxy-mode', choices=['auto','manual','inherit','direct'], default='auto')
    parser.add_argument('--proxy-url', default='')
    args=parser.parse_args()
    DATA=Path(args.data_dir).resolve();DATA.mkdir(parents=True,exist_ok=True)
    EXPECTED_PARENT=args.parent_pid
    lock=None
    def interrupted(signum, frame):
        global STOP
        STOP=True
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if args.command=='run':
            lock=open(DATA.parent/'.test-in-progress.lock','a')
            try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise RuntimeError('另一个独立测试正在运行，请先结束该测试。')
        if args.command=='probe':
            probe({'mode':args.proxy_mode,'url':args.proxy_url})
        else:
            run(args.config,args.resume)
    except Exception as error:
        status('paused' if args.command=='run' else 'error', str(error))
        return 1
    finally:
        disconnect()
        if lock:lock.close()
    return 0


if __name__=='__main__':
    sys.exit(main())
