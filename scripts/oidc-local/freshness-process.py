#!/usr/bin/env python3
"""Record/stop only the separate desktop regression app, preserving shared Kith."""
import json,os,pathlib,signal,subprocess,sys,time
os.umask(0o077)
root=pathlib.Path(__file__).resolve().parents[2]
state=root/'.oidc-local'
run=json.loads((state/'run.json').read_text())
assert run['worktree']==str(root)
def ps(pid,field):return subprocess.check_output(['ps','-p',str(pid),'-o',field+'='],text=True,stderr=subprocess.PIPE).strip()
record=state/'freshness-app.process.json'
if sys.argv[1]=='record':
    pid=int(sys.argv[2]);command=ps(pid,'command');start=ps(pid,'lstart')
    assert str(root/'scripts/oidc-local/server.exs') in command and '--kith-run='+run['run_id'] in command
    assert os.environ['KITH_OIDC_DATABASE_SUFFIX'].startswith('_fresh_')
    listener=''
    for _ in range(120):
        try:listener=subprocess.check_output(['lsof','-a','-p',str(pid),'-iTCP:8464','-sTCP:LISTEN','-t'],text=True,stderr=subprocess.PIPE).strip()
        except subprocess.CalledProcessError:pass
        if listener==str(pid):break
        time.sleep(0.25)
    assert listener==str(pid), 'PID does not own separate desktop app port'
    record.write_text(json.dumps({'pid':pid,'command':command,'start':start,'cwd':str(root),
        'run':run['run_id'],'database_suffix':os.environ['KITH_OIDC_DATABASE_SUFFIX']}))
    print('PASS separate desktop app identity recorded')
else:
    assert sys.argv[1]=='stop'
    saved=json.loads(record.read_text())
    assert saved['cwd']==str(root) and saved['run']==run['run_id']
    assert saved['database_suffix'].startswith('_fresh_')
    try:
        command=ps(saved['pid'],'command');start=ps(saved['pid'],'lstart')
    except subprocess.CalledProcessError:raise SystemExit('Separate test app already stopped')
    assert command==saved['command'] and start==saved['start']
    assert str(root/'scripts/oidc-local/server.exs') in command and '--kith-run='+run['run_id'] in command
    os.kill(saved['pid'],signal.SIGTERM)
    print('PASS exact owned desktop app stopped; shared app untouched')
