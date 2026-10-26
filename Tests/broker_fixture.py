#!/usr/bin/env python3
"""Test the real broker authentication/dispatch unprivileged, with signed peers.
No launchd job, root helper, administrator prompt, or VPN engine is installed.
"""
import pathlib,subprocess,tempfile,os,socket,json,time,uuid,shutil
root=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='fb-broker-') as temporary:
    base=pathlib.Path(temporary)
    server_source=base/'Server.swift'
    server_source.write_text('''import Foundation
import Darwin
@main struct FixtureServer {
 static func main() throws {
  let args=CommandLine.arguments
  let fd=try UnixSocket.create(args[1],server:true)
  let config=HelperConfiguration(version:PrivilegedPaths.version,ownerUID:UInt32(args[2])!,appCDHash:args[3])
  BrokerServer(configuration:config,worker:args[4]).serve(fd)
 }
}
''')
    client_source=base/'Client.swift'
    client_source.write_text('''import Foundation
import Darwin
@main struct FixtureClient {
 static func main() throws {
  let args=CommandLine.arguments
  if args[1]=="hash" {print(try CodeIdentity.hash(of:args[0]));return}
  let fd=try UnixSocket.create(args[1],server:false)
  defer {close(fd)}
  do {
   try UnixSocket.send(BrokerCommand(kind:args[2],directory:args.count>3 ? args[3]:""),fd:fd)
   let message=try BrokerProtocol.read(WireMessage.self,fd:fd)
   print(String(decoding:try JSONEncoder().encode(message),as:UTF8.self))
  } catch {print("REJECTED")}
 }
}
''')
    common=[str(root/'Sources/Core.swift'),str(root/'Sources/Privileged.swift')]
    subprocess.run(['swiftc','-parse-as-library',*common,str(root/'Sources/Broker.swift'),str(server_source),'-o',str(base/'Server'),'-framework','Security'],check=True)
    subprocess.run(['swiftc','-parse-as-library',*common,str(client_source),'-o',str(base/'Good'),'-framework','Security'],check=True)
    shutil.copy2(base/'Good',base/'Other')
    for name in ['Good','Other']:
        subprocess.run(['codesign','--force','--sign','-','--options','runtime','--identifier','eu.local.fortibreak.test.'+name,str(base/name)],check=True,capture_output=True)
    digest=subprocess.check_output([str(base/'Good'),'hash'],text=True).strip()
    worker=base/'worker';marker=base/'started'
    worker.write_text('#!/bin/sh\n/usr/bin/touch '+str(marker)+'\n');worker.chmod(0o700)
    def test_server(uid):
        directory=tempfile.TemporaryDirectory(prefix='fbb-',dir='/tmp')
        path=directory.name+'/broker.sock'
        process=subprocess.Popen([str(base/'Server'),path,str(uid),digest,str(worker)])
        for _ in range(100):
            if os.path.exists(path):break
            time.sleep(0.02)
        assert os.path.exists(path),'Fixture server failed to start'
        return directory,path,process
    def request(path,name='Good',kind='ping',directory=''):
        result=subprocess.run([str(base/name),path,kind,directory],capture_output=True,text=True,timeout=10,check=True)
        if result.stdout.strip()=='REJECTED':return None
        return json.loads(result.stdout)
    directory,path,process=test_server(os.getuid())
    try:
        assert request(path)['kind']=='ready','Approved signed client rejected'
        assert request(path,'Other') is None,'Unapproved signed binary accepted'
        assert request(path,kind='shell')['kind']=='error','Arbitrary action accepted'
        assert request(path,kind='start',directory='/etc')['kind']=='error','Arbitrary path accepted'
        assert not marker.exists(),'Rejected command launched a worker'
        session=pathlib.Path('/tmp/fb-'+str(uuid.uuid4()).upper());session.mkdir(mode=0o700)
        control=socket.socket(socket.AF_UNIX);control.bind(str(session/'control.sock'));os.chmod(session/'control.sock',0o600)
        try:
            assert request(path,kind='start',directory=str(session))['kind']=='ready'
            for _ in range(100):
                if marker.exists():break
                time.sleep(0.02)
            assert marker.exists(),'Approved command did not start fixture worker'
        finally:
            control.close();(session/'control.sock').unlink();session.rmdir()
    finally:
        process.terminate();process.wait(timeout=5);directory.cleanup()
    directory,path,process=test_server(os.getuid()+1)
    try:assert request(path) is None,'Wrong user accepted'
    finally:process.terminate();process.wait(timeout=5);directory.cleanup()
print('Passed broker audit-token/signature authentication, wrong-build/user rejection, action/path restrictions and approved dispatch. Unprivileged fixtures only.')
