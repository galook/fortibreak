import Foundation
import CryptoKit
import Darwin

@main struct InstallerMain {
    static func command(_ executable:String,_ arguments:[String],ignoreFailure:Bool=false) throws {
        let process=Process();process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
        process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":"/var/root","LC_ALL":"C","OPENSSL_CONF":"/dev/null"]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice
        let pipe=Pipe();process.standardError=pipe
        try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard ignoreFailure || process.terminationStatus==0 else {throw AppError(URL(fileURLWithPath:executable).lastPathComponent+" could not complete helper setup. "+String(decoding:data.prefix(1500),as:UTF8.self))}
    }
    static func sourcePath(_ file:InstallFile,app:String) -> String {
        file.source.hasPrefix("@app/") ? app+String(file.source.dropFirst(4)) : file.source
    }
    // Every runtime file comes from the signed app bundle; the engine and OpenSSL are relocated at build time.
    static let bundled=["FortiBreakDaemon":"/Contents/MacOS/","FortiBreakHelper":"/Contents/MacOS/","openfortivpn":"/Contents/Helpers/","libssl.4.dylib":"/Contents/Helpers/","libcrypto.4.dylib":"/Contents/Helpers/","cert.pem":"/Contents/Resources/"]
    static func allowedSource(_ file:InstallFile,app:String) -> Bool {
        guard let folder=bundled[file.name] else {return false}
        let source=sourcePath(file,app:app)
        return source==app+folder+file.name && URL(fileURLWithPath:source).resolvingSymlinksInPath().path==source
    }
    static func requireIdleEngine(_ action:String) throws {
        let probe=Process(),output=Pipe()
        probe.executableURL=URL(fileURLWithPath:"/bin/ps");probe.arguments=["-axo","comm="];probe.standardOutput=output
        try probe.run();let running=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);probe.waitUntilExit()
        guard !running.components(separatedBy:.newlines).contains(where:{$0.hasSuffix("/FortiBreakHelper") || $0.hasSuffix("/openfortivpn")}) else {throw AppError("Disconnect the running VPN engine before "+action+" the helper.")}
    }
    static func install(app:String,uid:UInt32) throws {
        guard geteuid()==0,uid>0 else {throw AppError("Administrator authorization is required for helper setup.")}
        let appURL=URL(fileURLWithPath:app).standardizedFileURL
        var appInfo=stat()
        guard appURL.path==app,app.hasSuffix(".app"),lstat(app,&appInfo)==0,appInfo.st_uid==uid,(appInfo.st_mode&S_IFMT)==S_IFDIR else {throw AppError("Unexpected FortiBreak application owner or location.")}
        try requireIdleEngine("enabling or updating")
        let hash=try CodeIdentity.hash(of:app)
        let fm=FileManager.default
        let manifest=try JSONDecoder().decode(InstallManifest.self,from:Data(contentsOf:appURL.appendingPathComponent("Contents/Resources/HelperInstallManifest.json")))
        let names=Set(["FortiBreakDaemon","FortiBreakHelper","openfortivpn","libssl.4.dylib","libcrypto.4.dylib","cert.pem"])
        guard Set(manifest.files.map{$0.name})==names,manifest.files.count==names.count else {throw AppError("Helper setup manifest is incomplete.")}
        try TrustedFiles.directory("/Library")
        let parent=URL(fileURLWithPath:PrivilegedPaths.base).deletingLastPathComponent().path
        if !fm.fileExists(atPath:parent) {try fm.createDirectory(atPath:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])}
        try TrustedFiles.directory(parent)
        let lock=open(PrivilegedPaths.lock,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard lock>=0 else {throw AppError("Cannot lock helper setup.")}
        defer {close(lock)}
        guard flock(lock,LOCK_EX|LOCK_NB)==0 else {throw AppError("Disconnect FortiBreak before updating its VPN helper.")}
        let stage=parent+"/.fortibreak-"+UUID().uuidString
        try fm.createDirectory(atPath:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? fm.removeItem(atPath:stage)}
        for file in manifest.files {
            guard allowedSource(file,app:app) else {throw AppError("Helper setup rejected an unexpected source path.")}
            let data=try Data(contentsOf:URL(fileURLWithPath:sourcePath(file,app:app)))
            guard data.count<40_000_000,SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==file.sha256 else {throw AppError("Helper setup files changed. Rebuild FortiBreak before installing the helper.")}
            let path=stage+"/"+file.name
            try data.write(to:URL(fileURLWithPath:path),options:.atomic)
            chmod(path,file.name=="cert.pem" ? 0o644 : 0o755)
        }
        for name in ["FortiBreakDaemon","FortiBreakHelper","openfortivpn","libssl.4.dylib","libcrypto.4.dylib"] {
            try command("/usr/bin/codesign",["--verify","--strict",stage+"/"+name])
        }
        let configuration=HelperConfiguration(version:PrivilegedPaths.version,ownerUID:uid,appCDHash:hash)
        try JSONEncoder().encode(configuration).write(to:URL(fileURLWithPath:stage+"/configuration.json"),options:.atomic)
        chmod(stage+"/configuration.json",0o644);chmod(stage,0o755)
        let plist:[String:Any]=["Label":PrivilegedPaths.label,"ProgramArguments":[PrivilegedPaths.daemon],"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":10,"ProcessType":"Interactive","UserName":"root","Umask":63]
        let plistData=try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0)
        let backup=parent+"/.fortibreak-backup-"+UUID().uuidString
        let previousPlist=try? Data(contentsOf:URL(fileURLWithPath:PrivilegedPaths.plist))
        let hadPrevious=fm.fileExists(atPath:PrivilegedPaths.base)
        if hadPrevious {try TrustedFiles.directory(PrivilegedPaths.base)}
        try command("/bin/launchctl",["bootout","system/"+PrivilegedPaths.label],ignoreFailure:true)
        if hadPrevious {try fm.moveItem(atPath:PrivilegedPaths.base,toPath:backup)}
        do {
            try fm.moveItem(atPath:stage,toPath:PrivilegedPaths.base)
            try plistData.write(to:URL(fileURLWithPath:PrivilegedPaths.plist),options:.atomic)
            chmod(PrivilegedPaths.plist,0o644)
            try TrustedFiles.runtime()
            try command("/bin/launchctl",["bootstrap","system",PrivilegedPaths.plist])
            try command("/bin/launchctl",["print","system/"+PrivilegedPaths.label])
            let deadline=Date().addingTimeInterval(5)
            var socketInfo=stat()
            while Date()<deadline {
                if lstat(PrivilegedPaths.socket,&socketInfo)==0,socketInfo.st_uid==0,(socketInfo.st_mode&S_IFMT)==S_IFSOCK {break}
                usleep(100000)
            }
            guard lstat(PrivilegedPaths.socket,&socketInfo)==0,socketInfo.st_uid==0,(socketInfo.st_mode&S_IFMT)==S_IFSOCK else {throw AppError("VPN helper did not start. Setup was rolled back.")}
            if hadPrevious {try? fm.removeItem(atPath:backup)}
        } catch {
            try? command("/bin/launchctl",["bootout","system/"+PrivilegedPaths.label],ignoreFailure:true)
            try? fm.removeItem(atPath:PrivilegedPaths.base)
            if hadPrevious {try? fm.moveItem(atPath:backup,toPath:PrivilegedPaths.base)}
            if let previousPlist {try? previousPlist.write(to:URL(fileURLWithPath:PrivilegedPaths.plist),options:.atomic);try? command("/bin/launchctl",["bootstrap","system",PrivilegedPaths.plist])}
            else {try? fm.removeItem(atPath:PrivilegedPaths.plist)}
            throw error
        }
    }
    // Same paths as the documented manual removal; profiles and Keychain items are user data and stay.
    static func uninstall() throws {
        guard geteuid()==0 else {throw AppError("Administrator authorization is required to remove the helper.")}
        try requireIdleEngine("removing")
        let fm=FileManager.default
        var info=stat()
        if lstat(PrivilegedPaths.lock,&info)==0 {
            let lock=open(PrivilegedPaths.lock,O_RDWR|O_NOFOLLOW)
            guard lock>=0 else {throw AppError("Cannot lock the VPN helper for removal.")}
            defer {close(lock)}
            guard flock(lock,LOCK_EX|LOCK_NB)==0 else {throw AppError("Disconnect FortiBreak before removing its VPN helper.")}
            try removeHelperFiles(fm)
            unlink(PrivilegedPaths.lock)
        } else {try removeHelperFiles(fm)}
    }
    static func removeHelperFiles(_ fm:FileManager) throws {
        try command("/bin/launchctl",["bootout","system/"+PrivilegedPaths.label],ignoreFailure:true)
        var info=stat()
        if lstat(PrivilegedPaths.plist,&info)==0 {try fm.removeItem(atPath:PrivilegedPaths.plist)}
        if lstat(PrivilegedPaths.base,&info)==0 {try TrustedFiles.directory(PrivilegedPaths.base);try fm.removeItem(atPath:PrivilegedPaths.base)}
        // bootout terminates the daemon before its own cleanup can unlink the socket.
        if lstat(PrivilegedPaths.socket,&info)==0,info.st_uid==0,(info.st_mode&S_IFMT)==S_IFSOCK {unlink(PrivilegedPaths.socket)}
    }
    static func main() {
        let arguments=CommandLine.arguments
        if arguments.count==2,arguments[1]=="--uninstall" {
            do {try uninstall()} catch {fputs(error.localizedDescription+"\n",stderr);exit(1)}
            return
        }
        guard arguments.count==3,let uid=UInt32(arguments[2]) else {exit(64)}
        do {try install(app:arguments[1],uid:uid)}
        catch {fputs(error.localizedDescription+"\n",stderr);exit(1)}
    }
}
