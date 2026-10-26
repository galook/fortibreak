import Foundation
import Darwin

@main struct DiagnosticsTests {
    static func main()throws {
        let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("cg-diagnostics-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("last-session.json")
        let date=Date(timeIntervalSince1970:100)
        SessionDiagnostics.save([LogLine(date:date,text:"Before VPN: physical route exists")],to:file)
        let restored=SessionDiagnostics.load(from:file)
        precondition(restored.count==1 && restored[0].date==date && restored[0].text.contains("physical route"))
        var info=stat();precondition(lstat(file.path,&info)==0 && info.st_mode & 0o777==0o600)
        precondition(lstat(directory.path,&info)==0 && info.st_mode & 0o777==0o700)
        SessionDiagnostics.save((0..<500).map{LogLine(text:"event \($0) "+String(repeating:"x",count:5000))},to:file)
        let data=try Data(contentsOf:file),bounded=SessionDiagnostics.load(from:file)
        precondition(data.count<=1_000_000 && !bounded.isEmpty && bounded.last!.text.hasPrefix("event 499"))
        SessionDiagnostics.save([],to:file)
        precondition(SessionDiagnostics.load(from:file).isEmpty)
        try Data("broken JSON".utf8).write(to:file)
        precondition(SessionDiagnostics.load(from:file).isEmpty)
        let snapshot=SessionDiagnostics.snapshot()
        precondition(snapshot.contains("scutil --dns") && snapshot.contains("netstat -rn -f inet"))
        print("Passed private diagnostics persistence, timestamp, bounded history, clear/corrupt-file and local network snapshot checks. No VPN or external probes.")
    }
}
