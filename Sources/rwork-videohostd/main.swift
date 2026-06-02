// rwork-videohostd — the GUI video path (PATH 2 / Phase 4) host daemon.
//
// It is the executable wrapper the `RworkVideoHostSession` orchestrator was missing: it
// enumerates the host's shareable windows (ScreenCaptureKit), picks one by CGWindowID (or
// title substring), binds the UDP media + cursor sockets (`NWVideoDatagramTransport`), and
// runs the session — which waits for the client `hello`, then captures → 2-session HEVC
// encodes → packetizes → serves, and injects client input back (doc 17 §3, doc 18).
//
// ⚠️ GUI + TCC ONLY. `SCShareableContent` (and the capture/encode the session starts) need a
// real window-server session + Screen-Recording permission (and Accessibility + Post-Event for
// input injection). They HANG / fail headlessly — run this from a real GUI login session, not
// SSH. This binary is COMPILED + reviewed; its live behaviour is verified on hardware.
//
// USAGE:
//   rwork-videohostd --list                          # enumerate shareable windows + exit
//   rwork-videohostd --window-id 12345               # serve that window (default ports 9000/9001)
//   rwork-videohostd --window-title Safari           # serve the first window whose title matches
//   rwork-videohostd --window-id 12345 --media-port 9000 --cursor-port 9001
//
// The client enters the printed windowID + ports in the Rwork app's Remote-window panel.

import Foundation

#if os(macOS)
import AppKit
import ScreenCaptureKit
import RworkVideoHost
import RworkVideoProtocol

// MARK: - Arguments

struct VideoHostdArguments {
    var list = false
    var windowID: UInt32?
    var windowTitle: String?
    var mediaPort: UInt16 = 9000
    var cursorPort: UInt16 = 9001
    var scale: Double = 1.0   // capture at window-points × scale PIXELS (1 = point-res/light; raise for sharper)
    var bitrateMbps: Int = 12 // live-encoder target bitrate (Mbps); raise for crisper text

    static func usage(_ program: String) -> String {
        """
        usage: \(program) [--list] [--window-id N | --window-title SUBSTR] \
        [--media-port N] [--cursor-port N]

          --list             enumerate shareable windows (id, app, title, size) and exit
          --window-id N      serve the window with CGWindowID N
          --window-title S   serve the first on-screen window whose title contains S
          --media-port N     UDP media/control/geometry/input port (default 9000)
          --cursor-port N    UDP dedicated cursor port (default 9001)
          --scale N          capture at window-points × N PIXELS (default 1 = light; 2 = Retina/sharper)
          --bitrate N        live-encoder target bitrate in Mbps (default 12; higher = crisper text,
                             but the low-latency rate-control caps keyframe growth — for truly sharp
                             text raise --scale instead, or use an all-intra mode)

        Needs Screen-Recording (capture) + Accessibility & Post-Event (input) TCC, and a
        real GUI login session. Run from the desktop, not over SSH.
        """
    }

    static func parse(_ argv: [String]) -> VideoHostdArguments? {
        var a = VideoHostdArguments()
        var i = 1
        func next() -> String? { i + 1 < argv.count ? argv[i + 1] : nil }
        while i < argv.count {
            switch argv[i] {
            case "--list": a.list = true
            case "--window-id":
                guard let v = next(), let n = UInt32(v) else { return nil }
                a.windowID = n; i += 1
            case "--window-title":
                guard let v = next() else { return nil }
                a.windowTitle = v; i += 1
            case "--media-port":
                guard let v = next(), let n = UInt16(v) else { return nil }
                a.mediaPort = n; i += 1
            case "--cursor-port":
                guard let v = next(), let n = UInt16(v) else { return nil }
                a.cursorPort = n; i += 1
            case "--scale":
                guard let v = next(), let n = Double(v), n >= 1 else { return nil }
                a.scale = n; i += 1
            case "--bitrate":
                guard let v = next(), let n = Int(v), n >= 1 else { return nil }
                a.bitrateMbps = n; i += 1
            case "-h", "--help": return nil
            default: return nil
            }
            i += 1
        }
        // Must either list, or name a window.
        if !a.list && a.windowID == nil && a.windowTitle == nil { return nil }
        // Two DISTINCT non-zero UDP ports (NWEndpoint.Port rejects 0; the sockets must differ).
        if a.mediaPort == 0 || a.cursorPort == 0 || a.mediaPort == a.cursorPort { return nil }
        return a
    }
}

let argv = CommandLine.arguments
let program = (argv.first as NSString?)?.lastPathComponent ?? "rwork-videohostd"

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(program): \(message)\n".utf8))
    exit(code)
}

guard let args = VideoHostdArguments.parse(argv) else {
    FileHandle.standardError.write(Data((VideoHostdArguments.usage(program) + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(program): \(message)\n".utf8))
}

// Live ScreenCaptureKit capture needs a window-server connection. A bare command-line binary
// never establishes one, so `SCStream.startCapture()` aborts with
// `Assertion failed: (did_initialize), CGS_REQUIRE_INIT` — even though `SCShareableContent`
// enumeration (used by --list) works without it. Initialising the shared `NSApplication`
// connects this process to the window server; `.accessory` keeps it off the Dock / out of the
// menu bar. Do this BEFORE any capture starts. (We keep `dispatchMain()` as the run loop;
// frame delivery is on SCStream's own dispatch queue.)
NSApplication.shared.setActivationPolicy(.accessory)

/// Fetches the shareable, on-screen windows (excluding desktop chrome).
func shareableWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    // Stable, readable order: by owning app then window id.
    return content.windows.sorted {
        let an = $0.owningApplication?.applicationName ?? ""
        let bn = $1.owningApplication?.applicationName ?? ""
        return an == bn ? $0.windowID < $1.windowID : an < bn
    }
}

func describe(_ w: SCWindow) -> String {
    let app = w.owningApplication?.applicationName ?? "?"
    let title = (w.title?.isEmpty == false) ? w.title! : "(untitled)"
    let size = "\(Int(w.frame.width))x\(Int(w.frame.height))"
    return String(format: "  id=%-8u  %-22@  %@  [%@]",
                  w.windowID, app as NSString, title as NSString, size as NSString)
}

func pick(_ windows: [SCWindow], _ args: VideoHostdArguments) -> SCWindow? {
    if let id = args.windowID {
        return windows.first { $0.windowID == id }
    }
    if let needle = args.windowTitle, !needle.isEmpty {
        return windows.first { ($0.title ?? "").localizedCaseInsensitiveContains(needle) }
    }
    return nil
}

// The session is held for the process lifetime; SIGINT drives the orderly stop. Set by the
// bring-up Task, read by the SIGINT Task — different threads, so a lock guards the shared var
// (the `@unchecked Sendable` would otherwise hide a real data race).
final class Holder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: RworkVideoHostSession?
    func set(_ s: RworkVideoHostSession) { lock.lock(); session = s; lock.unlock() }
    func current() -> RworkVideoHostSession? { lock.lock(); defer { lock.unlock() }; return session }
}
let holder = Holder()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    log("SIGINT — shutting down")
    Task {
        await holder.current()?.stop()
        exit(0)
    }
}
sigint.resume()

Task {
    do {
        let windows = try await shareableWindows()

        if args.list {
            if windows.isEmpty {
                log("no shareable windows (grant Screen-Recording permission, and ensure a GUI session)")
            } else {
                log("shareable windows (\(windows.count)):")
                for w in windows { log(describe(w)) }
            }
            exit(0)
        }

        guard let window = pick(windows, args) else {
            let how = args.windowID.map { "id \($0)" } ?? "title '\(args.windowTitle ?? "")'"
            die("no shareable window matched \(how). Run `\(program) --list` to see candidates.")
        }

        // Capture all display info BEFORE handing the (non-Sendable) SCWindow to the actor —
        // its last use must be the `init` so the value transfers without a data race.
        let app = window.owningApplication?.applicationName ?? "?"
        let title = (window.title?.isEmpty == false) ? window.title! : "(untitled)"
        let wid = window.windowID

        let transport = NWVideoDatagramTransport(mediaPort: args.mediaPort, cursorPort: args.cursorPort)
        let session = RworkVideoHostSession(window: window, transport: transport, captureScale: args.scale, bitrate: args.bitrateMbps * 1_000_000)
        holder.set(session)
        try await session.start()

        log("serving window id=\(wid) '\(title)' [\(app)] "
            + "on media:\(args.mediaPort) cursor:\(args.cursorPort) — awaiting client hello")
        log("client: open the Rwork app → Remote window → host=<this machine> "
            + "media=\(args.mediaPort) cursor=\(args.cursorPort) window-id=\(wid)")
    } catch {
        die("failed to start: \(error)")
    }
}

dispatchMain()

#else

FileHandle.standardError.write(Data(
    "rwork-videohostd: the GUI video path host is macOS-only (ScreenCaptureKit + VideoToolbox).\n".utf8))
exit(1)

#endif
