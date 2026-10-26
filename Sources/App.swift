import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import ServiceManagement

// Select the stable property wrapper when the SDK also exposes a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Design {
    static let palette:[Color]=[.blue,.indigo,.purple,.pink,.teal,.orange,.cyan,.mint]
    static func color(for profile:VPNProfile)->Color{palette[Int(profile.id.uuid.0)%palette.count]}
    private static let byteFormatter:ByteCountFormatter={let f=ByteCountFormatter();f.countStyle = .binary;f.allowsNonnumericFormatting=false;return f}()
    static func bytes(_ n:UInt64)->String{byteFormatter.string(fromByteCount:Int64(n))}
    static var version:String{Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev"}
    static func lastSession(_ entry:SessionEntry?)->(when:String,detail:String)? {
        guard let entry else{return nil}
        let when=entry.start.formatted(.relative(presentation:.named)).capitalizedFirst
        return entry.end == nil ? (when,"Still connected") : (when,"for "+duration(entry.duration()))
    }
    static func duration(_ seconds:TimeInterval)->String {
        let minutes=max(seconds>0 ? 1 : 0,Int(seconds/60))
        return minutes>=60 ? "\(minutes/60) h \(minutes%60) min" : "\(minutes) min"
    }
    static func quality(_ quality:TunnelQuality)->(symbol:String,color:Color) {
        switch quality {
        case .good:("checkmark.circle.fill",.green)
        case .slow:("tortoise.fill",.orange)
        case .stalled:("exclamationmark.octagon.fill",.red)
        case .measuring:("ellipsis.circle",.secondary)
        case .unavailable:("questionmark.circle",.secondary)
        }
    }
}
extension String {var capitalizedFirst:String{prefix(1).uppercased()+dropFirst()}}

// One visual language for every state: tint, glyph and wording.
enum Phase:Equatable {
    case idle,unavailable,working,connected,paused,failed
    var tint:Color{switch self{case .connected:.green;case .working:.orange;case .paused:.purple;case .failed:.red;case .unavailable:.gray;case .idle:.accentColor}}
}

final class AppDelegate:NSObject,NSApplicationDelegate {
    weak var tunnel:TunnelManager?
    var launchHandled=false
    func applicationWillFinishLaunching(_ notification:Notification){LinkReceiver.shared.register()}
    func applicationDidFinishLaunching(_ notification:Notification){Notifier.requestPermission();LinkReceiver.shared.register()}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard let tunnel,tunnel.busy else{return .terminateNow}
        tunnel.afterStop={sender.reply(toApplicationShouldTerminate:true)}
        tunnel.disconnect()
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}

@main struct FortiBreakApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var profiles:ProfileStore
    @StateObject private var tunnel:TunnelManager
    @StateObject private var controller:AppController
    init() {
        let store=ProfileStore(preview:CommandLine.arguments.contains("--preview")),tunnel=TunnelManager()
        _profiles=StateObject(wrappedValue:store);_tunnel=StateObject(wrappedValue:tunnel)
        _controller=StateObject(wrappedValue:AppController(store:store,tunnel:tunnel))
    }
    var body:some Scene{
        Window("FortiBreak",id:"main"){
            MainView(store:profiles,tunnel:tunnel).frame(minWidth:780,minHeight:600)
                .preferredColorScheme(CommandLine.arguments.contains("--preview-dark") ? .dark : nil).onAppear{delegate.tunnel=tunnel;NSApplication.shared.activate(ignoringOtherApps:true);tunnel.refreshHelperState();connectOnLaunch()}
        }
        .defaultSize(width:1000,height:760)
        .commands{
            CommandGroup(replacing:.newItem){Button("Import VPN Profiles…"){NotificationCenter.default.post(name:.init("importProfiles"),object:nil)}.keyboardShortcut("o");Button("New Connection…"){NotificationCenter.default.post(name:.init("newProfile"),object:nil)}.keyboardShortcut("n")}
            CommandMenu("Connection"){
                Button(tunnel.state == .reconnecting ? "Cancel Reconnect" : tunnel.busy ? "Disconnect" : "Connect"){
                    if tunnel.busy{tunnel.disconnect()} else if let p=profiles.current{tunnel.connect(p,password:CredentialStore.password(p.id),preview:profiles.preview)}
                }.keyboardShortcut("k").disabled(tunnel.state == .stopping || (!tunnel.busy && (profiles.current?.unsupported != nil || profiles.current == nil || !tunnel.helperReady)))
                Button("Show Activity"){NotificationCenter.default.post(name:.init("showActivity"),object:nil)}.keyboardShortcut("l")
            }
        }
        MenuBarExtra{MenuPanel(store:profiles,tunnel:tunnel,controller:controller)} label:{Image(systemName:MenuPanel.icon(tunnel.state))}
            .menuBarExtraStyle(.window)
        Settings{SettingsView(store:profiles,tunnel:tunnel,controller:controller)}
    }
    private func connectOnLaunch() {
        guard !delegate.launchHandled else{return}
        delegate.launchHandled=true
        if ["--preview-connected","--preview-connecting","--preview-paused","--preview-expiring"].contains(where:CommandLine.arguments.contains),let p=profiles.current {tunnel.previewConnected(p)}
        controller.launch()
    }
}

struct MainView:View {
    @ObservedObject var store:ProfileStore
    @ObservedObject var tunnel:TunnelManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ViewState<String> private var search=""
    @ViewState private var editor: VPNProfile?
    @ViewState private var imported: ImportResult?
    @ViewState<Bool> private var importOpen=false
    @ViewState<Int> private var page=CommandLine.arguments.contains("--preview-activity") ? 3 : CommandLine.arguments.contains("--preview-history") ? 2 : CommandLine.arguments.contains("--preview-network") ? 1 : 0
    @ViewState<Bool> private var confirmClearHistory=false
    @ViewState private var deleteTarget: VPNProfile?
    @ViewState<String> private var password=""
    @ViewState<Bool> private var savePassword=false
    @ViewState<String> private var response=""
    @ViewState<String> private var activityFilter=""
    @ViewState private var error: String?
    private var visible:[VPNProfile]{store.profiles.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)}.sorted{a,b in a.favorite != b.favorite ? a.favorite : a.name.localizedStandardCompare(b.name) == .orderedAscending}}
    private var active:Bool{tunnel.activeProfile==store.selected && tunnel.busy}
    private var connected:Bool{active && tunnel.state == .connected}
    var body:some View{
        NavigationSplitView{sidebar} detail:{detail}
            .fileImporter(isPresented:$importOpen,allowedContentTypes:[.item],allowsMultipleSelection:false){result in
                do{guard let url=try result.get().first else{return};let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}};imported=try ProfileImporter.load(url)}catch{self.error=error.localizedDescription}
            }
            .sheet(item:$editor){profile in ProfileEditor(profile:profile,isNew:!store.profiles.contains{$0.id == profile.id}){p in do{try store.save(p);editor=nil}catch{self.error=error.localizedDescription}}}
            .sheet(isPresented:Binding(get:{imported != nil},set:{if !$0{imported=nil}})){
                if let result=imported{ImportPreview(result:result){save in do{try store.importItems(result.items,savePasswords:save);imported=nil;page=0}catch{self.error=error.localizedDescription}}}
            }
            .alert("Could Not Complete Action",isPresented:Binding(get:{error != nil || store.error != nil},set:{if !$0{error=nil;store.error=nil}})){Button("OK"){error=nil;store.error=nil}}message:{Text(error ?? store.error ?? "")}
            .confirmationDialog("Delete this connection?",isPresented:Binding(get:{deleteTarget != nil},set:{if !$0{deleteTarget=nil}}),titleVisibility:.visible){Button("Delete",role:.destructive){if let p=deleteTarget{store.remove(p)};deleteTarget=nil};Button("Cancel",role:.cancel){deleteTarget=nil}}message:{Text("Its saved password in FortiBreak’s Keychain is also removed. FortiClient is unaffected.")}
            .onReceive(NotificationCenter.default.publisher(for:.init("importProfiles"))){_ in importOpen=true}
            .onReceive(NotificationCenter.default.publisher(for:.init("newProfile"))){_ in editor=VPNProfile()}
            .onReceive(NotificationCenter.default.publisher(for:.init("showActivity"))){_ in page=3}
            .confirmationDialog("Clear connection history?",isPresented:$confirmClearHistory){Button("Clear History",role:.destructive){tunnel.clearHistory()}}message:{Text("Removes past sessions for every connection. A learned session limit is forgotten too.")}
            .onChange(of:store.selected){_,_ in password="";savePassword=false;page=0}
            .onAppear{
                tunnel.showWindow={openWindow(id:"main")}
                // Design preview: open screens that otherwise need clicks.
                guard store.preview else{return}
                if CommandLine.arguments.contains(where:{$0.hasPrefix("--preview-settings")}) {openSettings()}
                if CommandLine.arguments.contains("--preview-editor") {editor=store.current}
                if CommandLine.arguments.contains("--preview-hud") {DispatchQueue.main.asyncAfter(deadline:.now()+1){HUD.show(symbol:"lock.shield.fill",title:"Connecting",detail:store.current?.name ?? "",tint:.accentColor)}}
            }
    }

    // MARK: Sidebar
    private var sidebar:some View{
        List(selection:$store.selected){
            Section("Connections"){
                ForEach(visible){p in
                    ProfileRow(profile:p,phase:tunnel.activeProfile == p.id && tunnel.busy ? (tunnel.state == .connected ? .connected : tunnel.state == .paused ? .paused : .working) : .idle,
                               status:tunnel.activeProfile == p.id && tunnel.busy ? (tunnel.state == .connected ? "Connected · "+tunnel.elapsed : tunnel.state.rawValue+"…") : nil)
                        .tag(p.id)
                        .contextMenu{
                            Button(tunnel.activeProfile == p.id && tunnel.busy ? "Disconnect" : "Connect"){store.selected=p.id;primaryAction(p)}.disabled(!primaryEnabled(p))
                            Divider()
                            Button(p.favorite ? "Remove from Favorites" : "Add to Favorites"){store.toggleFavorite(p)}
                            Button("Edit…"){editor=p}.disabled(tunnel.busy)
                            Divider()
                            Button("Delete…",role:.destructive){deleteTarget=p}.disabled(tunnel.busy)
                        }
                }
            }
        }
        .searchable(text:$search,placement:.sidebar,prompt:"Search")
        .navigationSplitViewColumnWidth(min:210,ideal:240,max:320)
        .safeAreaInset(edge:.bottom,spacing:0){engineFooter}
        .toolbar{
            ToolbarItem{
                Menu{
                    Button("Import Profiles…",systemImage:"square.and.arrow.down"){importOpen=true}
                    Button("Use FortiClient Profile",systemImage:"arrow.down.app"){importCurrentFortiProfile()}
                    Divider()
                    Button("New Connection…",systemImage:"plus"){editor=VPNProfile()}
                } label:{Label("Add Connection",systemImage:"plus")}.help("Add a connection")
            }
        }
    }
    private var engineFooter:some View{
        HStack(spacing:8){
            Image(systemName:tunnel.helperReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(tunnel.helperReady ? Color.green : Color.orange)
            Text(tunnel.helperReady ? "Helper ready" : "Helper needs approval").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("v"+Design.version).font(.caption2).foregroundStyle(.tertiary)
        }.padding(.horizontal,16).padding(.vertical,10)
    }
    private func importCurrentFortiProfile() {
        do { imported=try SystemFortiProfiles.load() } catch { self.error=error.localizedDescription }
    }

    // MARK: Detail
    @ViewBuilder private var detail:some View{
        if store.profiles.isEmpty {
            WelcomeView(onFortiClient:importCurrentFortiProfile,onImport:{importOpen=true},onCreate:{editor=VPNProfile()})
        } else if let p=store.current {
            Group{
                switch page {
                case 1:NetworkPage(tunnel:tunnel,profile:p,connected:connected)
                case 2:HistoryPage(tunnel:tunnel,profile:p)
                case 3:activity
                default:overview(p)
                }
            }
                .navigationTitle(p.name)
                .navigationSubtitle(connected ? "Connected · "+tunnel.elapsed : active ? tunnel.state.rawValue : p.host)
                .toolbar{detailToolbar(p)}
        } else {
            ContentUnavailableView("Select a Connection",systemImage:"network",description:Text("Choose a connection in the sidebar."))
        }
    }
    @ToolbarContentBuilder private func detailToolbar(_ p:VPNProfile)->some ToolbarContent{
        ToolbarItem(placement:.principal){
            Picker("View",selection:$page){Text("Overview").tag(0);Text("Network").tag(1);Text("History").tag(2);Text("Activity").tag(3)}.pickerStyle(.segmented).fixedSize().help("Overview, routes and DNS, past sessions, or the activity log (⌘L)")
        }
        if page==1 {
            ToolbarItem{Button("Refresh",systemImage:"arrow.clockwise"){tunnel.refreshRoutes()}.disabled(!connected).help("Read the routing table again")}
        } else if page==2 {
            ToolbarItem{Button("Clear History",systemImage:"trash"){confirmClearHistory=true}.disabled(tunnel.sessions.isEmpty).help("Clear past sessions")}
        } else if page==3 {
            ToolbarItemGroup{
                Button("Check Network",systemImage:"stethoscope"){tunnel.captureNetwork()}.help("Record local routes and DNS servers. No external probe is made.")
                Button("Copy",systemImage:"doc.on.doc"){copyLogs()}.disabled(tunnel.logs.isEmpty).help("Copy the shown events. Review addresses before sharing.")
                Button("Clear",systemImage:"trash"){tunnel.clearLogs()}.disabled(tunnel.busy || tunnel.logs.isEmpty).help("Clear the saved activity")
            }
        } else {
            ToolbarItem{Button(p.favorite ? "Remove from Favorites" : "Add to Favorites",systemImage:p.favorite ? "star.fill" : "star"){store.toggleFavorite(p)}.help(p.favorite ? "Remove from Favorites" : "Add to Favorites")}
            ToolbarItem{Button("Edit",systemImage:"slider.horizontal.3"){editor=p}.disabled(tunnel.busy).help("Edit connection settings")}
        }
    }

    // MARK: Overview
    private func phase(_ p:VPNProfile)->Phase{
        if connected {return .connected}
        if active && tunnel.state == .paused {return .paused}
        if active {return .working}
        if !primaryEnabled(p) {return .unavailable}
        return tunnel.state == .failed ? .failed : .idle
    }
    private func overview(_ p:VPNProfile)->some View{
        let phase=phase(p)
        return ScrollView{
            VStack(spacing:22){
                hero(p,phase:phase)
                if let reason=p.unsupported {Banner(symbol:"exclamationmark.triangle.fill",tint:.orange,title:"Import only",message:reason){EmptyView()}}
                if connected && tunnel.expiryWarning,let ends=tunnel.sessionEndsAt {
                    Banner(symbol:"hourglass",tint:.orange,title:"Gateway session ends around "+ends.formatted(date:.omitted,time:.shortened),message:"Sign in again now so the VPN does not drop in the middle of something."){
                        Button("Sign In Again"){tunnel.renewSession()}.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                if !tunnel.helperReady || tunnel.helperSetupBusy {
                    Banner(symbol:"lock.shield.fill",tint:.accentColor,title:tunnel.helperInstalled ? "Approve the VPN helper for this version" : "Enable the VPN helper",message:"A one-time macOS administrator prompt. FortiBreak never sees your password."){
                        if tunnel.helperSetupBusy {ProgressView().controlSize(.small)}
                        else {Button(tunnel.helperInstalled ? "Approve…" : "Enable…"){tunnel.enableHelper(preview:store.preview)}.buttonStyle(.borderedProminent).controlSize(.large).disabled(tunnel.busy || store.preview)}
                    }
                }
                if active,let prompt=tunnel.prompt {
                    Card(title:"Verification",symbol:"key.fill",tint:.orange){
                        Text(prompt).font(.headline)
                        HStack{
                            SecureField("Code or response",text:$response).textFieldStyle(.roundedBorder).controlSize(.large).onSubmit{submitResponse()}
                            Button("Continue"){submitResponse()}.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(response.isEmpty)
                        }
                    }
                }
                if !active && p.login == .password && p.unsupported == nil {
                    Card(title:"Sign In",symbol:"key.fill",tint:.accentColor){
                        SecureField("Password",text:$password,prompt:Text("Leave empty to use the saved Keychain password")).textFieldStyle(.roundedBorder).controlSize(.large).onSubmit{if primaryEnabled(p){primaryAction(p)}}
                        Toggle("Save password in Keychain",isOn:$savePassword).toggleStyle(.checkbox)
                    }
                }
                if connected {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:330),spacing:14,alignment:.top)],spacing:14){ThroughputCard(tunnel:tunnel);HealthCard(tunnel:tunnel)}
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:200),spacing:14)],spacing:14){
                    if connected {
                        Card(title:"Session",symbol:"clock.fill",tint:.green){
                            CardValue(tunnel.elapsed)
                            CardNote((tunnel.connectedAt.map{"Since "+$0.formatted(date:.omitted,time:.shortened)} ?? "")+(tunnel.sessionEndsAt.map{" · ends ~"+$0.formatted(date:.omitted,time:.shortened)} ?? ""))
                        }
                        Card(title:"VPN Address",symbol:"number",tint:.purple){
                            CardValue(tunnel.vpnAddress)
                            CardNote("Interface "+tunnel.interfaceName)
                        }
                    }
                    Card(title:"Gateway",symbol:"server.rack",tint:.blue){
                        CardValue(p.host)
                        CardNote("Port \(p.port) · "+(p.vpnProtocol == "ssl" ? "SSL VPN" : "IPsec"))
                    }
                    Card(title:"Sign-in",symbol:p.login == .browser ? "safari.fill" : "person.badge.key.fill",tint:.indigo){
                        CardValue(p.login == .browser ? "Browser SSO" : "Password & MFA")
                        CardNote(p.username.isEmpty ? (p.realm.isEmpty ? "No username" : "Realm "+p.realm) : p.username)
                    }
                    if !connected {
                        Card(title:"Last Session",symbol:"calendar",tint:.teal){
                            let last=Design.lastSession(tunnel.lastSession(p.id))
                            CardValue(last?.when ?? "Never")
                            CardNote(last?.detail ?? "Tracked after your first connection")
                        }
                    }
                }
                if !p.importWarnings.isEmpty {
                    Card(title:"Import Notes",symbol:"info.circle.fill",tint:.orange){
                        ForEach(p.importWarnings,id:\.self){Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                    }
                }
                Label("Credentials stay in your Keychain. The helper needs administrator approval only during setup.",systemImage:"lock.fill")
                    .font(.caption).foregroundStyle(.tertiary).padding(.top,4)
            }
            .padding(.horizontal,32).padding(.top,12).padding(.bottom,28)
            .frame(maxWidth:860).frame(maxWidth:.infinity)
        }
        .background(alignment:.top){
            RadialGradient(colors:[phase.tint.opacity(0.22),phase.tint.opacity(0.06),.clear],center:.top,startRadius:0,endRadius:560)
                .frame(height:560).ignoresSafeArea().allowsHitTesting(false)
                .animation(.easeInOut(duration:0.7),value:phase)
        }
    }
    private func hero(_ p:VPNProfile,phase:Phase)->some View{
        VStack(spacing:12){
            PowerButton(phase:phase){primaryAction(p)}
                .help(active ? primaryTitle : phase == .unavailable ? "Not available yet" : "Connect (⌘K)")
            Text(heroTitle(phase)).font(.system(size:32,weight:.bold,design:.rounded)).contentTransition(.opacity)
            Text(heroSubtitle(p,phase:phase)).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:460)
            if phase == .paused {
                HStack(spacing:10){
                    Button("Resume Now"){tunnel.resumeNow()}.buttonStyle(.borderedProminent).tint(.purple)
                    Button("Stay Off"){tunnel.disconnect()}.buttonStyle(.bordered)
                }.controlSize(.large).padding(.top,2)
            } else if active && !connected && tunnel.state != .stopping {
                Button(primaryTitle,role:.cancel){primaryAction(p)}.buttonStyle(.bordered).controlSize(.regular).padding(.top,2)
            }
            if connected {
                HStack(spacing:10){
                    Button("Disconnect",role:.destructive){primaryAction(p)}.buttonStyle(.bordered).tint(.red)
                    Menu{
                        ForEach([15,30,60,120],id:\.self){minutes in Button(minutes<60 ? "\(minutes) minutes" : minutes==60 ? "1 hour" : "\(minutes/60) hours"){tunnel.pause(minutes:minutes)}}
                    } label:{Label("Pause",systemImage:"pause.fill")}.menuStyle(.button).buttonStyle(.bordered).fixedSize().help("Disconnect now and reconnect automatically later")
                    if tunnel.sessionEndsAt != nil {Button("Sign In Again"){tunnel.renewSession()}.buttonStyle(.bordered).help("Start a fresh gateway session now")}
                }.controlSize(.regular).padding(.top,2)
                HStack(spacing:8){
                    Chip(symbol:Design.quality(tunnel.quality).symbol,text:tunnel.quality.rawValue+(HealthPolicy.median(tunnel.health).map{" · \(Int($0.rounded())) ms"} ?? ""))
                    Chip(symbol:"clock",text:tunnel.elapsed)
                    Chip(symbol:"number",text:tunnel.vpnAddress)
                    Chip(symbol:"arrow.down",text:Design.bytes(tunnel.receiveRate)+"/s")
                    Chip(symbol:"arrow.up",text:Design.bytes(tunnel.sendRate)+"/s")
                }.padding(.top,4)
            }
        }
        .frame(maxWidth:.infinity).padding(.top,6).padding(.bottom,8)
        .animation(.spring(response:0.45,dampingFraction:0.85),value:phase)
    }
    private func heroTitle(_ phase:Phase)->String{
        switch phase {
        case .connected:"Connected"
        case .working:tunnel.state.rawValue
        case .paused:"Paused"
        case .failed:"Couldn’t Connect"
        default:"Not Connected"
        }
    }
    private func heroSubtitle(_ p:VPNProfile,phase:Phase)->String{
        if active || phase == .failed {return tunnel.statusDetail}
        if tunnel.busy {return "Another connection is active. Disconnect it first."}
        if p.unsupported != nil {return "IPsec profiles can be reviewed but not connected yet."}
        if !tunnel.helperReady {return "Approve the VPN helper below to start connecting."}
        return "Click to connect to "+p.host+"."
    }
    private var primaryTitle:String{active ? (tunnel.state == .reconnecting ? "Cancel Reconnect" : tunnel.state == .paused ? "Resume Now" : tunnel.state == .connected ? "Disconnect" : "Cancel") : "Connect"}
    private func primaryEnabled(_ p:VPNProfile)->Bool {
        if tunnel.activeProfile == p.id && tunnel.busy {return tunnel.state != .stopping}
        return p.unsupported == nil && !tunnel.busy && tunnel.backendReady && !tunnel.helperSetupBusy && tunnel.helperReady
    }
    private func primaryAction(_ p:VPNProfile) {
        if tunnel.activeProfile == p.id && tunnel.state == .paused {tunnel.resumeNow();return}
        if tunnel.activeProfile == p.id && tunnel.busy {tunnel.disconnect();return}
        guard primaryEnabled(p) else{return}
        do{if savePassword && !password.isEmpty{try CredentialStore.save(password,id:p.id)};let secret=password.isEmpty ? CredentialStore.password(p.id):password;tunnel.connect(p,password:secret,preview:store.preview);password=""}catch{self.error=error.localizedDescription}
    }
    private func submitResponse(){tunnel.respond(response);response=""}

    // MARK: Activity
    private var shownLogs:[LogLine]{activityFilter.isEmpty ? tunnel.logs : tunnel.logs.filter{$0.text.localizedCaseInsensitiveContains(activityFilter)}}
    private var activity:some View{
        ScrollViewReader{proxy in
            List{
                ForEach(shownLogs){line in ActivityRow(line:line).id(line.id).listRowSeparator(.hidden)}
            }
            .listStyle(.inset)
            .overlay{
                if shownLogs.isEmpty {
                    ContentUnavailableView(tunnel.logs.isEmpty ? "No Activity Yet" : "No Matching Events",systemImage:tunnel.logs.isEmpty ? "waveform.path.ecg" : "magnifyingglass",description:Text(tunnel.logs.isEmpty ? "Connection events appear here after you connect." : "Try a different filter."))
                }
            }
            .onChange(of:tunnel.logs.count){_,_ in if activityFilter.isEmpty,let id=tunnel.logs.last?.id{withAnimation{proxy.scrollTo(id,anchor:.bottom)}}}
        }
        .searchable(text:$activityFilter,prompt:"Filter Events")
        .safeAreaInset(edge:.bottom,spacing:0){
            HStack(spacing:6){Image(systemName:"lock.fill");Text(activityFilter.isEmpty ? "\(tunnel.logs.count) events · passwords and session tokens are redacted · kept after quitting" : "\(shownLogs.count) of \(tunnel.logs.count) events");Spacer()}
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal,16).padding(.vertical,8).background(.bar)
        }
    }
    private func copyLogs() {
        let text=shownLogs.map{$0.date.formatted(date:.omitted,time:.standard)+"  "+$0.text}.joined(separator:"\n")
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
    }
}

// MARK: - Components

struct IconBadge:View {
    let symbol:String
    let color:Color
    var size:CGFloat=28
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:size*0.27,style:.continuous).fill(color.gradient)
            RoundedRectangle(cornerRadius:size*0.27,style:.continuous).strokeBorder(.white.opacity(0.18),lineWidth:0.5)
            Image(systemName:symbol).font(.system(size:size*0.5,weight:.semibold)).foregroundStyle(.white)
        }
        .frame(width:size,height:size)
        .shadow(color:color.opacity(0.25),radius:size*0.08,y:size*0.04)
    }
}

struct PowerButton:View {
    let phase:Phase
    let action:()->Void
    @ViewState<Bool> private var hovering=false
    @ViewState<Bool> private var spin=false
    @ViewState<Bool> private var breathe=false
    private var animated:Bool{phase == .working || phase == .connected}
    var body:some View {
        Button(action:action){
            ZStack {
                Circle().fill(phase.tint.opacity(0.07)).frame(width:216,height:216).scaleEffect(breathe ? 1.05 : 0.95)
                Circle().fill(phase.tint.opacity(0.12)).frame(width:172,height:172)
                if phase == .working {
                    Circle().trim(from:0,to:0.3).stroke(phase.tint.gradient,style:StrokeStyle(lineWidth:4,lineCap:.round))
                        .frame(width:172,height:172).rotationEffect(.degrees(spin ? 360 : 0))
                }
                Circle().fill(phase.tint.gradient).frame(width:128,height:128)
                    .overlay(Circle().fill(LinearGradient(colors:[.white.opacity(0.28),.clear],startPoint:.top,endPoint:.center)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25),lineWidth:1))
                    .shadow(color:phase == .unavailable ? .clear : phase.tint.opacity(hovering ? 0.6 : 0.42),radius:hovering ? 28 : 20,y:10)
                Image(systemName:phase == .connected ? "lock.shield.fill" : phase == .paused ? "play.fill" : "power")
                    .font(.system(size:46,weight:.semibold)).foregroundStyle(.white.opacity(phase == .unavailable ? 0.85 : 1))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width:220,height:220)
            .contentShape(Circle().inset(by:24))
            .scaleEffect(hovering && phase != .unavailable ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .disabled(phase == .unavailable)
        .onHover{h in withAnimation(.easeOut(duration:0.18)){hovering=h}}
        .onChange(of:phase,initial:true){_,p in
            if p == .working {spin=false;withAnimation(.linear(duration:1.1).repeatForever(autoreverses:false)){spin=true}} else {spin=false}
            if p == .working || p == .connected || p == .paused {withAnimation(.easeInOut(duration:2.4).repeatForever(autoreverses:true)){breathe=true}}
            else {withAnimation(.easeOut(duration:0.3)){breathe=false}}
        }
        .accessibilityLabel(phase == .connected ? "Disconnect" : phase == .paused ? "Resume" : "Connect")
    }
}

struct Chip:View {
    let symbol:String
    let text:String
    var body:some View {
        Label(text,systemImage:symbol).font(.callout.weight(.medium)).monospacedDigit()
            .padding(.horizontal,11).padding(.vertical,6)
            .background(.regularMaterial,in:Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .textSelection(.enabled)
    }
}

struct Card<Content:View>:View {
    let title:String
    let symbol:String
    let tint:Color
    @ViewBuilder var content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:7) {
                Image(systemName:symbol).font(.system(size:11,weight:.bold)).foregroundStyle(tint)
                Text(title.uppercased()).font(.system(size:11,weight:.semibold)).tracking(0.6).foregroundStyle(.secondary)
            }
            content
        }
        .padding(16).frame(maxWidth:.infinity,minHeight:92,alignment:.topLeading)
        .background(.background.opacity(0.7),in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color:.black.opacity(0.04),radius:8,y:3)
    }
}
struct CardValue:View {
    let text:String
    init(_ text:String){self.text=text}
    var body:some View {
        Text(text).font(.system(.title2,design:.rounded).weight(.semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled).contentTransition(.numericText())
    }
}
struct CardNote:View {
    let text:String
    init(_ text:String){self.text=text}
    var body:some View {Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)}
}

struct Banner<Trailing:View>:View {
    let symbol:String
    let tint:Color
    let title:String
    let message:String
    @ViewBuilder var trailing:Trailing
    var body:some View {
        HStack(spacing:14) {
            IconBadge(symbol:symbol,color:tint,size:38)
            VStack(alignment:.leading,spacing:3){Text(title).font(.headline);Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            Spacer(minLength:12)
            trailing
        }
        .padding(16)
        .background(tint.opacity(0.08),in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(tint.opacity(0.2)))
    }
}

struct ThroughputCard:View {
    @ObservedObject var tunnel:TunnelManager
    var body:some View {
        Card(title:"Throughput",symbol:"waveform.path.ecg",tint:.green){
            HStack(alignment:.top,spacing:28){
                stat("Download",symbol:"arrow.down.circle.fill",color:.green,rate:tunnel.receiveRate,total:tunnel.received)
                stat("Upload",symbol:"arrow.up.circle.fill",color:.blue,rate:tunnel.sendRate,total:tunnel.sent)
                Spacer()
            }
            Chart {
                ForEach(tunnel.history){sample in
                    AreaMark(x:.value("Time",sample.time),y:.value("Download",sample.down),series:.value("Direction","Download"))
                        .foregroundStyle(LinearGradient(colors:[Color.green.opacity(0.32),Color.green.opacity(0.02)],startPoint:.top,endPoint:.bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x:.value("Time",sample.time),y:.value("Download",sample.down),series:.value("Direction","Download"))
                        .foregroundStyle(Color.green).lineStyle(StrokeStyle(lineWidth:2,lineCap:.round)).interpolationMethod(.catmullRom)
                    LineMark(x:.value("Time",sample.time),y:.value("Upload",sample.up),series:.value("Direction","Upload"))
                        .foregroundStyle(Color.blue).lineStyle(StrokeStyle(lineWidth:2,lineCap:.round)).interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain:0...max(16_384,(tunnel.history.map{max($0.down,$0.up)}.max() ?? 0)*1.15))
            .chartYAxis{
                AxisMarks(position:.trailing,values:.automatic(desiredCount:3)){value in
                    AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[3,4]))
                    AxisValueLabel{if let v=value.as(Double.self){Text(Design.bytes(UInt64(max(0,v)))+"/s").font(.caption2)}}
                }
            }
            .chartLegend(.hidden)
            .frame(height:120)
            .overlay{if tunnel.history.count<2{Text("Measuring…").font(.callout).foregroundStyle(.secondary)}}
        }
    }
    private func stat(_ title:String,symbol:String,color:Color,rate:UInt64,total:UInt64)->some View{
        VStack(alignment:.leading,spacing:2){
            Label(title,systemImage:symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(Design.bytes(rate)+"/s").font(.system(.title2,design:.rounded).weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(Design.bytes(total)+" this session").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProfileRow:View {
    let profile:VPNProfile
    let phase:Phase
    var status:String?=nil
    var body:some View {
        HStack(spacing:10) {
            IconBadge(symbol:profile.vpnProtocol == "ssl" ? "network" : "lock.shield.fill",color:Design.color(for:profile),size:30)
                .overlay(alignment:.bottomTrailing){
                    if phase == .connected || phase == .working {
                        Circle().fill(phase.tint).frame(width:10,height:10).overlay(Circle().strokeBorder(.background,lineWidth:2)).offset(x:3,y:3)
                    }
                }
            VStack(alignment:.leading,spacing:1) {
                Text(profile.name).font(.body.weight(.medium)).lineLimit(1)
                Text(status ?? (profile.vpnProtocol == "ssl" ? profile.host : "IPsec · import only"))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength:0)
            if profile.favorite {Image(systemName:"star.fill").font(.caption2).foregroundStyle(.yellow).help("Favorite")}
        }.padding(.vertical,3)
    }
}

struct ActivityRow:View {
    let line:LogLine
    private var lower:String{line.text.lowercased()}
    private var style:(symbol:String,color:Color){
        if lower.contains("error") || lower.contains("fail") || lower.contains("could not") || lower.contains("timed out") {return ("exclamationmark.triangle.fill",.orange)}
        if lower.contains("tunnel is up") || lower.contains("connected to") || lower.contains("tunnel is up and running") {return ("checkmark.circle.fill",.green)}
        if lower.contains("browser") || lower.contains("saml") {return ("safari.fill",.blue)}
        if line.text.contains("\n") || lower.contains("snapshot") || lower.contains("routes and dns") {return ("network",.teal)}
        if lower.contains("disconnect") || lower.contains("stopped") || lower.contains("cancelled") {return ("stop.circle.fill",.secondary)}
        if lower.contains("reconnect") {return ("arrow.triangle.2.circlepath.circle.fill",.orange)}
        return ("circle.fill",Color.secondary.opacity(0.5))
    }
    var body:some View {
        let parts=line.text.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false)
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Image(systemName:style.symbol).font(style.symbol == "circle.fill" ? .system(size:6) : .callout).foregroundStyle(style.color).frame(width:16)
            VStack(alignment:.leading,spacing:6) {
                Text(String(parts.first ?? "")).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                if parts.count>1 {
                    Text(String(parts[1])).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(10).frame(maxWidth:.infinity,alignment:.leading)
                        .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8,style:.continuous))
                }
            }
            Spacer(minLength:8)
            Text(line.date,format:.dateTime.hour().minute().second()).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }.padding(.vertical,3)
    }
}

struct WelcomeView:View {
    let onFortiClient:()->Void
    let onImport:()->Void
    let onCreate:()->Void
    var body:some View {
        ScrollView {
            VStack(spacing:26) {
                Image(nsImage:NSApplication.shared.applicationIconImage).resizable().frame(width:104,height:104)
                    .shadow(color:.black.opacity(0.18),radius:16,y:8)
                VStack(spacing:8) {
                    Text("Welcome to FortiBreak").font(.system(size:34,weight:.bold,design:.rounded))
                    Text("Bring over your FortiClient connection in a few seconds.").font(.title3).foregroundStyle(.secondary)
                }
                HStack(alignment:.top,spacing:14) {
                    WelcomeTile(symbol:"arrow.down.app.fill",color:.blue,title:"Use FortiClient Profile",detail:"Reads the gateway and sign-in settings macOS already knows.",action:onFortiClient)
                    WelcomeTile(symbol:"doc.badge.plus",color:.indigo,title:"Import a File",detail:"FortiClient XML, JSON, Apple profiles or openfortivpn configs.",action:onImport)
                    WelcomeTile(symbol:"plus",color:.teal,title:"Set Up Manually",detail:"Enter a gateway and choose how you sign in.",action:onCreate)
                }
                Label("Importing never starts a VPN connection.",systemImage:"lock.fill").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(48).frame(maxWidth:.infinity)
        }
        .background(alignment:.top){
            RadialGradient(colors:[Color.accentColor.opacity(0.18),.clear],center:.top,startRadius:0,endRadius:520).frame(height:520).ignoresSafeArea()
        }
    }
}
struct WelcomeTile:View {
    let symbol:String
    let color:Color
    let title:String
    let detail:String
    let action:()->Void
    @ViewState<Bool> private var hovering=false
    var body:some View {
        Button(action:action){
            VStack(alignment:.leading,spacing:10) {
                IconBadge(symbol:symbol,color:color,size:40)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }
            .padding(18).frame(width:200,height:178,alignment:.topLeading)
            .background(.background,in:RoundedRectangle(cornerRadius:18,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).strokeBorder(hovering ? color.opacity(0.6) : Color.primary.opacity(0.08),lineWidth:hovering ? 1.5 : 1))
            .shadow(color:.black.opacity(hovering ? 0.12 : 0.05),radius:hovering ? 16 : 8,y:hovering ? 8 : 3)
            .offset(y:hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius:18,style:.continuous))
        }
        .buttonStyle(.plain)
        .onHover{h in withAnimation(.easeOut(duration:0.18)){hovering=h}}
    }
}

struct ProfileEditor:View {
    @Environment(\.dismiss) var dismiss
    @ViewState var profile: VPNProfile
    var isNew=false
    var onSave:(VPNProfile)->Void
    @ViewState private var validation: String?
    @ViewState private var actions=AfterConnectActions()
    @ViewState private var healthHost=""
    @ViewState private var limitMinutes=0
    @ViewState private var newLink=""
    var body:some View{
        VStack(spacing:0){
            Text(isNew ? "New Connection" : "Connection Settings").font(.headline).padding(.top,18)
            Form{
                Section("Profile"){TextField("Name",text:$profile.name);TextField("Description",text:$profile.notes,prompt:Text("Optional"))}
                Section("Gateway"){TextField("Host",text:$profile.host,prompt:Text("vpn.example.com"));TextField("Port",value:$profile.port,format:.number.grouping(.never));TextField("Realm",text:$profile.realm,prompt:Text("Optional"))}
                Section("Authentication"){Picker("Sign-in",selection:$profile.login){ForEach(LoginMode.allCases,id:\.self){Text($0.rawValue).tag($0)}};TextField("Username",text:$profile.username,prompt:Text(profile.login == .browser ? "Optional" : "Required"))}
                Section{
                    fileRow("CA bundle",path:$profile.caFile)
                    fileRow("Client certificate",path:$profile.certificateFile)
                    fileRow("Private key",path:$profile.keyFile)
                    TextField("Pinned SHA-256",text:$profile.trustedCertificate,prompt:Text("Optional"))
                } header:{Text("Certificates")} footer:{Text("PEM files. Normal certificate validation stays enabled. Pin a fingerprint only if you received it through a trusted channel.").foregroundStyle(.secondary)}
                Section{
                    TextField("Health check host",text:$healthHost,prompt:Text("Gateway DNS server"))
                    Picker("Session limit warning",selection:$limitMinutes){
                        Text("Learn from drops").tag(0);Text("Off").tag(-1)
                        ForEach([240,480,600,720,1440],id:\.self){Text("After \($0/60) hours").tag($0)}
                    }
                } header:{Text("Monitoring")} footer:{Text("While connected, FortiBreak checks this host every 5 seconds and restarts a stalled tunnel. Use host or host:port. The warning comes 10 minutes before the gateway ends a session.").foregroundStyle(.secondary)}
                Section{
                    ForEach(actions.urls.indices,id:\.self){i in
                        HStack{Label(actions.urls[i],systemImage:"link").lineLimit(1).truncationMode(.middle);Spacer();Button("Remove",systemImage:"minus.circle.fill"){actions.urls.remove(at:i)}.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.red)}
                    }
                    HStack{
                        TextField("Open link",text:$newLink,prompt:Text("https://intranet… or smb://server/share")).onSubmit{addLink()}
                        Button("Add"){addLink()}.disabled(!AfterConnectActions.valid(newLink))
                    }
                    fileRow("Run script",path:$actions.script)
                    Toggle("Also after automatic reconnects",isOn:$actions.afterReconnects)
                } header:{Text("After Connecting")} footer:{Text("Links can be web pages, file shares (smb://, afp://) or remote sessions. The script runs as you with FORTIBREAK_CONNECTION, FORTIBREAK_GATEWAY, FORTIBREAK_VPN_ADDRESS and FORTIBREAK_INTERFACE set.").foregroundStyle(.secondary)}
            }.formStyle(.grouped)
            if let validation{Label(validation,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding(.horizontal,20).padding(.bottom,8)}
            Divider()
            HStack{
                if profile.vpnProtocol != "ssl"{Text("IPsec · import only").font(.caption).foregroundStyle(.orange)}
                Spacer()
                Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save"){save()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width:560,height:720)
        .onAppear{actions=AfterConnectActions.load(profile.id);healthHost=ProfileSettings.healthHost(profile.id);limitMinutes=ProfileSettings.sessionLimitMinutes(profile.id)}
    }
    private func addLink(){let link=newLink.trimmingCharacters(in:.whitespaces);guard AfterConnectActions.valid(link) else{return};actions.urls.append(link);newLink=""}
    private func save() {
        do {
            try profile.validate()
            let host=healthHost.trimmingCharacters(in:.whitespaces)
            guard host.isEmpty || ReachTarget.parse(host) != nil else{throw AppError("Health check host must be a hostname or IP address, optionally with :port.")}
            ProfileSettings.setHealthHost(host,profile.id);ProfileSettings.setSessionLimitMinutes(limitMinutes,profile.id);actions.save(profile.id)
            onSave(profile)
        } catch {validation=error.localizedDescription}
    }
    private func fileRow(_ title:String,path:Binding<String>)->some View{
        LabeledContent(title){
            HStack(spacing:8){
                Text(path.wrappedValue.isEmpty ? "None" : URL(fileURLWithPath:path.wrappedValue).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path.wrappedValue)
                if !path.wrappedValue.isEmpty {Button("Clear",systemImage:"xmark.circle.fill"){path.wrappedValue=""}.labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove this file")}
                Button("Choose…"){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;if panel.runModal() == .OK,let url=panel.url{path.wrappedValue=url.path}}
            }
        }
    }
}

struct ImportPreview:View {
    @Environment(\.dismiss) var dismiss
    let result:ImportResult
    var onImport:(Bool)->Void
    @ViewState<Bool> private var storePasswords=false
    var body:some View{
        VStack(spacing:0){
            Text("Import VPN Profiles").font(.headline).padding(.top,18)
            Form{
                if !result.warnings.isEmpty {Section{ForEach(result.warnings,id:\.self){Label($0,systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}}}
                Section{
                    ForEach(result.items.indices,id:\.self){i in
                        let p=result.items[i].profile
                        VStack(alignment:.leading,spacing:4){
                            LabeledContent{Text(p.vpnProtocol == "ssl" ? "SSL VPN" : "IPsec · import only").foregroundStyle(p.vpnProtocol == "ssl" ? Color.secondary : Color.orange)} label:{Label(p.name,systemImage:"network")}
                            Text(p.endpoint).font(.callout.monospaced()).foregroundStyle(.secondary)
                            ForEach(p.importWarnings,id:\.self){Label($0,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange)}
                        }.padding(.vertical,2)
                    }
                } header:{Text("\(result.items.count) profile\(result.items.count == 1 ? "" : "s") found")} footer:{Text("Review the settings. Importing never starts a VPN connection.").foregroundStyle(.secondary)}
                if result.items.contains(where:{$0.password != nil}) {
                    Section{Toggle("Store imported passwords in Keychain",isOn:$storePasswords)} footer:{Text("If off, passwords from the file are discarded. Encrypted Fortinet passwords can’t be transferred.").foregroundStyle(.secondary)}
                }
            }.formStyle(.grouped)
            Divider()
            HStack{Spacer();Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction);Button("Import"){onImport(storePasswords)}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)}.padding(16)
        }.frame(width:540,height:500)
    }
}


struct MenuPanel:View {
    @ObservedObject var store:ProfileStore
    @ObservedObject var tunnel:TunnelManager
    let controller:AppController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoReconnect") private var autoReconnect=true
    static func icon(_ state:TunnelState)->String {
        switch state {
        case .connected:"network.badge.shield.half.filled"
        case .failed:"exclamationmark.triangle"
        case .idle:"network"
        case .paused:"pause.circle"
        default:"arrow.triangle.2.circlepath"
        }
    }
    private var phase:Phase{tunnel.state == .connected ? .connected : tunnel.state == .paused ? .paused : tunnel.busy ? .working : tunnel.state == .failed ? .failed : .idle}
    private var ready:[VPNProfile]{store.profiles.filter{$0.unsupported == nil}.sorted{a,b in a.favorite != b.favorite ? a.favorite : a.name.localizedStandardCompare(b.name) == .orderedAscending}}
    private var target:VPNProfile?{ready.first{$0.id == tunnel.activeProfile} ?? ready.first{$0.id == store.selected} ?? ready.first}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            header.padding(16)
            if tunnel.state == .connected {
                HStack(spacing:8){
                    stat("clock","Session",tunnel.elapsed)
                    stat("arrow.down","Down",Design.bytes(tunnel.receiveRate)+"/s")
                    stat("arrow.up","Up",Design.bytes(tunnel.sendRate)+"/s")
                    stat(Design.quality(tunnel.quality).symbol,"Health",tunnel.quality.rawValue)
                }.padding(.horizontal,16).padding(.bottom,10)
                HStack(spacing:8){
                    Menu{
                        ForEach([15,30,60,120],id:\.self){minutes in Button(minutes<60 ? "\(minutes) minutes" : minutes==60 ? "1 hour" : "\(minutes/60) hours"){tunnel.pause(minutes:minutes)}}
                    } label:{Label("Pause",systemImage:"pause.fill")}.menuStyle(.button).fixedSize()
                    if tunnel.sessionEndsAt != nil {Button("Sign In Again"){tunnel.renewSession()}}
                    Spacer()
                    if let ends=tunnel.sessionEndsAt {Text("Ends ~"+ends.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(tunnel.expiryWarning ? Color.orange : Color.secondary)}
                }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal,16).padding(.bottom,14)
            }
            if tunnel.state == .paused {
                HStack(spacing:8){
                    Button("Resume Now"){tunnel.resumeNow()}.buttonStyle(.borderedProminent).tint(.purple)
                    Button("Stay Off"){tunnel.disconnect()}.buttonStyle(.bordered)
                    Spacer()
                    if let until=tunnel.pausedUntil {Text("Resumes "+until.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.secondary)}
                }.controlSize(.small).padding(.horizontal,16).padding(.bottom,14)
            }
            Divider()
            VStack(alignment:.leading,spacing:2) {
                Text("Connections").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.top,8).padding(.bottom,2)
                if ready.isEmpty {Text("No connections yet. Open FortiBreak to add one.").font(.callout).foregroundStyle(.secondary).padding(10)}
                ForEach(ready){p in PanelRow(profile:p,status:rowStatus(p),enabled:rowEnabled(p)){toggle(p)}}
                if !ready.isEmpty && !tunnel.helperReady {
                    Label("Approve the VPN helper in FortiBreak to connect.",systemImage:"exclamationmark.shield.fill").font(.caption).foregroundStyle(.orange).padding(10)
                }
            }.padding(6)
            Divider()
            Toggle(isOn:$autoReconnect){Label("Reconnect automatically",systemImage:"arrow.triangle.2.circlepath")}
                .toggleStyle(.switch).controlSize(.small).padding(.horizontal,16).padding(.vertical,10)
            Divider()
            HStack(spacing:14) {
                Button{show()} label:{Label("Open FortiBreak",systemImage:"macwindow")}
                Spacer()
                SettingsLink{Image(systemName:"gearshape")}.help("Settings")
                Button{NSApplication.shared.terminate(nil)} label:{Image(systemName:"power")}.help("Quit FortiBreak")
            }
            .buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,11)
        }
        .frame(width:330)
    }
    private var header:some View {
        HStack(spacing:12) {
            IconBadge(symbol:phase == .connected ? "lock.shield.fill" : phase == .paused ? "pause.fill" : phase == .working ? "arrow.triangle.2.circlepath" : "network",color:phase == .idle ? .gray : phase.tint,size:40)
                .symbolEffect(.pulse,isActive:phase == .working)
            VStack(alignment:.leading,spacing:2) {
                Text(phase == .connected ? "Connected" : tunnel.busy ? tunnel.state.rawValue : phase == .failed ? "Connection failed" : "Not connected").font(.headline)
                Text(tunnel.activeName ?? target?.name ?? "FortiBreak").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("",isOn:Binding(get:{tunnel.busy},set:{on in if on,let p=target {connect(p)} else if !on {tunnel.disconnect()}}))
                .toggleStyle(.switch).labelsHidden()
                .disabled(tunnel.state == .stopping || (!tunnel.busy && (target == nil || !tunnel.helperReady || !tunnel.backendReady)))
                .help(tunnel.busy ? "Disconnect" : "Connect to "+(target?.name ?? "a connection"))
        }
    }
    private func stat(_ symbol:String,_ title:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:2) {
            Label(title,systemImage:symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout,design:.rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(8).frame(maxWidth:.infinity,alignment:.leading)
        .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:9,style:.continuous))
    }
    private func rowStatus(_ p:VPNProfile)->String? {
        guard tunnel.activeProfile == p.id && tunnel.busy else{return nil}
        return tunnel.state == .connected ? "Connected" : tunnel.state.rawValue
    }
    private func rowEnabled(_ p:VPNProfile)->Bool {
        if tunnel.activeProfile == p.id && tunnel.busy {return tunnel.state != .stopping}
        return !tunnel.busy && tunnel.helperReady && tunnel.backendReady
    }
    private func toggle(_ p:VPNProfile) {
        if tunnel.activeProfile == p.id && tunnel.busy {tunnel.disconnect()} else {connect(p)}
    }
    private func connect(_ p:VPNProfile) {controller.connect(p,origin:"Menu bar")}
    private func show(){dismiss();NSApplication.shared.activate(ignoringOtherApps:true);openWindow(id:"main")}
}

struct PanelRow:View {
    let profile:VPNProfile
    let status:String?
    let enabled:Bool
    let action:()->Void
    @ViewState<Bool> private var hovering=false
    var body:some View {
        Button(action:action){
            HStack(spacing:10) {
                IconBadge(symbol:"network",color:Design.color(for:profile),size:26)
                VStack(alignment:.leading,spacing:0) {
                    Text(profile.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(status ?? profile.host).font(.caption).foregroundStyle(status == "Connected" ? Color.green : Color.secondary).lineLimit(1)
                }
                Spacer()
                if hovering && enabled {Text(status == nil ? "Connect" : "Disconnect").font(.caption.weight(.semibold)).foregroundStyle(.tint)}
                else if status == "Connected" {Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)}
                else if status != nil {ProgressView().controlSize(.mini)}
            }
            .padding(.horizontal,10).padding(.vertical,7)
            .background(hovering && enabled ? Color.primary.opacity(0.07) : Color.clear,in:RoundedRectangle(cornerRadius:8,style:.continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover{hovering=$0}
    }
}

struct SettingsView:View {
    @ObservedObject var store:ProfileStore
    @ObservedObject var tunnel:TunnelManager
    let controller:AppController
    @ViewState<String> private var tab=CommandLine.arguments.first{$0.hasPrefix("--preview-settings=")}.map{String($0.dropFirst("--preview-settings=".count))} ?? "general"
    var body:some View {
        TabView(selection:$tab) {
            GeneralSettings(store:store,tunnel:tunnel).tabItem{Label("General",systemImage:"gearshape")}.tag("general")
            WiFiSettings(store:store,controller:controller,wifi:controller.wifi).tabItem{Label("Wi-Fi",systemImage:"wifi")}.tag("wifi")
            ShortcutSettings(store:store,controller:controller).tabItem{Label("Shortcuts",systemImage:"command")}.tag("shortcuts")
            HelperSettings(store:store,tunnel:tunnel).tabItem{Label("VPN Helper",systemImage:"lock.shield")}.tag("helper")
        }
        .frame(width:520)
    }
}

struct GeneralSettings:View {
    @ObservedObject var store:ProfileStore
    @ObservedObject var tunnel:TunnelManager
    @AppStorage("autoReconnect") private var autoReconnect=true
    @AppStorage("notifications") private var notifications=true
    @AppStorage("connectOnLaunch") private var connectOnLaunch="favorite"
    @ViewState<Bool> private var openAtLogin=false
    @ViewState private var loginNote: String?
    var body:some View {
        Form {
            Section {
                Toggle("Reconnect automatically if the tunnel drops",isOn:$autoReconnect)
                Picker("When FortiBreak opens",selection:$connectOnLaunch){
                    Text("Don’t connect").tag("")
                    Text("Connect the favorite").tag("favorite")
                    ForEach(store.profiles.filter{$0.unsupported == nil}){Text("Connect to "+$0.name).tag($0.id.uuidString)}
                }
            } header:{Text("Connection")} footer:{
                Text("The favorite is your starred connection, or your only one. Reconnecting makes up to \(ReconnectPolicy.delays.count) attempts after \(ReconnectPolicy.delays.map{"\(Int($0))"}.joined(separator:", ")) seconds, once a network is available, and also restarts a stalled tunnel. Browser SSO may open a sign-in tab.").foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Open FortiBreak at login",isOn:Binding(get:{openAtLogin},set:{setOpenAtLogin($0)}))
                if let loginNote {Text(loginNote).font(.caption).foregroundStyle(.orange)}
                Toggle("Notify when the VPN connects, drops or needs input",isOn:$notifications)
                    .onChange(of:notifications){_,on in if on {Notifier.requestPermission()}}
            }
            Section {
                LabeledContent("Version",value:Design.version)
                LabeledContent("VPN engine",value:tunnel.backendReady ? "openfortivpn" : "Missing from this build. Reinstall FortiBreak.")
            }
        }
        .formStyle(.grouped).frame(height:440)
        .onAppear{refreshLoginState()}
    }
    private func refreshLoginState() {
        let status=SMAppService.mainApp.status
        openAtLogin=status == .enabled || status == .requiresApproval
        loginNote=status == .requiresApproval ? "Allow FortiBreak in System Settings › General › Login Items." : nil
    }
    private func setOpenAtLogin(_ on:Bool) {
        do {if on {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()};refreshLoginState()}
        catch {refreshLoginState();loginNote=error.localizedDescription}
    }
}

struct HelperSettings:View {
    @ObservedObject var store:ProfileStore
    @ObservedObject var tunnel:TunnelManager
    @ViewState<Bool> private var confirmRemove=false
    var body:some View {
        Form {
            Section {
                LabeledContent{Label(tunnel.helperReady ? "Approved" : tunnel.helperInstalled ? "Needs approval" : "Not installed",systemImage:tunnel.helperReady ? "checkmark.shield.fill" : "exclamationmark.shield").foregroundStyle(tunnel.helperReady ? Color.green : Color.orange)} label:{
                    VStack(alignment:.leading,spacing:2){Text("Status");Text(tunnel.helperStatus).font(.caption).foregroundStyle(.secondary)}
                }
                HStack {
                    if tunnel.helperSetupBusy {ProgressView().controlSize(.small)}
                    Spacer()
                    Button("Remove Helper…",role:.destructive){confirmRemove=true}
                        .disabled(!tunnel.helperInstalled || tunnel.busy || tunnel.helperSetupBusy || store.preview)
                    Button(tunnel.helperReady ? "Repair Helper…" : "Approve Helper…"){tunnel.enableHelper(preview:store.preview)}
                        .disabled(tunnel.busy || tunnel.helperSetupBusy || store.preview)
                }
            } footer:{
                Text("A root launchd service that only accepts this signed FortiBreak build and your Mac user. Each new FortiBreak build needs approval again. Removing it keeps your connections and saved passwords.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(height:250)
        .confirmationDialog("Remove the VPN helper?",isPresented:$confirmRemove){
            Button("Remove Helper",role:.destructive){tunnel.removeHelper(preview:store.preview)}
        } message:{Text("macOS asks for administrator approval. FortiBreak can’t connect until the helper is approved again.")}
        .onAppear{tunnel.refreshHelperState()}
    }
}
