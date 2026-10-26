import SwiftUI
import AppKit
import Charts

// MARK: - Tunnel health

struct HealthCard:View {
    @ObservedObject var tunnel:TunnelManager
    var body:some View {
        let style=Design.quality(tunnel.quality)
        Card(title:"Tunnel Health",symbol:"heart.text.square.fill",tint:style.color){
            HStack(alignment:.top,spacing:28){
                VStack(alignment:.leading,spacing:2){
                    Label(tunnel.quality.rawValue,systemImage:style.symbol).font(.caption.weight(.semibold)).foregroundStyle(style.color)
                    Text(HealthPolicy.median(tunnel.health).map{"\(Int($0.rounded())) ms"} ?? "—").font(.system(.title2,design:.rounded).weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                    Text("median latency").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment:.leading,spacing:2){
                    Label("Loss",systemImage:"drop.triangle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(loss).font(.system(.title2,design:.rounded).weight(.semibold)).monospacedDigit()
                    Text("last minute").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Chart{
                ForEach(tunnel.health){sample in
                    if let latency=sample.latency {
                        AreaMark(x:.value("Time",sample.time),y:.value("Latency",latency)).foregroundStyle(LinearGradient(colors:[style.color.opacity(0.28),style.color.opacity(0.02)],startPoint:.top,endPoint:.bottom)).interpolationMethod(.monotone)
                        LineMark(x:.value("Time",sample.time),y:.value("Latency",latency)).foregroundStyle(style.color).lineStyle(StrokeStyle(lineWidth:2,lineCap:.round)).interpolationMethod(.monotone)
                    } else {
                        RuleMark(x:.value("Time",sample.time)).foregroundStyle(Color.red.opacity(0.5)).lineStyle(StrokeStyle(lineWidth:2,dash:[2,3]))
                    }
                }
            }
            .chartXAxis(.hidden).chartLegend(.hidden)
            .chartYAxis{AxisMarks(position:.trailing,values:.automatic(desiredCount:3)){value in AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[3,4]));AxisValueLabel{if let v=value.as(Double.self){Text("\(Int(v)) ms").font(.caption2)}}}}
            .frame(height:120)
            .overlay{if tunnel.health.count<2{Text(tunnel.quality == .unavailable ? "No host to check" : "Measuring…").font(.callout).foregroundStyle(.secondary)}}
            Text(tunnel.healthTarget.isEmpty ? "Set a health check host in the connection settings." : "Checks \(tunnel.healthTarget) every \(Int(HealthPolicy.interval)) s. Red marks are missed answers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var loss:String {
        let recent=tunnel.health.suffix(12)
        guard !recent.isEmpty else{return "—"}
        return "\(Int((Double(recent.filter{$0.latency == nil}.count)/Double(recent.count)*100).rounded())) %"
    }
}

// MARK: - Network page

struct ReachResult:Identifiable {
    let id=UUID()
    let target:String
    let port:UInt16
    let probe:NetworkProbe.Reach
    let vpnInterface:String
}

struct NetworkPage:View {
    @ObservedObject var tunnel:TunnelManager
    let profile:VPNProfile
    let connected:Bool
    @ViewState<String> private var target=""
    @ViewState private var results:[ReachResult]=[]
    @ViewState<Bool> private var testing=false
    var body:some View {
        ScrollView{
            VStack(spacing:18){
                if connected {
                    Card(title:"Routes Through the VPN",symbol:"point.3.connected.trianglepath.dotted",tint:.blue){
                        Text(routeSummary).font(.headline)
                        if !tunnel.routes.isEmpty {
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:8,alignment:.leading)],alignment:.leading,spacing:8){
                                ForEach(tunnel.routes,id:\.self){route in
                                    Text(route).font(.callout.monospaced()).padding(.horizontal,10).padding(.vertical,5)
                                        .background(Color.blue.opacity(0.08),in:Capsule()).textSelection(.enabled)
                                }
                            }
                        }
                        Text("Everything else uses your normal connection. The gateway decides these routes.").font(.caption).foregroundStyle(.secondary)
                    }
                    Card(title:"DNS",symbol:"server.rack",tint:.purple){
                        LabeledContent("Servers"){Text(tunnel.dnsServers.isEmpty ? "None assigned" : tunnel.dnsServers.joined(separator:", ")).monospaced().textSelection(.enabled)}
                        LabeledContent("Search domains"){Text(tunnel.searchDomains.isEmpty ? "None" : tunnel.searchDomains.joined(separator:", ")).textSelection(.enabled)}
                        Text("Assigned by the gateway. macOS uses them while the VPN is connected.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Banner(symbol:"network",tint:.secondary,title:"Not connected",message:"Connect to see the routes and DNS servers the gateway assigns."){EmptyView()}
                }
                Card(title:"Reachability Test",symbol:"scope",tint:.teal){
                    Text("Check whether a host answers, and whether the VPN carries the traffic.").font(.callout).foregroundStyle(.secondary)
                    HStack{
                        TextField("Host",text:$target,prompt:Text("intranet.example.com or 10.0.0.5:22")).textFieldStyle(.roundedBorder).controlSize(.large).onSubmit{run()}
                        Button("Test"){run()}.buttonStyle(.borderedProminent).controlSize(.large).disabled(ReachTarget.parse(target) == nil || testing)
                    }
                    if testing {HStack(spacing:8){ProgressView().controlSize(.small);Text("Testing…").font(.callout).foregroundStyle(.secondary)}}
                    ForEach(results){result in ReachRow(result:result)}
                }
            }
            .padding(.horizontal,32).padding(.vertical,22)
            .frame(maxWidth:860).frame(maxWidth:.infinity)
        }
        .onAppear{tunnel.refreshRoutes()}
    }
    private var routeSummary:String {
        if TunnelLog.isFullTunnel(tunnel.routes) {return "All internet traffic goes through the VPN."}
        if tunnel.routes.isEmpty {return "Reading the routing table…"}
        return "\(tunnel.routes.count) network\(tunnel.routes.count == 1 ? "" : "s") go through the VPN."
    }
    private func run() {
        guard let parsed=ReachTarget.parse(target),!testing else{return}
        testing=true
        let interface=tunnel.interfaceName,label=target.trimmingCharacters(in:.whitespaces)
        DispatchQueue.global(qos:.userInitiated).async{
            let probe=NetworkProbe.reach(host:parsed.host,port:parsed.port)
            Task{@MainActor in
                results.insert(ReachResult(target:label,port:parsed.port,probe:probe,vpnInterface:interface),at:0)
                if results.count>6 {results.removeLast(results.count-6)}
                testing=false
            }
        }
    }
}

struct ReachRow:View {
    let result:ReachResult
    private var viaVPN:Bool {result.probe.interface != nil && result.probe.interface == result.vpnInterface}
    private var route:String {
        guard let interface=result.probe.interface else{return ""}
        return viaVPN ? " through the VPN (\(interface))" : " outside the VPN (\(interface))"
    }
    private var outcome:(symbol:String,color:Color,text:String) {
        switch result.probe.result {
        case .open(let ms):return (viaVPN ? "checkmark.circle.fill" : "checkmark.circle",viaVPN ? .green : .orange,"Answered in \(Int(ms.rounded())) ms"+route)
        case .refused(let ms):return ("exclamationmark.circle.fill",.yellow,"Reachable in \(Int(ms.rounded())) ms, but port \(result.port) is closed"+route)
        case .failed:return ("xmark.circle.fill",.red,result.probe.address == nil ? "Could not resolve this name" : "No answer on port \(result.port)"+route)
        }
    }
    var body:some View {
        HStack(alignment:.top,spacing:12){
            Image(systemName:outcome.symbol).font(.title3).foregroundStyle(outcome.color)
            VStack(alignment:.leading,spacing:2){
                Text(result.target).font(.callout.weight(.semibold).monospaced())
                Text(outcome.text).font(.callout).foregroundStyle(.secondary)
                if let address=result.probe.address,address != result.target.split(separator:":").first.map(String.init) {Text(address).font(.caption.monospaced()).foregroundStyle(.tertiary)}
            }
            Spacer()
        }
        .padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12,style:.continuous))
    }
}

// MARK: - History page

struct HistoryPage:View {
    @ObservedObject var tunnel:TunnelManager
    let profile:VPNProfile
    private var entries:[SessionEntry]{tunnel.sessions.filter{$0.profileID == profile.id}}
    private var weekStart:Date{Calendar.current.date(byAdding:.day,value:-6,to:Calendar.current.startOfDay(for:Date()))!}
    private var thisWeek:[SessionEntry]{entries.filter{$0.start>=weekStart}}
    private var days:[(day:Date,hours:Double)] {
        let calendar=Calendar.current
        return (0..<7).map{offset in
            let day=calendar.date(byAdding:.day,value:offset,to:weekStart)!
            let seconds=thisWeek.filter{calendar.isDate($0.start,inSameDayAs:day)}.reduce(0){$0+$1.duration(now:tunnel.clock)}
            return (day,seconds/3600)
        }
    }
    var body:some View {
        ScrollView{
            VStack(spacing:18){
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:14,alignment:.top)],spacing:14){
                    Card(title:"This Week",symbol:"clock.fill",tint:.blue){
                        CardValue(Design.duration(thisWeek.reduce(0){$0+$1.duration(now:tunnel.clock)}))
                        CardNote("\(thisWeek.count) session\(thisWeek.count == 1 ? "" : "s")")
                    }
                    Card(title:"Data This Week",symbol:"arrow.up.arrow.down",tint:.green){
                        let down=thisWeek.reduce(UInt64(0)){$0+$1.received},up=thisWeek.reduce(UInt64(0)){$0+$1.sent}
                        CardValue(Design.bytes(down+up))
                        CardNote("↓ "+Design.bytes(down)+" · ↑ "+Design.bytes(up))
                    }
                    Card(title:"Drops",symbol:"bolt.horizontal.fill",tint:.red){
                        CardValue("\(thisWeek.filter{$0.reason == .dropped || $0.reason == .stalled}.count)")
                        CardNote("this week, including stalls")
                    }
                    Card(title:"Session Limit",symbol:"hourglass",tint:.orange){
                        CardValue(limit.value)
                        CardNote(limit.note)
                    }
                }
                Card(title:"Connected Time",symbol:"chart.bar.fill",tint:.accentColor){
                    Chart(days,id:\.day){item in
                        BarMark(x:.value("Day",item.day,unit:.day),y:.value("Hours",item.hours))
                            .foregroundStyle(Color.accentColor.gradient).cornerRadius(6)
                    }
                    .chartXAxis{AxisMarks(values:.stride(by:.day)){_ in AxisValueLabel(format:.dateTime.weekday(.abbreviated),centered:true)}}
                    .chartYAxis{AxisMarks(position:.trailing,values:.automatic(desiredCount:3)){value in AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[3,4]));AxisValueLabel{if let v=value.as(Double.self){Text("\(Int(v)) h").font(.caption2)}}}}
                    .frame(height:170)
                }
                Card(title:"Sessions",symbol:"list.bullet",tint:.secondary){
                    if entries.isEmpty {Text("Sessions appear here after you connect.").font(.callout).foregroundStyle(.secondary)}
                    ForEach(Array(entries.reversed().prefix(60))){entry in
                        SessionRow(entry:entry,now:tunnel.clock,live:entry.end == nil ? (tunnel.received,tunnel.sent) : nil)
                        if entry.id != entries.reversed().prefix(60).last?.id {Divider()}
                    }
                }
            }
            .padding(.horizontal,32).padding(.vertical,22)
            .frame(maxWidth:860).frame(maxWidth:.infinity)
        }
    }
    private var limit:(value:String,note:String) {
        let minutes=ProfileSettings.sessionLimitMinutes(profile.id)
        if minutes<0 {return ("Off","Warnings turned off")}
        if minutes>0 {return ("\(minutes/60) h","Set in connection settings")}
        if let learned=tunnel.learnedLimit(profile.id) {return ("~"+Design.duration(learned),"Learned from your drops")}
        return ("Not known","Learned after drops at the same length")
    }
}

struct SessionRow:View {
    let entry:SessionEntry
    let now:Date
    var live:(UInt64,UInt64)?=nil
    private var style:(symbol:String,color:Color,text:String) {
        switch entry.reason {
        case nil:("dot.radiowaves.left.and.right",.green,"Connected now")
        case .disconnected?:("power.circle.fill",.secondary,"Disconnected")
        case .dropped?:("bolt.horizontal.circle.fill",.red,"Dropped by the network or gateway")
        case .stalled?:("exclamationmark.octagon.fill",.orange,"Restarted after a stall")
        case .paused?:("pause.circle.fill",.purple,"Paused")
        case .renewed?:("arrow.clockwise.circle.fill",.blue,"Signed in again")
        }
    }
    var body:some View {
        HStack(spacing:12){
            Image(systemName:style.symbol).font(.title3).foregroundStyle(style.color).frame(width:24)
            VStack(alignment:.leading,spacing:2){
                Text(entry.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())).font(.callout.weight(.medium))
                Text(style.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment:.trailing,spacing:2){
                Text(Design.duration(entry.duration(now:now))).font(.callout.weight(.medium)).monospacedDigit()
                Text("↓ "+Design.bytes(live?.0 ?? entry.received)+" · ↑ "+Design.bytes(live?.1 ?? entry.sent)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.vertical,4)
    }
}

// MARK: - Settings: Wi-Fi

struct WiFiSettings:View {
    @ObservedObject var store:ProfileStore
    let controller:AppController
    @ObservedObject var wifi:WiFiMonitor
    @AppStorage("wifiRules") private var enabled=false
    @AppStorage("wifiDisconnectTrusted") private var disconnectTrusted=false
    @AppStorage("wifiProfile") private var profile="favorite"
    @ViewState private var trusted:[String]=[]
    @ViewState<String> private var newNetwork=""
    var body:some View {
        Form{
            Section{
                Toggle("Connect automatically on untrusted Wi-Fi",isOn:$enabled).onChange(of:enabled){_,_ in controller.evaluateWiFi()}
                Picker("Connection",selection:$profile){
                    Text("The favorite").tag("favorite")
                    ForEach(store.profiles.filter{$0.unsupported == nil}){Text($0.name).tag($0.id.uuidString)}
                }.disabled(!enabled)
                Toggle("Disconnect when I join a trusted network",isOn:$disconnectTrusted).disabled(!enabled)
            } footer:{Text("Wired and unknown networks are left alone. After you disconnect by hand, FortiBreak waits until you change networks.").foregroundStyle(.secondary)}
            Section("Trusted Networks"){
                if trusted.isEmpty {Text("None yet. Add your office or home network.").foregroundStyle(.secondary)}
                ForEach(trusted,id:\.self){name in
                    HStack{Label(name,systemImage:"wifi");Spacer();Button("Remove",systemImage:"minus.circle.fill"){update(trusted.filter{$0 != name})}.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.red)}
                }
                HStack{
                    TextField("Network name",text:$newNetwork).onSubmit{add(newNetwork)}
                    Button("Add"){add(newNetwork)}.disabled(newNetwork.trimmingCharacters(in:.whitespaces).isEmpty)
                }
                if let current=wifi.ssid,!trusted.contains(current) {Button("Trust “\(current)”"){add(current)}}
            }
            Section("This Mac"){
                LabeledContent("Current Wi-Fi",value:wifi.ssid ?? (wifi.allowed ? "Not connected to Wi-Fi" : "Hidden until Location is allowed"))
                if !wifi.allowed {
                    Text("macOS shows Wi-Fi names only to apps allowed to use Location. FortiBreak uses it only to read the network name.").font(.caption).foregroundStyle(.secondary)
                    HStack{
                        Button("Allow Location Access…"){wifi.requestAccess()}
                        Button("Open Privacy Settings"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)}
                    }
                }
            }
        }
        .formStyle(.grouped).frame(height:480)
        .onAppear{trusted=WiFiRules.trusted;wifi.refresh()}
    }
    private func add(_ name:String){let value=name.trimmingCharacters(in:.whitespaces);guard !value.isEmpty,!trusted.contains(value) else{return};update(trusted+[value]);newNetwork=""}
    private func update(_ list:[String]){trusted=list;UserDefaults.standard.set(list,forKey:"wifiTrusted");controller.evaluateWiFi()}
}

// MARK: - Settings: shortcuts and links

struct ShortcutSettings:View {
    @ObservedObject var store:ProfileStore
    let controller:AppController
    @AppStorage("hotkey") private var hotkey=HotKeyChoice.controlOptionCommandV.rawValue
    @AppStorage("linksEnabled") private var linksEnabled=true
    @ViewState private var copied:String?
    private var links:[(url:String,detail:String)] {
        let name=(LaunchTarget.pick("favorite",profiles:store.profiles) ?? store.profiles.first)?.name ?? "Office"
        let encoded=name.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed) ?? name
        return [("fortibreak://connect","Connect the favorite"),("fortibreak://connect?profile="+encoded,"Connect a named connection"),
                ("fortibreak://disconnect","Disconnect or cancel a pause"),("fortibreak://toggle","Connect or disconnect"),
                ("fortibreak://pause?minutes=30","Pause for 1 to 480 minutes"),("fortibreak://resume","End a pause now"),("fortibreak://open","Show the window")]
    }
    var body:some View {
        Form{
            Section{
                Picker("Connect or disconnect from anywhere",selection:$hotkey){ForEach(HotKeyChoice.allCases){Text($0.title).tag($0.rawValue)}}
                    .onChange(of:hotkey){_,_ in controller.applyHotKey()}
            } header:{Text("Global Shortcut")} footer:{Text("Connects the favorite, or disconnects whatever is active. A small confirmation appears on screen.").foregroundStyle(.secondary)}
            Section{
                Toggle("Allow fortibreak:// links",isOn:$linksEnabled)
                ForEach(links,id:\.url){link in
                    HStack{
                        VStack(alignment:.leading,spacing:2){Text(link.url).font(.callout.monospaced()).textSelection(.enabled);Text(link.detail).font(.caption).foregroundStyle(.secondary)}
                        Spacer()
                        Button(copied == link.url ? "Copied" : "Copy"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(link.url,forType:.string);copied=link.url}.buttonStyle(.borderless)
                    }
                }
            } header:{Text("Links for Shortcuts and Scripts")} footer:{Text("Use them in the Shortcuts app (Open URLs), Raycast, or open \"fortibreak://toggle\" in Terminal. Browsers ask before opening them.").foregroundStyle(.secondary)}
        }
        .formStyle(.grouped).frame(height:520)
    }
}
