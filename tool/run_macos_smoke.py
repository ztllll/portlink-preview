#!/usr/bin/env python3
"""Launch the dedicated native Flutter smoke app against an isolated SSH fixture.
Never launches a user's server, reads user credentials or sends traffic to 3080.
Use the Python venv that contains asyncssh; pass the explicit smoke executable.
"""
import argparse, json, pathlib, subprocess, sys, threading

def main():
 parser=argparse.ArgumentParser();parser.add_argument('executable',type=pathlib.Path);parser.add_argument('--timeout',type=int,default=120);args=parser.parse_args()
 binary=args.executable.resolve();root=pathlib.Path(__file__).resolve().parents[1]
 if not binary.is_file():parser.error('dedicated smoke executable does not exist')
 fixture=subprocess.Popen([sys.executable,str(root/'tool'/'ssh_fixture.py')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,cwd=root)
 output={};code=1
 try:
  timer=threading.Timer(15,fixture.kill);timer.start()
  try:line=fixture.stdout.readline()
  finally:timer.cancel()
  info=json.loads(line)
  result=subprocess.run([str(binary),'--fixture-port='+str(info['port']),'--fingerprint='+info['fingerprint']],capture_output=True,text=True,timeout=args.timeout,cwd=root)
  records=[]
  for text in result.stdout.splitlines():
   if text.startswith('PORTLINK_NATIVE_SMOKE '):records.append(json.loads(text.split(' ',1)[1]))
   elif text.startswith('PORTLINK_NATIVE_SMOKE_FAILURE '):output['failure']=json.loads(text.split(' ',1)[1])
  output.update({'executableExitCode':result.returncode,'nativeSmoke':records[-1] if records else None,'rawStdout':result.stdout,'rawStderr':result.stderr})
  code=0 if result.returncode==0 and records and records[-1].get('success') is True else 1
 except subprocess.TimeoutExpired:
  output={'success':False,'reason':'native smoke process exceeded bounded timeout'}
 except Exception as error:
  output={'success':False,'reason':type(error).__name__}
 finally:
  fixture.terminate()
  try:fixture.communicate(timeout=8)
  except subprocess.TimeoutExpired:fixture.kill();fixture.communicate()
 print(json.dumps(output,ensure_ascii=False,indent=2));return code
if __name__=='__main__':sys.exit(main())
