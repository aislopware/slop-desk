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
        .library(name: "AislopdeskWorkspaceCore", targets: ["AislopdeskWorkspaceCore"]),
        // The native-SwiftUI rewrite (REBUILD-V2): the rebuilt SwiftUI client UI (a thin layer over
        // AislopdeskWorkspaceCore using STOCK SwiftUI + system semantic colours/fonts — no custom token
        // target). The deleted `AislopdeskDesignSystem` (Warp-clone token system) is gone for good.
        .library(name: "AislopdeskClientUI", targets: ["AislopdeskClientUI"]),
        // PATH 2 (GUI video path, Phase 4 / WF-9).
        .library(name: "AislopdeskVideoProtocol", targets: ["AislopdeskVideoProtocol"]),
        .library(name: "AislopdeskVideoHost", targets: ["AislopdeskVideoHost"]),
        .library(name: "AislopdeskVideoClient", targets: ["AislopdeskVideoClient"]),
    ],
    // External UI dependencies — attach ONLY to the GUI target `AislopdeskClientUI` (the headless core +
    // wire/codec/controller targets stay dependency-free, so `swift test` / golden never fetch). Adopting
    // these trades the "clean checkout builds with no prerequisite" property for SPM network resolution;
    // versions are pinned in Package.resolved. KeyboardShortcuts is macOS-only → platform-conditioned.
    dependencies: [
        .package(url: "https://github.com/siteline/swiftui-introspect.git", from: "26.0.1"),
        .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols.git", from: "7.0.0"),
        // KeyboardShortcuts floor pinned to 3.0.1: 3.0.0 CRASHES in release builds compiled by the
        // Swift 6.3 compiler (Xcode 26.5 ships Swift 6.3.2); 3.0.1 is the crash fix. macOS-only.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.1"),
        // Type-safe UserDefaults for the global app-flag namespace (`SettingsKey`). We depend ONLY on the
        // `Defaults` library product — it is pure-Foundation with NO transitive deps; the package's
        // swift-syntax dependency is reachable only from the `DefaultsMacros`/macro targets, which we do
        // NOT use. `Defaults` is exempt from the "UI deps attach only to ClientUI" rule because it is not
        // UI — it lands on the headless `AislopdeskWorkspaceCore` where `SettingsKey` lives (and on
        // ClientUI for the `@Default` views). HELD at 8.2.0 (upToNextMajor, so the latest swift-syntax-FREE
        // 8.x): Defaults 9.x added the `@ObservableDefault` macro target, which drags swift-syntax (603.x,
        // a 75k-file fetch) into Package.resolved — verified absent at 8.x, present at 9.0.9. We use
        // Defaults ONLY for type-safe UserDefaults, never the macro, so 9.x gives ZERO functional gain
        // while regressing the deliberate "no swift-syntax in the resolved graph" invariant. Re-evaluate
        // only if a future need requires the macro. (Phase-D upgrade 2026-06-29.)
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "8.2.0"),
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

        // Headless workspace CORE (L0 of the Warp-clone UI rewrite): the proven logic extracted out
        // of the dying `AislopdeskClientUI` view target — the tree-of-intent domain value types, the
        // single `@MainActor @Observable WorkspaceStore` + its extensions, `AppConnection`/
        // `ConnectionViewModel`, the terminal block/search/context-menu engines, the video &
        // remote-window LOGIC, `InputBarModel`, the pure iOS input logic, `PreferencesStore`, and the
        // injection SEAMS (`TerminalRendererFactory`, `VideoWindowFactory`, `RemoteWindowDiscovery`,
        // `SystemDialogDiscovery`).
        //
        // This target imports NO view chrome / design-system tokens — every SwiftUI/AppKit/UIKit
        // *presentation* file was deleted (D1) and the SEAM placeholder `View` bodies were split out
        // (A2). The rebuilt `AislopdeskClientUI` (L1+) will be a thin SwiftUI layer over this core +
        // a new headless `AislopdeskDesignSystem`. The terminal pixels and the remote-GUI video view
        // stay behind the factory seams so the library + tests stay headless (no libghostty / Metal /
        // VideoToolbox / SCStream in `swift build` or a test).
        //
        // Builds for macOS 26 + iOS 26 (the deployment floor — no fallback below that).
        .target(
            name: "AislopdeskWorkspaceCore",
            dependencies: [
                "AislopdeskClient",
                "AislopdeskTransport",
                "AislopdeskInspector",
                "AislopdeskClaudeCode",
                // W5: the pure headless Claude-status enum (`ClaudeStatus`) the sidebar/chrome dots read.
                // AgentDetect depends on nothing GUI/transport/video, so this never widens the graph.
                "AislopdeskAgentDetect",
                "AislopdeskTerminal",
                // W13: the W12 settings MODELS + the pure config bridges (`VideoPreferences`,
                // `TerminalPreferences`, `AgentPreferences`, `KeybindingPreferences`, `EnvConfig`,
                // `EnvBridge`, `TerminalConfigBuilder`) the `PreferencesStore` binds to.
                // AislopdeskVideoProtocol is the cross-platform PURE wire/settings target (no
                // ScreenCaptureKit/VideoToolbox/AppKit), so this does NOT widen the graph with HW deps.
                "AislopdeskVideoProtocol",
                // Type-safe UserDefaults for the global `SettingsKey` app-flag namespace. Pure-Foundation,
                // zero transitive deps (the macro/swift-syntax targets are not pulled — see the dep note).
                .product(name: "Defaults", package: "Defaults"),
            ],
        ),

        // The native-SwiftUI rewrite (REBUILD-V2): the rebuilt `AislopdeskClientUI` — pure SwiftUI views
        // over `AislopdeskWorkspaceCore` (the proven headless logic), built from STOCK SwiftUI components
        // and SYSTEM semantic colours/fonts (no custom design-system token target — the old
        // `AislopdeskDesignSystem` was deleted in L0). The app SCENE + the native IDE shell land here; the
        // pane/terminal/video content stays behind the `TerminalRendererFactory`/`VideoWindowFactory` seams
        // (it renders the headless placeholder in `swift build`/tests — NO libghostty/Metal/VideoToolbox).
        // L0 ships a minimal placeholder scene; L1+ rebuild the real shell.
        .target(
            name: "AislopdeskClientUI",
            dependencies: [
                "AislopdeskWorkspaceCore",
                // E4: the Details-Panel inspector views name the host-metadata `MetadataCodec` value types
                // (process / port / dir / git-file) directly. Transitive via WorkspaceCore, but a
                // `swift build` import needs the module declared here (same as Transport below).
                "AislopdeskProtocol",
                // E4/WI-6: `AgentSessionHistoryView` parses the raw `readAgentSession` JSONL through
                // `AislopdeskInspector.TranscriptParser`. Transitive via WorkspaceCore, but a direct
                // `import` needs the module declared here (same rationale as Protocol/Transport).
                "AislopdeskInspector",
                // L1: the app scene builds the production per-host shared-connection pool with
                // `ConnectionRegistry` + `LiveMuxConnectionFactory` (both live in Transport). These are
                // a direct dependency of WorkspaceCore, but a `swift build` import needs the module
                // declared here; this does NOT widen the headless graph (no HW deps in Transport).
                "AislopdeskTransport",
                // E20/WI-5: `WorkspaceControlBackend.jump` resolves the frecency/$HOME-toggle/`--no-cd`
                // target through the PURE `JumpResolver` (the single source of truth the CLI tests pin).
                // CLICore is a headless internal target (deps CtlCore/Protocol/WorkspaceCore, all already
                // below ClientUI) — no HW deps, no cycle.
                "AislopdeskCLICore",
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

        // Pure, testable core for aislopdesk-ctl: arg-parsing (GlobalArgs / parseGlobal) and
        // NDJSON request/response helpers (encodeRequestLine / decodeResponseLine / verb
        // param builders). No socket I/O — Foundation-only so it builds for macOS + iOS and
        // is unit-testable without any AF_UNIX socket (hang-safety rule). The thin
        // `aislopdesk-ctl` executable imports this and adds the socket I/O + exit calls.
        .target(name: "AislopdeskCtlCore"),

        // Agent-control CLI: the reference client for the agent-control Unix-domain socket.
        // Sends a single NDJSON request to $AISLOPDESK_CONTROL_SOCKET (or --socket PATH),
        // prints the result, and exits. Agents shell out to this. Pure socket I/O in main.swift;
        // the testable logic lives in AislopdeskCtlCore.
        .executableTarget(name: "aislopdesk-ctl", dependencies: ["AislopdeskCtlCore"]),

        // PURE, testable core of the user-facing `aislopdesk` CLI (E20): the global-flag
        // parser (`CLIArgs`), the `version` summary builder (`CLIVersion`), the per-shell completion
        // generator (`CLICompletions`), and (later WIs) list formatting / watch-progress / jump
        // resolution. No socket I/O, no exit — Foundation-only so it builds macOS + iOS and is
        // exhaustively unit-testable without an AF_UNIX socket or a GUI (hang-safety rule). The thin
        // `aislopdesk` executable imports this and adds the socket I/O + GUI launch + dispatch.
        // Reuses the `AislopdeskCtlCore` NDJSON line protocol; reads `AislopdeskProtocol` for the
        // wire-version summary and `AislopdeskWorkspaceCore` for the frecency/progress reuse seams.
        .target(
            name: "AislopdeskCLICore",
            // AislopdeskAgentDetect supplies `ClaudeStatus`, which `WatchClaudeOutcome` (WI-8) maps to
            // the `watch:claude` exit codes. It is a transitive dep via AislopdeskWorkspaceCore, but
            // declared here so the `import` is explicit.
            dependencies: [
                "AislopdeskCtlCore",
                "AislopdeskProtocol",
                "AislopdeskWorkspaceCore",
                "AislopdeskAgentDetect",
            ],
        ),

        // The user-facing `aislopdesk` CLI: arg → `CLIArgs`, dispatch, GUI-launch passthrough for the
        // bare / `-e <cmd>` invocation, the local `version` / `completions` / `config path|edit|validate`
        // ops, and the AF_UNIX NDJSON client socket I/O for the app-driving subcommands. Pure logic
        // (parsing, formatting, the `ClientControlProtocol` method/param vocabulary) lives in
        // AislopdeskCLICore / AislopdeskWorkspaceCore; this thin shell adds the socket + GUI launch + exit.
        .executableTarget(
            name: "aislopdesk",
            // AislopdeskVideoProtocol supplies `KeybindGrammar` — the parser `config validate` injects
            // into `CLIConfig.validate` to check the keybind config file against the real grammar. It is
            // transitive via AislopdeskWorkspaceCore (pure wire/settings target, no HW deps), declared
            // here so the `import` is explicit.
            dependencies: [
                "AislopdeskCLICore", "AislopdeskCtlCore", "AislopdeskVideoProtocol", "AislopdeskWorkspaceCore",
            ],
        ),

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

        // Headless VideoToolbox encode/decode TIMING benchmark (perf work, not shipped product):
        // real VideoEncoder + VideoDecoder + packetizer/FEC at the ACTUAL host configs (resolution ×
        // LiveBitratePolicy bitrate × fps × motion) → per-frame encode latency, output size /
        // effective bitrate (QP starvation = blur), drops, decode + packetize timing. Runs from a
        // normal shell (VT hangs only inside xctest). macOS-only.
        .executableTarget(
            name: "aislopdesk-perfbench",
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

        // Fuzzy-match benchmark + parity validator: drives the vendored `FuzzyMatcher` (the in-tree fzf
        // FuzzyMatchV2 port behind the command palette) against the REAL `fzf --filter` binary and a
        // Bitap (Fuse-style) baseline on a shared corpus — reports ranking parity (match-set + top-K
        // agreement) and throughput. macOS dev instrument: shells out to `fzf` when present (skips that
        // comparison otherwise), so it is NOT part of `swift test`. Depends on AislopdeskClientUI for
        // `FuzzyMatcher`. `swift run -c release aislopdesk-fuzzybench [scaleN]`.
        .executableTarget(name: "aislopdesk-fuzzybench", dependencies: ["AislopdeskClientUI"]),

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

        // aislopdesk-ctl CLI: arg-parsing + request-encoding tests. No real socket — the pure
        // AislopdeskCtlCore logic (parseGlobal, encodeRequestLine, verb param builders) is
        // exercised directly (hang-safety: no AF_UNIX in tests).
        .testTarget(name: "AislopdeskCtlTests", dependencies: ["AislopdeskCtlCore"]),

        // The user-facing `aislopdesk` CLI core: global-flag parsing (`CLIArgs`), the `version`
        // summary builder, and the per-shell completion generator. PURE — no socket, no GUI, no
        // subprocess (the `aislopdesk` executable's socket I/O + GUI launch are compiled-only and
        // never exercised here, per the hang-safety rule).
        // WorkspaceCore: `JumpResolverTests` constructs `FolderEntry` values to drive the PURE
        // `JumpResolver` (WI-5). Protocol: `WatchProgressTests` (WI-7) asserts the emitted OSC 9;4
        // bytes round-trip through `ProgressOSCParser`/`ProgressState`. Both are transitive deps of
        // CLICore, but declared here so the imports are explicit.
        .testTarget(
            name: "AislopdeskCLITests",
            // AislopdeskAgentDetect: `WatchClaudeOutcomeTests` (WI-8) drives the `ClaudeStatus` →
            // exit-code mapping directly. Transitive via CLICore, but declared so the import is explicit.
            dependencies: [
                "AislopdeskCLICore",
                "AislopdeskWorkspaceCore",
                "AislopdeskProtocol",
                "AislopdeskAgentDetect",
                // `CLIConfigTests` injects the REAL `KeybindGrammar.parseLine` into `CLIConfig.validate`
                // so the verdict tracks exactly what the app honours. Transitive via WorkspaceCore.
                "AislopdeskVideoProtocol",
            ],
        ),

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
        // L0 workspace-core: the rescued PURE logic tests from the old AislopdeskClientUITests —
        // the tree-of-intent domain ops, WorkspaceStore reconcile, AppConnection/ConnectionViewModel
        // lifecycle, the terminal block/search engines, the iOS input timing/mapping logic, the
        // PreferencesStore, and the video/remote-window logic. Genuinely view-rendering tests
        // (DS tokens, chrome transforms, palette-entry/sidebar views) were deleted with the views.
        // Deterministic, runs on macOS — no libghostty / Metal / VideoToolbox instantiated.
        .testTarget(
            name: "AislopdeskWorkspaceCoreTests",
            dependencies: [
                "AislopdeskWorkspaceCore",
                "AislopdeskClient",
                "AislopdeskTransport",
                "AislopdeskHost",
                "AislopdeskInspector",
                "AislopdeskClaudeCode",
                "AislopdeskAgentDetect",
                "AislopdeskTerminal",
                "AislopdeskVideoProtocol",
            ],
        ),
        // Client UI: view-logic tests for the rebuilt native-SwiftUI chrome. VIEW-MODEL level only —
        // never instantiates Ghostty/VT/Metal/SCStream (the hang-safety rule); the renderer/video views
        // stay behind the factory seams. L0 carries only a placeholder test (the old Warp-clone view +
        // design-system tests were deleted with their views); L1+ re-add per-layer view-logic tests.
        .testTarget(
            name: "AislopdeskClientUITests",
            // E5/WI-3: `TerminalFindBarModelTests` conforms an in-memory fake to `AislopdeskTerminal`'s
            // `TerminalSurface`/`TerminalSurfaceActions` (the scrollback-mirror + bind-action seam) to drive
            // the find bar's view-model headlessly — declare the (already-transitive) module explicitly.
            dependencies: ["AislopdeskClientUI", "AislopdeskWorkspaceCore", "AislopdeskProtocol", "AislopdeskTerminal"],
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
