#!/usr/bin/env python3
import http.client,json,pathlib,socket,ssl
state=pathlib.Path(__file__).resolve().parents[2]/'.oidc-local'
run=json.loads((state/'run.json').read_text())
ctx=ssl.create_default_context(cafile=str(state/'ca.pem'))
def get(host,port,path,headers={}):
    conn=http.client.HTTPSConnection(host,port,context=ctx,timeout=5)
    conn._create_connection=lambda address,*a,**kw: socket.create_connection(('127.0.0.1',address[1]),timeout=5)
    conn.request('GET',path,headers=headers)
    response=conn.getresponse()
    assert response.status==200, 'readiness HTTP status'
    data=json.loads(response.read());conn.close();return data
metadata=get('authentik.test',8443,'/application/o/kith-local/.well-known/openid-configuration')
assert metadata['issuer']==run['issuer'], 'exact issuer mismatch'
for key,value in [('response_types_supported','code'),('response_modes_supported','query'),
                  ('id_token_signing_alg_values_supported','RS256'),('code_challenge_methods_supported','S256'),
                  ('token_endpoint_auth_methods_supported','client_secret_basic')]:
    assert value in metadata.get(key,[]), f'incompatible provider capability: {key}'
for host,port in [('kith.test',8444),('fixture.test',8445)]:
    assert get(host,port,'/__fixture__',{'Authorization':'Bearer '+run['control_token']})['run']==run['control_token'], 'owned identity mismatch'
print('PASS host exact-hostname verified TLS; owned app/fixture identity; Authentik discovery code/query RS256 S256 client_secret_basic')
