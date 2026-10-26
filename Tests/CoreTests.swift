import Foundation
import Darwin

@main struct CoreTests {
    static var count=0
    static func check(_ test: @autoclosure ()->Bool,_ label:String){count+=1;if !test(){fputs("FAIL: \(label)\n",stderr);exit(1)}}
    static func rejects(_ body:()->Void){}
    static func main()throws{
        let xml="""
        <?xml version="1.0"?><forticlient_configuration><vpn><sslvpn><connections><connection><name>Engineering</name><server>vpn.example.com:10443;backup.example.com</server><username>person</username><password>Enc deadbeef</password><sso_enabled>1</sso_enabled></connection></connections></sslvpn><ipsecvpn><connections><connection><name>Office</name><remote-gw>office.example.com</remote-gw></connection></connections></ipsecvpn></vpn></forticlient_configuration>
        """
        let imported=try ProfileImporter.parse(Data(xml.utf8),source:"test.conf")
        check(imported.items.count==2,"Both SSL and IPsec profiles preserved")
        let ssl=imported.items[0]
        check(ssl.profile.host=="vpn.example.com" && ssl.profile.port==10443,"Gateway and explicit port parsed")
        check(ssl.profile.login == .browser,"SSO recognized")
        check(ssl.password==nil && ssl.profile.importWarnings.count==2,"Encrypted secret discarded and fallback gateway flagged")
        check(imported.items[1].profile.unsupported != nil,"IPsec never silently converted to SSL")
        let conf=try ProfileImporter.parse(Data("host = vpn.example.com\nusername = me\npassword = secret-for-test\nport = 8443\npppd-plugin = /tmp/bad.so\n".utf8),source:"test.cfg")
        check(conf.items[0].password=="secret-for-test","Plain config password offered for explicit Keychain import")
        check(conf.items[0].profile.importWarnings.count==1,"Arbitrary backend directives flagged")
        let stored=try JSONEncoder().encode(conf.items[0].profile)
        check(!String(decoding:stored,as:UTF8.self).contains("secret-for-test"),"Persisted model excludes credentials")
        let args=try Backend.arguments(ConnectRequest(profile:conf.items[0].profile,password:"secret-for-test"))
        check(!args.joined().contains("secret-for-test"),"Backend argv excludes password")
        check(args.contains("--config=/dev/null") && !args.joined().contains("--insecure"),"Default config ignored and TLS validation retained")
        check(args.contains("--set-routes=1") && args.contains("--half-internet-routes=1"),"Full-tunnel route policy preserves the physical default route")
        check(args.contains("--set-dns=0") && args.contains("--pppd-use-peerdns=1"),"Only macOS PPP owns DNS; backend cannot rewrite generated resolv.conf")
        var invalid=ssl.profile;invalid.host="vpn.example.com;touch /tmp/no"
        do{try invalid.validate();check(false,"Reject hostname injection")}catch{check(true,"Reject hostname injection")}
        invalid=ssl.profile;invalid.port=70000
        do{try invalid.validate();check(false,"Reject invalid port")}catch{check(true,"Reject invalid port")}
        do{_ = try ProfileImporter.parse(Data("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>".utf8),source:"entity.xml");check(false,"Reject XML entities")}catch{check(true,"Reject XML entities")}
        do{_ = try ProfileImporter.parse(Data("encrypted-export-garbage".utf8),source:"encrypted.conf");check(false,"Encrypted export fails explicitly")}catch{check(true,"Encrypted export fails explicitly")}
        let plist:[String:Any] = ["PayloadContent":[["PayloadType":"com.apple.vpn.managed","UserDefinedName":"Apple VPN","VPNType":"VPN","VPN":["RemoteAddress":"vpn.example.com","AuthName":"person"]]]]
        let pdata=try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0)
        let mobile=try ProfileImporter.parse(pdata,source:"vpn.mobileconfig")
        check(mobile.items[0].profile.username=="person","Apple managed VPN payload read")
        var r=LogRedactor();r.add("my-password")
        let redacted=r.clean("my-password Cookie: SVPNCOOKIE=abcdef id https://vpn.example.com/?id=sensitive&token=private")
        check(!redacted.contains("my-password") && !redacted.contains("abcdef") && !redacted.contains("sensitive") && !redacted.contains("private"),"Log secret and token redaction")
        let json=try ProfileImporter.parse(Data("{\"profiles\":[{\"name\":\"JSON\",\"host\":\"vpn.example.com\",\"port\":443}]}".utf8),source:"vpn.json")
        check(json.items[0].profile.name=="JSON","JSON profile import")
        check(r.clean("\u{001B}[31mred\u{001B}[0m")=="red","ANSI terminal controls removed")
        let mixed="<forticlient_configuration><sslvpn><connection><name>Valid</name><server>vpn.example.com</server></connection><connection><name>Broken</name></connection></sslvpn></forticlient_configuration>"
        do{_ = try ProfileImporter.parse(Data(mixed.utf8),source:"mixed.xml");check(false,"Malformed connections cannot disappear silently")}catch{check(true,"Malformed connections cannot disappear silently")}
        do{_ = try ProfileImporter.parse(Data("host=vpn.example.com\nport=garbage".utf8),source:"port.cfg");check(false,"Malformed imported ports cannot silently default")}catch{check(true,"Malformed imported ports cannot silently default")}
        do{_ = try ProfileImporter.parse(Data("{\"host\":\"vpn.example.com\",\"protocol\":\"wireguard\"}".utf8),source:"unknown.json");check(false,"Unknown VPN protocols never become SSL")}catch{check(true,"Unknown VPN protocols never become SSL")}
        let services=FortiSystemParser.services("* (Connected) F7112688-A441-4B67-A54F-F59FF95B417D VPN (com.fortinet.forticlient.vpn) \"FortiClient VPN\" [VPN:com.fortinet.forticlient.vpn]\n* (Disconnected) 44A1CF99-B482-4F71-AAE7-592F926691B2 VPN (com.other.vpn) \"Other\" [VPN:com.other.vpn]")
        check(services.count==1 && services[0].connected,"Only FortiClient service selected and active tunnel recognized")
        let systemItem=try FortiSystemParser.profile("RemoteAddress : https://vpn.example.com:10443\nSSO : TRUE\nSecretOption : must-not-copy",service:services[0])
        check(systemItem.profile.port==10443 && systemItem.profile.login == .browser && systemItem.password==nil,"macOS profile imports gateway and SSO without secrets")
        var browser=ssl.profile; browser.port=443
        let login="https://vpn.example.com:443/remote/saml/start?redirect=1"
        check(BrowserSSO.loginURL(in:"INFO: Authenticate at '\(login)'",profile:browser)?.absoluteString==login,"Quoted engine login URL excludes the closing quote")
        check(BrowserSSO.loginURL(in:"INFO: Authenticate at \"\(login)\"",profile:browser)?.absoluteString==login,"Double-quoted engine URL excludes punctuation")
        check(BrowserSSO.loginURL(in:"\(login)%27",profile:browser)==nil,"Reject corrupted redirect flag")
        check(BrowserSSO.loginURL(in:login.replacingOccurrences(of:"vpn.example.com",with:"vpn.example.com.attacker.invalid"),profile:browser)==nil,"Reject browser handoff to another host")
        check(BrowserSSO.loginURL(in:login.replacingOccurrences(of:":443",with:":8443"),profile:browser)==nil,"Reject browser handoff to another port")
        check(BrowserSSO.loginURL(in:login+"&redirect=0",profile:browser)==nil,"Reject duplicate redirect flag")
        browser.realm="staff team"
        check(BrowserSSO.loginURL(in:"'\(login)&realm=staff%20team'",profile:browser)?.query?.contains("realm=staff%20team")==true,"Realm survives quoted login handoff")
        check(BrowserSSO.loginURL(in:login,profile:browser)==nil,"Missing realm cannot silently change login")
        let browserArgs=try Backend.arguments(ConnectRequest(profile:browser,password:""))
        check(browserArgs.contains("--saml-login=8020"),"Browser listener uses the gateway's fixed callback port")
        do{_ = try Backend.arguments(ConnectRequest(profile:browser,password:"",samlPort:49152));check(false,"Random callback ports rejected")}catch{check(true,"Random callback ports rejected")}
        let directory="/tmp/cg-test-"+UUID().uuidString
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(atPath:directory)}
        let path=directory+"/control.sock",server=try UnixSocket.create(path,server:true)
        defer{close(server)}
        let client=try UnixSocket.create(path,server:false);defer{close(client)}
        let accepted=accept(server,nil,nil);defer{close(accepted)}
        try UnixSocket.send(WireMessage(kind:"input",text:"code"),fd:client)
        var buffer=[UInt8](repeating:0,count:1024);let n=read(accepted,&buffer,buffer.count)
        let roundtrip=try JSONDecoder().decode(WireMessage.self,from:Data(buffer.prefix(n)).dropLast())
        check(roundtrip.text=="code","Private socket JSON framing works")
        var st=stat();lstat(path,&st)
        check(st.st_mode & 0o777 == 0o600,"Session socket permissions restrict access")
        check(ReconnectPolicy.delay(enabled:true,wasConnected:true,userStopped:false,attempt:0)==5,"Dropped tunnel reconnects after a short delay")
        check(ReconnectPolicy.delay(enabled:true,wasConnected:false,userStopped:false,attempt:0)==nil,"Failed first sign-in never loops")
        check(ReconnectPolicy.delay(enabled:true,wasConnected:true,userStopped:true,attempt:0)==nil,"User disconnect never reconnects")
        check(ReconnectPolicy.delay(enabled:false,wasConnected:true,userStopped:false,attempt:0)==nil,"Reconnect respects the setting")
        check(ReconnectPolicy.delay(enabled:true,wasConnected:true,userStopped:false,attempt:ReconnectPolicy.delays.count)==nil && ReconnectPolicy.delays==ReconnectPolicy.delays.sorted(),"Reconnect attempts are bounded with growing delays")
        print("Passed \(count) core checks. No network connections made.")
    }
}
