// swift-tools-version:6.2
import Foundation
import PackageDescription

// Absolute package-root path from the manifest's own location. Makes the Rust staticlib `-L`
// search path absolute so it resolves in BOTH `swift build` (CWD = package root) AND an Xcode
// app build (CWD = DerivedData), where relative `-Lrust/target/release` is not found. Recomputes
// if the repo moves.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// SlopDesk — terminal-first remote-coding for Apple platforms.
//
// Headless-first (docs/19-implementation-plan.md): the PATH 1 byte pipeline (host PTY <->
// TCP/TCP_NODELAY <-> client, replay-buffer reconnect) is the de-risked core; builds + tests
// with NO GUI, NO libghostty.
//
// Swift 6 tools default to Swift 6 language mode (strict concurrency).
let package = Package(
    name: "SlopDesk",
    platforms: [
        // PackageDescription 6.2 makes the `.v26` enum available for the macOS 26 / iOS 26 floor.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "SlopDeskProtocol", targets: ["SlopDeskProtocol"]),
        .library(name: "SlopDeskTransport", targets: ["SlopDeskTransport"]),
        .library(name: "SlopDeskHost", targets: ["SlopDeskHost"]),
        .library(name: "SlopDeskClient", targets: ["SlopDeskClient"]),
        .library(name: "SlopDeskTerminal", targets: ["SlopDeskTerminal"]),
        .library(name: "SlopDeskTTY", targets: ["SlopDeskTTY"]),
        .library(name: "SlopDeskInspector", targets: ["SlopDeskInspector"]),
        .library(name: "SlopDeskClaudeCode", targets: ["SlopDeskClaudeCode"]),
        .library(name: "SlopDeskAgentDetect", targets: ["SlopDeskAgentDetect"]),
        .library(name: "SlopDeskWorkspaceCore", targets: ["SlopDeskWorkspaceCore"]),
        // REBUILD-V2: thin SwiftUI layer over SlopDeskWorkspaceCore, STOCK SwiftUI + system semantic
        // colours/fonts — no custom token target (the Warp-clone `SlopDeskDesignSystem` is deleted).
        .library(name: "SlopDeskClientUI", targets: ["SlopDeskClientUI"]),
        // PATH 2 (GUI video path, Phase 4 / WF-9).
        .library(name: "SlopDeskVideoProtocol", targets: ["SlopDeskVideoProtocol"]),
        .library(name: "SlopDeskVideoHost", targets: ["SlopDeskVideoHost"]),
        .library(name: "SlopDeskVideoClient", targets: ["SlopDeskVideoClient"]),
    ],
    // External UI deps — attach ONLY to `SlopDeskClientUI` so the headless core + wire/codec/controller
    // targets stay dependency-free (`swift test` / golden never fetch). Trades "clean checkout builds
    // with no prerequisite" for SPM resolution; versions pinned in Package.resolved. KeyboardShortcuts
    // is macOS-only → platform-conditioned.
    dependencies: [
        .package(url: "https://github.com/siteline/swiftui-introspect.git", from: "26.0.1"),
        .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols.git", from: "7.0.0"),
        // Pinned to 3.0.1: 3.0.0 CRASHES in release builds under the Swift 6.3 compiler (Xcode 26.5
        // ships 6.3.2); 3.0.1 is the crash fix. macOS-only.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.1"),
        // Type-safe UserDefaults for the global `SettingsKey` namespace. Depend ONLY on the `Defaults`
        // product — pure-Foundation, NO transitive deps (swift-syntax is reachable only from the
        // `DefaultsMacros` targets we don't use). Exempt from the "UI deps attach only to ClientUI"
        // rule: it's not UI, and lands on the headless `SlopDeskWorkspaceCore` (where `SettingsKey`
        // lives) plus ClientUI's `@Default` views. HELD at 8.2.0 (upToNextMajor = latest swift-syntax-
        // FREE 8.x): 9.x adds the `@ObservableDefault` macro target, which drags swift-syntax (603.x,
        // 75k-file fetch) into Package.resolved (absent at 8.x, present at 9.0.9) for ZERO functional
        // gain, regressing the "no swift-syntax in the resolved graph" invariant. Re-evaluate only if
        // the macro is needed. (Phase-D upgrade 2026-06-29.)
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "8.2.0"),
    ],
    targets: [
        // MARK: Libraries

        // Native SIMD kernels (replaces the Rust FFI NEON). A tiny C target SwiftPM COMPILES FROM
        // SOURCE every build — no cbindgen, no marshalling, no prebuilt staticlib, no build-ordering.
        // Holds the two genuine-SIMD kernels: the GF(2^8) split-table region multiply (`vqtbl1q_u8`)
        // and the xxHash64 NV12 frame-hash fold (synthesized `vmull_u32` u64 lane multiply), each
        // guarded `#if __aarch64__` with a scalar fallback so x86_64 CI/sim builds stay green. Swift
        // links it via the `include/` modulemap; byte-identical to the scalar reference (pinned by a
        // differential test). The ONLY remaining C/unsafe surface after the Rust core is reabsorbed.
        .target(
            name: "CSlopDeskSIMD",
            path: "Sources/CSlopDeskSIMD",
            cSettings: [.unsafeFlags(["-O3"])],
        ),

        // Pure-Swift wire format: framing, MessageType, seq(Int64), Hello/Ack. ZERO platform
        // dependency (no Network/Darwin) → builds macOS + iOS, unit-testable in isolation. Native
        // Swift codecs (single source of truth).
        .target(name: "SlopDeskProtocol"),

        // NWConnection + TCP_NODELAY, dual data/control channel, ET-style replay
        // buffer, reconnect handshake. (Implemented in WF-2.)
        .target(name: "SlopDeskTransport", dependencies: ["SlopDeskProtocol"]),

        // macOS host: PTY (openpty + posix_spawn createSession), session mgr, no-buffer
        // PTY<->transport relay, TIOCSWINSZ resize. (WF-3.) Also hosts the inspector's
        // second-connection server (InspectorServer), depending on SlopDeskInspector for the wire
        // types + replay log — acyclic, since SlopDeskInspector depends ONLY on SlopDeskProtocol.
        //
        // W10 adds SlopDeskAgentDetect: the host folds foreground-process / Claude-hook signals
        // through the pure `ClaudeStatusMachine` to decide the type-26/27 CONTROL emissions. Acyclic
        // — SlopDeskAgentDetect depends on NOTHING (physically cannot import SlopDeskHost).
        // W12 adds SlopDeskVideoProtocol for `EnvConfig` — the agent-detection gates
        // (`SLOPDESK_AGENT_DETECT`/`_HOOKS`) resolve through the settings overlay so a GUI toggle
        // reaches them (same `video-prefs.json` sidecar). Acyclic — SlopDeskVideoProtocol is the
        // cross-platform PURE wire/settings leaf (deps only CSlopDeskSIMD), never imports a host module.
        .target(
            name: "SlopDeskHost",
            dependencies: [
                "SlopDeskTransport", "SlopDeskProtocol", "SlopDeskInspector",
                "SlopDeskAgentDetect", "SlopDeskVideoProtocol",
            ],
        ),

        // Shared client: connection mgr, reconnect, input encoding. (WF-4.)
        .target(name: "SlopDeskClient", dependencies: ["SlopDeskTransport", "SlopDeskProtocol"]),

        // TerminalSurface protocol + HeadlessTerminalSurface. The libghostty-backed GhosttySurface
        // lives in the GUI app target (WF-5) and conforms to the same protocol.
        .target(name: "SlopDeskTerminal", dependencies: ["SlopDeskProtocol"]),

        // Local-terminal raw-mode + termios save/restore + TIOCGWINSZ/TIOCSWINSZ helpers for the
        // interactive CLI. A library so the save/restore + SIGWINCH mapping logic is unit-testable
        // (the executable target is not importable).
        .target(name: "SlopDeskTTY"),

        // Read-only structured inspector (WF-6). Tails Claude Code's JSONL transcript (+ subagent
        // files + hooks) on the host, models typed `InspectorEvent`s, streams them over a SECOND
        // length-prefixed channel (NWConnection #2) to a SwiftUI client. INDEPENDENT of the terminal
        // byte pipeline — reuses only SlopDeskProtocol's framing *style*, never the terminal
        // WireMessage. Read-only: observes the transcript, never drives the agent.
        .target(name: "SlopDeskInspector", dependencies: ["SlopDeskProtocol"]),

        // Cross-platform Claude Code integration LOGIC (WF-7): the terminal-mode sniffer (DECSET/
        // DECRST 1049 + OSC 133, robust to sequences split across chunk boundaries), the input
        // dedup ring (input-box B1 echo suppression), the input-box state machine (A shell / B1
        // TUI-compose). Pure Swift, Foundation-only — builds macOS + iOS, fixture-tested. The host
        // launch env + auth resolution live in SlopDeskHost (macOS, the WF-7 seam).
        .target(name: "SlopDeskClaudeCode", dependencies: ["SlopDeskProtocol"]),

        // Pure, headless Claude-Code DETECTION CORE (W7): the per-pane status enum (`ClaudeStatus`),
        // the deterministic clock-injected state machine (`ClaudeStatusMachine` — `Date()` is
        // physically unreachable; time arrives as a `TimeInterval` parameter), and the Herdr-style
        // no-hooks fallback (`ClaudeManifestMatcher`) reading a pane's title/screen for Claude TUI
        // cues. Foundation-only — depends on NOTHING GUI/transport/video, so it physically cannot
        // import them; the `SlopDeskInspector.HookPayload` → `ClaudeSignal` adapter is W8/W10, not
        // here. Validate-then-drop on every foreign string; no force-unwrap.
        .target(name: "SlopDeskAgentDetect"),

        // Headless workspace CORE (L0 of the UI rewrite): the proven logic extracted from the dying
        // `SlopDeskClientUI` view target — the tree-of-intent domain value types, the single
        // `@MainActor @Observable WorkspaceStore` + extensions, `AppConnection`/`ConnectionViewModel`,
        // the terminal block/search/context-menu engines, the video & remote-window LOGIC,
        // `InputBarModel`, the pure iOS input logic, `PreferencesStore`, and the injection SEAMS
        // (`TerminalRendererFactory`, `VideoWindowFactory`, `RemoteWindowDiscovery`, `SystemDialogDiscovery`).
        //
        // Imports NO view chrome / design-system tokens — every SwiftUI/AppKit/UIKit *presentation*
        // file was deleted (D1), SEAM placeholder `View` bodies split out (A2). The terminal pixels
        // and remote-GUI video view stay behind the factory seams so the library + tests stay headless
        // (no libghostty / Metal / VideoToolbox / SCStream in `swift build` or a test).
        //
        // Builds macOS 26 + iOS 26 (the deployment floor — no fallback below).
        .target(
            name: "SlopDeskWorkspaceCore",
            dependencies: [
                "SlopDeskClient",
                "SlopDeskTransport",
                "SlopDeskInspector",
                "SlopDeskClaudeCode",
                // W5: the pure headless Claude-status enum (`ClaudeStatus`) the sidebar/chrome dots read.
                // AgentDetect depends on nothing GUI/transport/video, so this never widens the graph.
                "SlopDeskAgentDetect",
                "SlopDeskTerminal",
                // W13: the W12 settings MODELS + the pure config bridges (`VideoPreferences`,
                // `TerminalPreferences`, `AgentPreferences`, `KeybindingPreferences`, `EnvConfig`,
                // `EnvBridge`, `TerminalConfigBuilder`) the `PreferencesStore` binds to.
                // SlopDeskVideoProtocol is the cross-platform PURE wire/settings target (no
                // ScreenCaptureKit/VideoToolbox/AppKit), so this does NOT widen the graph with HW deps.
                "SlopDeskVideoProtocol",
                // Type-safe UserDefaults for the global `SettingsKey` app-flag namespace. Pure-Foundation,
                // zero transitive deps (the macro/swift-syntax targets are not pulled — see the dep note).
                .product(name: "Defaults", package: "Defaults"),
            ],
        ),

        // REBUILD-V2: `SlopDeskClientUI` — pure SwiftUI views over `SlopDeskWorkspaceCore`, STOCK
        // SwiftUI + SYSTEM semantic colours/fonts (no custom token target — the old
        // `SlopDeskDesignSystem` was deleted in L0). The app SCENE + native IDE shell land here; the
        // pane/terminal/video content stays behind the `TerminalRendererFactory`/`VideoWindowFactory`
        // seams (renders the headless placeholder in `swift build`/tests — NO libghostty/Metal/
        // VideoToolbox). L0 ships a placeholder scene; L1+ rebuild the real shell.
        .target(
            name: "SlopDeskClientUI",
            dependencies: [
                "SlopDeskWorkspaceCore",
                // E4: the Details-Panel inspector views name the host-metadata `MetadataCodec` value types
                // (process / port / dir / git-file) directly. Transitive via WorkspaceCore, but a
                // `swift build` import needs the module declared here (same as Transport below).
                "SlopDeskProtocol",
                // E4/WI-6: `AgentSessionHistoryView` parses the raw `readAgentSession` JSONL through
                // `SlopDeskInspector.TranscriptParser`. Transitive via WorkspaceCore, but a direct
                // `import` needs the module declared here (same rationale as Protocol/Transport).
                "SlopDeskInspector",
                // L1: the app scene builds the production per-host shared-connection pool with
                // `ConnectionRegistry` + `LiveMuxConnectionFactory` (both live in Transport). These are
                // a direct dependency of WorkspaceCore, but a `swift build` import needs the module
                // declared here; this does NOT widen the headless graph (no HW deps in Transport).
                "SlopDeskTransport",
                // E20/WI-5: `WorkspaceControlBackend.jump` resolves the frecency/$HOME-toggle/`--no-cd`
                // target through the PURE `JumpResolver` (the single source of truth the CLI tests pin).
                // CLICore is a headless internal target (deps CtlCore/Protocol/WorkspaceCore, all already
                // below ClientUI) — no HW deps, no cycle.
                "SlopDeskCLICore",
                // L8: external UI libraries (chrome). Cross-platform: SwiftUIIntrospect (reach AppKit
                // under SwiftUI), SFSafeSymbols (type-safe SF Symbols). (Pow was dropped with the last
                // `changeEffect` — MERIDIAN L3: status dots hard-cut, nothing glows at rest.)
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
                // macOS-only: user-customizable global shortcuts + the recorder view.
                .product(
                    name: "KeyboardShortcuts",
                    package: "KeyboardShortcuts",
                    condition: .when(platforms: [.macOS]),
                ),
                // Type-safe UserDefaults — the `@Default(.key)` SwiftUI bindings in SettingsView (replacing
                // the stringly-typed `@AppStorage`). Same pure-Foundation `Defaults` product as the core.
                .product(name: "Defaults", package: "Defaults"),
            ],
        ),

        // MARK: PATH 2 — GUI video path (Phase 4 / WF-9)

        // Cross-platform PURE wire format for the GUI video path: UDP frame packetizer/reassembler
        // (loss detect + recovery signalling), FEC (XOR parity, swappable for Reed-Solomon), cursor
        // side-channel codec, window-geometry codec, coordinate-mapping math (multi-monitor
        // Cocoa-flip + Retina), and the client->host input-event codec. ZERO platform dependency (no
        // ScreenCaptureKit/VideoToolbox/AppKit) → builds macOS + iOS, unit-testable in isolation.
        .target(name: "SlopDeskVideoProtocol", dependencies: ["CSlopDeskSIMD"]),

        // macOS-only host capture + encode + input injection. USES ScreenCaptureKit / VideoToolbox /
        // CoreGraphics / AppKit. COMPILED + code-reviewed, NEVER executed in tests: SCStream capture
        // AND VTCompressionSession HW encode HANG without a window-server + Screen-Recording TCC
        // session, absent in a headless test/CI run (docs/research/spikes/vtbench/RESULTS.md). The
        // encoder/capture configs match the MEASURED spike configs exactly.
        // Private CoreGraphics `CGVirtualDisplay*` headers (clang module). Lets the host create a
        // HiDPI 2× virtual display so a remoted window renders at real Retina backing (sharp text)
        // instead of point-resolution upscale. macOS-only (CoreGraphics); see the header for the
        // run-loop / main-thread / retain contract. The classes link from the PUBLIC CoreGraphics
        // framework — only the headers are private (no dlopen, no entitlement).
        .target(
            name: "CSlopDeskVirtualDisplay",
            path: "Sources/CSlopDeskVirtualDisplay",
            publicHeadersPath: "include",
        ),

        .target(
            name: "SlopDeskVideoHost",
            dependencies: ["SlopDeskVideoProtocol", "CSlopDeskVirtualDisplay"],
            // macOS-only: SCStream + VTCompressionSession + AX/CGEvent are macOS APIs.
            // (SlopDeskVideoProtocol stays cross-platform; only this host layer is gated.)
            swiftSettings: [],
        ),

        // macOS + iOS client decode + Metal render + client-side cursor. USES VideoToolbox (decode) /
        // Metal / CoreVideo / QuartzCore. COMPILED + reviewed; decode is MEASURED-safe (~0.9-1.1ms
        // synchronous) but per the hang-safety rule NO VTDecompressionSession is instantiated in tests.
        .target(name: "SlopDeskVideoClient", dependencies: ["SlopDeskVideoProtocol"]),

        // MARK: Executables

        // Headless host daemon (PTY + transport). Sources under Sources/slopdesk-hostd.
        .executableTarget(name: "slopdesk-hostd", dependencies: ["SlopDeskHost"]),

        // Pure, testable core for slopdesk-ctl: arg-parsing (GlobalArgs / parseGlobal) + NDJSON
        // request/response helpers (encodeRequestLine / decodeResponseLine / verb param builders).
        // No socket I/O — Foundation-only, unit-testable without any AF_UNIX socket (hang-safety
        // rule). The thin `slopdesk-ctl` executable adds the socket I/O + exit calls.
        .target(name: "SlopDeskCtlCore"),

        // Agent-control CLI: the reference client for the agent-control Unix-domain socket.
        // Sends a single NDJSON request to $SLOPDESK_CONTROL_SOCKET (or --socket PATH),
        // prints the result, and exits. Agents shell out to this. Pure socket I/O in main.swift;
        // the testable logic lives in SlopDeskCtlCore.
        .executableTarget(name: "slopdesk-ctl", dependencies: ["SlopDeskCtlCore"]),

        // PURE, testable core of the user-facing `slopdesk` CLI (E20): the global-flag parser
        // (`CLIArgs`), the `version` summary builder (`CLIVersion`), the per-shell completion
        // generator (`CLICompletions`), and (later WIs) list formatting / watch-progress / jump
        // resolution. No socket I/O, no exit — Foundation-only, unit-testable without an AF_UNIX
        // socket or a GUI (hang-safety rule). Reuses `SlopDeskCtlCore`'s NDJSON line protocol; reads
        // `SlopDeskProtocol` for the wire-version summary and `SlopDeskWorkspaceCore` for the
        // frecency/progress reuse seams.
        .target(
            name: "SlopDeskCLICore",
            // SlopDeskAgentDetect supplies `ClaudeStatus`, which `WatchClaudeOutcome` (WI-8) maps to
            // the `watch:claude` exit codes. It is a transitive dep via SlopDeskWorkspaceCore, but
            // declared here so the `import` is explicit.
            dependencies: [
                "SlopDeskCtlCore",
                "SlopDeskProtocol",
                "SlopDeskWorkspaceCore",
                "SlopDeskAgentDetect",
            ],
        ),

        // The user-facing `slopdesk` CLI: arg → `CLIArgs`, dispatch, GUI-launch passthrough for the
        // bare / `-e <cmd>` invocation, the local `version` / `completions` / `config path|edit|validate`
        // ops, and the AF_UNIX NDJSON client socket I/O for the app-driving subcommands. Pure logic
        // (parsing, formatting, the `ClientControlProtocol` method/param vocabulary) lives in
        // SlopDeskCLICore / SlopDeskWorkspaceCore; this thin shell adds the socket + GUI launch + exit.
        .executableTarget(
            name: "slopdesk",
            // SlopDeskVideoProtocol supplies `KeybindGrammar` — the parser `config validate` injects
            // into `CLIConfig.validate` to check the keybind config file against the real grammar. It is
            // transitive via SlopDeskWorkspaceCore (pure wire/settings target, no HW deps), declared
            // here so the `import` is explicit.
            dependencies: [
                "SlopDeskCLICore", "SlopDeskCtlCore", "SlopDeskVideoProtocol", "SlopDeskWorkspaceCore",
            ],
        ),

        // Interactive remote terminal client. Sources under Sources/slopdesk-client.
        .executableTarget(
            name: "slopdesk-client",
            dependencies: ["SlopDeskClient", "SlopDeskTransport", "SlopDeskTerminal", "SlopDeskTTY"],
        ),

        // GUI video path (PATH 2) host daemon: enumerate shareable windows, bind the UDP
        // media+cursor sockets, run `SlopDeskVideoHostSession`. macOS-only at runtime
        // (ScreenCaptureKit/VideoToolbox); the `main.swift` is `#if os(macOS)`-gated with a
        // clear non-macOS error. COMPILED + reviewed; live behaviour is GUI+TCC-gated.
        .executableTarget(
            name: "slopdesk-videohostd",
            dependencies: ["SlopDeskVideoHost", "SlopDeskVideoProtocol"],
        ),

        // Headless closed-loop validation harness: synthetic CVPixelBuffer -> REAL HW
        // VideoEncoder -> VideoPacketizer (FEC tier + isLTR + hostSendTs) -> deterministic
        // fragment loss -> FrameReassembler (FEC recovery) -> REAL HW VideoDecoder, plus the
        // pure WF-1..WF-8 controllers driven on synthetic telemetry. Runs from a normal
        // (non-GUI, non-TCC) executable; its stdout IS the validation evidence. macOS-only.
        .executableTarget(
            name: "slopdesk-loopback-validate",
            dependencies: ["SlopDeskVideoHost", "SlopDeskVideoClient", "SlopDeskVideoProtocol"],
        ),

        // Headless VideoToolbox encode/decode TIMING benchmark (perf work, not shipped product):
        // real VideoEncoder + VideoDecoder + packetizer/FEC at the ACTUAL host configs (resolution ×
        // LiveBitratePolicy bitrate × fps × motion) → per-frame encode latency, output size /
        // effective bitrate (QP starvation = blur), drops, decode + packetize timing. Runs from a
        // normal shell (VT hangs only inside xctest). macOS-only.
        .executableTarget(
            name: "slopdesk-perfbench",
            dependencies: ["SlopDeskVideoHost", "SlopDeskVideoClient", "SlopDeskVideoProtocol"],
        ),

        // Frame-cadence watcher: SCK desktopIndependentWindow capture of ANY window (foreground
        // or background) that logs per-frame arrival timestamps + content checksums and prints a
        // stall histogram — the objective frame-level smoothness instrument (works on SlopDesk AND
        // Parsec windows alike). GUI+TCC-gated at runtime; no video file is written.
        .executableTarget(name: "slopdesk-framewatch"),

        // Capture-mode probe: drives the REAL `WindowCapturer` (the production capture path,
        // including the `SLOPDESK_DISPLAY_CAPTURE` mode seam) against one window and dumps
        // delivered frames as PNGs — the host-side instrument for geometric capture artifacts
        // (the Chrome-tooltip 1px crop shift) where a client-side screenshot would be polluted
        // by pane scaling. GUI+TCC-gated at runtime.
        .executableTarget(name: "slopdesk-capture-probe", dependencies: ["SlopDeskVideoHost"]),

        // Fake video client: a minimal UDP `hello` trigger that makes the real host start capturing a
        // window, so the FULL host pipeline (capture→encode→FEC→send) runs on one machine without the
        // GUI client. Diagnostic-only (overnight capture-cadence root-cause work). GUI+TCC at runtime.
        .executableTarget(name: "slopdesk-fake-client", dependencies: ["SlopDeskVideoProtocol"]),

        // Micro-benchmark for the Swift-level hot paths (frame hash, GF region multiply, RS FEC).
        .executableTarget(name: "slopdesk-bench", dependencies: ["SlopDeskVideoProtocol"]),

        // Fuzzy-match benchmark + parity validator: drives the vendored `FuzzyMatcher` (the in-tree fzf
        // FuzzyMatchV2 port behind the command palette) against the REAL `fzf --filter` binary and a
        // Bitap (Fuse-style) baseline on a shared corpus — reports ranking parity (match-set + top-K
        // agreement) and throughput. macOS dev instrument: shells out to `fzf` when present (skips that
        // comparison otherwise), so it is NOT part of `swift test`. Depends on SlopDeskClientUI for
        // `FuzzyMatcher`. `swift run -c release slopdesk-fuzzybench [scaleN]`.
        .executableTarget(name: "slopdesk-fuzzybench", dependencies: ["SlopDeskClientUI"]),

        // Golden-vector dumper: emits the golden reference corpus — a deterministic JSON corpus from
        // the SlopDeskVideoProtocol codecs + the pure realtime controllers (public API only) that the
        // Rust `slopdesk-core` crate asserts byte-/bit-identical against in its `golden_parity` test.
        // Pure value types only — constructs NO SCStream / encoder, so it touches no GUI/TCC:
        // `swift run slopdesk-corevectors > rust/slopdesk-core/tests/vectors/golden_vectors.json`.
        // IMPORTANT: run with no `SLOPDESK_*` env set so the controllers resolve their default
        // tunables (the Rust core pins those defaults as compile-time consts).
        .executableTarget(
            name: "slopdesk-corevectors",
            dependencies: [
                "SlopDeskProtocol",
                "SlopDeskVideoProtocol",
                "SlopDeskVideoHost",
                "SlopDeskVideoClient",
            ],
        ),

        // MARK: Tests

        // slopdesk-ctl CLI: arg-parsing + request-encoding tests. No real socket — the pure
        // SlopDeskCtlCore logic (parseGlobal, encodeRequestLine, verb param builders) is
        // exercised directly (hang-safety: no AF_UNIX in tests).
        .testTarget(name: "SlopDeskCtlTests", dependencies: ["SlopDeskCtlCore"]),

        // The user-facing `slopdesk` CLI core: global-flag parsing (`CLIArgs`), the `version`
        // summary builder, and the per-shell completion generator. PURE — no socket, no GUI, no
        // subprocess (the `slopdesk` executable's socket I/O + GUI launch are compiled-only and
        // never exercised here, per the hang-safety rule).
        // WorkspaceCore: `JumpResolverTests` constructs `FolderEntry` values to drive the PURE
        // `JumpResolver` (WI-5). Protocol: `WatchProgressTests` (WI-7) asserts the emitted OSC 9;4
        // bytes round-trip through `ProgressOSCParser`/`ProgressState`. Both are transitive deps of
        // CLICore, but declared here so the imports are explicit.
        .testTarget(
            name: "SlopDeskCLITests",
            // SlopDeskAgentDetect: `WatchClaudeOutcomeTests` (WI-8) drives the `ClaudeStatus` →
            // exit-code mapping directly. Transitive via CLICore, but declared so the import is explicit.
            dependencies: [
                "SlopDeskCLICore",
                "SlopDeskWorkspaceCore",
                "SlopDeskProtocol",
                "SlopDeskAgentDetect",
                // `CLIConfigTests` injects the REAL `KeybindGrammar.parseLine` into `CLIConfig.validate`
                // so the verdict tracks exactly what the app honours. Transitive via WorkspaceCore.
                "SlopDeskVideoProtocol",
            ],
        ),

        .testTarget(name: "SlopDeskProtocolTests", dependencies: ["SlopDeskProtocol"]),
        // W7: the pure detection core — state-machine transitions (incl. injected-clock
        // timeouts, idempotent/out-of-order signals), the conservative manifest matcher,
        // and the rollup most-urgent order. No GUI/socket/PTY — signals are fed directly.
        .testTarget(name: "SlopDeskAgentDetectTests", dependencies: ["SlopDeskAgentDetect"]),
        .testTarget(name: "SlopDeskTransportTests", dependencies: ["SlopDeskTransport"]),
        .testTarget(
            name: "SlopDeskHostTests",
            // W12: SlopDeskVideoProtocol for `EnvConfig` — the agent-gate reaches-consumer test sets
            // `EnvConfig.overlay` and asserts the default-arg path (overlay → env) reaches the gate.
            dependencies: ["SlopDeskHost", "SlopDeskInspector", "SlopDeskAgentDetect", "SlopDeskVideoProtocol"],
        ),
        // SlopDeskClientTests exercises the REAL PATH 1 e2e: a HostServer (SlopDeskHost) +
        // SlopDeskClient over loopback, so it depends on SlopDeskHost + SlopDeskTTY too.
        .testTarget(
            name: "SlopDeskClientTests",
            dependencies: [
                "SlopDeskClient",
                "SlopDeskHost",
                "SlopDeskTransport",
                "SlopDeskTerminal",
                "SlopDeskTTY",
            ],
        ),
        // Fixture-based tests for the inspector: JSONL parsing, tool-card pairing,
        // subagent tree, the append-follow tailer, transport round-trip, hook ingest.
        // The `Fixtures/` tree is read off disk via `#filePath` (see Fixtures.swift),
        // so it is excluded from the build rather than bundled as a resource.
        .testTarget(
            name: "SlopDeskInspectorTests",
            dependencies: ["SlopDeskInspector", "SlopDeskProtocol"],
            exclude: ["Fixtures"],
        ),
        // WF-7 logic: env/auth (SlopDeskHost) + mode sniffer / dedup ring / input-box model
        // (SlopDeskClaudeCode). Byte-sequence + fixture based; the sniffer tests feed the
        // SAME stream at adversarial split boundaries and assert identical results.
        .testTarget(
            name: "SlopDeskClaudeCodeTests",
            dependencies: ["SlopDeskClaudeCode", "SlopDeskHost", "SlopDeskProtocol"],
        ),
        // L0 workspace-core: the rescued PURE logic tests from the old SlopDeskClientUITests —
        // the tree-of-intent domain ops, WorkspaceStore reconcile, AppConnection/ConnectionViewModel
        // lifecycle, the terminal block/search engines, the iOS input timing/mapping logic, the
        // PreferencesStore, and the video/remote-window logic. Genuinely view-rendering tests
        // (DS tokens, chrome transforms, palette-entry/sidebar views) were deleted with the views.
        // Deterministic, runs on macOS — no libghostty / Metal / VideoToolbox instantiated.
        .testTarget(
            name: "SlopDeskWorkspaceCoreTests",
            dependencies: [
                "SlopDeskWorkspaceCore",
                "SlopDeskClient",
                "SlopDeskTransport",
                "SlopDeskHost",
                "SlopDeskInspector",
                "SlopDeskClaudeCode",
                "SlopDeskAgentDetect",
                "SlopDeskTerminal",
                "SlopDeskVideoProtocol",
            ],
        ),
        // Client UI: view-logic tests for the rebuilt native-SwiftUI chrome. VIEW-MODEL level only —
        // never instantiates Ghostty/VT/Metal/SCStream (the hang-safety rule); the renderer/video views
        // stay behind the factory seams. L0 carries only a placeholder test (the old Warp-clone view +
        // design-system tests were deleted with their views); L1+ re-add per-layer view-logic tests.
        .testTarget(
            name: "SlopDeskClientUITests",
            // E5/WI-3: `TerminalFindBarModelTests` conforms an in-memory fake to `SlopDeskTerminal`'s
            // `TerminalSurface`/`TerminalSurfaceActions` (the scrollback-mirror + bind-action seam) to drive
            // the find bar's view-model headlessly — declare the (already-transitive) module explicitly.
            dependencies: ["SlopDeskClientUI", "SlopDeskWorkspaceCore", "SlopDeskProtocol", "SlopDeskTerminal"],
        ),

        // WF-9 GUI video path: ONLY the PURE SlopDeskVideoProtocol is unit-tested
        // (packetize/reassemble incl. fragment-loss → drop + recovery, FEC real
        // single-loss recovery, cursor codec round-trip + <64B size, coordinate
        // mapping single/multi-monitor/Retina, window-geometry codec, input-event
        // codec). NO VideoToolbox / ScreenCaptureKit is instantiated anywhere here —
        // the host/client video code HANGS without a window-server + TCC session, so
        // it is COMPILED (swift build) + code-reviewed, never executed in a test.
        .testTarget(name: "SlopDeskVideoProtocolTests", dependencies: ["SlopDeskVideoProtocol"]),
        // WF-9 host orchestrator: ONLY the PURE host-session logic is unit-tested —
        // the session state machine (hello/helloAck/bye transitions + strict version
        // check), the input-datagram routing decisions (inject/drop/ignore + raise
        // latch), and the send-scheduler channel/packet ordering — all against an
        // in-memory `VideoDatagramTransport` fake. NO SCStream / VTCompressionSession /
        // CGEvent / live UDP socket is instantiated here (the hang-safety rule): the
        // capture/encode/inject components are COMPILED + code-reviewed only.
        .testTarget(name: "SlopDeskVideoHostTests", dependencies: ["SlopDeskVideoHost", "SlopDeskVideoProtocol"]),
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
            name: "SlopDeskVideoClientTests",
            dependencies: ["SlopDeskVideoClient", "SlopDeskVideoProtocol"],
        ),
    ],
)
