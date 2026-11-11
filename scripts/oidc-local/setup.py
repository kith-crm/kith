#!/usr/bin/env python3
"""Generate private run state; never modifies machine trust or DNS."""
import json, os, pathlib, secrets, socket, subprocess
root = pathlib.Path(__file__).resolve().parents[2]
state = root / '.oidc-local'
os.umask(0o077)
if state.exists():
    raise SystemExit('Existing .oidc-local retained; use its run or explicitly remove after teardown')
for port in (15449, 19049, 8443, 8444, 8445):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', port))
state.mkdir(mode=0o700)
values = {'POSTGRES_PASSWORD': secrets.token_hex(24), 'AUTHENTIK_SECRET_KEY': secrets.token_hex(48),
          'AUTHENTIK_BOOTSTRAP_PASSWORD': secrets.token_urlsafe(32), 'AUTHENTIK_BOOTSTRAP_TOKEN': secrets.token_hex(32)}
values['AUTHENTIK_POSTGRESQL__PASSWORD'] = values['POSTGRES_PASSWORD']
(state/'runtime.env').write_text(''.join(f'{k}={v}\n' for k,v in values.items()))
run = {'run_id': secrets.token_hex(16), 'worktree':str(root), 'client_id':'kith-local', 'client_secret':secrets.token_hex(32),
       'issuer':'https://authentik.test:8443/application/o/kith-local/',
       'callback':'https://kith.test:8444/auth/oidc/callback',
       'control_token':secrets.token_hex(32), 'users':[
           {'username':f'oidc-user-{i}', 'email':f'oidc-user-{i}@example.test',
            'password':secrets.token_urlsafe(24), 'verified': i != 2} for i in range(4)]}
run['project']='kith-oidc-c8f3c762-'+run['run_id'][:12]
(state/'run.json').write_text(json.dumps(run))
with (state/'runtime.env').open('a') as env:
    env.write(f'KITH_RUN_ID={run["run_id"]}\nKITH_WORKTREE={root}\nCOMPOSE_PROJECT_NAME={run["project"]}\n')
def openssl(*args):
    subprocess.run(['openssl', *args], cwd=state, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
openssl('req','-x509','-newkey','rsa:2048','-nodes','-keyout','ca-key.pem','-out','ca.pem','-days','2','-subj','/CN=Kith isolated real provider CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign','-addext','subjectKeyIdentifier=hash')
for host in ('kith.test','fixture.test','authentik.test'):
    openssl('req','-newkey','rsa:2048','-nodes','-keyout',f'{host}-key.pem','-out',f'{host}.csr','-subj',f'/CN={host}')
    (state/'leaf.ext').write_text(f'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=DNS:{host}\n')
    openssl('x509','-req','-in',f'{host}.csr','-CA','ca.pem','-CAkey','ca-key.pem','-CAcreateserial','-out',f'{host}.pem','-days','2','-extfile','leaf.ext')
print('Private local provider run generated; secrets retained only in .oidc-local (0700/0600).')
