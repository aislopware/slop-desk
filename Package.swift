// swift-tools-version:6.0
import PackageDescription

// Rwork — terminal-first remote-coding for Apple platforms.
//
// Headless-first layout (see docs/19-implementation-plan.md): the PATH 1 byte
// pipeline (host PTY <-> TCP/TCP_NODELAY <-> client, with replay-buffer reconnect)
// is the de-risked core and builds + tests with NO GUI and NO libghostty.
//
// Swift 6 tools default to the Swift 6 language mode (strict concurrency).
let package = Package(
    name: "Rwork",
    platforms: [
        // `.v26` requires _PackageDescription 6.2; this manifest is swift-tools-version:6.0,
        // so the string form is used to express the macOS 26 / iOS 26 floor.
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "RworkProtocol", targets: ["RworkProtocol"]),
        .library(name: "RworkTransport", targets: ["RworkTransport"]),
        .library(name: "RworkHost", targets: ["RworkHost"]),
        .library(name: "RworkClient", targets: ["RworkClient"]),
        .library(name: "RworkTerminal", targets: ["RworkTerminal"]),
        .library(name: "RworkTTY", targets: ["RworkTTY"]),
        .library(name: "RworkInspector", targets: ["RworkInspector"]),
        .library(name: "RworkClaudeCode", targets: ["RworkClaudeCode"]),
        .library(name: "RworkClientUI", targets: ["RworkClientUI"]),
        // PATH 2 (GUI video path, Phase 4 / WF-9).
        .library(name: "RworkVideoProtocol", targets: ["RworkVideoProtocol"]),
        .library(name: "RworkVideoHost", targets: ["RworkVideoHost"]),
        .library(name: "RworkVideoClient", targets: ["RworkVideoClient"]),
    ],
    targets: [
        // MARK: Libraries

        // Pure-Swift wire format: framing, MessageType, seq(Int64), Hello/Ack.
        // ZERO platform dependency (no Network/Darwin) so it builds for macOS + iOS
        // and is unit-testable in isolation.
        .target(name: "RworkProtocol"),

        // NWConnection + TCP_NODELAY, dual data/control channel, ET-style replay
        // buffer, reconnect handshake. (Implemented in WF-2.)
        .target(name: "RworkTransport", dependencies: ["RworkProtocol"]),

        // macOS host: PTY (openpty + posix_spawn createSession), session mgr,
        // no-buffer PTY<->transport relay, TIOCSWINSZ resize. (Implemented in WF-3.)
        // Also hosts the inspector's second-connection server (InspectorServer):
        // RworkHost depends on RworkInspector for the wire types + replay log. This is
        // acyclic — RworkInspector depends ONLY on RworkProtocol, never on RworkHost.
        .target(name: "RworkHost", dependencies: ["RworkTransport", "RworkProtocol", "RworkInspector"]),

        // Shared client: connection mgr, reconnect, input encoding. (WF-4.)
        .target(name: "RworkClient", dependencies: ["RworkTransport", "RworkProtocol"]),

        // TerminalSurface protocol + HeadlessTerminalSurface. The libghostty-backed
        // GhosttySurface lives in the GUI app target (WF-5) and conforms to the same
        // protocol.
        .target(name: "RworkTerminal", dependencies: ["RworkProtocol"]),

        // Local-terminal raw-mode + termios save/restore + TIOCGWINSZ/TIOCSWINSZ helpers
        // for the interactive CLI. Split into a library so the save/restore + SIGWINCH
        // mapping logic is unit-testable (the executable target itself is not importable).
        .target(name: "RworkTTY"),

        // Read-only structured inspector (WF-6). Tails Claude Code's JSONL transcript
        // (+ subagent files + hooks) on the host, models typed `InspectorEvent`s, and
        // streams them over a SECOND length-prefixed channel (NWConnection #2) to a
        // SwiftUI read-only client. INDEPENDENT of the terminal byte pipeline — it
        // reuses only RworkProtocol's framing *style*, never the terminal WireMessage.
        // Read-only: it observes the transcript, it never drives the agent.
        .target(name: "RworkInspector", dependencies: ["RworkProtocol"]),

        // Cross-platform Claude Code integration LOGIC (WF-7): the terminal-mode sniffer
        // (DECSET/DECRST 1049 + OSC 133, robust to sequences split across chunk
        // boundaries), the input dedup ring (input-box B1 echo suppression), and the
        // input-box state machine (A shell / B1 TUI-compose). Pure Swift, no platform
        // dependency beyond Foundation — builds for macOS + iOS, fixture-tested. The host
        // launch env + auth resolution live in RworkHost (macOS, the WF-7 seam).
        .target(name: "RworkClaudeCode", dependencies: ["RworkProtocol"]),

        // Cross-platform SwiftUI client UI (WF-8): the views + @MainActor @Observable
        // view-models that bind the existing modules — RworkClient (byte pipeline +
        // reconnect), RworkInspector (read-only structured panel), RworkClaudeCode
        // (input-box A/B1 affordance), RworkTerminal (the renderer SEAM) — into a
        // working client.
        //
        // The terminal pixels are a SEAM (`TerminalRenderingView`): production =
        // `GhosttyTerminalView` (Metal-hosted `GhosttySurface`, the gated binding under
        // ThirdParty/ghostty/integration, compiled only inside the Xcode app target with
        // the xcframework); the no-framework case shows a labelled BUILD-STATUS
        // placeholder — NOT a substitute VT renderer (libghostty-only policy, DECISIONS).
        //
        // The iOS UIKit native-feel table-stakes (doc 17 §2.5) live here too: all
        // timing/threshold/mapping LOGIC is in pure, `#if`-unguarded types
        // (`KeyRepeater`/`FloatingCursorMapping`/`KeyboardAccessoryDecision`/`InputRouting`)
        // unit-tested on macOS; the UIKit view wrappers that drive them are `#if os(iOS)`
        // and are typechecked via an iOS-triple build.
        //
        // Builds for macOS 26 + iOS 26 (the deployment floor — no fallback below that).
        .target(
            name: "RworkClientUI",
            dependencies: ["RworkClient", "RworkTransport", "RworkInspector", "RworkClaudeCode", "RworkTerminal"]
        ),

        // MARK: PATH 2 — GUI video path (Phase 4 / WF-9)

        // Cross-platform PURE wire format for the GUI video path: UDP frame
        // packetizer/reassembler (with loss detect + recovery signalling), FEC
        // (XOR parity, swappable for Reed-Solomon), cursor side-channel codec,
        // window-geometry codec, coordinate-mapping math (multi-monitor Cocoa-flip +
        // Retina), and the client->host input-event codec. ZERO platform dependency
        // (no ScreenCaptureKit/VideoToolbox/AppKit) so it builds macOS + iOS and is
        // fully unit-testable in isolation — same discipline as RworkProtocol.
        .target(name: "RworkVideoProtocol"),

        // macOS-only host capture + encode + input injection. USES
        // ScreenCaptureKit / VideoToolbox / CoreGraphics / AppKit. COMPILED + code-
        // reviewed, NEVER executed in tests: SCStream capture AND VTCompressionSession
        // HW encode HANG without a window-server + Screen-Recording TCC session, which
        // a headless test/CI run does not have (docs/research/spikes/vtbench/RESULTS.md).
        // The encoder/capture configs match the MEASURED spike configs exactly.
        .target(
            name: "RworkVideoHost",
            dependencies: ["RworkVideoProtocol"],
            // macOS-only: SCStream + VTCompressionSession + AX/CGEvent are macOS APIs.
            // (RworkVideoProtocol stays cross-platform; only this host layer is gated.)
            swiftSettings: []
        ),

        // macOS + iOS client decode + Metal render + client-side cursor. USES
        // VideoToolbox (decode) / Metal / CoreVideo / QuartzCore. COMPILED + reviewed;
        // decode is MEASURED-safe (~0.9-1.1ms synchronous) but to honour the hang-
        // safety rule NO VTDecompressionSession is instantiated in tests either.
        .target(name: "RworkVideoClient", dependencies: ["RworkVideoProtocol"]),

        // MARK: Executables

        // Headless host daemon (PTY + transport). Sources under Sources/rwork-hostd.
        .executableTarget(name: "rwork-hostd", dependencies: ["RworkHost"]),

        // Interactive remote terminal client. Sources under Sources/rwork-client.
        .executableTarget(name: "rwork-client", dependencies: ["RworkClient", "RworkTerminal", "RworkTTY"]),

        // GUI video path (PATH 2) host daemon: enumerate shareable windows, bind the UDP
        // media+cursor sockets, run `RworkVideoHostSession`. macOS-only at runtime
        // (ScreenCaptureKit/VideoToolbox); the `main.swift` is `#if os(macOS)`-gated with a
        // clear non-macOS error. COMPILED + reviewed; live behaviour is GUI+TCC-gated.
        .executableTarget(name: "rwork-videohostd", dependencies: ["RworkVideoHost", "RworkVideoProtocol"]),

        // MARK: Tests
        .testTarget(name: "RworkProtocolTests", dependencies: ["RworkProtocol"]),
        .testTarget(name: "RworkTransportTests", dependencies: ["RworkTransport"]),
        .testTarget(name: "RworkHostTests", dependencies: ["RworkHost", "RworkInspector"]),
        // RworkClientTests exercises the REAL PATH 1 e2e: a HostServer (RworkHost) +
        // RworkClient over loopback, so it depends on RworkHost + RworkTTY too.
        .testTarget(name: "RworkClientTests", dependencies: ["RworkClient", "RworkHost", "RworkTransport", "RworkTerminal", "RworkTTY"]),
        // Fixture-based tests for the inspector: JSONL parsing, tool-card pairing,
        // subagent tree, the append-follow tailer, transport round-trip, hook ingest.
        // The `Fixtures/` tree is read off disk via `#filePath` (see Fixtures.swift),
        // so it is excluded from the build rather than bundled as a resource.
        .testTarget(
            name: "RworkInspectorTests",
            dependencies: ["RworkInspector", "RworkProtocol"],
            exclude: ["Fixtures"]
        ),
        // WF-7 logic: env/auth (RworkHost) + mode sniffer / dedup ring / input-box model
        // (RworkClaudeCode). Byte-sequence + fixture based; the sniffer tests feed the
        // SAME stream at adversarial split boundaries and assert identical results.
        .testTarget(
            name: "RworkClaudeCodeTests",
            dependencies: ["RworkClaudeCode", "RworkHost", "RworkProtocol"]
        ),
        // WF-8 client UI: the iOS table-stakes PURE logic (key-repeat cadence via an
        // injected scheduler, floating-cursor delta→arrow mapping, accessory-bar show/hide
        // decision, IME-vs-key routing) + the view-model state transitions on RworkClient
        // events (driven by an in-process stub client over loopback). Deterministic, runs
        // on macOS — the UIKit view wrappers are iOS-gated and typechecked via the iOS
        // triple build, not here.
        .testTarget(
            name: "RworkClientUITests",
            dependencies: ["RworkClientUI", "RworkClient", "RworkTransport", "RworkHost", "RworkInspector", "RworkClaudeCode", "RworkTerminal"]
        ),
        // WF-9 GUI video path: ONLY the PURE RworkVideoProtocol is unit-tested
        // (packetize/reassemble incl. fragment-loss → drop + recovery, FEC real
        // single-loss recovery, cursor codec round-trip + <64B size, coordinate
        // mapping single/multi-monitor/Retina, window-geometry codec, input-event
        // codec). NO VideoToolbox / ScreenCaptureKit is instantiated anywhere here —
        // the host/client video code HANGS without a window-server + TCC session, so
        // it is COMPILED (swift build) + code-reviewed, never executed in a test.
        .testTarget(name: "RworkVideoProtocolTests", dependencies: ["RworkVideoProtocol"]),
        // WF-9 host orchestrator: ONLY the PURE host-session logic is unit-tested —
        // the session state machine (hello/helloAck/bye transitions + strict version
        // check), the input-datagram routing decisions (inject/drop/ignore + raise
        // latch), and the send-scheduler channel/packet ordering — all against an
        // in-memory `VideoDatagramTransport` fake. NO SCStream / VTCompressionSession /
        // CGEvent / live UDP socket is instantiated here (the hang-safety rule): the
        // capture/encode/inject components are COMPILED + code-reviewed only.
        .testTarget(name: "RworkVideoHostTests", dependencies: ["RworkVideoHost", "RworkVideoProtocol"]),
        // WF-9 client orchestrator: ONLY the PURE client-session logic is unit-tested —
        // the client state machine (hello/helloAck/bye transitions + accept/reject + the
        // idempotent duplicate ack), the videoScale math (layer/decoded ratio + cursor
        // placement), the received-datagram routing decisions (control/video/geometry/
        // ignore/drop), the input-event normalisation (view-space → clamped 0..1), the
        // HEVC parameter-set extraction (pure NAL walk), and the frame-pacer cap throttle
        // — all against an in-memory `VideoClientTransport` fake. NO VTDecompressionSession
        // / Metal / CVDisplayLink / CADisplayLink / live UDP socket is instantiated here
        // (the hang-safety rule): the decode/render/display-link components are COMPILED +
        // code-reviewed only.
        .testTarget(name: "RworkVideoClientTests", dependencies: ["RworkVideoClient", "RworkVideoProtocol"]),
    ]
)
