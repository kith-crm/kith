#!/usr/bin/env python3
"""Fail closed on project/run ownership; never print private run configuration."""
import datetime,json,os,pathlib,signal,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
STATE=ROOT/'.oidc-local'
def command(*args):
    return subprocess.check_output(args,text=True,stderr=subprocess.PIPE)
def run():
    data=json.loads((STATE/'run.json').read_text())
    if data.get('worktree')!=str(ROOT): raise SystemExit('Run belongs to another worktree')
    return data
def inventory(data):
    result=[]
    for kind,listing in [('container',['docker','ps','-aq','--filter',f'label=com.docker.compose.project={data["project"]}']),('volume',['docker','volume','ls','-q','--filter',f'label=com.docker.compose.project={data["project"]}']),('network',['docker','network','ls','-q','--filter',f'label=com.docker.compose.project={data["project"]}'])]:
        for ident in command(*listing).split():
            obj=json.loads(command('docker',kind,'inspect',ident))[0]
            labels=(obj.get('Config',{}).get('Labels') if kind=='container' else obj.get('Labels')) or {}
            result.append({'kind':kind,'id':obj.get('Id',obj.get('Name')),'name':obj.get('Name'),
                'created':obj.get('Created',obj.get('CreatedAt')), 'labels':labels})
    return result
def verify(data,items):
    legacy=json.loads((STATE/'legacy-ownership.json').read_text()) if (STATE/'legacy-ownership.json').exists() else []
    for item in items:
        labels=item['labels']
        if labels.get('io.kith.test.run')==data['run_id'] and labels.get('io.kith.test.worktree')==str(ROOT): continue
        if item in legacy: continue
        raise SystemExit('Ownership mismatch: refusing project mutation')
def process(kind,data,record=False):
    path=STATE/(kind+'.process.json')
    if record:
        pid=int((STATE/(kind+'.pid')).read_text())
        start=command('ps','-p',str(pid),'-o','lstart=').strip()
        args=command('ps','-p',str(pid),'-o','command=').strip()
        script=str(ROOT/'scripts/oidc-local'/('server.exs' if kind=='kith' else 'proxy.py'))
        marker='--kith-run='+data['run_id']
        if script not in args or marker not in args: raise SystemExit('Process missing absolute script or run marker')
        path.write_text(json.dumps({'pid':pid,'start':start,'command':args,'kind':kind,'worktree':str(ROOT),'run':data['run_id']}))
        return
    if not path.exists(): raise SystemExit('Missing exact process identity; refusing signal')
    saved=json.loads(path.read_text())
    if saved['worktree']!=str(ROOT) or saved['run']!=data['run_id'] or saved['kind']!=kind: raise SystemExit('Process owner mismatch')
    try:
        start=command('ps','-p',str(saved['pid']),'-o','lstart=').strip()
        args=command('ps','-p',str(saved['pid']),'-o','command=').strip()
    except subprocess.CalledProcessError:return
    if start!=saved['start'] or args!=saved['command']: raise SystemExit('PID identity changed; refusing signal')
    os.kill(saved['pid'],signal.SIGTERM)
if __name__=='__main__':
    os.umask(0o077);data=run();action=sys.argv[1]
    if action=='check':verify(data,inventory(data));print('PASS project/run/worktree ownership')
    elif action=='project':print(data['project'])
    elif action=='record':process(sys.argv[2],data,True)
    elif action=='stop':process(sys.argv[2],data)
    elif action=='evidence':
        items=inventory(data);verify(data,items)
        (STATE/'final-inventory.json').write_text(json.dumps(items,indent=2))
        # Structured allowlist excludes callback URLs, headers, tokens, log bodies and env.
        summaries=[]
        for item in items:
            if item['kind']!='container':continue
            obj=json.loads(command('docker','container','inspect',item['id']))[0]
            state=obj['State'];health=state.get('Health',{})
            summaries.append({'name':item['name'],'status':state['Status'],'exit_code':state['ExitCode'],
                'oom_killed':state['OOMKilled'],'health':health.get('Status','unknown'),
                'health_failures':health.get('FailingStreak',0),'restart_count':obj['RestartCount']})
            raw=subprocess.check_output(['docker','logs','--tail','200',item['id']],
                text=True,stderr=subprocess.STDOUT)
            (STATE/(item['name'].strip('/')+'-private.log')).write_text(raw)
        (STATE/'sanitized-diagnostics.json').write_text(json.dumps({'run':data['run_id'],
            'captured_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'services':summaries,
            'note':'Raw logs restricted; evidence includes only allowlisted health/failure state.'},indent=2))
        print('PASS owned inventory and sanitized diagnostics preserved')
