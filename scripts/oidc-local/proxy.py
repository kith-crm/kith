#!/usr/bin/env python3
"""Private verified TLS edge. No request logging (OIDC queries contain codes)."""
import http.client, http.server, json, pathlib, ssl, base64, threading, urllib.parse
lock=threading.Lock()
observations=[]
run=json.loads((pathlib.Path(__file__).resolve().parents[2]/'.oidc-local/run.json').read_text())
state=pathlib.Path(__file__).resolve().parents[2]/'.oidc-local'
class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.forward()
    def do_POST(self): self.forward()
    def forward(self):
        upstream=http.client.HTTPConnection('127.0.0.1',19049,timeout=15)
        headers={k:v for k,v in self.headers.items() if k.lower() not in ('connection','transfer-encoding')}
        headers.update({'X-Forwarded-Proto':'https','X-Forwarded-Host':'authentik.test:8443','X-Forwarded-For':'127.0.0.1'})
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        try:
            upstream.request(self.command,self.path,body,headers)
            result=upstream.getresponse()
            data=result.read()
            # Persist only protocol booleans; bodies, codes, tokens and headers stay in memory.
            if urllib.parse.urlsplit(self.path).path == '/application/o/token/':
                form=urllib.parse.parse_qs(body.decode())
                record={'status':result.status,
                    'authorization_code':form.get('grant_type')==['authorization_code'],
                    'code_present':bool(form.get('code')),
                    'verifier_present':bool(form.get('code_verifier')),
                    'client_secret_basic':self.headers.get('Authorization','') == 'Basic '+base64.b64encode((run['client_id']+':'+run['client_secret']).encode()).decode()}
                if result.status==200:
                    try:
                        token=json.loads(data)['id_token'].split('.')
                        decode=lambda x:json.loads(base64.urlsafe_b64decode(x+'='*(-len(x)%4)))
                        header,claims=decode(token[0]),decode(token[1])
                        record.update(rs256=header.get('alg')=='RS256',kid_present=bool(header.get('kid')),
                            issuer_matches=claims.get('iss')==run['issuer'],
                            audience_matches=claims.get('aud')==run['client_id'] or run['client_id'] in claims.get('aud',[]),
                            nonce_present=isinstance(claims.get('nonce'),str),
                            auth_time_integer=isinstance(claims.get('auth_time'),int))
                    except (ValueError,KeyError,IndexError): record['token_shape_valid']=False
                with lock:
                    observations.append(record)
                    target=state/'protocol-observations.json'
                    target.write_text(json.dumps(observations,indent=2));target.chmod(0o600)
            self.send_response(result.status)
            for k,v in result.getheaders():
                if k.lower() not in ('connection','transfer-encoding','content-length'): self.send_header(k,v)
            self.send_header('Content-Length',str(len(data)))
            self.end_headers(); self.wfile.write(data)
        except (OSError,http.client.HTTPException):
            self.send_error(502)
        finally: upstream.close()
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(state/'authentik.test.pem',state/'authentik.test-key.pem')
server=http.server.ThreadingHTTPServer(('0.0.0.0',8443),Proxy)
server.socket=context.wrap_socket(server.socket,server_side=True)
server.serve_forever()
