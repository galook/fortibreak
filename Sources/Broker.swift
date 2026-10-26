import Foundation
import Darwin

final class BrokerServer {
    let configuration:HelperConfiguration
    let worker:String
    private var active:Process?
    init(configuration:HelperConfiguration,worker:String){self.configuration=configuration;self.worker=worker}
    func handle(_ fd:Int32) {
        defer {close(fd)}
        do {
            try CodeIdentity.authorize(peer:fd,uid:configuration.ownerUID,hash:configuration.appCDHash)
        } catch {return} // No protocol or privileged action for an unauthenticated peer.
        do {
            let command=try BrokerProtocol.read(BrokerCommand.self,fd:fd)
            switch command.kind {
            case "ping":break
            case "start":
                guard active?.isRunning != true else {throw AppError("A ClearGate VPN session is already running.")}
                try TrustedFiles.sessionDirectory(command.directory,uid:configuration.ownerUID)
                let child=Process()
                child.executableURL=URL(fileURLWithPath:worker)
                child.arguments=[command.directory]
                child.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":"/var/root","LC_ALL":"C"]
                child.standardInput=FileHandle.nullDevice;child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
                try child.run();active=child
            default:throw AppError("Unsupported VPN helper request.")
            }
            try UnixSocket.send(WireMessage(kind:"ready",code:Int32(PrivilegedPaths.version)),fd:fd)
        } catch {try? UnixSocket.send(WireMessage(kind:"error",text:error.localizedDescription),fd:fd)}
    }
    func serve(_ fd:Int32) {
        while true {
            let client=accept(fd,nil,nil)
            if client<0 {if errno==EINTR {continue};return}
            _ = fcntl(client,F_SETFD,FD_CLOEXEC)
            var noSignal:Int32=1
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
            handle(client)
        }
    }
}
