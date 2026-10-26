#!/usr/bin/env python3
"""Replay quoted engine URLs and loopback callbacks without a gateway or browser.
The fixture remaps 8020 in isolated source copies to an ephemeral local port, so
it cannot receive a real FortiClient callback during the tests.
"""
import json, os, pathlib, socket, subprocess, tempfile, urllib.request, sys
root=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='cg-saml-') as temporary:
    base=pathlib.Path(temporary)
    probe=socket.socket();probe.bind(('127.0.0.1',0));port=probe.getsockname()[1];probe.close()
    modefile=base/'mode'
    fake=base/'fake-vpn'
    script='''import socket,sys,signal,pathlib,time
signal.signal(signal.SIGINT,lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM,lambda *_: sys.exit(0))
mode=pathlib.Path(MODEFILE).read_text()
port=int(next(arg.split('=',1)[1] for arg in sys.argv if arg.startswith('--saml-login=')))
url="https://vpn.example.invalid:443/remote/saml/start?redirect=1"
if mode=='no-listener':
 print("INFO: Authenticate at '%s'"%url,flush=True);sys.exit(1)
server=socket.socket();server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try:server.bind(('127.0.0.1',port))
except OSError:
 print('ERROR: Failed to bind socket to port %d'%port,flush=True);sys.exit(1)
server.listen(1)
print('INFO: Listening for SAML login on port %d'%port,flush=True)
print("INFO: Authenticate at '%s'"%url,flush=True)
print("INFO: Authenticate at '%s'"%url,flush=True)
server.settimeout(0.5 if mode=='timeout' else 8)
try:conn,_=server.accept()
except socket.timeout:
 print('ERROR: Finally failed to retrieve SAML authentication token',flush=True);sys.exit(1)
request=conn.recv(4096)
if not request.startswith(b'GET /?id=synthetic-session-only '):sys.exit(2)
conn.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nOK')
conn.close();server.close()
print('INFO: Callback http://127.0.0.1/?id=synthetic-session-only',flush=True)
print('INFO: Tunnel is up and running.',flush=True)
while True:signal.pause()
'''.replace('MODEFILE',repr(str(modefile)))
    fake.write_text('#!'+sys.executable+'\n'+script);fake.chmod(0o700)
    core=(root/'Sources/Core.swift').read_text().replace('static let paths = ["/opt/homebrew/bin/openfortivpn", "/usr/local/bin/openfortivpn"]','static let paths = ['+json.dumps(str(fake))+']')
    core=core.replace('static let callbackPort = 8020','static let callbackPort = '+str(port))
    helper=(root/'Sources/Helper.swift').read_text().replace('guard geteuid() == 0,','guard geteuid() == getuid(),')
    (base/'Core.swift').write_text(core);(base/'Helper.swift').write_text(helper)
    subprocess.run(['clang','-c',str(root/'Sources/PTY.c'),'-o',str(base/'PTY.o')],check=True)
    subprocess.run(['swiftc','-parse-as-library',str(base/'Core.swift'),str(base/'Helper.swift'),str(base/'PTY.o'),'-o',str(base/'Helper')],check=True)
    profile=dict(id='11111111-1111-1111-1111-111111111111',name='SSO fixture',host='vpn.example.invalid',port=443,username='',realm='',login='Browser SSO',vpnProtocol='ssl',favorite=False,caFile='',certificateFile='',keyFile='',trustedCertificate='',notes='',source='Fixture',importWarnings=[])
    def session(mode):
        modefile.write_text(mode)
        held=None
        if mode=='busy':
            held=socket.socket();held.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);held.bind(('127.0.0.1',port));held.listen(1)
        try:
            with tempfile.TemporaryDirectory(prefix='cgs-',dir='/tmp') as directory:
                os.chmod(directory,0o700)
                server=socket.socket(socket.AF_UNIX);server.bind(directory+'/control.sock');server.listen(1);server.settimeout(10)
                process=subprocess.Popen([str(base/'Helper'),directory])
                conn=None
                try:
                    conn,_=server.accept();conn.settimeout(10)
                    conn.sendall((json.dumps(dict(profile=profile,password='',samlPort=port))+'\n').encode())
                    events=[];pending=b''
                    while True:
                        data=conn.recv(8192)
                        if not data:break
                        pending+=data
                        while b'\n' in pending:
                            line,pending=pending.split(b'\n',1);event=json.loads(line);events.append(event)
                            if event['kind']=='browser' and mode=='normal':
                                assert event['text']=='https://vpn.example.invalid:443/remote/saml/start?redirect=1'
                                # Send only a synthetic ID to our isolated local fixture.
                                with urllib.request.urlopen('http://127.0.0.1:%d/?id=synthetic-session-only'%port,timeout=3) as response:assert response.read()==b'OK'
                            if event['kind']=='connected':conn.sendall(b'{"kind":"stop","text":""}\n')
                    process.wait(timeout=10)
                    browser=[event for event in events if event['kind']=='browser']
                    exits=[event for event in events if event['kind']=='exit']
                    assert exits,(mode,events)
                    if mode=='normal':
                        assert len(browser)==1 and any(event['kind']=='connected' for event in events)
                        assert exits[-1]['code']==0
                        assert not any('synthetic-session-only' in event.get('text','') for event in events)
                    elif mode=='timeout':assert 'timed out' in exits[-1]['text'] and exits[-1]['code']!=0
                    else:
                        assert not browser and exits[-1]['code']!=0,(mode,events)
                        if mode=='busy':assert 'busy' in exits[-1]['text']
                finally:
                    if conn:conn.close()
                    server.close()
                    if process.poll() is None:process.terminate();process.wait(timeout=20)
        finally:
            if held:held.close()
    for mode in ['normal','busy','timeout','no-listener']:session(mode)
print('Passed SAML URL handoff, synthetic callback, one-browser-only, occupied-port, timeout and listener-readiness fixtures. No real login or VPN connection.')
