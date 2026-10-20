#!/usr/bin/env python3
"""隔离的内存 DAV：使用合成账号，绝不读取用户服务器或凭据。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os,subprocess,threading,base64
files={}; version=0; leaked=False
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def respond(self,code,body=b'',headers=None):
  self.send_response(code)
  for k,v in (headers or {}).items():self.send_header(k,v)
  self.send_header('Content-Length',str(len(body)));self.send_header('Connection','close');self.end_headers();self.wfile.write(body)
 def authorized(self):
  expected='Basic '+base64.b64encode(b'synthetic:test-only').decode()
  if self.headers.get('Authorization')!=expected:self.respond(401);return False
  return True
 def do_MKCOL(self):
  if self.authorized():self.respond(405)
 def do_GET(self):
  global leaked
  if self.path=='/trap':leaked=True;self.respond(200);return
  if not self.authorized():return
  if '/redirect/' in self.path:self.respond(302,headers={'Location':f'http://127.0.0.1:{self.server.server_port}/trap'});return
  if self.path not in files:self.respond(404);return
  self.respond(200,files[self.path],{'ETag':f'"v{version}"'})
 def do_PUT(self):
  global version
  if not self.authorized():return
  body=self.rfile.read(int(self.headers.get('Content-Length','0')))
  if self.headers.get('If-None-Match')=='*' and self.path in files:self.respond(412);return
  match=self.headers.get('If-Match')
  if match is not None and match!=f'"v{version}"':self.respond(412);return
  files[self.path]=body;version+=1;self.respond(201)
 def do_DELETE(self):
  if self.authorized():files.pop(self.path,None);self.respond(204)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 root=Path(__file__).resolve().parents[1]
 env=dict(os.environ,TVCORE_LOCAL_DAV=f'http://127.0.0.1:{server.server_port}/dav')
 result=subprocess.run(['swift','run','--package-path',str(root),'TVCoreChecks'],env=env)
 if result.returncode:raise SystemExit(result.returncode)
 if leaked:raise SystemExit('失败：客户端跟随了重定向')
 if any('probe-ios-' in key for key in files):raise SystemExit('失败：探测文件未清理')
 print('服务端确认：探测文件已清理，重定向目标未收到请求')
finally:server.shutdown();server.server_close()
