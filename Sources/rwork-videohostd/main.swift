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
        // Must either list, or name a window — UNLESS UDP-mux (RWORK_VIDEO_MUX) is ON, in which case
        // the daemon mints a per-channel session from EACH client hello's own windowID (the §2
        // asymmetry: two panes watch different windows over one shared flow), so no fixed window arg
        // is required (one may still be passed to validate at --list time).
        let muxOn = VideoMuxGate.enabledFromEnvironment()
        if !a.list && a.windowID == nil && a.windowTitle == nil && !muxOn { return nil }
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

@Sendable func log(_ message: String) {
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
@Sendable func shareableWindows() async throws -> [SCWindow] {
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

// What is held for the process lifetime; SIGINT drives the orderly stop. Set by the bring-up
// Task, read by the SIGINT Task — different threads, so a lock guards the shared vars (the
// `@unchecked Sendable` would otherwise hide a real data race). In the OFF (single-window) path
// only `session` is set; in the UDP-mux (RWORK_VIDEO_MUX) path the `registry` + shared `mux`
// transport are set instead (N sessions, one per channel/window, over the one shared flow).
final class Holder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: RworkVideoHostSession?
    private var registry: VideoMuxSessionRegistry?
    private var mux: NWVideoMuxDatagramTransport?
    func set(_ s: RworkVideoHostSession) { lock.lock(); session = s; lock.unlock() }
    func setMux(_ r: VideoMuxSessionRegistry, _ m: NWVideoMuxDatagramTransport) { lock.lock(); registry = r; mux = m; lock.unlock() }
    func current() -> RworkVideoHostSession? { lock.lock(); defer { lock.unlock() }; return session }
    func currentMux() -> (VideoMuxSessionRegistry, NWVideoMuxDatagramTransport)? {
        lock.lock(); defer { lock.unlock() }
        guard let registry, let mux else { return nil }
        return (registry, mux)
    }
}
let holder = Holder()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    log("SIGINT — shutting down")
    Task {
        if let (registry, mux) = holder.currentMux() {
            await registry.stopAll()
            await mux.stop()
        } else {
            await holder.current()?.stop()
        }
        exit(0)
    }
}
sigint.resume()

/// Daemon-side errors surfaced from the UDP-mux mint factory (a thrown error drops the triggering
/// datagram; the lane is never created, sibling lanes are untouched).
enum VideoHostdError: Error, CustomStringConvertible {
    case muxNoWindow(requestedWindowID: UInt32)
    var description: String {
        switch self {
        case .muxNoWindow(let id): return "no shareable window matched hello requestedWindowID=\(id)"
        }
    }
}

/// Breaks the registry↔lane-transport capture cycle: the lane's `onRetire` hook needs to call the
/// (actor) registry's `retire`, but the lane is built INSIDE the registry's mint closure. This box
/// is captured by the lane synchronously and `bind`-ed to the registry the line after it is built.
/// `@unchecked Sendable` via the `NSLock`; the bound closure hops to the actor itself.
final class MuxRetireBox: @unchecked Sendable {
    private let lock = NSLock()
    private var retireFn: (@Sendable (UInt32) -> Void)?
    func bind(_ fn: @escaping @Sendable (UInt32) -> Void) { lock.withLock { retireFn = fn } }
    func retire(_ id: UInt32) { let fn = lock.withLock { retireFn }; fn?(id) }
}

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

        // ── UDP-mux (RWORK_VIDEO_MUX) bring-up: ONE shared UDP flow, N sessions (one per channel/
        // window). Each client video pane sends its OWN hello (its own windowID); the daemon mints/
        // looks-up the session by channelID (`VideoMuxSessionRegistry`). The §2 asymmetry — two panes
        // watching DIFFERENT windows on the same host — is served by minting a fresh session per
        // hello's requestedWindowID. A `bye` retires ONLY the closing lane; sibling lanes survive.
        if VideoMuxGate.enabledFromEnvironment() {
            let displayScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
            let effectiveScale = min(args.scale, displayScale)
            let bitrate = args.bitrateMbps * 1_000_000
            let mediaPort = args.mediaPort, cursorPort = args.cursorPort

            // CONCURRENCY-HOST-1 mux analogue: the shared transport arms the per-lane reaper.
            let mux = NWVideoMuxDatagramTransport(mediaPort: mediaPort, cursorPort: cursorPort)
            // One shared sink table both the registry (reads on dispatch) and the per-lane transports
            // (register synchronously inside session.start) use, so the triggering hello is delivered
            // the moment a lane is minted. The lane's retire hook is bound after the registry exists.
            let sinkTable = VideoMuxSinkTable()
            let retireBox = MuxRetireBox()
            // The session registry mints a session per new channel's hello. The lane transport
            // (`VideoMuxChannelTransport`) wires the session's sink into the shared sink table.
            let registry = VideoMuxSessionRegistry(sinkTable: sinkTable, forgetLane: { id in mux.retire(id) }) { channelID, hello in
                guard case .hello(_, let requestedWindowID, _) = hello else {
                    throw VideoHostdError.muxNoWindow(requestedWindowID: 0)
                }
                // Re-enumerate live windows for THIS hello (a pane may open long after launch).
                let live = try await shareableWindows()
                guard let w = live.first(where: { $0.windowID == requestedWindowID }) else {
                    throw VideoHostdError.muxNoWindow(requestedWindowID: requestedWindowID)
                }
                // ⚠️ FIX #7 (UN-coded, documented limitation — needs RWORK_VIDEO_MUX ON AND two
                // panes naming the SAME windowID): each lane mints
                // its OWN session bound to this `windowID`. Two lanes on one windowID would each AX-
                // resize the SAME real window on a resizeRequest, so concurrent resizes can fight
                // (last write wins, capture/window aspect can briefly disagree). This atypical config
                // is out of scope here; the resize-fight is not coded against (see docs/25).
                let lane = VideoMuxChannelTransport(
                    channelID: channelID,
                    shared: mux,
                    sinkTable: sinkTable,
                    onRetire: { id in retireBox.retire(id) }
                )
                let session = RworkVideoHostSession(window: w, transport: lane, captureScale: effectiveScale, bitrate: bitrate)
                try await session.start()
                log("mux: minted session chan=\(channelID) window-id=\(requestedWindowID) over shared flow")
                return session
            }
            retireBox.bind { id in Task { await registry.retire(id) } }
            // CONCURRENCY-HOST-1: when the reaper reclaims a dead lane, retire it AND stop its session
            // (capture/encode actually stops — the leak `retire` alone left).
            mux.onReapLane = { id in await registry.retireAndStop(id) }
            holder.setMux(registry, mux)
            try await mux.start { channelID, channel, data in
                // ORDERING (mirrors the OFF InboundQueue discipline): an ADMITTED lane's sink
                // appends to its session's serial inbound queue SYNCHRONOUSLY, in arrival order, on
                // the transport's serial receive queue — so a mouseUp can never overtake its
                // preceding mouseDown/mouseDrag (InputButtonBalance + down/up pairing are
                // load-bearing; video tolerates reorder, INPUT does not). Spawning a Task per
                // datagram loses arrival order (no FIFO guarantee across Tasks hitting the actor).
                // Only the FIRST hello for a not-yet-minted lane needs the async mint hop.
                if let sink = sinkTable.sink(channelID) {
                    sink(channel, data)
                } else {
                    Task { await registry.dispatch(channelID: channelID, channel: channel, data: data) }
                }
            }
            log("UDP-mux: serving SHARED flow on media:\(mediaPort) cursor:\(cursorPort) — N panes, one flow, per-hello windows")
            log("client: set RWORK_VIDEO_MUX on the Rwork app too (both ends must agree); each pane's hello picks its window")
            return
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

        // Clamp captureScale to the host display's backing scale. ScreenCaptureKit captures a
        // window whose backing is 1× into a LARGER (e.g. 2×) output buffer by placing the content
        // 1:1 in the TOP-LEFT + black padding — it does NOT upscale. A client then faithfully
        // renders that half/quarter-filled buffer → the video appears "in one corner" ("nhỏ 1
        // góc"). Requesting more scale than the host display has buys no real detail anyway, so
        // cap it. (A 2× host display will allow --scale 2 for crisp text.)
        let displayScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
        let effectiveScale = min(args.scale, displayScale)
        if effectiveScale < args.scale {
            log("clamping --scale \(args.scale) → \(effectiveScale) (host display backing scale; SCK pads, not upscales)")
        }
        // CONCURRENCY-HOST-1: the transport constructs + arms the crash-without-bye reaper.
        let transport = NWVideoDatagramTransport(mediaPort: args.mediaPort, cursorPort: args.cursorPort)
        let session = RworkVideoHostSession(window: window, transport: transport, captureScale: effectiveScale, bitrate: args.bitrateMbps * 1_000_000)
        holder.set(session)
        // When the reaper reclaims the dead flow, mirror a bye's capture teardown on the session
        // (the only new async work). Weak ref so a racing stop()/exit can't keep it alive.
        transport.onReap = { [weak session] in Task { await session?.handleReap() } }
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
