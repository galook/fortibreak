import Foundation
import Darwin

struct AppError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ s: String) { message = s } }
enum LoginMode: String, Codable, CaseIterable { case password = "Password & MFA", browser = "Browser SSO" }
struct VPNProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New connection"
    var host = ""
    var port = 443
    var username = ""
    var realm = ""
    var login: LoginMode = .password
    var vpnProtocol = "ssl"
    var favorite = false
    var caFile = ""
    var certificateFile = ""
    var keyFile = ""
    var trustedCertificate = ""
    var notes = ""
    var source = "Manual"
    var importWarnings: [String] = []
    var endpoint: String { host + ":" + String(port) }
    var unsupported: String? { vpnProtocol == "ssl" ? nil : "This profile uses IPsec. Connection details were imported, but this build cannot connect IPsec tunnels or translate their tunnel settings." }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("Give this connection a name.") }
        guard !host.isEmpty, host.utf8.count < 254, !host.hasPrefix("-"), host.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else { throw AppError("Enter a hostname or IP address, without a URL path or spaces.") }
        guard (1...65535).contains(port) else { throw AppError("Port must be between 1 and 65535.") }
        for value in [username, realm, caFile, certificateFile, keyFile, trustedCertificate] {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AppError("Profile fields must not contain control characters.") }
        }
        if !trustedCertificate.isEmpty, trustedCertificate.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) == nil { throw AppError("Certificate fingerprint must contain exactly 64 hexadecimal characters.") }
        if certificateFile.isEmpty != keyFile.isEmpty { throw AppError("Choose both a PEM client certificate and its PEM private key.") }
    }
}

struct ImportedProfile { var profile: VPNProfile; var password: String? }
struct ImportResult { var items: [ImportedProfile]; var warnings: [String] = [] }

private final class XMLNode {
    let tag: String; let attrs: [String:String]; var text = ""; var children: [XMLNode] = []
    init(_ tag: String, _ attrs: [String:String] = [:]) { self.tag = tag.lowercased(); self.attrs = attrs }
    func all(_ name: String) -> [XMLNode] { children.flatMap { ($0.tag == name ? [$0] : []) + $0.all(name) } }
    func value(_ names: [String]) -> String? {
        for n in names { if let c = children.first(where: { $0.tag == n }), !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return c.text.trimmingCharacters(in: .whitespacesAndNewlines) } }
        return nil
    }
}
private final class ConfigXML: NSObject, XMLParserDelegate {
    let root = XMLNode("root"); var stack: [XMLNode] = []; var failure: Error?
    override init() { super.init(); stack = [root] }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) { let n = XMLNode(name, attributes); stack.last?.children.append(n); stack.append(n) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { if stack.count > 1 { stack.removeLast() } }
    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) { failure = error }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

enum ProfileImporter {
    static func load(_ url: URL) throws -> ImportResult {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 10_000_000 else { throw AppError("Config file exceeds the 10 MB limit.") }
        return try parse(Data(contentsOf: url), source: url.lastPathComponent)
    }
    static func parse(_ data: Data, source: String) throws -> ImportResult {
        guard data.count <= 10_000_000 else { throw AppError("Config file exceeds the 10 MB limit.") }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String:Any], plist["PayloadContent"] != nil { return try mobile(plist, source: source) }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let object = try JSONSerialization.jsonObject(with: data)
            if let profiles = object as? [[String:Any]] ?? (object as? [String:Any])?["profiles"] as? [[String:Any]] {
                return try dictionaries(profiles, source: source)
            }
            if let dictionary = object as? [String:Any] { return try dictionaries([dictionary], source: source) }
        }
        if trimmed.hasPrefix("<") {
            guard !trimmed.localizedCaseInsensitiveContains("<!ENTITY") else { throw AppError("XML entities are not supported in VPN exports.") }
            let delegate = ConfigXML(), parser = XMLParser(data: Data(trimmed.utf8))
            parser.delegate = delegate; parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw AppError("This XML export could not be read. Export an unencrypted FortiClient configuration.") }
            var items: [ImportedProfile] = []
            for kind in ["sslvpn", "ipsecvpn"] {
                for section in delegate.root.all(kind) {
                    for connection in section.all("connection") {
                        var dict: [String:Any] = [:]
                        for child in connection.children { dict[child.tag] = child.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        dict["name"] = connection.value(["name"]) ?? connection.attrs["name"] ?? "Imported connection"
                        dict["protocol"] = kind == "sslvpn" ? "ssl" : "ipsec"
                        if connection.all("sso_enabled").contains(where: { ["1", "true"].contains($0.text.lowercased()) }) { dict["sso_enabled"] = "1" }
                        if !connection.all("certificate").isEmpty || !connection.all("client_certificate").isEmpty { dict["certificate_required"] = "1" }
                        items.append(try convert(dict, source: source))
                    }
                }
            }
            guard !items.isEmpty else { throw AppError("No VPN profiles found in this XML. Supported exports contain sslvpn/ipsecvpn connection entries.") }
            return ImportResult(items: items)
        }
        if trimmed.contains("=") && trimmed.range(of: "(?m)^\\s*host\\s*=", options: .regularExpression) != nil {
            var dict: [String:Any] = [:]
            let allowed = Set(["host","port","username","password","realm","ca-file","user-cert","user-key","trusted-cert"])
            var ignored = false
            for line in text.components(separatedBy: .newlines) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") || line.isEmpty { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if allowed.contains(parts[0]) { dict[parts[0]] = parts[1] } else { ignored = true }
            }
            var item = try convert(dict, source: source)
            if ignored { item.profile.importWarnings.append("Custom backend directives were not imported. Review routing, DNS and authentication requirements before connecting.") }
            return ImportResult(items: [item])
        }
        throw AppError("Unsupported or encrypted export. Choose an unencrypted FortiClient XML, JSON, Apple .mobileconfig, or openfortivpn config. Encrypted Fortinet passwords must be entered again.")
    }
    private static func dictionaries(_ dicts: [[String:Any]], source: String) throws -> ImportResult {
        var result: [ImportedProfile] = []
        for d in dicts { result.append(try convert(d, source: source)) }
        guard !result.isEmpty else { throw AppError("No profiles in this file.") }
        return ImportResult(items: result)
    }
    private static func convert(_ d: [String:Any], source: String) throws -> ImportedProfile {
        func value(_ names: String...) -> String { for n in names { if let v = d[n] as? String { return v }; if let v = d[n] as? NSNumber { return v.stringValue } }; return "" }
        let original = value("host", "server", "remote_gateway", "remote-gw", "RemoteAddress")
        guard !original.isEmpty else { throw AppError("Profile has no gateway hostname.") }
        let gateways = original.split(separator: ";").map(String.init)
        let first = gateways.first!.trimmingCharacters(in: .whitespaces)
        guard let url = URLComponents(string: first.contains("://") ? first : "https://" + first), let host = url.host else { throw AppError("Cannot read gateway address.") }
        var p = VPNProfile()
        p.host = host
        let explicitPort=value("port")
        if !explicitPort.isEmpty, Int(explicitPort) == nil {throw AppError("Profile port must be a number.")}
        p.port = Int(explicitPort) ?? url.port ?? 443
        p.name = value("name", "Name", "connection_name"); if p.name.isEmpty { p.name = host }
        p.username = value("username", "user", "AuthName")
        p.realm = value("realm"); if p.realm.isEmpty { p.realm = url.queryItems?.first(where: { $0.name == "realm" })?.value ?? "" }
        let proto = value("protocol", "vpnProtocol", "VPNType").lowercased()
        guard ["", "ssl", "sslvpn", "vpn", "ipsec", "ikev2", "ipsecvpn"].contains(proto) else {throw AppError("Unsupported VPN protocol: " + proto)}
        p.vpnProtocol = ["ipsec", "ikev2", "ipsecvpn"].contains(proto) ? "ipsec" : "ssl"
        if ["1","true"].contains(value("sso_enabled", "sso", "saml").lowercased()) || value("login") == LoginMode.browser.rawValue { p.login = .browser }
        p.caFile = value("ca-file", "caFile"); p.certificateFile = value("user-cert", "certificateFile"); p.keyFile = value("user-key", "keyFile")
        p.trustedCertificate = value("trusted-cert", "trustedCertificate").replacingOccurrences(of: ":", with: "")
        p.notes = value("description", "notes"); p.source = source
        if gateways.count > 1 { p.importWarnings.append("Multiple gateways found. First gateway imported; automatic failover is not implemented.") }
        if !url.path.isEmpty && url.path != "/" { p.importWarnings.append("Gateway URL path was omitted. Check whether an authentication realm is required.") }
        let password = value("password", "AuthPassword")
        var clear: String? = password.isEmpty ? nil : password
        if password.lowercased().hasPrefix("enc") || password.hasPrefix("<") || password.range(of: "^[0-9A-Fa-f]{64,}$", options: .regularExpression) != nil {
            clear = nil; p.importWarnings.append("Fortinet-encrypted password was not imported. Enter your VPN password when connecting.")
        }
        if !value("certificate_required").isEmpty { p.importWarnings.append("Export references a client certificate. Select its PEM certificate and key in profile settings.") }
        try p.validate()
        return ImportedProfile(profile: p, password: clear)
    }
    private static func mobile(_ dict: [String:Any], source: String) throws -> ImportResult {
        func payloads(_ d: [String:Any]) -> [[String:Any]] { [d] + ((d["PayloadContent"] as? [[String:Any]]) ?? []).flatMap(payloads) }
        var items: [ImportedProfile] = []
        for payload in payloads(dict) where (payload["PayloadType"] as? String) == "com.apple.vpn.managed" {
            let vendor = payload["VendorConfig"] as? [String:Any] ?? [:]
            let vpn = payload["VPN"] as? [String:Any] ?? payload["IPSec"] as? [String:Any] ?? payload["IKEv2"] as? [String:Any] ?? [:]
            let ppp = payload["PPP"] as? [String:Any] ?? [:]
            var merged = vendor.merging(vpn) { _, b in b }.merging(ppp) { _, b in b }
            merged["name"] = payload["UserDefinedName"] ?? payload["PayloadDisplayName"] ?? "Imported VPN"
            merged["protocol"] = payload["VPNType"]
            var item = try convert(merged, source: source)
            if vpn["PayloadCertificateUUID"] != nil || payload["PayloadCertificateUUID"] != nil { item.profile.importWarnings.append("Embedded certificate identities require manual PEM certificate/key selection.") }
            items.append(item)
        }
        guard !items.isEmpty else { throw AppError("No managed VPN payload found in this Apple configuration.") }
        return ImportResult(items: items)
    }
}

enum BrowserSSO {
    // FortiGate's redirect=1 flow returns to this fixed loopback port.
    static let callbackPort = 8020
    static func checkCallbackAvailable() throws {
        let fd=socket(AF_INET,SOCK_STREAM,0)
        guard fd>=0 else {throw AppError("Cannot check the browser sign-in callback.")}
        defer {close(fd)}
        var address=sockaddr_in()
        address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET)
        address.sin_addr.s_addr=inet_addr("127.0.0.1")
        address.sin_port=UInt16(callbackPort).bigEndian
        let result=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard result==0 else {throw AppError("Browser sign-in needs port 8020, but another app is using it. Finish or cancel FortiClient sign-in, then retry FortiBreak.")}
    }
    static func loginURL(in line:String,profile:VPNProfile) -> URL? {
        // openfortivpn prints Authenticate at 'https://...'. Quotes are log punctuation.
        guard let regex=try? NSRegularExpression(pattern:#"https://[^\s'\"<>]+"#),
              let match=regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),
              let range=Range(match.range,in:line),
              let parts=URLComponents(string:String(line[range])),
              parts.scheme=="https", parts.host?.lowercased()==profile.host.lowercased(),
              (parts.port ?? 443)==profile.port, parts.user==nil, parts.password==nil,
              parts.path=="/remote/saml/start", parts.fragment==nil else {return nil}
        let queries=parts.queryItems ?? []
        guard queries.filter({$0.name=="redirect"}).map({$0.value}) == ["1"],
              queries.allSatisfy({["redirect","realm"].contains($0.name)}),
              queries.filter({$0.name=="realm"}).count<=1,
              (queries.first(where:{$0.name=="realm"})?.value ?? "")==profile.realm else {return nil}
        return parts.url
    }
}
struct ConnectRequest: Codable { var profile: VPNProfile; var password: String; var samlPort: Int = BrowserSSO.callbackPort }
struct WireMessage: Codable { var kind: String; var text: String = ""; var code: Int32? = nil }

enum ReconnectPolicy {
    // Only a tunnel that was up and then dropped without a user stop is retried.
    // A failed first sign-in (wrong password, cancelled SSO) never loops.
    // The first delay outlasts the SAML callback port's TCP TIME_WAIT.
    static let delays: [TimeInterval] = [5, 15, 45]
    static func delay(enabled: Bool, wasConnected: Bool, userStopped: Bool, attempt: Int) -> TimeInterval? {
        guard enabled, wasConnected, !userStopped, attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}

enum Backend {
    #if PRIVILEGED_RUNTIME
    static let paths = [PrivilegedPaths.engine]
    #else
    static let paths = ["/opt/homebrew/bin/openfortivpn", "/usr/local/bin/openfortivpn"]
    #endif
    static var executable: String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static func arguments(_ request: ConnectRequest) throws -> [String] {
        try request.profile.validate()
        if let reason = request.profile.unsupported { throw AppError(reason) }
        let p = request.profile
        if p.login == .password && p.username.isEmpty {throw AppError("Enter your VPN username in Connection settings before connecting.")}
        // Keep the physical default route available when PPP disappears. The /1
        // routes still send all public IPv4 traffic into a full tunnel; gateway
        // supplied split routes continue to take precedence in openfortivpn.
        // On macOS pppd publishes DNS via SystemConfiguration. Editing the
        // generated resolv.conf in parallel races configd and is not system DNS.
        var args = ["--config=/dev/null", "--username=" + p.username, "--realm=" + p.realm, "--set-routes=1", "--half-internet-routes=1", "--set-dns=0", "--pppd-use-peerdns=1", "--pppd-accept-remote=0"]
        if p.login == .browser { guard request.samlPort == BrowserSSO.callbackPort else { throw AppError("Browser SSO requires callback port 8020.") }; args.append("--saml-login=" + String(BrowserSSO.callbackPort)) }
        for (flag,path) in [("--ca-file=",p.caFile),("--user-cert=",p.certificateFile),("--user-key=",p.keyFile)] where !path.isEmpty {
            guard path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path) else { throw AppError("Certificate/key file is missing or unreadable: " + URL(fileURLWithPath:path).lastPathComponent) }
            args.append(flag + path)
        }
        if !p.trustedCertificate.isEmpty { args.append("--trusted-cert=" + p.trustedCertificate) }
        let host = p.host.contains(":") ? "[" + p.host + "]" : p.host
        args.append(host + ":" + String(p.port))
        return args
    }
}

struct LogRedactor {
    var secrets: [String] = []
    mutating func add(_ s: String) { if !s.isEmpty { secrets.append(s) } }
    func clean(_ s: String) -> String {
        var s = s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        for secret in secrets.sorted(by: { $0.count > $1.count }) { s = s.replacingOccurrences(of: secret, with: "[redacted]") }
        s = s.replacingOccurrences(of: "(?i)(SVPNCOOKIE[=:\\s]+)[^\\s;]+", with: "$1[redacted]", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)([?&](?:id|token|code)=)[^&\\s]+", with: "$1[redacted]", options: .regularExpression)
        return String(s.unicodeScalars.filter { $0.value >= 32 || [9,10,13].contains($0.value) }.map(Character.init))
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw AppError("Session socket path is too long.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in ptr.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    static func create(_ path: String, server: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError("Could not create local session socket.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSig: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        do {
            var addr = try address(path)
            let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in server ? Darwin.bind(fd,p,socklen_t(MemoryLayout<sockaddr_un>.size)) : Darwin.connect(fd,p,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw AppError("Could not establish private session channel (errno \(errno)).") }
            if server { chmod(path, 0o600); guard listen(fd,1) == 0 else { throw AppError("Could not listen for VPN helper.") } }
            return fd
        } catch { close(fd); throw error }
    }
    static func send<T: Encodable>(_ value: T, fd: Int32) throws {
        var data = try JSONEncoder().encode(value); data.append(10)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let n = Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset); if n <= 0 { throw AppError("Session channel closed.") }; offset += n }
        }
    }
}

struct FortiSystemService:Equatable {
    let id:String
    let name:String
    let connected:Bool
}
enum FortiSystemParser {
    static func services(_ text:String) -> [FortiSystemService] {
        let pattern="(?m)^.*?\\((Connected|Disconnected|Connecting|Disconnecting)\\)\\s+([A-Fa-f0-9-]{36})\\s+VPN \\(com\\.fortinet\\.forticlient\\.vpn\\) \\\"([^\\\"]+)\\\""
        guard let regex=try? NSRegularExpression(pattern:pattern) else {return []}
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match in
            func value(_ index:Int) -> String {Range(match.range(at:index),in:text).map{String(text[$0])} ?? ""}
            return FortiSystemService(id:value(2),name:value(3),connected:value(1) != "Disconnected")
        }
    }
    static func profile(_ text:String,service:FortiSystemService) throws -> ImportedProfile {
        var fields:[String:String]=[:]
        let allowed=Set(["RemoteAddress","SSO","AuthName","UserName","Realm"])
        for line in text.components(separatedBy:.newlines) {
            let pair=line.split(separator:":",maxSplits:1).map{$0.trimmingCharacters(in:.whitespaces)}
            if pair.count==2,allowed.contains(pair[0]) {fields[pair[0]]=pair[1]}
        }
        guard let address=fields["RemoteAddress"],!address.isEmpty else {throw AppError("macOS did not expose the FortiClient gateway. Enter the gateway in a new connection.")}
        var dictionary:[String:Any]=["name":service.name,"host":address,"username":fields["AuthName"] ?? fields["UserName"] ?? "","realm":fields["Realm"] ?? "","protocol":"ssl","sso_enabled":fields["SSO"]?.lowercased() == "true" ? "1":"0"]
        dictionary["notes"]="Imported from the macOS FortiClient VPN service."
        let data=try JSONSerialization.data(withJSONObject:dictionary)
        var item=try ProfileImporter.parse(data,source:"macOS FortiClient profile").items[0]
        item.profile.importWarnings.append("macOS exposes gateway and browser-login settings. Saved passwords, certificate identities and private FortiClient options were not copied. Review settings before connecting.")
        return item
    }
}
