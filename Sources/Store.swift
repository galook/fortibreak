import Foundation
import AppKit
import Security
import Combine
import Darwin
import Network
import UserNotifications

enum CredentialStore {
    static let service = "eu.local.fortibreak.vpn"
    static func password(_ id: UUID) -> String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func save(_ password: String, id: UUID) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString]
        if password.isEmpty { SecItemDelete(query as CFDictionary);return }
        let values: [String:Any] = [kSecValueData as String:Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if status == errSecItemNotFound { status=SecItemAdd(query.merging(values) { _,b in b }.merging([kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _,b in b } as CFDictionary,nil) }
        guard status == errSecSuccess else { throw AppError("Keychain could not save this credential (\(status)).") }
    }
}

@MainActor final class ProfileStore: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var selected: UUID?
    @Published var error: String?
    let preview: Bool
    private var file: URL
    init(preview: Bool = false) {
        self.preview=preview
        file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FortiBreak/profiles.json")
        if preview {
            var p=VPNProfile();p.name="Studio network";p.host="vpn.example.com";p.username="your.name";p.favorite=true;p.notes="Internal tools, files, and services.";profiles=[p]
            var office=VPNProfile();office.name="Office";office.host="gate.example.org";office.login = .browser;office.notes="Single sign-on through the company browser login."
            if !CommandLine.arguments.contains("--preview-empty") {profiles.append(office)} else {profiles=[]}
        } else if FileManager.default.fileExists(atPath:file.path) {
            do { profiles=try JSONDecoder().decode([VPNProfile].self,from:Data(contentsOf:file)) } catch { self.error="Saved profiles could not be read. Original file was preserved: " + error.localizedDescription }
        }
        selected=profiles.first?.id
    }
    var current: VPNProfile? { profiles.first { $0.id == selected } }
    func persist() throws {
        guard !preview else { return }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(profiles)
        try data.write(to:file,options:[.atomic,.completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func save(_ profile: VPNProfile) throws {
        try profile.validate()
        let previous=profiles
        if let i=profiles.firstIndex(where:{$0.id == profile.id}) { profiles[i]=profile } else { profiles.append(profile) }
        do { try persist();selected=profile.id } catch { profiles=previous;throw error }
    }
    func remove(_ profile: VPNProfile) {
        let previous=profiles
        profiles.removeAll{$0.id == profile.id}
        do { try persist(); if !preview { try CredentialStore.save("",id:profile.id) }; if selected == profile.id { selected=profiles.first?.id } } catch { profiles=previous; self.error=error.localizedDescription }
    }
    func toggleFavorite(_ profile: VPNProfile) { var p=profile;p.favorite.toggle();do{try save(p)}catch{self.error=error.localizedDescription} }
    func importItems(_ items: [ImportedProfile], savePasswords: Bool) throws {
        let old=profiles
        var importedIDs: [UUID] = []
        for item in items {
            var p=item.profile
            if let i=profiles.firstIndex(where:{$0.host == p.host && $0.port == p.port && $0.username == p.username && $0.realm == p.realm && $0.vpnProtocol == p.vpnProtocol}) { p.id=profiles[i].id;profiles[i]=p } else { profiles.append(p) }
            importedIDs.append(p.id)
        }
        do {
            try persist()
            if savePasswords && !preview {
                for (item,id) in zip(items,importedIDs) { if let password=item.password { try CredentialStore.save(password,id:id) } }
            }
            selected=importedIDs.first
        } catch { profiles=old;try? persist();throw error }
    }
}

enum TunnelState: String { case idle="Not connected", authorizing="Waiting for macOS", connecting="Connecting", authenticating="Authentication needed", connected="Connected", reconnecting="Reconnecting", stopping="Disconnecting", failed="Connection failed" }
enum Preferences {
    static var autoReconnect:Bool {UserDefaults.standard.object(forKey:"autoReconnect") as? Bool ?? true}
    static var notifications:Bool {UserDefaults.standard.object(forKey:"notifications") as? Bool ?? true}
}
enum Notifier {
    static var enabled:Bool {Preferences.notifications && !CommandLine.arguments.contains("--preview") && Bundle.main.bundleIdentifier != nil}
    static func requestPermission() {guard enabled else{return};UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]){_,_ in}}
    // macOS shows these only while FortiBreak is in the background.
    static func post(_ title:String,_ body:String) {
        guard enabled else{return}
        let content=UNMutableNotificationContent();content.title=title;content.body=body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil))
    }
}
struct SessionRecord: Codable { var start: Date; var end: Date? }
struct ThroughputSample: Identifiable { let id=UUID(); let time: Date; let down: Double; let up: Double }
enum SessionHistory {
    private static func key(_ id:UUID)->String {"lastSession."+id.uuidString}
    static func last(_ id:UUID)->SessionRecord? {UserDefaults.standard.data(forKey:key(id)).flatMap{try? JSONDecoder().decode(SessionRecord.self,from:$0)}}
    static func record(_ value:SessionRecord,for id:UUID) {if let data=try? JSONEncoder().encode(value){UserDefaults.standard.set(data,forKey:key(id))}}
}
struct LogLine: Identifiable, Codable {
    let id:UUID;let date:Date;let text:String
    init(date:Date=Date(),text:String){id=UUID();self.date=date;self.text=text}
}
enum SessionDiagnostics {
    static var file:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FortiBreak/last-session.json")}
    static func load(from file:URL=SessionDiagnostics.file)->[LogLine] {
        guard let data=try? Data(contentsOf:file),data.count<2_000_000,let lines=try? JSONDecoder().decode([LogLine].self,from:data) else{return []}
        return Array(lines.suffix(400))
    }
    static func save(_ lines:[LogLine],to file:URL=SessionDiagnostics.file) {
        var kept=Array(lines.suffix(400))
        guard var data=try? JSONEncoder().encode(kept) else{return}
        while data.count>1_000_000 && !kept.isEmpty {
            kept.removeFirst();guard let smaller=try? JSONEncoder().encode(kept) else{return};data=smaller
        }
        let directory=file.deletingLastPathComponent()
        do {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}catch{return}
        let temp=directory.appendingPathComponent(".diagnostics-"+UUID().uuidString).path
        let fd=open(temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else{return}
        defer{close(fd);unlink(temp)}
        let complete=data.withUnsafeBytes{ bytes -> Bool in
            var written=0
            while written<bytes.count {
                let count=write(fd,bytes.baseAddress!.advanced(by:written),bytes.count-written)
                if count<0 && errno==EINTR{continue}
                guard count>0 else{return false};written+=count
            }
            return true
        }
        if complete{_ = rename(temp,file.path)}
    }
    static func snapshot()->String {
        // Fixed, read-only system commands: no external probes or credentials.
        [("/usr/sbin/scutil",["--nwi"]),("/usr/sbin/scutil",["--dns"]),("/usr/sbin/netstat",["-rn","-f","inet"])].map{path,args in
            let process=Process(),pipe=Pipe()
            process.executableURL=URL(fileURLWithPath:path);process.arguments=args
            process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            do {
                try process.run()
                let timeout=DispatchWorkItem{if process.isRunning{process.terminate()}}
                DispatchQueue.global().asyncAfter(deadline:.now()+3,execute:timeout)
                let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();timeout.cancel()
                return path+" "+args.joined(separator:" ")+"\n"+String(decoding:data.prefix(24576),as:UTF8.self)
            }catch{return path+": unavailable"}
        }.joined(separator:"\n")
    }
}
private final class SessionChannel: @unchecked Sendable {
    let directory: String
    var server: Int32
    var client: Int32 = -1
    let token=UUID()
    init(directory:String,server:Int32){self.directory=directory;self.server=server}
}

@MainActor final class TunnelManager: ObservableObject {
    @Published var state: TunnelState = .idle
    @Published var statusDetail = "Ready when you are."
    @Published var logs: [LogLine] = []
    @Published var prompt: String?
    @Published var connectedAt: Date?
    @Published var activeProfile: UUID?
    @Published var interfaceName = "—"
    @Published var received: UInt64 = 0
    @Published var sent: UInt64 = 0
    @Published var clock = Date()
    @Published var vpnAddress = "—"
    @Published var receiveRate: UInt64 = 0
    @Published var sendRate: UInt64 = 0
    @Published var history: [ThroughputSample] = []
    @Published var reconnectAttempt = 0
    @Published var helperInstalled = false
    var showWindow: (() -> Void)?
    private var channel: SessionChannel?
    private var sessionProfile: VPNProfile?
    private var reconnectProfile: VPNProfile?
    private var reconnectWork: DispatchWorkItem?
    private var lastTotals: (UInt64,UInt64)?
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true
    @Published var helperReady=false
    @Published var helperSetupBusy=false
    @Published var helperStatus="Enable VPN helper once."
    private var installer:Process?
    init(){
        if !CommandLine.arguments.contains("--preview"){logs=SessionDiagnostics.load()}
        refreshHelperState()
        pathMonitor.pathUpdateHandler={[weak self] path in let up=path.status == .satisfied;Task{@MainActor in self?.networkUp=up}}
        pathMonitor.start(queue:.global(qos:.utility))
    }
    func refreshHelperState() {
        do {
            let configuration=try TrustedFiles.configuration()
            let localHash=try CodeIdentity.hash(of:Bundle.main.bundlePath)
            helperReady=configuration.ownerUID==getuid() && configuration.appCDHash==localHash
        } catch {helperReady=false}
        helperInstalled=FileManager.default.fileExists(atPath:PrivilegedPaths.plist)
        helperStatus=helperReady ? "VPN helper approved for this build" : helperInstalled ? "This FortiBreak build needs the VPN helper approved again" : "One-time VPN helper setup needed"
    }
    func enableHelper(preview:Bool) {
        guard !preview,!busy,!helperSetupBusy else {return}
        guard let executable=Bundle.main.url(forAuxiliaryExecutable:"FortiBreakInstaller") else {helperStatus="Helper installer missing. Reinstall FortiBreak.";return}
        runInstaller(shellQuote(executable.path)+" "+shellQuote(Bundle.main.bundlePath)+" "+String(getuid()),waiting:"Approve the one-time macOS setup prompt.",failure:"Helper setup")
    }
    func removeHelper(preview:Bool) {
        guard !preview,!busy,!helperSetupBusy else {return}
        guard let executable=Bundle.main.url(forAuxiliaryExecutable:"FortiBreakInstaller") else {helperStatus="Helper installer missing. Reinstall FortiBreak.";return}
        runInstaller(shellQuote(executable.path)+" --uninstall",waiting:"Approve the macOS prompt to remove the helper.",failure:"Helper removal")
    }
    private func runInstaller(_ command:String,waiting:String,failure:String) {
        helperSetupBusy=true;helperStatus=waiting
        let process=Process(),errors=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript")
        process.arguments=["-e","do shell script \""+appleEscape(command)+"\" with administrator privileges"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=errors
        process.terminationHandler={ [weak self] result in
            let data=errors.fileHandleForReading.readDataToEndOfFile()
            let text=String(decoding:data.prefix(3000),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else {return}
                self.installer=nil;self.helperSetupBusy=false;self.refreshHelperState()
                if result.terminationStatus != 0 {self.helperStatus=text.contains("-128") ? failure+" cancelled." : failure+" failed. "+text}
                else if !self.helperInstalled {self.helperStatus="VPN helper removed. Enable it again to connect."}
            }
        }
        installer=process
        do {try process.run()} catch {installer=nil;helperSetupBusy=false;helperStatus=error.localizedDescription}
    }
    private var timer: Timer?
    private var baseline: (UInt64,UInt64)?
    private var stopRequested=false
    var afterStop: (() -> Void)?
    var busy: Bool { [.authorizing,.connecting,.authenticating,.connected,.reconnecting,.stopping].contains(state) }
    var activeName: String? { activeProfile == nil ? nil : sessionProfile?.name }
    func bringForward() {
        NSApplication.shared.activate(ignoringOtherApps:true)
        if let showWindow {showWindow()} else {NSApplication.shared.windows.first(where:{$0.canBecomeMain})?.makeKeyAndOrderFront(nil)}
    }
    var backendReady: Bool { Backend.executable != nil || FileManager.default.isExecutableFile(atPath:PrivilegedPaths.engine) }
    var elapsed: String {
        guard let start=connectedAt else{return "—"}
        let t=max(0,Int(clock.timeIntervalSince(start)))
        return String(format:"%02d:%02d:%02d",t/3600,(t/60)%60,t%60)
    }
    func log(_ text:String) {
        logs.append(LogLine(text:String(text.prefix(80000))));if logs.count > 400 { logs.removeFirst(logs.count-400) }
        if !CommandLine.arguments.contains("--preview"){SessionDiagnostics.save(logs)}
    }
    func clearLogs(){logs=[];if !CommandLine.arguments.contains("--preview"){SessionDiagnostics.save([])}}
    func captureNetwork(_ reason:String="Manual network snapshot") {
        guard !CommandLine.arguments.contains("--preview") else{return}
        let token=channel?.token
        log(reason+" — capturing local routes and DNS.")
        DispatchQueue.global(qos:.utility).async{[weak self] in
            let snapshot=SessionDiagnostics.snapshot()
            Task{@MainActor in
                guard let self,self.channel?.token==token else{return}
                self.log(reason+"\n"+snapshot)
            }
        }
    }
    func connect(_ profile: VPNProfile, password: String, preview: Bool) {
        guard !busy else{return}
        guard !preview else { state = .failed;statusDetail="Design preview cannot connect. Open the installed app normally.";return }
        reconnectWork?.cancel();reconnectWork=nil;reconnectProfile=nil;reconnectAttempt=0
        start(profile,password:password,resuming:false)
    }
    private func start(_ profile: VPNProfile, password: String, resuming: Bool) {
        sessionProfile=profile
        do {
            if try SystemFortiProfiles.hasActiveTunnel() {throw AppError("FortiClient is already connected. Disconnect it there first, then press Connect here.")}
            let request=ConnectRequest(profile:profile,password:password)
            if profile.login == .browser {try BrowserSSO.checkCallbackAvailable()}
            _=try Backend.arguments(request)
            guard backendReady else{throw AppError("VPN backend is missing. Install openfortivpn with Homebrew.")}
            refreshHelperState()
            guard helperReady,!helperSetupBusy else {throw AppError("Enable the VPN helper once before connecting.")}
            let directory="/tmp/fb-"+UUID().uuidString
            try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let fd: Int32
            do { fd=try UnixSocket.create(directory+"/control.sock",server:true) } catch { try? FileManager.default.removeItem(atPath:directory);throw error }
            let session=SessionChannel(directory:directory,server:fd);channel=session
            activeProfile=profile.id;state = .connecting;statusDetail=resuming ? "Reconnecting (attempt \(reconnectAttempt) of \(ReconnectPolicy.delays.count))…" : "Starting the approved VPN helper…";prompt=nil;stopRequested=false;resetCounters()
            if !resuming {logs=[]}
            log(resuming ? statusDetail : "Connection requested through the approved VPN helper.")
            log("Routing follows the gateway. Physical default route is preserved; macOS PPP manages DNS.")
            captureNetwork("Before VPN startup")
            let frozen=request
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                do {
                    _ = try PrivilegedClient.request(BrokerCommand(kind:"start",directory:directory))
                    var item=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                    guard poll(&item,1,6000)>0,item.revents & Int16(POLLIN) != 0 else {throw AppError("VPN worker did not start. Repair the helper and retry.")}
                    let accepted=accept(fd,nil,nil)
                    guard accepted>=0 else {throw AppError("VPN session channel closed.")}
                    var uid:uid_t=9999,gid:gid_t=9999
                    guard getpeereid(accepted,&uid,&gid)==0,uid==0 else {close(accepted);throw AppError("Unexpected VPN worker identity.")}
                    Task { @MainActor in self?.accepted(session,fd:accepted,request:frozen) }
                } catch {
                    let detail=error.localizedDescription
                    Task { @MainActor in
                        guard let self,self.channel?.token==session.token else {return}
                        self.finish(code:1,detail:detail)
                    }
                }
            }
        } catch { finish(code:1,detail:error.localizedDescription) }
    }
    private func accepted(_ session:SessionChannel,fd:Int32,request:ConnectRequest) {
        guard channel?.token==session.token,!stopRequested else{close(fd);return}
        _ = fcntl(fd,F_SETFD,FD_CLOEXEC)
        session.client=fd
        do{try UnixSocket.send(request,fd:fd)}catch{close(fd);session.client = -1;finish(code:1,detail:error.localizedDescription);return}
        state = .connecting;statusDetail="Authenticating with gateway…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            defer {close(fd)}
            var pending=Data(),bytes=[UInt8](repeating:0,count:8192),sawTerminal=false
            while true {
                let n=read(fd,&bytes,bytes.count)
                if n<=0{break}
                pending.append(contentsOf:bytes.prefix(n))
                while let end=pending.firstIndex(of:10) {
                    let data=Data(pending.prefix(upTo:end));pending.removeSubrange(...end)
                    if let event=try? JSONDecoder().decode(WireMessage.self,from:data) {
                        if ["exit","error"].contains(event.kind) {sawTerminal=true}
                        Task { @MainActor in self?.receive(event,token:session.token) }
                    }
                }
                if pending.count>1_000_000{break}
            }
            if !sawTerminal {
                Task { @MainActor in
                    guard let self,self.channel?.token==session.token else {return}
                    self.finish(code:1,detail:"VPN worker closed its session channel.")
                }
            }
        }
    }
    private func receive(_ event:WireMessage,token:UUID) {
        guard channel?.token==token else{return}
        switch event.kind {
        case "log":log(event.text)
        case "started":log("VPN engine started. Certificate verification is enabled.")
        case "connected":
            guard !stopRequested else{return}
            state = .connected;statusDetail="VPN tunnel is up.";connectedAt=Date();clock=Date();prompt=nil
            if let p=sessionProfile {
                SessionHistory.record(SessionRecord(start:Date(),end:nil),for:p.id)
                Notifier.post(reconnectAttempt>0 ? "VPN reconnected" : "VPN connected",p.name+" is connected.")
            }
            reconnectProfile=sessionProfile;reconnectAttempt=0
            captureNetwork("VPN connected")
            timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){ [weak self] _ in Task { @MainActor in self?.tick() } }
        case "interface":if interfaceName != event.text{interfaceName=event.text;baseline=nil}
        case "prompt":
            guard !stopRequested else{return}
            state = .authenticating;prompt=event.text;statusDetail=event.text
            if !NSApplication.shared.isActive {Notifier.post("FortiBreak needs you",event.text+".");bringForward()}
        case "browser":
            guard !stopRequested,let url=URL(string:event.text),url.scheme=="https" else{return}
            NSWorkspace.shared.open(url);statusDetail="Complete browser sign-in within about 50 seconds. Return here after login.";log("Browser sign-in opened. Callback is 127.0.0.1:8020; listener waits up to about 50 seconds. Session tokens are omitted from logs.")
        case "error":finish(code:1,detail:event.text)
        case "exit":finish(code:event.code ?? 1,detail:event.text.isEmpty ? nil : event.text)
        default:break
        }
    }
    func respond(_ text:String){guard let fd=channel?.client,fd>=0 else{return};do{try UnixSocket.send(WireMessage(kind:"input",text:text),fd:fd);prompt=nil;state = .connecting;statusDetail="Checking authentication response…"}catch{finish(code:1,detail:error.localizedDescription)}}
    func disconnect() {
        guard busy else{return}
        if state == .reconnecting {stopRequested=true;finish(code:0,detail:"Reconnect cancelled.");return}
        stopRequested=true;prompt=nil;state = .stopping;statusDetail="Closing tunnel and restoring network settings…"
        if let session=channel,session.client>=0{try? UnixSocket.send(WireMessage(kind:"stop"),fd:session.client);log("Disconnect requested. Waiting for network cleanup.")}
        else{finish(code:0,detail:"Connection cancelled.")}
    }
    private func finish(code:Int32,detail:String?=nil) {
        let wasStopped=stopRequested,wasConnected=connectedAt != nil
        timer?.invalidate();timer=nil;prompt=nil;connectedAt=nil
        reconnectWork?.cancel();reconnectWork=nil
        if let session=channel {
            channel=nil
            if session.client>=0{shutdown(session.client,SHUT_RDWR)}
            shutdown(session.server,SHUT_RDWR);close(session.server)
            try? FileManager.default.removeItem(atPath:session.directory)
        }
        if wasConnected,let p=sessionProfile,var last=SessionHistory.last(p.id),last.end==nil {last.end=Date();SessionHistory.record(last,for:p.id)}
        let ended=detail ?? (wasStopped ? "Disconnected. VPN process stopped." : code==0 ? "VPN session ended." : "VPN engine exited (\(code)). Open Activity for details.")
        if let profile=reconnectProfile,let delay=ReconnectPolicy.delay(enabled:Preferences.autoReconnect,wasConnected:true,userStopped:wasStopped,attempt:reconnectAttempt) {
            // Keep the profile active so the window and menu bar stay on this connection.
            state = .reconnecting;resetCounters()
            statusDetail=(reconnectAttempt==0 ? "Tunnel dropped." : "Reconnect attempt failed.")+" Reconnecting in \(Int(delay)) s (attempt \(reconnectAttempt+1) of \(ReconnectPolicy.delays.count))."
            log(ended);log(statusDetail)
            if reconnectAttempt==0 {Notifier.post("VPN dropped",profile.name+" lost its tunnel. FortiBreak is reconnecting.")}
            scheduleReconnect(profile,after:delay)
            captureNetwork("After VPN session")
            return
        }
        if !wasStopped,let profile=reconnectProfile {Notifier.post("VPN disconnected",profile.name+" is no longer connected. "+(Preferences.autoReconnect ? "Automatic reconnect gave up." : "Press Connect to try again."))}
        reconnectProfile=nil;reconnectAttempt=0
        activeProfile=nil
        state = wasStopped || code==0 ? .idle : .failed
        statusDetail=ended
        log(statusDetail);let callback=afterStop;afterStop=nil;callback?()
        captureNetwork("After VPN session")
    }
    private func scheduleReconnect(_ profile:VPNProfile,after delay:TimeInterval) {
        let work=DispatchWorkItem{[weak self] in Task{@MainActor in self?.attemptReconnect(profile)}}
        reconnectWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func attemptReconnect(_ profile:VPNProfile) {
        guard state == .reconnecting,!stopRequested else{return}
        // Waiting for Wi-Fi or wake does not use up an attempt.
        guard networkUp else {statusDetail="Waiting for a network connection before reconnecting…";scheduleReconnect(profile,after:5);return}
        reconnectAttempt+=1
        start(profile,password:CredentialStore.password(profile.id),resuming:true)
    }
    // Design preview of a live tunnel: sample values only, no helper or network.
    func previewConnected(_ profile:VPNProfile) {
        guard CommandLine.arguments.contains("--preview") else{return}
        sessionProfile=profile;activeProfile=profile.id;state = .connected;statusDetail="VPN tunnel is up."
        connectedAt=Date().addingTimeInterval(-4523);clock=Date();interfaceName="ppp0";vpnAddress="10.212.134.27"
        received=48_213_442;sent=6_120_331;receiveRate=182_400;sendRate=21_700
        let start=Date().addingTimeInterval(-4530)
        logs=["Connection requested through the approved VPN helper.","VPN engine started. Certificate verification is enabled.","Before VPN startup\n/usr/sbin/netstat -rn -f inet\nDestination        Gateway            Flags  Netif\ndefault            192.168.1.1        UGScg  en0","INFO:   Listening for SAML login on port 8020","Browser sign-in opened. Callback is 127.0.0.1:8020; listener waits up to about 50 seconds.","INFO:   Connected to gateway.","INFO:   Got addresses: [10.212.134.27], ns [10.0.0.53]","INFO:   Tunnel is up and running.","WARN:   Could not resolve an optional split-DNS domain."].enumerated().map{LogLine(date:start.addingTimeInterval(Double($0.offset)*1.5),text:$0.element)}
        if CommandLine.arguments.contains("--preview-connecting") {state = .connecting;statusDetail="Complete browser sign-in within about 50 seconds.";connectedAt=nil;return}
        history=(0..<60).map{i in let t=Double(i);return ThroughputSample(time:Date().addingTimeInterval(t-60),down:max(4_000,150_000+80_000*sin(t/6)+40_000*sin(t/2.3)+(i>40 ? 90_000 : 0)),up:max(1_000,22_000+12_000*sin(t/4)+6_000*cos(t/1.7)))}
    }
    private func resetCounters(){history=[];baseline=nil;lastTotals=nil;interfaceName="—";vpnAddress="—";received=0;sent=0;receiveRate=0;sendRate=0}
    private func tick(){
        clock=Date();guard interfaceName != "—" else{return}
        var addresses:UnsafeMutablePointer<ifaddrs>?;guard getifaddrs(&addresses)==0 else{return};defer{freeifaddrs(addresses)}
        var p=addresses
        while let item=p {
            defer{p=item.pointee.ifa_next}
            guard String(cString:item.pointee.ifa_name)==interfaceName,let address=item.pointee.ifa_addr else{continue}
            if address.pointee.sa_family==UInt8(AF_INET) {
                var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
                if getnameinfo(address,socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)==0 {vpnAddress=String(cString:host)}
            }
            if address.pointee.sa_family==UInt8(AF_LINK),let data=item.pointee.ifa_data?.assumingMemoryBound(to:if_data.self) {
                let pair=(UInt64(data.pointee.ifi_ibytes),UInt64(data.pointee.ifi_obytes))
                if baseline==nil{baseline=pair}
                received=pair.0>=baseline!.0 ? pair.0-baseline!.0:0;sent=pair.1>=baseline!.1 ? pair.1-baseline!.1:0
                if let last=lastTotals {receiveRate=received>=last.0 ? received-last.0:0;sendRate=sent>=last.1 ? sent-last.1:0}
                if lastTotals != nil {history.append(ThroughputSample(time:clock,down:Double(receiveRate),up:Double(sendRate)));if history.count>90{history.removeFirst(history.count-90)}}
                lastTotals=(received,sent)
            }
        }
    }
    private func shellQuote(_ s:String)->String{"'"+s.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func appleEscape(_ s:String)->String{s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")}
}

enum SystemFortiProfiles {
    private static func query(_ arguments:[String]) throws -> String {
        let process=Process(),pipe=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/sbin/scutil")
        process.arguments=["--nc"]+arguments
        process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        try process.run()
        let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus==0 else {throw AppError("macOS could not read FortiClient VPN service details.")}
        return String(decoding:data,as:UTF8.self)
    }
    static func load() throws -> ImportResult {
        let services=FortiSystemParser.services(try query(["list"]))
        guard !services.isEmpty else {throw AppError("No FortiClient VPN service found in macOS. Import an export or create a connection manually.")}
        let items=try services.map{try FortiSystemParser.profile(query(["show",$0.id]),service:$0)}
        return ImportResult(items:items)
    }
    static func hasActiveTunnel() throws -> Bool {FortiSystemParser.services(try query(["list"])).contains{$0.connected}}
}
