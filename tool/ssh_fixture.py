#!/usr/bin/env python3
"""Loopback-only integration SSH fixture; never uses a real user's credentials.
Requires asyncssh==2.24.1 in an isolated test environment.
"""
import asyncio, json, signal
import asyncssh

class Server(asyncssh.SSHServer):
 def begin_auth(self, username): return True
 def password_auth_supported(self): return True
 def validate_password(self, username, password):
  return username=='portlink-test' and password=='fixture-only-password'
 def connection_requested(self, dest_host, dest_port, orig_host, orig_port):
  return dest_host=='127.0.0.1' and dest_port==3080

async def echo(reader, writer):
 try:
  while True:
   b=await reader.read(65536)
   if not b: break
   writer.write(b); await writer.drain()
  if writer.can_write_eof(): writer.write_eof()
 except (ConnectionError,asyncio.CancelledError): pass
 finally:
  writer.close()
  try: await writer.wait_closed()
  except ConnectionError: pass

async def main():
 # Client listener is on 127.0.0.1:3080. Bind test target on 127.0.0.2, and
 # map SSH's requested 127.0.0.1:3080 to it inside the fixture only.
 target=await asyncio.start_server(echo,'127.0.0.1',0)
 target_port=target.sockets[0].getsockname()[1]
 class MappedServer(Server):
  def connection_requested(self,dest_host,dest_port,orig_host,orig_port):
   if dest_host!='127.0.0.1' or dest_port!=3080: return False
   return self._conn.forward_connection('127.0.0.1',target_port)
  def connection_made(self,conn): self._conn=conn
 key=asyncssh.generate_private_key('ssh-ed25519')
 server=await asyncssh.create_server(MappedServer,'127.0.0.1',0,server_host_keys=[key],
  encoding=None,login_timeout=15)
 print(json.dumps({'port':server.get_port(),'fingerprint':key.get_fingerprint('sha256')}),flush=True)
 stop=asyncio.Event()
 loop=asyncio.get_running_loop()
 for sig in (signal.SIGINT,signal.SIGTERM):loop.add_signal_handler(sig,stop.set)
 await stop.wait()
 server.close(); await server.wait_closed();target.close();await target.wait_closed()

if __name__=='__main__':asyncio.run(main())
