// aislopdesk-videohostd — the GUI video path (PATH 2 / Phase 4) host daemon.
//
// It is the executable wrapper the `AislopdeskVideoHostSession` orchestrator was missing: it
// enumerates the host's shareable windows (ScreenCaptureKit), binds ONE shared UDP media +
// cursor flow (`NWVideoMuxDatagramTransport`), and mints a per-channel session from each
// client `hello`'s own windowID — which then captures → HEVC encodes (live + crisp refresh) → packetizes
// → serves, and injects client input back (doc 17 §3, doc 18). One UDP flow per host, N panes.
//
// ⚠️ GUI + TCC ONLY. `SCShareableContent` (and the capture/encode the session starts) need a
// real window-server session + Screen-Recording permission (and Accessibility + Post-Event for
// input injection). They HANG / fail headlessly — run this from a real GUI login session, not
// SSH. This binary is COMPILED + reviewed; its live behaviour is verified on hardware.
//
// USAGE:
//   aislopdesk-videohostd --list                          # enumerate shareable windows + exit
//   aislopdesk-videohostd --window-id 12345               # serve that window (default ports 9000/9001)
//   aislopdesk-videohostd --window-title Safari           # serve the first window whose title matches
//   aislopdesk-videohostd --window-id 12345 --media-port 9000 --cursor-port 9001
//
// The client enters the printed windowID + ports in the Aislopdesk app's Remote-window panel.

import Foundation

#if os(macOS)
import AppKit
import ScreenCaptureKit
import AislopdeskVideoHost
import AislopdeskVideoProtocol

// MARK: - Arguments

struct VideoHostdArguments {
    var list = false
    var windowID: UInt32?
    var windowTitle: String?
    var mediaPort: UInt16 = 9000
    var cursorPort: UInt16 = 9001
    var scale: Double = 1.0   // capture at window-points × scale PIXELS (1 = point-res/light; raise for sharper)
    var bitrateMbps: Int = 12 // live-encoder target bitrate (Mbps); raise for crisper text
    var fps: Int = 60         // capture + encoder frame-rate cap; 60 = smooth scroll/motion, 30 = lighter
    // Feature #1: create a HiDPI 2× virtual display and move each remoted window onto it, so the
    // window renders at REAL Retina backing (sharp text) instead of point-res-upscale on a 1× host.
    // Env `AISLOPDESK_VD=1` is an A/B default; `--virtual-display` forces it on.
    var virtualDisplay = false
    var vdPointWidth = 1920   // VD logical (point) size; windows larger than this are resized to fit
    var vdPointHeight = 1080

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
          --fps N            capture + encoder frame-rate cap (default 60; 30 = lighter/less smooth)
          --virtual-display  create a HiDPI 2× virtual display and move each remoted window onto it
                             so it renders at REAL Retina backing (razor-sharp text) instead of a
                             point-resolution upscale. Falls back to 1× if unavailable. (env AISLOPDESK_VD=1)
          --vd-point-size WxH  virtual-display logical size in points (default 1920x1080 → 3840x2160 px)

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
            case "--fps":
                guard let v = next(), let n = Int(v), n >= 1, n <= 120 else { return nil }
                a.fps = n; i += 1
            case "--virtual-display": a.virtualDisplay = true
            case "--vd-point-size":
                // Parse WxH (e.g. 1920x1080).
                guard let v = next() else { return nil }
                let parts = v.lowercased().split(separator: "x")
                guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w >= 320, h >= 240 else { return nil }
                a.vdPointWidth = w; a.vdPointHeight = h; i += 1
            case "-h", "--help": return nil
            default: return nil
            }
            i += 1
        }
        // Env A/B default: AISLOPDESK_VD=1 enables the virtual display without a CLI flag (--virtual-display
        // still forces it on regardless).
        if ProcessInfo.processInfo.environment["AISLOPDESK_VD"] == "1" { a.virtualDisplay = true }
        // The daemon ALWAYS runs the UDP-mux path: it mints a per-channel session from EACH client
        // hello's own windowID (the §2 asymmetry: two panes watch different windows over one shared
        // flow), so no fixed window arg is required (one may still be passed to validate at --list
        // time). Only `--list` and the per-hello mint pick a window now.
        // Two DISTINCT non-zero UDP ports (NWEndpoint.Port rejects 0; the sockets must differ).
        if a.mediaPort == 0 || a.cursorPort == 0 || a.mediaPort == a.cursorPort { return nil }
        return a
    }
}

let argv = CommandLine.arguments
let program = (argv.first as NSString?)?.lastPathComponent ?? "aislopdesk-videohostd"

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

/// System apps whose windows are NOT useful to stream — filtered OUT of the picker list (docs/31).
private let pickerSystemApps: Set<String> = [
    "", "Window Server", "Control Center", "Dock", "Notification Center", "Spotlight", "Wallpaper",
]

/// Maps an `SCWindow` to a picker ``WindowSummary``, or `nil` if it is system chrome / a tiny indicator
/// (StatusIndicator, Cursor, Menubar, Control Center items) that should not appear in the picker.
@Sendable func pickerSummary(_ w: SCWindow) -> WindowSummary? {
    let app = w.owningApplication?.applicationName ?? ""
    let width = Int(w.frame.width.rounded()), height = Int(w.frame.height.rounded())
    guard !pickerSystemApps.contains(app), width >= 80, height >= 80 else { return nil }
    return WindowSummary(
        windowID: w.windowID,
        appName: app,
        title: w.title ?? "",
        width: UInt16(clamping: width),
        height: UInt16(clamping: height)
    )
}

/// Coalesces concurrent `listWindows` answers per channelID (the discovery-path mirror of
/// `VideoMuxSessionRegistry.minting`): a list lane never mints a session, so without this a lossy /
/// fast-retransmitting / looping client would spawn one expensive `SCShareableContent` enumeration PER
/// retransmit, piling up concurrent window-server round-trips. `begin` admits exactly one in-flight
/// answer per channelID; retransmits while it runs are dropped.
final class ListAnswerGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Set<UInt32> = []
    /// Marks `id` in-flight and returns `true`; returns `false` if an answer for `id` is already running.
    func begin(_ id: UInt32) -> Bool { lock.withLock { inFlight.insert(id).inserted } }
    func end(_ id: UInt32) { lock.withLock { _ = inFlight.remove(id) } }
}

/// Answers a client `listWindows` discovery request (docs/31 picker): enumerate the shareable windows,
/// filter to real app windows, cap to a control-datagram-safe count, send a `windowList` back on the
/// request's channelID, then RETIRE that channelID's reply-flow entry (the lane was never admitted as a
/// streaming session, so its `channelMediaConn` mapping would otherwise linger). The `answerGuard` slot
/// is cleared on every exit so a later (post-reply) retransmit can re-answer.
@Sendable func answerWindowList(channelID: UInt32, mux: NWVideoMuxDatagramTransport, answerGuard: ListAnswerGuard) async {
    defer { answerGuard.end(channelID) }
    let summaries = ((try? await shareableWindows()) ?? []).compactMap(pickerSummary).prefix(64)
    let reply = VideoControlMessage.windowList(Array(summaries)).encode()
    mux.send(reply, on: .control, channelID: channelID)
    mux.retire(channelID)
    log("answered listWindows on chan=\(channelID): \(summaries.count) windows (\(reply.count) bytes)")
}

// What is held for the process lifetime; SIGINT drives the orderly stop. Set by the bring-up
// Task, read by the SIGINT Task — different threads, so a lock guards the shared vars (the
// `@unchecked Sendable` would otherwise hide a real data race). The daemon always runs the
// UDP-mux path, so the `registry` + shared `mux` transport are held (N sessions, one per
// channel/window, over the one shared flow).
final class Holder: @unchecked Sendable {
    private let lock = NSLock()
    private var registry: VideoMuxSessionRegistry?
    private var mux: NWVideoMuxDatagramTransport?
    private var virtualDisplay: VirtualDisplay?   // feature #1: held for daemon lifetime (ARC owns the CGVirtualDisplay)
    func setMux(_ r: VideoMuxSessionRegistry, _ m: NWVideoMuxDatagramTransport) { lock.lock(); registry = r; mux = m; lock.unlock() }
    func currentMux() -> (VideoMuxSessionRegistry, NWVideoMuxDatagramTransport)? {
        lock.lock(); defer { lock.unlock() }
        guard let registry, let mux else { return nil }
        return (registry, mux)
    }
    func setVirtualDisplay(_ vd: VirtualDisplay) { lock.lock(); virtualDisplay = vd; lock.unlock() }
    func currentVirtualDisplay() -> VirtualDisplay? { lock.lock(); defer { lock.unlock() }; return virtualDisplay }
}
let holder = Holder()

// A one-shot latch so a second SIGINT during the async shutdown does not spawn a second teardown Task
// that calls `exit(0)` again (two concurrent libc `exit()` calls are UB). R16 HOSTD-1.
final class VideoShutdownLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
let videoShutdownLatch = VideoShutdownLatch()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    guard videoShutdownLatch.tryFire() else { return }   // ignore repeated Ctrl-C during the async drain
    log("SIGINT — shutting down")
    Task {
        if let (registry, mux) = holder.currentMux() {
            await registry.stopAll()
            await mux.stop()
        }
        // Tear the virtual display down AFTER all SCStreams stopped (FB17797423: never release the
        // VD while a stream targets it). ARC dealloc unregisters it from WindowServer.
        if let vd = holder.currentVirtualDisplay() {
            await MainActor.run { vd.destroy() }
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

        // ── WF-7 (#9) LTR capability probe (AISLOPDESK_LTR_PROBE, default OFF) — DIAGNOSTIC ONLY ──────────
        // Runs ONCE here, BEFORE `mux.start` admits any client, on a THROWAWAY VTCompressionSession
        // that never touches a live encoder, and logs a single `LTR-PROBE:` verdict line to stderr (the
        // user reads it on the Mac Studio host). Placing it before the listener guarantees zero
        // HW-encoder concurrency (no live session can exist yet). NSApplication.accessory (above) has
        // already connected the window-server so the HW create/encode won't CGS_REQUIRE_INIT-abort. The
        // probe is bounded by VTCompressionSessionCompleteFrames (a few ms) so it does not meaningfully
        // delay bring-up. When the env var is unset this branch is skipped → the normal path is
        // byte-identical (no live encode/recovery behaviour changes).
        if ProcessInfo.processInfo.environment["AISLOPDESK_LTR_PROBE"] != nil {
            VideoEncoder.runLTRCapabilityProbe(bitrate: args.bitrateMbps * 1_000_000, fps: args.fps, log: log)
        }

        // ── UDP-mux bring-up: ONE shared UDP flow, N sessions (one per channel/window). Each client
        // video pane sends its OWN hello (its own windowID); the daemon mints/looks-up the session by
        // channelID (`VideoMuxSessionRegistry`). The §2 asymmetry — two panes watching DIFFERENT
        // windows on the same host — is served by minting a fresh session per hello's requestedWindowID.
        // A `bye` retires ONLY the closing lane; sibling lanes survive.
        let displayScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
        let effectiveScale = min(args.scale, displayScale)
        let bitrate = args.bitrateMbps * 1_000_000
        let mediaPort = args.mediaPort, cursorPort = args.cursorPort

        // ── Feature #1: optional HiDPI 2× virtual display ────────────────────────────────────────
        // Created ONCE and SHARED across panes (held by `holder` for the daemon lifetime — recreating
        // it mid-session risks the SCK FB17797423 wrong-framebuffer bug). Each remoted window is then
        // moved onto it (per-mint, below) so it renders at REAL Retina 2× backing → razor-sharp text,
        // versus the soft point-resolution upscale on the 1× host display. ANY failure (private API
        // absent, WindowServer refusal, pixel-limit) leaves `vdDisplayID == 0` → capture stays at the
        // existing 1× `effectiveScale`. Never crashes.
        let virtualDisplay = await MainActor.run { VirtualDisplay() }
        holder.setVirtualDisplay(virtualDisplay)
        var vdID: CGDirectDisplayID = 0
        if args.virtualDisplay {
            let geo = VirtualDisplayGeometry(pointWidth: args.vdPointWidth, pointHeight: args.vdPointHeight, scale: 2)
            if let id = await virtualDisplay.create(geo) {
                vdID = id
                log("virtual display ONLINE id=\(id) (\(args.vdPointWidth)x\(args.vdPointHeight)pt @2× → \(geo.pixelWidth)x\(geo.pixelHeight)px) — windows will be moved onto it for sharp capture")
            } else {
                log("virtual display unavailable — falling back to 1× real-display capture")
            }
        }
        let vdDisplayID = vdID   // immutable capture for the mint closure

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
            // ⚠️ FIX #7 (UN-coded, documented limitation — needs two panes naming the SAME windowID):
            // each lane mints its OWN session bound to this `windowID`. Two lanes on one windowID would
            // each AX-resize the SAME real window on a resizeRequest, so concurrent resizes can fight
            // (last write wins, capture/window aspect can briefly disagree). This atypical config is
            // out of scope here; the resize-fight is not coded against (see docs/25).
            let lane = VideoMuxChannelTransport(
                channelID: channelID,
                shared: mux,
                sinkTable: sinkTable,
                onRetire: { id in retireBox.retire(id) }
            )
            // Feature #1: if the VD is up, move THIS window onto it (AX) and capture at 2× real
            // backing. The move returns the ACHIEVED post-move point size (a window larger than the VD
            // is resized down) — thread it in as the authoritative capture/helloAck size so the
            // SCStream + the client's input mapping use the new size, not the stale SCWindow.frame.
            // If the move fails (fixed-size/hung app/AX denied) fall back to 1× for this pane — the
            // window simply stays where it is and still streams. Per-pane so two panes can each be
            // moved onto the shared VD.
            let paneCaptureScale: Double
            var paneSizeOverride: VideoSize? = nil
            if vdDisplayID != 0, let movePid = w.owningApplication?.processID,
               let achieved = await WindowPlacement.moveWindowOntoDisplay(windowID: requestedWindowID, pid: movePid, displayID: vdDisplayID) {
                paneCaptureScale = 2.0
                paneSizeOverride = VideoSize(width: Double(achieved.width), height: Double(achieved.height))
            } else {
                paneCaptureScale = effectiveScale
                if vdDisplayID != 0 { log("mux: could not move window \(requestedWindowID) onto the VD — capturing at 1×") }
            }
            let session = AislopdeskVideoHostSession(window: w, transport: lane, captureScale: paneCaptureScale, captureSizeOverride: paneSizeOverride, bitrate: bitrate, fps: args.fps)
            try await session.start()
            log("mux: minted session chan=\(channelID) window-id=\(requestedWindowID) over shared flow")
            return session
        }
        retireBox.bind { id in Task { await registry.retire(id) } }
        // CONCURRENCY-HOST-1: when the reaper reclaims a dead lane, retire it AND stop its session
        // (capture/encode actually stops — the leak `retire` alone left).
        mux.onReapLane = { id in await registry.retireAndStop(id) }
        holder.setMux(registry, mux)
        // Coalesces concurrent listWindows answers per channelID (so a lossy/looping client can't pile up
        // SCShareableContent enumerations — the discovery mirror of the registry's `minting` dedup).
        let listAnswerGuard = ListAnswerGuard()
        try await mux.start { channelID, channel, data in
            // ORDERING: an ADMITTED lane's sink appends to its session's serial inbound queue
            // SYNCHRONOUSLY, in arrival order, on the transport's serial receive queue — so a mouseUp
            // can never overtake its preceding mouseDown/mouseDrag (InputButtonBalance + down/up pairing
            // are load-bearing; video tolerates reorder, INPUT does not). Spawning a Task per datagram
            // loses arrival order (no FIFO guarantee across Tasks hitting the actor). Only the FIRST
            // hello for a not-yet-minted lane needs the async mint hop.
            if let sink = sinkTable.sink(channelID) {
                sink(channel, data)
            } else if channel == .control, let msg = try? VideoControlMessage.decode(data), case .listWindows = msg {
                // Session-LESS window discovery (docs/31 picker): enumerate + reply, NEVER mint a capture
                // session. The transport already stamped this channelID's reply flow (listWindows
                // bootstraps like a hello), so the reply can be sent back; answerWindowList retires it.
                // Coalesce retransmits: only spawn an enumeration if one isn't already in flight for this id.
                if listAnswerGuard.begin(channelID) {
                    Task { await answerWindowList(channelID: channelID, mux: mux, answerGuard: listAnswerGuard) }
                }
            } else {
                Task { await registry.dispatch(channelID: channelID, channel: channel, data: data) }
            }
        }
        log("UDP-mux: serving SHARED flow on media:\(mediaPort) cursor:\(cursorPort) — N panes, one flow, per-hello windows")
        log("client: open the Aislopdesk app → Remote window; each pane's hello picks its window")
    } catch {
        die("failed to start: \(error)")
    }
}

// Run loop. CGVirtualDisplay needs a live CFRunLoop to stay registered with WindowServer, which
// `dispatchMain()` does NOT provide; `NSApplication.run()` runs the main run loop AND drains the
// main dispatch queue (so the `.main` SIGINT source still fires). Switch to it ONLY when the VD is
// enabled — the default path keeps the proven `dispatchMain()` untouched. NSApp is already
// configured `.accessory` above (no Dock/menu-bar presence).
if args.virtualDisplay {
    NSApplication.shared.run()
} else {
    dispatchMain()
}

#else

FileHandle.standardError.write(Data(
    "aislopdesk-videohostd: the GUI video path host is macOS-only (ScreenCaptureKit + VideoToolbox).\n".utf8))
exit(1)

#endif
