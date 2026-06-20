// swift-tools-version:6.2
import Foundation
import PackageDescription

// Absolute path to this package's root, computed from the manifest's own location at
// evaluation time. Used to make the Rust staticlib search path (`-L`) absolute so it resolves
// in BOTH `swift build` (CWD = package root) AND an Xcode app build (CWD = DerivedData), where
// a relative `-Lrust/target/release` is not found. Portable: recomputes if the repo moves.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Aislopdesk — terminal-first remote-coding for Apple platforms.
//
// Headless-first layout (see docs/19-implementation-plan.md): the PATH 1 byte
// pipeline (host PTY <-> TCP/TCP_NODELAY <-> client, with replay-buffer reconnect)
// is the de-risked core and builds + tests with NO GUI and NO libghostty.
//
// Swift 6 tools default to the Swift 6 language mode (strict concurrency).
let package = Package(
    name: "Aislopdesk",
    platforms: [
        // swift-tools-version:6.2 → PackageDescription 6.2, so the `.v26` enum is available
        // for the macOS 26 / iOS 26 floor (previously expressed via the string form under 6.0).
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "AislopdeskProtocol", targets: ["AislopdeskProtocol"]),
        .library(name: "AislopdeskTransport", targets: ["AislopdeskTransport"]),
        .library(name: "AislopdeskHost", targets: ["AislopdeskHost"]),
        .library(name: "AislopdeskClient", targets: ["AislopdeskClient"]),
        .library(name: "AislopdeskTerminal", targets: ["AislopdeskTerminal"]),
        .library(name: "AislopdeskTTY", targets: ["AislopdeskTTY"]),
        .library(name: "AislopdeskInspector", targets: ["AislopdeskInspector"]),
        .library(name: "AislopdeskClaudeCode", targets: ["AislopdeskClaudeCode"]),
        .library(name: "AislopdeskAgentDetect", targets: ["AislopdeskAgentDetect"]),
        .library(name: "AislopdeskClientUI", targets: ["AislopdeskClientUI"]),
        // PATH 2 (GUI video path, Phase 4 / WF-9).
        .library(name: "AislopdeskVideoProtocol", targets: ["AislopdeskVideoProtocol"]),
        .library(name: "AislopdeskVideoHost", targets: ["AislopdeskVideoHost"]),
        .library(name: "AislopdeskVideoClient", targets: ["AislopdeskVideoClient"]),
    ],
    targets: [
        // MARK: Libraries

        // Native SIMD kernels (the all-Swift migration's replacement for the Rust FFI NEON).
        // A tiny C target SwiftPM COMPILES FROM SOURCE every build — no cbindgen, no marshalling,
        // no prebuilt staticlib, no build-ordering. Holds the two genuine-SIMD kernels: the
        // GF(2^8) split-table region multiply (`vqtbl1q_u8`) and the xxHash64 NV12 frame-hash
        // fold (synthesized `vmull_u32` u64 lane multiply), each guarded `#if __aarch64__` with a
        // scalar fallback so x86_64 CI/sim builds stay green. Swift links it directly via the
        // `include/` modulemap; byte-identical to the scalar reference (pinned by a differential
        // test). This is the ONLY remaining C/unsafe surface after the Rust core is reabsorbed.
        .target(
            name: "CAislopdeskSIMD",
            path: "Sources/CAislopdeskSIMD",
            cSettings: [.unsafeFlags(["-O3"])],
        ),

        // Pure-Swift wire format: framing, MessageType, seq(Int64), Hello/Ack.
        // ZERO platform dependency (no Network/Darwin) so it builds for macOS + iOS
        // and is unit-testable in isolation. Native Swift codecs (single source of truth).
        .target(name: "AislopdeskProtocol"),

        // NWConnection + TCP_NODELAY, dual data/control channel, ET-style replay
        // buffer, reconnect handshake. (Implemented in WF-2.)
        .target(name: "AislopdeskTransport", dependencies: ["AislopdeskProtocol"]),

        // macOS host: PTY (openpty + posix_spawn createSession), session mgr,
        // no-buffer PTY<->transport relay, TIOCSWINSZ resize. (Implemented in WF-3.)
        // Also hosts the inspector's second-connection server (InspectorServer):
        // AislopdeskHost depends on AislopdeskInspector for the wire types + replay log. This is
        // acyclic — AislopdeskInspector depends ONLY on AislopdeskProtocol, never on AislopdeskHost.
        //
        // W10 adds AislopdeskAgentDetect: the host folds foreground-process / Claude-hook signals
        // through the pure `ClaudeStatusMachine` to decide the type-26/27 CONTROL emissions. The
        // edge stays acyclic — AislopdeskAgentDetect depends on NOTHING (it physically cannot
        // import AislopdeskHost), and AislopdeskInspector still depends only on AislopdeskProtocol.
        // W12: AislopdeskHost also depends on AislopdeskVideoProtocol for `EnvConfig` — the host's
        // agent-detection gates (`AISLOPDESK_AGENT_DETECT`/`_HOOKS`) resolve through the settings overlay
        // so a GUI toggle reaches them (it loads the same `video-prefs.json` sidecar). The edge is
        // acyclic — AislopdeskVideoProtocol is the cross-platform PURE wire/settings leaf (deps only
        // CAislopdeskSIMD) and never imports any host module.
        .target(
            name: "AislopdeskHost",
            dependencies: [
                "AislopdeskTransport", "AislopdeskProtocol", "AislopdeskInspector",
                "AislopdeskAgentDetect", "AislopdeskVideoProtocol",
            ],
        ),

        // Shared client: connection mgr, reconnect, input encoding. (WF-4.)
        .target(name: "AislopdeskClient", dependencies: ["AislopdeskTransport", "AislopdeskProtocol"]),

        // TerminalSurface protocol + HeadlessTerminalSurface. The libghostty-backed
        // GhosttySurface lives in the GUI app target (WF-5) and conforms to the same
        // protocol.
        .target(name: "AislopdeskTerminal", dependencies: ["AislopdeskProtocol"]),

        // Local-terminal raw-mode + termios save/restore + TIOCGWINSZ/TIOCSWINSZ helpers
        // for the interactive CLI. Split into a library so the save/restore + SIGWINCH
        // mapping logic is unit-testable (the executable target itself is not importable).
        .target(name: "AislopdeskTTY"),

        // Read-only structured inspector (WF-6). Tails Claude Code's JSONL transcript
        // (+ subagent files + hooks) on the host, models typed `InspectorEvent`s, and
        // streams them over a SECOND length-prefixed channel (NWConnection #2) to a
        // SwiftUI read-only client. INDEPENDENT of the terminal byte pipeline — it
        // reuses only AislopdeskProtocol's framing *style*, never the terminal WireMessage.
        // Read-only: it observes the transcript, it never drives the agent.
        .target(name: "AislopdeskInspector", dependencies: ["AislopdeskProtocol"]),

        // Cross-platform Claude Code integration LOGIC (WF-7): the terminal-mode sniffer
        // (DECSET/DECRST 1049 + OSC 133, robust to sequences split across chunk
        // boundaries), the input dedup ring (input-box B1 echo suppression), and the
        // input-box state machine (A shell / B1 TUI-compose). Pure Swift, no platform
        // dependency beyond Foundation — builds for macOS + iOS, fixture-tested. The host
        // launch env + auth resolution live in AislopdeskHost (macOS, the WF-7 seam).
        .target(name: "AislopdeskClaudeCode", dependencies: ["AislopdeskProtocol"]),

        // Pure, headless Claude-Code DETECTION CORE (W7): the per-pane status enum
        // (`ClaudeStatus`), the deterministic, clock-injected state machine
        // (`ClaudeStatusMachine` — `Date()` is physically unreachable; time arrives as
        // a `TimeInterval` parameter), and the Herdr-style no-hooks fallback
        // (`ClaudeManifestMatcher`) that reads a terminal pane's title/screen for
        // recognizable Claude TUI cues. Foundation-only — it depends on NOTHING
        // GUI/transport/video so it physically cannot import them; the adapter that
        // maps `AislopdeskInspector.HookPayload` → `ClaudeSignal` is W8/W10, not here.
        // Validate-then-drop on every foreign string; no force-unwrap.
        .target(name: "AislopdeskAgentDetect"),

        // Cross-platform SwiftUI client UI (WF-8): the views + @MainActor @Observable
        // view-models that bind the existing modules — AislopdeskClient (byte pipeline +
        // reconnect), AislopdeskInspector (read-only structured panel), AislopdeskClaudeCode
        // (input-box A/B1 affordance), AislopdeskTerminal (the renderer SEAM) — into a
        // working client.
        //
        // The terminal pixels are a SEAM (`TerminalRenderingView`): production =
        // `GhosttyTerminalView` (Metal-hosted `GhosttySurface`, the gated binding under
        // ThirdParty/ghostty/integration, compiled only inside the Xcode app target with
        // the xcframework); the no-framework case shows a labelled BUILD-STATUS
        // placeholder — build-status telemetry, not a terminal (libghostty is the renderer).
        //
        // The iOS UIKit native-feel table-stakes (doc 17 §2.5) live here too: all
        // timing/threshold/mapping LOGIC is in pure, `#if`-unguarded types
        // (`KeyRepeater`/`FloatingCursorMapping`/`KeyboardAccessoryDecision`/`InputRouting`)
        // unit-tested on macOS; the UIKit view wrappers that drive them are `#if os(iOS)`
        // and are typechecked via an iOS-triple build.
        //
        // Builds for macOS 26 + iOS 26 (the deployment floor — no fallback below that).
        .target(
            name: "AislopdeskClientUI",
            dependencies: [
                "AislopdeskClient",
                "AislopdeskTransport",
                "AislopdeskInspector",
                "AislopdeskClaudeCode",
                // W5: the pure headless Claude-status enum (`ClaudeStatus`) the sidebar/chrome dots read.
                // AgentDetect depends on nothing GUI/transport/video, so this never widens the GUI graph.
                "AislopdeskAgentDetect",
                "AislopdeskTerminal",
                // W13: the W12 settings MODELS + the pure config bridges (`VideoPreferences`,
                // `TerminalPreferences`, `AgentPreferences`, `KeybindingPreferences`, `EnvConfig`,
                // `EnvBridge`, `TerminalConfigBuilder`) the `PreferencesStore` + Settings panels bind to.
                // AislopdeskVideoProtocol is the cross-platform PURE wire/settings target (no
                // ScreenCaptureKit/VideoToolbox/AppKit), so this does NOT widen the GUI graph with HW deps.
                "AislopdeskVideoProtocol",
            ],
        ),

        // MARK: PATH 2 — GUI video path (Phase 4 / WF-9)

        // Cross-platform PURE wire format for the GUI video path: UDP frame
        // packetizer/reassembler (with loss detect + recovery signalling), FEC
        // (XOR parity, swappable for Reed-Solomon), cursor side-channel codec,
        // window-geometry codec, coordinate-mapping math (multi-monitor Cocoa-flip +
        // Retina), and the client->host input-event codec. ZERO platform dependency
        // (no ScreenCaptureKit/VideoToolbox/AppKit) so it builds macOS + iOS and is
        // fully unit-testable in isolation — same discipline as AislopdeskProtocol.
        .target(name: "AislopdeskVideoProtocol", dependencies: ["CAislopdeskSIMD"]),

        // macOS-only host capture + encode + input injection. USES
        // ScreenCaptureKit / VideoToolbox / CoreGraphics / AppKit. COMPILED + code-
        // reviewed, NEVER executed in tests: SCStream capture AND VTCompressionSession
        // HW encode HANG without a window-server + Screen-Recording TCC session, which
        // a headless test/CI run does not have (docs/research/spikes/vtbench/RESULTS.md).
        // The encoder/capture configs match the MEASURED spike configs exactly.
        // Private CoreGraphics `CGVirtualDisplay*` headers (clang module). Lets the host create a
        // HiDPI 2× virtual display so a remoted window renders at real Retina backing (sharp text)
        // instead of point-resolution upscale. macOS-only (CoreGraphics); see the header for the
        // run-loop / main-thread / retain contract. The classes link from the PUBLIC CoreGraphics
        // framework — only the headers are private (no dlopen, no entitlement).
        .target(
            name: "CAislopdeskVirtualDisplay",
            path: "Sources/CAislopdeskVirtualDisplay",
            publicHeadersPath: "include",
        ),

        .target(
            name: "AislopdeskVideoHost",
            dependencies: ["AislopdeskVideoProtocol", "CAislopdeskVirtualDisplay"],
            // macOS-only: SCStream + VTCompressionSession + AX/CGEvent are macOS APIs.
            // (AislopdeskVideoProtocol stays cross-platform; only this host layer is gated.)
            swiftSettings: [],
        ),

        // macOS + iOS client decode + Metal render + client-side cursor. USES
        // VideoToolbox (decode) / Metal / CoreVideo / QuartzCore. COMPILED + reviewed;
        // decode is MEASURED-safe (~0.9-1.1ms synchronous) but to honour the hang-
        // safety rule NO VTDecompressionSession is instantiated in tests either.
        .target(name: "AislopdeskVideoClient", dependencies: ["AislopdeskVideoProtocol"]),

        // MARK: Executables

        // Headless host daemon (PTY + transport). Sources under Sources/aislopdesk-hostd.
        .executableTarget(name: "aislopdesk-hostd", dependencies: ["AislopdeskHost"]),

        // Interactive remote terminal client. Sources under Sources/aislopdesk-client.
        .executableTarget(
            name: "aislopdesk-client",
            dependencies: ["AislopdeskClient", "AislopdeskTransport", "AislopdeskTerminal", "AislopdeskTTY"],
        ),

        // GUI video path (PATH 2) host daemon: enumerate shareable windows, bind the UDP
        // media+cursor sockets, run `AislopdeskVideoHostSession`. macOS-only at runtime
        // (ScreenCaptureKit/VideoToolbox); the `main.swift` is `#if os(macOS)`-gated with a
        // clear non-macOS error. COMPILED + reviewed; live behaviour is GUI+TCC-gated.
        .executableTarget(
            name: "aislopdesk-videohostd",
            dependencies: ["AislopdeskVideoHost", "AislopdeskVideoProtocol"],
        ),

        // Headless closed-loop validation harness: synthetic CVPixelBuffer -> REAL HW
        // VideoEncoder -> VideoPacketizer (FEC tier + isLTR + hostSendTs) -> deterministic
        // fragment loss -> FrameReassembler (FEC recovery) -> REAL HW VideoDecoder, plus the
        // pure WF-1..WF-8 controllers driven on synthetic telemetry. Runs from a normal
        // (non-GUI, non-TCC) executable; its stdout IS the validation evidence. macOS-only.
        .executableTarget(
            name: "aislopdesk-loopback-validate",
            dependencies: ["AislopdeskVideoHost", "AislopdeskVideoClient", "AislopdeskVideoProtocol"],
        ),

        // Frame-cadence watcher: SCK desktopIndependentWindow capture of ANY window (foreground
        // or background) that logs per-frame arrival timestamps + content checksums and prints a
        // stall histogram — the objective frame-level smoothness instrument (works on Aislopdesk AND
        // Parsec windows alike). GUI+TCC-gated at runtime; no video file is written.
        .executableTarget(name: "aislopdesk-framewatch"),

        // Capture-mode probe: drives the REAL `WindowCapturer` (the production capture path,
        // including the `AISLOPDESK_DISPLAY_CAPTURE` mode seam) against one window and dumps
        // delivered frames as PNGs — the host-side instrument for geometric capture artifacts
        // (the Chrome-tooltip 1px crop shift) where a client-side screenshot would be polluted
        // by pane scaling. GUI+TCC-gated at runtime.
        .executableTarget(name: "aislopdesk-capture-probe", dependencies: ["AislopdeskVideoHost"]),

        // Fake video client: a minimal UDP `hello` trigger that makes the real host start capturing a
        // window, so the FULL host pipeline (capture→encode→FEC→send) runs on one machine without the
        // GUI client. Diagnostic-only (overnight capture-cadence root-cause work). GUI+TCC at runtime.
        .executableTarget(name: "aislopdesk-fake-client", dependencies: ["AislopdeskVideoProtocol"]),

        // Micro-benchmark for the Swift-level hot paths (frame hash, GF region multiply, RS FEC).
        .executableTarget(name: "aislopdesk-bench", dependencies: ["AislopdeskVideoProtocol"]),

        // Golden-vector dumper: emits the golden reference corpus for the Rust core's
        // parity test — a deterministic JSON corpus from the AislopdeskVideoProtocol codecs
        // + the pure realtime controllers (public API only) that the Rust `aislopdesk-core`
        // crate asserts byte-/bit-identical against in its `golden_parity` test. Pure value
        // types only — constructs NO SCStream / encoder, so it touches no GUI/TCC:
        // `swift run aislopdesk-corevectors > rust/aislopdesk-core/tests/vectors/golden_vectors.json`.
        // IMPORTANT: run with no `AISLOPDESK_*` env set so the controllers resolve their
        // default tunables (the Rust core pins those defaults as compile-time consts).
        .executableTarget(
            name: "aislopdesk-corevectors",
            dependencies: [
                "AislopdeskProtocol",
                "AislopdeskVideoProtocol",
                "AislopdeskVideoHost",
                "AislopdeskVideoClient",
            ],
        ),

        // MARK: Tests

        .testTarget(name: "AislopdeskProtocolTests", dependencies: ["AislopdeskProtocol"]),
        // W7: the pure detection core — state-machine transitions (incl. injected-clock
        // timeouts, idempotent/out-of-order signals), the conservative manifest matcher,
        // and the rollup most-urgent order. No GUI/socket/PTY — signals are fed directly.
        .testTarget(name: "AislopdeskAgentDetectTests", dependencies: ["AislopdeskAgentDetect"]),
        .testTarget(name: "AislopdeskTransportTests", dependencies: ["AislopdeskTransport"]),
        .testTarget(
            name: "AislopdeskHostTests",
            // W12: AislopdeskVideoProtocol for `EnvConfig` — the agent-gate reaches-consumer test sets
            // `EnvConfig.overlay` and asserts the default-arg path (overlay → env) reaches the gate.
            dependencies: ["AislopdeskHost", "AislopdeskInspector", "AislopdeskAgentDetect", "AislopdeskVideoProtocol"],
        ),
        // AislopdeskClientTests exercises the REAL PATH 1 e2e: a HostServer (AislopdeskHost) +
        // AislopdeskClient over loopback, so it depends on AislopdeskHost + AislopdeskTTY too.
        .testTarget(
            name: "AislopdeskClientTests",
            dependencies: [
                "AislopdeskClient",
                "AislopdeskHost",
                "AislopdeskTransport",
                "AislopdeskTerminal",
                "AislopdeskTTY",
            ],
        ),
        // Fixture-based tests for the inspector: JSONL parsing, tool-card pairing,
        // subagent tree, the append-follow tailer, transport round-trip, hook ingest.
        // The `Fixtures/` tree is read off disk via `#filePath` (see Fixtures.swift),
        // so it is excluded from the build rather than bundled as a resource.
        .testTarget(
            name: "AislopdeskInspectorTests",
            dependencies: ["AislopdeskInspector", "AislopdeskProtocol"],
            exclude: ["Fixtures"],
        ),
        // WF-7 logic: env/auth (AislopdeskHost) + mode sniffer / dedup ring / input-box model
        // (AislopdeskClaudeCode). Byte-sequence + fixture based; the sniffer tests feed the
        // SAME stream at adversarial split boundaries and assert identical results.
        .testTarget(
            name: "AislopdeskClaudeCodeTests",
            dependencies: ["AislopdeskClaudeCode", "AislopdeskHost", "AislopdeskProtocol"],
        ),
        // WF-8 client UI: the iOS table-stakes PURE logic (key-repeat cadence via an
        // injected scheduler, floating-cursor delta→arrow mapping, accessory-bar show/hide
        // decision, IME-vs-key routing) + the view-model state transitions on AislopdeskClient
        // events (driven by an in-process stub client over loopback). Deterministic, runs
        // on macOS — the UIKit view wrappers are iOS-gated and typechecked via the iOS
        // triple build, not here.
        .testTarget(
            name: "AislopdeskClientUITests",
            dependencies: [
                "AislopdeskClientUI",
                "AislopdeskClient",
                "AislopdeskTransport",
                "AislopdeskHost",
                "AislopdeskInspector",
                "AislopdeskClaudeCode",
                "AislopdeskAgentDetect",
                "AislopdeskTerminal",
            ],
        ),
        // WF-9 GUI video path: ONLY the PURE AislopdeskVideoProtocol is unit-tested
        // (packetize/reassemble incl. fragment-loss → drop + recovery, FEC real
        // single-loss recovery, cursor codec round-trip + <64B size, coordinate
        // mapping single/multi-monitor/Retina, window-geometry codec, input-event
        // codec). NO VideoToolbox / ScreenCaptureKit is instantiated anywhere here —
        // the host/client video code HANGS without a window-server + TCC session, so
        // it is COMPILED (swift build) + code-reviewed, never executed in a test.
        .testTarget(name: "AislopdeskVideoProtocolTests", dependencies: ["AislopdeskVideoProtocol"]),
        // WF-9 host orchestrator: ONLY the PURE host-session logic is unit-tested —
        // the session state machine (hello/helloAck/bye transitions + strict version
        // check), the input-datagram routing decisions (inject/drop/ignore + raise
        // latch), and the send-scheduler channel/packet ordering — all against an
        // in-memory `VideoDatagramTransport` fake. NO SCStream / VTCompressionSession /
        // CGEvent / live UDP socket is instantiated here (the hang-safety rule): the
        // capture/encode/inject components are COMPILED + code-reviewed only.
        .testTarget(name: "AislopdeskVideoHostTests", dependencies: ["AislopdeskVideoHost", "AislopdeskVideoProtocol"]),
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
        .testTarget(
            name: "AislopdeskVideoClientTests",
            dependencies: ["AislopdeskVideoClient", "AislopdeskVideoProtocol"],
        ),
    ],
)
