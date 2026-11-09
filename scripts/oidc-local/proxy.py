#!/usr/bin/env python3
"""Private verified TLS edge. No request logging (OIDC queries contain codes)."""
import http.client, http.server, json, pathlib, ssl
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
