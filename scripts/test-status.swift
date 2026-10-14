// Self-check for Sources/ProgramStatus.swift. Run: scripts/test-status.sh
import Foundation
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}

// Parsing: base64 without padding, kind only with blocked, progress clamped.
let r = StatusRecord(body: "state=blocked:kind=permission:app=terraform:msg=QWxsb3cgZWRpdD8:progress=140")!
check(r.state == .blocked && r.kind == "permission" && r.app == "terraform", "fields")
check(r.msg == "Allow edit?", "msg decoded: \(String(describing: r.msg))")
check(r.progress == 100, "progress clamped")
check(StatusRecord(body: "state=bogus") == nil, "unknown state ignored")
check(StatusRecord(body: "state=working:kind=auth")!.kind == nil, "kind only when blocked")
// "a\u{202E}b\u{7}" -> bidi override and BEL stripped
check(StatusRecord.text("YeKArmIH") == "ab", "sanitized")

// Board: replace, subtree clear, lifetime, urgency.
var b = StatusBoard()
b.apply(StatusRecord(body: "state=working:app=deploy")!)
b.apply(StatusRecord(body: "state=working:id=us/east:progress=40")!)
b.apply(StatusRecord(body: "state=blocked:id=eu")!)
check(b.top?.state == .blocked && b.app == "deploy", "blocked wins, app inherited")
b.apply(StatusRecord(body: "state=clear:id=us")!)
check(b.records["us/east"] == nil && b.records["eu"] != nil, "subtree clear")
b.apply(StatusRecord(body: "state=done:id=eu")!)
b.processEnded()
check(b.records.keys.sorted() == ["eu"], "live records dropped, done kept")
b.markSeen()
check(b.records["eu"]?.state == .idle, "done drops to idle when seen")
b.apply(StatusRecord(body: "state=error")!)
b.apply(StatusRecord(body: "state=clear")!)
check(b.records.isEmpty, "root clear removes all")

print("ok")
