import Foundation
import Security
import CryptoKit
import Darwin

enum PrivilegedPaths {
    static let label="eu.local.fortibreak.vpn-helper"
    static let base="/Library/PrivilegedHelperTools/eu.local.fortibreak"
    static let socket="/var/run/eu.local.fortibreak.sock"
    static let plist="/Library/LaunchDaemons/"+label+".plist"
    static let configuration=base+"/configuration.json"
    static let worker=base+"/FortiBreakHelper"
    static let daemon=base+"/FortiBreakDaemon"
    static let engine=base+"/openfortivpn"
    static let certificates=base+"/cert.pem"
    static let lock="/Library/PrivilegedHelperTools/eu.local.fortibreak.session.lock"
    static let version=1
}
struct HelperConfiguration:Codable {
    let version:Int
    let ownerUID:UInt32
    let appCDHash:String
}
struct BrokerCommand:Codable {let kind:String;var directory:String=""}
struct InstallFile:Codable {let source:String;let name:String;let sha256:String}
struct DependencyRewrite:Codable {let name:String;let from:String;let to:String}
struct InstallManifest:Codable {let files:[InstallFile];let rewrites:[DependencyRewrite]}

enum CodeIdentity {
    static func hash(of executableOrApp:String) throws -> String {
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath:executableOrApp) as CFURL,[],&code)==errSecSuccess,let code else {throw AppError("Cannot inspect FortiBreak signature.")}
        guard SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil)==errSecSuccess else {throw AppError("FortiBreak signature is invalid. Reinstall the app.")}
        var information:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,
              let dictionary=information as? [String:Any],let digest=dictionary[kSecCodeInfoUnique as String] as? Data else {throw AppError("FortiBreak signing identity is unavailable.")}
        guard let flags=dictionary[kSecCodeInfoFlags as String] as? NSNumber,flags.uint32Value & 0x10000 != 0 else {throw AppError("FortiBreak requires its hardened runtime signature. Rebuild the app before helper setup.")}
        return digest.map{String(format:"%02x",$0)}.joined()
    }
    static func authorize(peer fd:Int32,uid:UInt32,hash:String) throws {
        guard hash.range(of:"^[a-f0-9]{40}$",options:.regularExpression) != nil else {throw AppError("Invalid installed app identity.")}
        var actual:uid_t=0,gid:gid_t=0
        guard getpeereid(fd,&actual,&gid)==0,actual==uid else {throw AppError("VPN helper rejected the client user.")}
        // Kernel-supplied audit token binds signature validation to the socket peer,
        // avoiding a PID lookup/reuse race or a caller-provided identity.
        var token=audit_token_t(),length=socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&length)==0,length==MemoryLayout<audit_token_t>.size else {throw AppError("VPN helper could not authenticate its peer.")}
        let data=withUnsafeBytes(of:&token){Data($0)}
        var guest:SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit as String:data] as CFDictionary,[],&guest)==errSecSuccess,let guest else {throw AppError("VPN helper could not inspect client signature.")}
        var requirement:SecRequirement?
        let rule="cdhash H\""+hash+"\""
        guard SecRequirementCreateWithString(rule as CFString,[],&requirement)==errSecSuccess,
              SecCodeCheckValidity(guest,SecCSFlags(rawValue:kSecCSStrictValidate),requirement)==errSecSuccess else {throw AppError("VPN helper accepts only the approved FortiBreak build. Enable the helper again after updating the app.")}
    }
}

enum TrustedFiles {
    static func regular(_ path:String) throws {
        var info=stat()
        guard lstat(path,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_uid==0,(info.st_mode&0o022)==0 else {throw AppError("VPN helper files need repair. Enable the helper again.")}
    }
    static func directory(_ path:String) throws {
        var info=stat()
        guard lstat(path,&info)==0,(info.st_mode&S_IFMT)==S_IFDIR,info.st_uid==0,(info.st_mode&0o022)==0 else {throw AppError("VPN helper directory is not protected.")}
    }
    static func configuration() throws -> HelperConfiguration {
        try directory(PrivilegedPaths.base)
        try regular(PrivilegedPaths.configuration)
        let data=try Data(contentsOf:URL(fileURLWithPath:PrivilegedPaths.configuration))
        let config=try JSONDecoder().decode(HelperConfiguration.self,from:data)
        guard config.version==PrivilegedPaths.version,config.ownerUID>0 else {throw AppError("VPN helper needs an update.")}
        return config
    }
    static func runtime() throws {
        try directory(PrivilegedPaths.base)
        for file in ["FortiBreakHelper","FortiBreakDaemon","openfortivpn","libssl.4.dylib","libcrypto.4.dylib","cert.pem"] {try regular(PrivilegedPaths.base+"/"+file)}
    }
    static func sessionDirectory(_ path:String,uid:UInt32) throws {
        guard path.hasPrefix("/tmp/fb-"),UUID(uuidString:String(path.dropFirst("/tmp/fb-".count))) != nil else {throw AppError("Invalid VPN session directory.")}
        var info=stat(),socketInfo=stat()
        guard lstat(path,&info)==0,(info.st_mode&S_IFMT)==S_IFDIR,info.st_uid==uid,(info.st_mode&0o077)==0,
              lstat(path+"/control.sock",&socketInfo)==0,(socketInfo.st_mode&S_IFMT)==S_IFSOCK,socketInfo.st_uid==uid,(socketInfo.st_mode&0o077)==0 else {throw AppError("VPN session channel is not private.")}
    }
}

enum BrokerProtocol {
    static func read<T:Decodable>(_ type:T.Type,fd:Int32,limit:Int=16384) throws -> T {
        let deadline=Date().addingTimeInterval(5)
        var data=Data(),byte:UInt8=0
        while data.count<limit {
            let remaining=Int32(max(0,deadline.timeIntervalSinceNow*1000))
            var item=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            guard remaining>0,poll(&item,1,remaining)>0,Darwin.read(fd,&byte,1)==1 else {throw AppError("VPN helper did not answer. Enable or repair the helper.")}
            if byte==10 {return try JSONDecoder().decode(type,from:data)}
            data.append(byte)
        }
        throw AppError("VPN helper request is too large.")
    }
}

enum PrivilegedClient {
    static func request(_ command:BrokerCommand) throws -> WireMessage {
        var info=stat()
        guard lstat(PrivilegedPaths.socket,&info)==0,(info.st_mode&S_IFMT)==S_IFSOCK,info.st_uid==0 else {throw AppError("Enable the VPN helper once before connecting.")}
        let fd=try UnixSocket.create(PrivilegedPaths.socket,server:false)
        defer {close(fd)}
        var uid:uid_t=1,gid:gid_t=1
        guard getpeereid(fd,&uid,&gid)==0,uid==0 else {throw AppError("Unexpected VPN helper identity.")}
        try UnixSocket.send(command,fd:fd)
        let reply=try BrokerProtocol.read(WireMessage.self,fd:fd)
        guard reply.kind != "error" else {throw AppError(reply.text)}
        guard reply.kind=="ready",reply.code==Int32(PrivilegedPaths.version) else {throw AppError("VPN helper needs an update.")}
        return reply
    }
}
