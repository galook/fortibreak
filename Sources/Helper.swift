import Foundation
import Darwin

@_silgen_name("cg_spawn") private func cg_spawn(_ args: UnsafePointer<UnsafeMutablePointer<CChar>?>!, _ master: UnsafeMutablePointer<Int32>!) -> Int32
@_silgen_name("cg_wait") private func cg_wait(_ pid: Int32, _ code: UnsafeMutablePointer<Int32>!) -> Int32
@_silgen_name("cg_signal") private func cg_signal(_ pid: Int32, _ signal: Int32)
@_silgen_name("cg_signal_engine") private func cg_signal_engine(_ pid: Int32, _ signal: Int32)

@main struct HelperMain {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let dir = CommandLine.arguments[1], path = dir + "/control.sock"
        var st = stat()
        guard geteuid() == 0, lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, (st.st_mode & 0o077) == 0 else { exit(77) }
        do {
            #if PRIVILEGED_RUNTIME
            let configuration=try TrustedFiles.configuration()
            try TrustedFiles.runtime()
            guard configuration.ownerUID==st.st_uid else {throw AppError("Unexpected session owner.")}
            let lock=open(PrivilegedPaths.lock,O_RDWR|O_NOFOLLOW)
            guard lock>=0 else {throw AppError("Cannot lock VPN session.")}
            defer {close(lock)}
            guard flock(lock,LOCK_EX|LOCK_NB)==0 else {throw AppError("A VPN session or helper update is already running.")}
            #endif
            try run(path, owner: st.st_uid)
        } catch { exit(1) }
    }
    static func run(_ path: String, owner: uid_t) throws {
        let fd = try UnixSocket.create(path, server: false)
        defer { close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == owner, uid != 0 else { throw AppError("Unexpected session owner.") }
        #if PRIVILEGED_RUNTIME
        let configuration=try TrustedFiles.configuration()
        try CodeIdentity.authorize(peer:fd,uid:configuration.ownerUID,hash:configuration.appCDHash)
        #endif
        func event(_ kind: String, _ text: String = "", _ code: Int32? = nil) { try? UnixSocket.send(WireMessage(kind: kind, text: text, code: code), fd: fd) }
        var first = Data(), byte: UInt8 = 0
        while first.count < 1_000_000 {
            var poller = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            guard poll(&poller,1,30_000) > 0, read(fd,&byte,1) == 1 else { throw AppError("No connection request.") }
            if byte == 10 { break }; first.append(byte)
        }
        var request = try JSONDecoder().decode(ConnectRequest.self, from: first)
        first.resetBytes(in: 0..<first.count); first.removeAll()
        guard let executable = Backend.executable else { event("error","openfortivpn backend was not found."); return }
        #if PRIVILEGED_RUNTIME
        if request.profile.caFile.isEmpty {request.profile.caFile=PrivilegedPaths.certificates}
        #endif
        let arguments: [String]
        do { arguments = try Backend.arguments(request) } catch { event("error",error.localizedDescription); return }
        var redactor = LogRedactor(); redactor.add(request.password)
        var initialPassword = request.password
        request.password = ""
        var argv = ([executable] + arguments).map { strdup($0) }; argv.append(nil)
        defer { argv.forEach { if let p = $0 { free(p) } } }
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { cg_spawn($0.baseAddress, &master) }
        guard pid > 0 else { event("error","Could not start VPN backend."); return }
        defer { close(master) }
        event("started")
        var input = Data(), pending = "", promptTail = "", lastPrompt = "", stopAt: Date?, eof = false
        var connectedSent = false, samlListening = false, browserOpened = false
        var terminated = false, killed = false
        var exitDetail = ""
        func sendInput(_ s: String) {
            let s = s.replacingOccurrences(of:"\r",with:"").replacingOccurrences(of:"\n",with:"")
            redactor.add(s)
            let data = Data((s + "\n").utf8)
            data.withUnsafeBytes { raw in _ = write(master,raw.baseAddress,raw.count) }
            lastPrompt = ""; promptTail = ""
        }
        func output(_ text: String) {
            let clean = redactor.clean(text)
            if !clean.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { event("log",clean) }
            if !connectedSent && clean.contains("Tunnel is up and running") { connectedSent = true; event("connected") }
            if let range = clean.range(of:"ppp[0-9]+",options:.regularExpression) { event("interface",String(clean[range])) }
            if request.profile.login == .browser {
                if clean.contains("Listening for SAML login on port \(BrowserSSO.callbackPort)") {samlListening=true}
                if clean.contains("Failed to bind socket to port") {exitDetail="Browser callback port 8020 is busy. Cancel FortiClient sign-in and retry ClearGate."}
                if clean.contains("Finally failed to retrieve SAML authentication token") {exitDetail="Browser sign-in timed out. Press Connect and finish sign-in within about 50 seconds."}
                if samlListening, !browserOpened, let url=BrowserSSO.loginURL(in:text,profile:request.profile) {
                    browserOpened=true
                    event("browser",url.absoluteString)
                }
            }
        }
        while true {
            var code: Int32 = 0
            if cg_wait(pid,&code) == 1 {
                // Drain trailing engine diagnostics before emitting its exit status.
                var bytes=[UInt8](repeating:0,count:8192)
                while true {
                    var ready=pollfd(fd:master,events:Int16(POLLIN),revents:0)
                    guard poll(&ready,1,0)>0,ready.revents & Int16(POLLIN) != 0 else {break}
                    let count=read(master,&bytes,bytes.count)
                    guard count>0 else {break}
                    pending += String(decoding:bytes.prefix(count),as:UTF8.self).replacingOccurrences(of:"\r",with:"")
                }
                if !pending.isEmpty { output(pending) }
                if killed {exitDetail="VPN engine required a forced stop. Network cleanup could not be confirmed; check Activity."}
                event("exit",exitDetail,code); return
            }
            if let since = stopAt {
                let elapsed = Date().timeIntervalSince(since)
                if elapsed > 45 && !killed {
                    killed=true;event("log","VPN engine did not finish cleanup within 45 seconds. Forcing its process group to stop.");cg_signal(pid,SIGKILL)
                } else if elapsed > 30 && !terminated {
                    terminated=true;event("log","VPN cleanup is taking longer than expected. Asking the engine to terminate.");cg_signal_engine(pid,SIGTERM)
                }
            }
            var fds = [pollfd(fd:master,events:Int16(POLLIN),revents:0),pollfd(fd:eof ? -1 : fd,events:Int16(POLLIN),revents:0)]
            let n = poll(&fds,2,250)
            if n < 0 { if errno == EINTR { continue }; if stopAt == nil { stopAt=Date();cg_signal_engine(pid,SIGINT) }; continue }
            if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                var bytes = [UInt8](repeating:0,count:4096)
                let got = read(fd,&bytes,bytes.count)
                if got <= 0 { eof = true; if stopAt == nil { stopAt=Date();cg_signal_engine(pid,SIGINT) } }
                else {
                    input.append(contentsOf:bytes.prefix(got))
                    while let end = input.firstIndex(of:10) {
                        let line = input.prefix(upTo:end); input.removeSubrange(...end)
                        if let command = try? JSONDecoder().decode(WireMessage.self,from:line) {
                            if command.kind == "stop", stopAt == nil { stopAt=Date();cg_signal_engine(pid,SIGINT) }
                            if command.kind == "input", command.text.utf8.count < 4096 { sendInput(command.text) }
                        }
                    }
                    if input.count > 8192 { input.removeAll(); if stopAt == nil { stopAt=Date();cg_signal_engine(pid,SIGINT) } }
                }
            }
            if fds[0].revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating:0,count:8192)
                let got = read(master,&bytes,bytes.count)
                if got > 0 {
                    let text = String(decoding:bytes.prefix(got),as:UTF8.self).replacingOccurrences(of:"\r",with:"")
                    pending += text; promptTail = String((promptTail + text).suffix(4096))
                    while let end = pending.firstIndex(of:"\n") { let line=String(pending[..<end]);pending.removeSubrange(...end);output(line) }
                    if pending.count > 16384 { output(pending);pending="" }
                    let tail = promptTail.trimmingCharacters(in:.whitespacesAndNewlines)
                    if tail != lastPrompt, tail.range(of:"(?i)(password|passphrase|token|one.time|otp|response|pin)[^\\n]{0,180}[:?]\\s*$",options:.regularExpression) != nil {
                        lastPrompt=tail
                        if !initialPassword.isEmpty && tail.localizedCaseInsensitiveContains("account password") { sendInput(initialPassword); initialPassword="" }
                        else { event("prompt",tail.localizedCaseInsensitiveContains("passphrase") ? "Enter private-key passphrase" : tail.localizedCaseInsensitiveContains("password") ? "Enter VPN password" : "Enter verification code or authentication response") }
                    }
                }
            }
        }
    }
}
