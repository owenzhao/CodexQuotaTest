"""Build and package the local macOS application; does not launch it."""
from pathlib import Path
import plistlib
import os
import shutil
import subprocess
import time

source=Path(__file__).resolve().parent
version='1.3.13'
target=source/'build'/f'CodexQuotaTest-{version}.app'
app=source/'build'/'work'/'app-build'/target.name
if app.exists():shutil.rmtree(app)
mac=app/'Contents/MacOS'
resources=app/'Contents/Resources'
mac.mkdir(parents=True,exist_ok=True)
resources.mkdir(parents=True,exist_ok=True)
for name in ['runner.py','suite.json','defaults.json','AppIcon-v3.icns']:
    shutil.copy2(source/name,resources/name)
info={'CFBundleName':'Codex 额度测试','CFBundleDisplayName':f'Codex 额度测试 {version}',
    'CFBundleIdentifier':'com.parussoft.CodexQuotaTest','CFBundleExecutable':'CodexQuotaTest',
    'CFBundlePackageType':'APPL','CFBundleShortVersionString':version,'CFBundleVersion':'21',
    'CFBundleIconFile':'AppIcon-v3.icns',
    'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
cache=source/'build'/'work'/'swift-module-cache'
cache.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-O',
    '-module-cache-path',str(cache),
    '-target','arm64-apple-macosx14.0','-framework','SwiftUI','-framework','AppKit',
    str(source/'BenchmarkApp.swift'),'-o',str(mac/'CodexQuotaTest')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
if target.exists():
    backup=source/'build'/'work'/'app-backups'/(target.stem+'-'+str(time.time_ns())+'.app')
    backup.parent.mkdir(parents=True,exist_ok=True)
    target.rename(backup)
app.rename(target)
os.utime(target,None)
subprocess.run(['ditto','-c','-k','--keepParent',str(target),str(source/'build'/f'CodexQuotaTest-{version}.app.zip')],check=True)
print('Built and packaged:',target)
