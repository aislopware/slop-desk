// slopdesk-navhistory-probe — runtime proof that `HostNavHistory` (the swipe-nav history
// gate's AX reader, doc 20 §9.6) reads a live app's canGoBack/canGoForward correctly: the
// reader is process-external AX IPC, which hang-safety bars from unit tests, so this probe is
// the only way to exercise the REAL strategy selection (toolbar identifiers vs menu key
// equivalents), the per-pid element cache, and the per-WINDOW currency check (navigate /
// switch windows in the target while it runs and watch the flags follow). Needs Accessibility
// TCC on the invoking terminal. Diagnostic-only, sibling of slopdesk-swipestatus-probe.
//
// Usage: slopdesk-navhistory-probe [bundle-id] [--seconds N]   (default com.google.Chrome, 8 s)

#if os(macOS)
import AppKit
import ApplicationServices
import SlopDeskVideoHost

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var bundleID = "com.google.Chrome"
var seconds = 8.0
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    switch a {
    case "--seconds": seconds = it.next().flatMap(Double.init) ?? seconds
    default: bundleID = a
    }
}

eprint("AXIsProcessTrusted=\(AXIsProcessTrusted())")
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    eprint("app not running: \(bundleID)")
    exit(2)
}

eprint("target \(bundleID) pid \(app.processIdentifier)")

let reader = HostNavHistory()
let deadline = Date().addingTimeInterval(seconds)
var beat = 0
var sawKnown = false
while Date() < deadline {
    beat += 1
    let t0 = DispatchTime.now().uptimeNanoseconds
    // Every 8th beat is the forced beat (unknown-retry + window-currency verify), mirroring
    // the kicker's heartbeat cadence.
    let force = beat % 8 == 1
    let flags = reader.read(pid: app.processIdentifier, rescanUnknown: force, verifyWindow: force)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    let desc = flags.map { "back=\($0.canGoBack) fwd=\($0.canGoForward)" } ?? "unknown"
    eprint(String(format: "beat %2d: %@ (%.2f ms)", beat, desc, ms))
    if flags != nil { sawKnown = true }
    Thread.sleep(forTimeInterval: 0.25)
}

// Exit 0 ⇒ at least one KNOWN read (strategy found a pair); exit 2 ⇒ everything UNKNOWN.
exit(sawKnown ? 0 : 2)
#else
fatalError("slopdesk-navhistory-probe is macOS-only")
#endif
