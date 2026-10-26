import Foundation
import Darwin

@main struct DaemonMain {
    static func main() {
        guard geteuid()==0 else {exit(77)}
        do {
            let config=try TrustedFiles.configuration()
            try TrustedFiles.runtime()
            // Root owns /var/run; replace only our own prior socket.
            var info=stat()
            if lstat(PrivilegedPaths.socket,&info)==0 {
                guard info.st_uid==0,(info.st_mode&S_IFMT)==S_IFSOCK else {throw AppError("Unexpected helper socket file.")}
                unlink(PrivilegedPaths.socket)
            }
            let fd=try UnixSocket.create(PrivilegedPaths.socket,server:true)
            chmod(PrivilegedPaths.socket,0o666) // Every connection is authenticated before reading commands.
            defer {close(fd);unlink(PrivilegedPaths.socket)}
            BrokerServer(configuration:config,worker:PrivilegedPaths.worker).serve(fd)
        } catch {exit(1)}
    }
}
