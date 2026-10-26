#!/usr/bin/env python3
"""Exercise helper protocol unprivileged, using an isolated fake VPN executable."""
import json, os, pathlib, socket, subprocess, tempfile, time, sys
root=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='fb-harness-') as tmp:
    base=pathlib.Path(tmp)
    fake=base/'fake-vpn'
    fake.write_text('#!'+sys.executable+'\n'+r'''import pathlib,subprocess,signal,sys,time
base=pathlib.Path(__file__).parent
for name in ['child-ready','child-signalled','cleanup-complete']:
    (base/name).unlink(missing_ok=True)
print('VPN account password: ',end='',flush=True)
password=input()
if password!='fixture-password':sys.exit(8)
print('echo-test: '+password+'\nOTP: ',end='',flush=True)
if input()!='428731':sys.exit(9)
child=subprocess.Popen([sys.executable,'-c',"import pathlib,signal,time,sys; p=pathlib.Path(sys.argv[1]); signal.signal(signal.SIGINT,lambda *_:(p/'child-signalled').write_text('INT')); (p/'child-ready').touch(); time.sleep(60)",str(base)])
for _ in range(100):
    if (base/'child-ready').exists():break
    time.sleep(.01)
def stop(*_):
    # A premature group signal would reach PPP before the engine restores routes.
    time.sleep(.2)
    premature=(base/'child-signalled').exists() or child.poll() is not None
    child.terminate();child.wait(timeout=3)
    (base/'cleanup-complete').write_text('premature' if premature else 'ordered')
    print('Tunnel stopped.',flush=True)
    sys.exit(88 if premature else 0)
signal.signal(signal.SIGINT,stop);signal.signal(signal.SIGTERM,stop)
print('Using interface ppp123\nTunnel is up and running.',flush=True)
while True:signal.pause()
''')
    fake.chmod(0o700)
    core=(root/'Sources/Core.swift').read_text().replace('static let paths = ["/opt/homebrew/bin/openfortivpn", "/usr/local/bin/openfortivpn"]','static let paths = ['+json.dumps(str(fake))+']')
    helper=(root/'Sources/Helper.swift').read_text().replace('guard geteuid() == 0,','guard geteuid() == getuid(),')
    (base/'Core.swift').write_text(core)
    (base/'Helper.swift').write_text(helper)
    pty_object=base/'PTY.o'
    subprocess.run(['clang','-c',str(root/'Sources/PTY.c'),'-o',str(pty_object)],check=True)
    subprocess.run(['swiftc','-parse-as-library',str(base/'Core.swift'),str(base/'Helper.swift'),str(pty_object),'-o',str(base/'Helper')],check=True)
    profile=dict(id='11111111-1111-1111-1111-111111111111',name='Fixture',host='vpn.example.invalid',port=443,username='fixture',realm='',login='Password & MFA',vpnProtocol='ssl',favorite=False,caFile='',certificateFile='',keyFile='',trustedCertificate='',notes='',source='Fixture',importWarnings=[])
    def session(mode):
        # Short path stays within Darwin's 104-byte Unix socket limit.
        with tempfile.TemporaryDirectory(prefix='fbt-',dir='/tmp') as directory:
            os.chmod(directory,0o700)
            server=socket.socket(socket.AF_UNIX);server.bind(directory+'/control.sock');server.listen(1);server.settimeout(10)
            process=subprocess.Popen([str(base/'Helper'),directory])
            conn,_=server.accept();conn.settimeout(10)
            conn.sendall((json.dumps(dict(profile=profile,password='fixture-password',samlPort=8020))+'\n').encode())
            events=[];pending=b'';connected=False
            while True:
                data=conn.recv(8192)
                if not data:break
                pending+=data
                while b'\n' in pending:
                    line,pending=pending.split(b'\n',1)
                    event=json.loads(line);events.append(event)
                    if event['kind']=='prompt':
                        conn.sendall((json.dumps(dict(kind='input',text='428731'))+'\n').encode())
                    if event['kind']=='connected':
                        connected=True
                        if mode=='eof':conn.shutdown(socket.SHUT_RDWR);conn.close();break
                        conn.sendall(b'{"kind":"stop","text":""}\n')
                if connected and mode=='eof':break
            process.wait(timeout=20)
            assert process.returncode==0,(mode,process.returncode)
            assert connected,(mode,events)
            assert (base/'cleanup-complete').read_text()=='ordered', 'PPP received a premature group stop'
            assert any(e['kind']=='prompt' for e in events),(mode,events)
            assert not any('fixture-password' in e.get('text','') or '428731' in e.get('text','') for e in events),events
            if mode=='stop': assert any(e['kind']=='exit' and e['code']==0 for e in events),events
            server.close()
    session('stop');session('eof')
    print('Passed helper password/MFA, connected state, secret redaction, disconnect, socket-loss and engine-before-PPP cleanup checks. Unprivileged fake backend; no VPN connection.')
