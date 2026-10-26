import SwiftUI
import AppKit
import Carbon
import CoreLocation
import CoreWLAN
import Network

// MARK: - Global shortcut

enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off, controlOptionCommandV = "ctrl-opt-cmd-v", controlOptionV = "ctrl-opt-v", controlOptionCommandK = "ctrl-opt-cmd-k"
    var id: String { rawValue }
    // ⌥⌘V is Finder's Move Item, so the default adds Control.
    static var current: HotKeyChoice { HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .controlOptionCommandV }
    var title: String {
        switch self { case .off: "Off"; case .controlOptionCommandV: "⌃⌥⌘V"; case .controlOptionV: "⌃⌥V"; case .controlOptionCommandK: "⌃⌥⌘K" }
    }
    var keyCode: UInt32 { self == .controlOptionCommandK ? UInt32(kVK_ANSI_K) : UInt32(kVK_ANSI_V) }
    var modifiers: UInt32 { self == .controlOptionV ? UInt32(controlKey | optionKey) : UInt32(controlKey | optionKey | cmdKey) }
}

// Carbon hot keys work system-wide without Accessibility access.
final class HotKey {
    static var action: (() -> Void)?
    private static var handlerInstalled = false
    private var reference: EventHotKeyRef?
    func register(_ choice: HotKeyChoice) {
        unregister()
        guard choice != .off else { return }
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in DispatchQueue.main.async { HotKey.action?() }; return noErr }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }
        RegisterEventHotKey(choice.keyCode, choice.modifiers, EventHotKeyID(signature: OSType(0x4642_4b59), id: 1), GetApplicationEventTarget(), 0, &reference)
    }
    func unregister() { if let reference { UnregisterEventHotKey(reference) }; reference = nil }
}

// MARK: - On-screen confirmation

@MainActor enum HUD {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?
    static func show(symbol: String, title: String, detail: String, tint: Color) {
        let size = NSSize(width: 230, height: 190)
        let panel = Self.panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(symbol: symbol, title: title, detail: detail, tint: tint))
        if let screen = NSScreen.main { let frame = screen.visibleFrame; panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.16)) }
        panel.alphaValue = 1; panel.orderFrontRegardless(); Self.panel = panel
        hide?.cancel()
        let work = DispatchWorkItem { NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) }) }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
struct HUDView: View {
    let symbol: String, title: String, detail: String, tint: Color
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 54, weight: .semibold)).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
            Text(title).font(.system(.title3, design: .rounded).weight(.semibold))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(20).frame(width: 210, height: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Wi-Fi rules

enum WiFiRules {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "wifiRules") }
    static var trusted: [String] { UserDefaults.standard.stringArray(forKey: "wifiTrusted") ?? [] }
    static var disconnectOnTrusted: Bool { UserDefaults.standard.bool(forKey: "wifiDisconnectTrusted") }
    static var profile: String { UserDefaults.standard.string(forKey: "wifiProfile") ?? "favorite" }
}

// macOS reveals Wi-Fi names only to apps the user allowed to use Location.
@MainActor final class WiFiMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var ssid: String?
    @Published var authorization: CLAuthorizationStatus
    var onChange: (() -> Void)?
    private let location = CLLocationManager()
    private let monitor = NWPathMonitor()
    override init() {
        authorization = location.authorizationStatus
        super.init()
        location.delegate = self
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
        monitor.start(queue: .global(qos: .utility))
    }
    var allowed: Bool { ![.notDetermined, .denied, .restricted].contains(authorization) }
    func requestAccess() { location.requestWhenInUseAuthorization() }
    func refresh() {
        let current = CWWiFiClient.shared().interface()?.ssid()
        let changed = current != ssid
        ssid = current
        if changed { onChange?() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status; self.refresh() }
    }
}

// MARK: - After-connect actions

struct AfterConnectActions: Codable, Equatable {
    var urls: [String] = []
    var script = ""
    var afterReconnects = false
    // Web pages, file shares and remote sessions; never file: or javascript:.
    static let schemes: Set<String> = ["http", "https", "smb", "afp", "nfs", "vnc", "ssh", "rdp"]
    var isEmpty: Bool { urls.isEmpty && script.isEmpty }
    static func load(_ id: UUID) -> AfterConnectActions {
        UserDefaults.standard.data(forKey: "afterConnect." + id.uuidString).flatMap { try? JSONDecoder().decode(AfterConnectActions.self, from: $0) } ?? AfterConnectActions()
    }
    func save(_ id: UUID) { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "afterConnect." + id.uuidString) } }
    static func valid(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
        return schemes.contains(scheme) && url.host?.isEmpty == false
    }
}

// MARK: - fortibreak:// links

// Installed before and again after launch, so SwiftUI's own URL handling cannot replace it.
final class LinkReceiver: NSObject {
    static let shared = LinkReceiver()
    func register() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: text) else { return }
        Task { @MainActor in AppController.shared?.open(url) }
    }
}

// MARK: - Coordinator

@MainActor final class AppController: ObservableObject {
    static weak var shared: AppController?
    let store: ProfileStore
    let tunnel: TunnelManager
    let wifi = WiFiMonitor()
    private let hotKey = HotKey()
    private var suppressedSSID: String?
    private var launched = false
    init(store: ProfileStore, tunnel: TunnelManager) {
        self.store = store; self.tunnel = tunnel
        AppController.shared = self
        tunnel.onConnected = { [weak self] profile, automatic in self?.afterConnect(profile, automatic: automatic) }
        // A manual disconnect on a network is respected until the Wi-Fi changes.
        tunnel.onUserDisconnect = { [weak self] in guard let self else { return }; self.suppressedSSID = self.wifi.ssid }
        wifi.onChange = { [weak self] in self?.evaluateWiFi() }
        HotKey.action = { [weak self] in self?.hotKeyPressed() }
        applyHotKey()
    }
    var defaultTarget: VPNProfile? {
        LaunchTarget.pick("favorite", profiles: store.profiles) ?? store.current.flatMap { $0.unsupported == nil ? $0 : nil }
    }
    func connect(_ profile: VPNProfile, origin: String) {
        guard !tunnel.busy else { return }
        guard tunnel.helperReady || store.preview else { tunnel.log(origin + " wanted to connect \(profile.name), but the VPN helper needs approval first."); return }
        store.selected = profile.id
        let secret = CredentialStore.password(profile.id)
        // Without a saved password the engine asks for one, so show the window.
        if profile.login == .password && secret.isEmpty { tunnel.bringForward() }
        tunnel.log(origin + ": connecting \(profile.name).")
        tunnel.connect(profile, password: secret, preview: store.preview)
    }
    func launch() {
        guard !launched else { return }
        launched = true
        guard !store.preview else { return }
        let setting = UserDefaults.standard.string(forKey: "connectOnLaunch") ?? "favorite"
        guard let profile = LaunchTarget.pick(setting, profiles: store.profiles) else { return }
        wifi.refresh()
        if WiFiRules.enabled, let ssid = wifi.ssid, WiFiRules.trusted.contains(ssid) { tunnel.log("Not connecting at launch: “\(ssid)” is a trusted network."); return }
        guard tunnel.helperReady else { tunnel.log("Skipped connecting \(profile.name) at launch: approve the VPN helper first."); return }
        connect(profile, origin: "Launch")
    }
    func applyHotKey() { store.preview ? hotKey.unregister() : hotKey.register(HotKeyChoice.current) }
    func hotKeyPressed() {
        if tunnel.busy {
            let name = tunnel.activeName ?? ""
            let title = tunnel.state == .paused ? "Pause Cancelled" : tunnel.state == .reconnecting ? "Reconnect Cancelled" : "Disconnecting"
            tunnel.disconnect()
            HUD.show(symbol: "power.circle.fill", title: title, detail: name, tint: .secondary)
        } else if let profile = defaultTarget {
            guard tunnel.helperReady else { HUD.show(symbol: "exclamationmark.shield.fill", title: "Approve the Helper", detail: "Open FortiBreak to approve it", tint: .orange); return }
            connect(profile, origin: "Shortcut")
            HUD.show(symbol: "lock.shield.fill", title: "Connecting", detail: profile.name, tint: .accentColor)
        } else {
            HUD.show(symbol: "star.slash.fill", title: "No Favorite", detail: "Star a connection in FortiBreak", tint: .secondary)
        }
    }
    func open(_ url: URL) {
        guard UserDefaults.standard.object(forKey: "linksEnabled") as? Bool ?? true else { tunnel.log("Ignored a fortibreak:// link because links are turned off in Settings."); return }
        guard let command = LinkParser.parse(url) else { tunnel.log("Ignored an unknown fortibreak:// link."); return }
        let named = command.profile.flatMap { LaunchTarget.pick($0, profiles: store.profiles) }
        if command.profile != nil && named == nil { tunnel.log("A fortibreak:// link named a connection that does not exist."); return }
        switch command.action {
        case .connect: if let profile = named ?? defaultTarget { connect(profile, origin: "Link") }
        case .disconnect: tunnel.disconnect()
        case .toggle: if tunnel.busy { tunnel.disconnect() } else if let profile = named ?? defaultTarget { connect(profile, origin: "Link") }
        case .pause: tunnel.pause(minutes: command.minutes ?? 30)
        case .resume: tunnel.resumeNow()
        case .open: tunnel.bringForward()
        }
    }
    func evaluateWiFi() {
        if suppressedSSID != nil && suppressedSSID != wifi.ssid { suppressedSSID = nil }
        guard !store.preview else { return }
        let ssid = wifi.ssid ?? ""
        switch WiFiPolicy.decide(enabled: WiFiRules.enabled, ssid: wifi.ssid, trusted: Set(WiFiRules.trusted), disconnectOnTrusted: WiFiRules.disconnectOnTrusted, vpnActive: tunnel.busy, suppressed: suppressedSSID == wifi.ssid) {
        case .connect:
            guard tunnel.helperReady, let profile = LaunchTarget.pick(WiFiRules.profile, profiles: store.profiles) ?? defaultTarget else { return }
            tunnel.log("“\(ssid)” is not a trusted network.")
            connect(profile, origin: "Wi-Fi rule")
        case .disconnect:
            tunnel.log("“\(ssid)” is a trusted network. Disconnecting.")
            tunnel.disconnect()
        case .none: break
        }
    }
    private func afterConnect(_ profile: VPNProfile, automatic: Bool) {
        let actions = AfterConnectActions.load(profile.id)
        guard !actions.isEmpty, !automatic || actions.afterReconnects, !store.preview else { return }
        for raw in actions.urls {
            guard AfterConnectActions.valid(raw), let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) else { tunnel.log("After connecting: skipped “\(raw)”, which is not a supported link."); continue }
            NSWorkspace.shared.open(url); tunnel.log("After connecting: opened \(url.absoluteString).")
        }
        if !actions.script.isEmpty {
            // Give the engine a moment to publish the VPN address the script receives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runScript(actions.script, profile: profile) }
        }
    }
    private func runScript(_ path: String, profile: VPNProfile) {
        var info = stat()
        guard path.hasPrefix("/"), lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
            tunnel.log("After-connect script skipped: it must be a file you own that others cannot change."); return
        }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                           "FORTIBREAK_CONNECTION": profile.name, "FORTIBREAK_GATEWAY": profile.host,
                           "FORTIBREAK_VPN_ADDRESS": tunnel.vpnAddress, "FORTIBREAK_INTERFACE": tunnel.interfaceName]
        tunnel.log("After connecting: running \(URL(fileURLWithPath: path).lastPathComponent).")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = [path]; process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
            let summary: String
            if (try? process.run()) != nil {
                let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: stop)
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile().prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit(); stop.cancel()
                summary = "After-connect script finished with exit code \(process.terminationStatus)." + (output.isEmpty ? "" : "\n" + output)
            } else { summary = "After-connect script could not start." }
            Task { @MainActor in self?.tunnel.log(summary) }
        }
    }
}
