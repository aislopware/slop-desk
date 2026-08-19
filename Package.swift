// swift-tools-version:6.3
import PackageDescription

// SlopDesk — terminal-first remote-coding for Apple platforms.
//
// Headless-first (docs/19-implementation-plan.md): the PATH 1 byte pipeline (host PTY <->
// TCP/TCP_NODELAY <-> client, replay-buffer reconnect) is the de-risked core; builds + tests
// with NO GUI, NO libghostty.
//
// Swift 6 tools default to Swift 6 language mode (strict concurrency).

// What the FFI archive's C needs from the system, carried by every target that links it.
//
// `CSlopDeskFFI`'s macOS slice contains a vendored `libgit2` — `slopdesk_git_status`, the door that
// replaced five process spawns per FSEvents tick with one call. libgit2 wants `iconv` for the
// NFD/NFC path normalisation Apple filesystems make it do, and `Security` + `CoreFoundation` for its
// certificate handling. (zlib is NOT here: it is compiled into the archive by `libz-sys`'s `static`,
// because it was the one dependency small enough to vendor.)
//
// Every target that names `CSlopDeskFFI` carries this, not just the one whose door it is, because a
// Rust staticlib is ONE object per crate: the object holding that door also holds every other
// `slopdesk_*` entry point, so an executable calling ANY of them drags libgit2's members in. The
// three flags cost a link-time symbol lookup on the products that never call it — `-dead_strip`
// removes the code itself — and `scripts/check-supervisor.sh` fails a new `CSlopDeskFFI` dependent
// that forgets them, which is the failure a person would otherwise meet as a wall of `_iconv`.
//
// macOS only: the iOS slices have no libgit2 in them at all (`slopdesk_ffi.h`'s `TARGET_OS_OSX`
// region, and the `cfg` behind it).
let ffiCLibraries: [LinkerSetting] = [
    .linkedLibrary("iconv", .when(platforms: [.macOS])),
    .linkedFramework("Security", .when(platforms: [.macOS])),
    .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
]
let package = Package(
    name: "SlopDesk",
    platforms: [
        // PackageDescription 6.2 makes the `.v26` enum available for the macOS 26 / iOS 26 floor.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "SlopDeskProtocol", targets: ["SlopDeskProtocol"]),
        .library(name: "SlopDeskScreen", targets: ["SlopDeskScreen"]),
        .library(name: "SlopDeskTransport", targets: ["SlopDeskTransport"]),
        .library(name: "SlopDeskHost", targets: ["SlopDeskHost"]),
        .library(name: "SlopDeskClient", targets: ["SlopDeskClient"]),
        .library(name: "SlopDeskTerminal", targets: ["SlopDeskTerminal"]),
        .library(name: "SlopDeskTTY", targets: ["SlopDeskTTY"]),
        .library(name: "SlopDeskInspector", targets: ["SlopDeskInspector"]),
        .library(name: "SlopDeskClaudeCode", targets: ["SlopDeskClaudeCode"]),
        .library(name: "SlopDeskAgentDetect", targets: ["SlopDeskAgentDetect"]),
        .library(name: "SlopDeskWorkspaceCore", targets: ["SlopDeskWorkspaceCore"]),
        // docs/56: the simulator + Android panels' DOMAIN — their wire, their sockets, their device
        // models. No view framework, so both UI halves reach the one implementation (docs 47, 48).
        .library(name: "SlopDeskDevicePanels", targets: ["SlopDeskDevicePanels"]),
        .library(name: "SlopDeskClientCore", targets: ["SlopDeskClientCore"]),
        // docs/56: the DESIGN FLOOR — the token ladder in BOTH of its spellings, the status mark's
        // geometry and cadence, the vector artwork. Values, never views, so the AppKit half and the
        // SwiftUI half render one design instead of two.
        .library(name: "SlopDeskSlate", targets: ["SlopDeskSlate"]),
        // REBUILD-V2: thin SwiftUI layer over SlopDeskWorkspaceCore, over the `SlopDeskSlate` tokens.
        .library(name: "SlopDeskClientUI", targets: ["SlopDeskClientUI"]),
        // docs/56 stage C: the two APP SHELLS. Each Xcode app target links exactly one of them, and
        // neither imports the other — the products exist so the two `@main`s can be linked apart.
        .library(name: "SlopDeskMacUI", targets: ["SlopDeskMacUI"]),
        .library(name: "SlopDeskPhoneUI", targets: ["SlopDeskPhoneUI"]),
        // PATH 2 (GUI video path, Phase 4 / WF-9).
        .library(name: "SlopDeskVideoProtocol", targets: ["SlopDeskVideoProtocol"]),
        .library(name: "SlopDeskVideoHost", targets: ["SlopDeskVideoHost"]),
        .library(name: "SlopDeskVideoClient", targets: ["SlopDeskVideoClient"]),
        // PATH 4 (dedicated drag-drop file-transfer channel).
        .library(name: "SlopDeskFileTransfer", targets: ["SlopDeskFileTransfer"]),
        // The three SHIPPED executables (scripts/package-release.sh, docs/49). Products, not just
        // targets, because `swift build --target <exe>` under the Swift 6.3 build backend compiles
        // the module and never links a binary — the release tarball needs `--product`, which only
        // exists for a declared product. Every other executableTarget below is a dev/bench tool and
        // stays product-less on purpose: `swift build` still builds them, `--product` won't ship them.
        .executable(name: "slopdesk", targets: ["slopdesk"]),
        .executable(name: "slopdesk-hostd", targets: ["slopdesk-hostd"]),
        // No `slopdesk-ctl` product: the agent-control CLI is Rust (`rust/slopdesk-ctl`), built by
        // `make ctl` and shipped straight out of `rust/target/release`.
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
        // product — the macro/swift-syntax targets (`DefaultsMacros`) are not linked. Exempt from the
        // "UI deps attach only to ClientUI" rule: it's not UI, and lands on the headless
        // `SlopDeskWorkspaceCore` (where `SettingsKey` lives) plus ClientUI's `@Default` views.
        // 2026-07-11: un-HELD from 8.2.0 → 9.x (user call). This drags swift-syntax into
        // Package.resolved (Defaults declares it package-level for the `@ObservableDefault` macro we
        // don't use) — swift-syntax is FETCHED at resolve time but NOT built/linked into any product
        // here, so build time and binaries are unaffected; only the checkout is heavier.
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "9.0.9"),
    ],
    targets: [
        // MARK: Libraries

        // (The `CSlopDeskSIMD` C target lived here: a NEON GF(2^8) split-table region multiply
        // for the FEC inner loop. The codec moved to `rust/slopdesk-video`, which is
        // `forbid(unsafe_code)`; the kernel itself did not dissolve — it came back as
        // `rust/slopdesk-gfsimd`, the third and smallest crate allowed to write `unsafe`, holding
        // the two byte-region loops and nothing else. What went with the C target is the last
        // hand-written implementation under `Sources/`, not the intrinsics — docs/DECISIONS.md.)

        // Pure-Swift wire format: framing, MessageType, seq(Int64), Hello/Ack. ZERO platform
        // dependency (no Network/Darwin) → builds macOS + iOS, unit-testable in isolation. Native
        // Swift codecs (single source of truth).
        // The Swift side of `docs/55` §4c's arena convention — a `(offset, length)` pair read back
        // as text. Dependency-free ON PURPOSE, including of the shim: an offset and a length are
        // arithmetic, not a boundary, so every leaf that reads an arena can name this one without
        // any of them widening its graph. It was nine copies in five targets before it was one.
        .target(name: "SlopDeskArena"),

        // One `NWConnection` as a byte stream, for the two lanes that need one: the inspector's
        // event channel and PATH-4's file transfer. It was the same actor in both, line for line,
        // and a lifetime this fussy — three separate fd-leak fixes — must not be maintained twice.
        // Foundation + Network only, so neither caller widens its graph by naming it.
        .target(name: "SlopDeskNet"),

        .target(
            name: "SlopDeskProtocol",
            dependencies: ["SlopDeskArena", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // The `NSPasteboard` ↔ `MetadataCodec.ClipboardClip` conversion, both directions. Clipboard
        // sync has two ends — `HostClipboardPerformer` (daemon graph) and `ClipboardSyncEngine`
        // (client graph) — and neither target can see the other, so the shared reading of the WIRE's
        // own clip type had been written twice and had already drifted. The only thing below both is
        // SlopDeskProtocol, which is the wire and has no business importing AppKit; hence a leaf of
        // its own. macOS-only content behind `#if os(macOS)`, so the iOS client compiles it empty.
        .target(name: "SlopDeskPasteboard", dependencies: ["SlopDeskProtocol"]),

        // The Rust logic the Swift clients call in-process, as three arm64 static slices.
        //
        // Built by `scripts/build-ffi.sh` (any `make build`/`test`/`check` runs it first) and
        // GITIGNORED: 17 MB of archive rewritten by every Rust edit is not a source. cargo still
        // never runs inside `swift build` — the artifact is an input to it, the way
        // `libghostty.xcframework` is to the Xcode targets.
        //
        // Unlike libghostty, this one IS in the SwiftPM graph, and that is the point: the
        // one-implementation rule means a ported module's Swift original is DELETED, so the Rust
        // has to be what `swift test` actually exercises. A binary target reachable only from Xcode
        // would have left the Swift copy alive as the thing under test.
        .binaryTarget(
            name: "CSlopDeskFFI",
            path: "ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework",
        ),

        // NWConnection + TCP_NODELAY, dual data/control channel, ET-style replay
        // buffer, reconnect handshake. (Implemented in WF-2.)
        .target(
            name: "SlopDeskTransport",
            dependencies: ["SlopDeskProtocol", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

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
        // cross-platform PURE wire/settings leaf (deps only CSlopDeskFFI), never imports a host module.
        .target(
            name: "SlopDeskHost",
            dependencies: [
                "SlopDeskTransport", "SlopDeskProtocol", "SlopDeskInspector",
                "SlopDeskAgentDetect", "SlopDeskVideoProtocol",
                // The pasteboard↔clip conversion the client's sync engine reads from the same file.
                "SlopDeskPasteboard",
                // The `write(2)`-until-done loop the control listener and the mux session both
                // used to spell. Zero-dependency leaf, so the daemon graph is unchanged.
                "SlopDeskTTY",
                // docs/51: `slopdesk-superd` forks the pane shells now, so the fork-to-exec window +
                // argv/envp vectors live in the shared leaf and `PTYProcess` calls into them. This
                // is also how hostd adopts a supervised master fd.
                "SlopDeskSupervisor",
                // docs/52: the VT screen engine is `slopdesk-screend`, a Rust binary over an
                // AF_UNIX socket. This is the CLIENT end only — there is no Swift parser left.
                "SlopDeskScreen",
                // docs/45: the host owns the workspace document, so it needs the value model.
                // Leaf target (Foundation + CoreGraphics), so this does NOT widen the daemon graph.
                "SlopDeskWorkspaceModel",
                // docs/49: the per-sidecar version policy is `rust/slopdesk-sidecars`, because the
                // OTHER caller of that policy — `slopdesk sidecars` — is Rust, and two tables in two
                // languages is the mirror `CLAUDE.md` bans. Named here rather than reached through
                // one of the targets above: an import that works by transitivity works until the
                // target it rode in on drops the dependency.
                "CSlopDeskFFI",
            ],

            linkerSettings: ffiCLibraries,
        ),

        // The workspace VALUE MODEL — the Session→Tab→split tree, `PaneSpec`, the pure
        // `WorkspaceTreeOps`, the canvas value types, and (from docs/45) the host workspace-document
        // state + codec.
        //
        // A LEAF: Foundation + CoreGraphics, and no SWIFT package dependency. That is the whole point.
        // `SlopDeskWorkspaceCore` depends on SlopDeskClient/Transport/Inspector/ClaudeCode/
        // AgentDetect/Terminal/VideoProtocol/Defaults, so hostd — which depends on none of those —
        // could not import it and therefore could not so much as name a tab. Splitting the values out
        // lets the HOST own the workspace document (docs/45) without dragging the client graph into
        // the daemon. Keep it that way: anything needing a Swift package dep belongs one level up.
        //
        // `CSlopDeskFFI` is not a step back from that. It is the static archive `make ffi` builds
        // (docs/55), the same one hostd and both clients already link, and it carries the SOLVERS this
        // module used to hold a second copy of — focus, send-keys, the sidebar's ordering. The leaf is
        // still a leaf: it names no other target here, and hostd links the archive regardless.
        .target(
            name: "SlopDeskWorkspaceModel",
            dependencies: ["SlopDeskArena", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // Shared client: connection mgr, reconnect, input encoding. (WF-4.)
        .target(name: "SlopDeskClient", dependencies: ["SlopDeskTransport", "SlopDeskProtocol"]),

        // TerminalSurface protocol + HeadlessTerminalSurface. The libghostty-backed GhosttySurface
        // lives in the GUI app target (WF-5) and conforms to the same protocol.
        .target(name: "SlopDeskTerminal", dependencies: ["SlopDeskProtocol"]),

        // The leaf that owns a RAW DESCRIPTOR on the Swift side: local-terminal raw mode, termios
        // save/restore, TIOCGWINSZ/TIOCSWINSZ, and the `write(2)`-until-done loop six call sites
        // each used to spell (`FileDescriptorWrite`). A library so the save/restore + SIGWINCH
        // mapping logic is unit-testable (the executable target is not importable). Zero
        // dependencies, so naming it never widens a graph.
        .target(name: "SlopDeskTTY"),

        // Read-only structured inspector (WF-6). Tails Claude Code's JSONL transcript (+ subagent
        // files + hooks) on the host, models typed `InspectorEvent`s, streams them over a SECOND
        // length-prefixed channel (NWConnection #2) to a SwiftUI client. INDEPENDENT of the terminal
        // byte pipeline — reuses only SlopDeskProtocol's framing *style*, never the terminal
        // WireMessage. Read-only: observes the transcript, never drives the agent.
        .target(
            // CSlopDeskFFI: the inspector's FRAME lives in `rust/slopdesk-inspectord`, the daemon
            // that speaks the other end of it, and this end reaches it in process. Only the event
            // JSON is decoded here.
            name: "SlopDeskInspector",
            dependencies: ["SlopDeskProtocol", "SlopDeskNet", "CSlopDeskFFI"],

            linkerSettings: ffiCLibraries,
        ),

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
        // docs/55: every RULE here — the alias table, the keystroke classes, the temporal hold and
        // the status machine — is `rust/slopdesk-agent`, reached in-process. The Swift enums that
        // remain are the case lists a SwiftUI switch needs, and nothing else.
        .target(name: "SlopDeskAgentDetect", dependencies: ["CSlopDeskFFI"], linkerSettings: ffiCLibraries),

        // Headless workspace CORE (L0 of the UI rewrite): the proven logic extracted from the dying
        // `SlopDeskClientUI` view target — the tree-of-intent domain value types, the single
        // `@MainActor @Observable WorkspaceStore` + extensions, `AppConnection`/`ConnectionViewModel`,
        // the terminal block/search/context-menu engines, the video & remote-window LOGIC,
        // `InputBarModel`, the pure iOS input logic, `PreferencesStore`, and the injection SEAMS
        // (`TerminalRendererFactory`, `VideoWindowFactory`, `RemoteWindowDiscovery`).
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
                // The dependency-free workspace VALUE MODEL (tree, PaneSpec, canvas, tree ops).
                "SlopDeskWorkspaceModel",
                // The link/path/URL scan (`TerminalLinkDetector`) is the Swift face of
                // `rust/slopdesk-terminal`'s `link`, so this target links the door directly rather
                // than importing it through whichever neighbour happens to pull it in today.
                "CSlopDeskFFI",
                // …and the scan's arena is read through the one reader every face shares.
                "SlopDeskArena",
                // The pasteboard↔clip conversion the HOST's performer reads from the same file —
                // clipboard sync's two ends agree by sharing it, not by staying in step by hand.
                "SlopDeskPasteboard",
                // The store dials the inspector's event lane over the shared byte channel.
                "SlopDeskNet",
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

            linkerSettings: ffiCLibraries,
        ),

        // docs/56 stage A: the DEVICE-PANEL domain, evacuated out of the view target.
        //
        // The simulator panel (docs/47) and the Android panel (docs/48) are each a wire format, a
        // socket client, a frame sink and a device model — none of which is a view, and all of which
        // both UI halves need once iOS carries the same features macOS does. Leaving them inside
        // `SlopDeskClientUI` would have forced the AppKit and SwiftUI halves to each carry a copy of
        // `SimulatorSidebarModel` (731 lines) and `AndroidSidebarModel` (833), which is the same
        // product implemented twice — what `CLAUDE.md`'s one-implementation rule exists to stop.
        //
        // Declarations are `package`, not `public`: every caller is inside this package (the two UI
        // targets and the test target), and the Xcode app targets are outside it, so the app-facing
        // surface does not grow by a symbol.
        //
        // NO PLATFORM GATE ANYWHERE INSIDE. Every one of these files used to be wrapped whole in
        // `#if os(macOS)` — inherited from the days the panels were a Mac-only surface, never from a
        // Mac-only dependency: the module imports Foundation, CoreGraphics, CoreMedia and Network,
        // all four of which the phone has. The gates made the iOS build compile forty-one EMPTY
        // files, which is why the parity gap was invisible. They are gone, `scripts/check-supervisor.sh`
        // keeps them gone, and what is left is the floor both UI halves stand on.
        .target(
            name: "SlopDeskDevicePanels",
            dependencies: [
                // The two sidebar models read the workspace store (a panel row opens a pane).
                "SlopDeskWorkspaceCore",
                // Pane specs + the `PaneID` a device row spawns against.
                "SlopDeskWorkspaceModel",
                // The metadata RPC the simulator control client rides.
                "SlopDeskProtocol",
                // `MuxNWConnection` — the Android bridge and the simulator stream are mux channels.
                "SlopDeskTransport",
                // `DevicePanelGeometry` maps a touch into VIDEO pixels (docs/48 — the jank fix), which
                // is the video path's coordinate domain, not the panel's.
                "SlopDeskVideoProtocol",
                // The Android control codec + the device console grammars are Rust (`slopdesk-devicelog`).
                "CSlopDeskFFI",
                // Device-kind glyph names. A string enum, not a view framework — the UI half maps the
                // name onto its own image type.
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
            ],

            linkerSettings: ffiCLibraries,
        ),

        // docs/56 stage A: the client's PRESENTATION LOGIC, evacuated out of the view target.
        //
        // The layer between the domain and a view: what the palette offers and in what order, which
        // rows the rail draws, which overlay is up, what a settings option means, how a key chord
        // normalises. None of it draws — every file here imported neither SwiftUI nor AppKit while it
        // still lived in the view target — and all of it is answered the same way on a phone as on a
        // Mac, since the two halves ship the same features and differ only in layout (docs/56 §2).
        //
        // Distinct from `SlopDeskWorkspaceCore`, which is the DOMAIN: a store, a connection, a
        // terminal, an agent. A rail row is not a domain concept; it is what a UI asks the domain
        // for. Keeping the two apart is what stops the domain target from growing a view model every
        // time a surface is added.
        //
        // The three files that name a framework name it as an ACTUATOR, not a view:
        // `SecureKeyboardEntryController` (Carbon `EnableSecureEventInput` + the app-frontmost edge),
        // `CodeSidebarFontSchemeHandler` (a `WKScriptMessageHandler`) and `WorkspaceControlBackend`
        // (`NSFontManager`, for `font list`). A framework call is not a view; a `some View` is.
        .target(
            name: "SlopDeskClientCore",
            dependencies: [
                // The store, the connection, the settings keys, the terminal — what this layer
                // presents.
                "SlopDeskWorkspaceCore",
                // Pane specs, `PaneID`, `ShellQuoting`.
                "SlopDeskWorkspaceModel",
                // The palette + the rail read host metadata (process / port / dir / git-file).
                "SlopDeskProtocol",
                // The rail's rows and the palette's agent entries are keyed by agent state.
                "SlopDeskAgentDetect",
                // `PendingToolSummary` — the todo SCENT a working row's tooltip carries.
                "SlopDeskInspector",
                // `SessionResumeOutcome` — the fresh-vs-resumed reconnect verdict a toast reports.
                "SlopDeskClient",
                // `JumpResolver` — the PURE frecency/$HOME-toggle/`--no-cd` resolution the CLI pins.
                "SlopDeskCLICore",
                // The client control server answers over a mux channel and writes with `write(2)`.
                "SlopDeskTransport",
                "SlopDeskTTY",
                // The pane's drop destination drives `FileTransferClient`.
                "SlopDeskFileTransfer",
                // Settings options name video-path knobs.
                "SlopDeskVideoProtocol",
                // `DevicePanelPhase` — the right panel's four surfaces are drawn twice, and what each
                // one SAYS is not a fact about either drawing (`CodePanelPresentation`). Two of the
                // four phases are that target's, so the panel's one vocabulary lives above both
                // rather than in a third target they would each have to agree with.
                "SlopDeskDevicePanels",
                // `FuzzyMatcher` marshals `slopdesk_fuzzy_score` — fzf's `FuzzyMatchV2` is Rust, and
                // every search field in the app ranks through it. `SettingsCatalog` marshals the
                // rest: what Settings OFFERS is one table of strings both UI splits read.
                "CSlopDeskFFI",
                // The `SettingsKey` app-flag namespace and the persisted chrome flags.
                .product(name: "Defaults", package: "Defaults"),
            ],
            // The bundled faces: the Symbols Nerd Font (the SAME fallback face ghostty gives the
            // terminal grid) and JetBrains Mono (the face libghostty falls back to when "SF Mono"
            // does not resolve, which on a stock system it does not). They live with the CORE rather
            // than with a UI target because the code sidebar injects the same bytes as @font-face
            // data URIs — the webview's WebContent process cannot see a `CTFontManager` process-scope
            // registration — and that dressing is not a view. MIT / OFL-1.1, licences beside them.
            resources: [.copy("Resources/Fonts")],

            linkerSettings: ffiCLibraries,
        ),

        // docs/56: the DESIGN FLOOR. `SlopDeskClientUI` is the DRAINING target — when the last macOS
        // surface leaves it, what is left is the phone's and it is renamed `SlopDeskPhoneUI`. The
        // token ladder cannot ride that rename: `SlopDeskMacUI` reads ~200 of these constants, and an
        // AppKit target importing the phone's would be exactly the common view ancestor docs/56 §3
        // forbids. So the floor is its own target, BELOW both halves.
        //
        // The line it holds is "a value, never a `some View`": `Slate` (the ladder, in `NSColor`/
        // `UIColor` AND in `Color`), `StatusDot`/`StatusMark`/`StatusDotStyle`, `AgentSpinner`'s
        // wandering tempo and `BrailleCell`'s walk, `SVGPath`/`VectorIcon`/`OttyIcon`, the nerd-font
        // splice's AppKit half, the search field's jump-free configuration, and `StatusPresentation`
        // — which is a palette ANSWER, not a drawing. Every mark that has two renderers keeps them
        // one floor up, one per framework, and `check-supervisor.sh` fails the build if a `some View`
        // appears here.
        //
        // It reverses the 2026-06-24 "no separate SPM target — `SlopDeskDesignSystem` stays deleted"
        // ruling on new grounds: that decision was taken when there was exactly ONE UI target to
        // compile the constants into, and there are two now.
        .target(
            name: "SlopDeskSlate",
            dependencies: [
                // `AgentReading` / `NerdSymbolFont` / `TabBadgeReading` — the readings this ladder
                // resolves an ink and a silhouette for, decided one floor further down.
                "SlopDeskClientCore",
                "SlopDeskAgentDetect",
                "SlopDeskWorkspaceCore",
                // The marks are named as `SFSymbol`s, so both renderers ask for the same artwork.
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
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
                // docs/56: the design floor both halves render.
                "SlopDeskSlate",
                // docs/56: the simulator + Android panel domain, which this target now only RENDERS.
                "SlopDeskDevicePanels",
                // docs/56: the presentation logic this target now only DRAWS.
                "SlopDeskClientCore",
                // The one `write(2)`-until-done loop, for the control server's replies.
                "SlopDeskTTY",
                // The `ShellQuoting` face — one door for every place that types a path into a live
                // shell. Transitive via WorkspaceCore, but a direct `import` needs it declared here
                // (same rationale as Protocol/Inspector/Transport below).
                "SlopDeskWorkspaceModel",
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
                // CLICore is a headless internal target (deps Protocol/WorkspaceCore/AgentDetect, all already
                // below ClientUI) — no HW deps, no cycle.
                "SlopDeskCLICore",
                // L8: external UI libraries (chrome). Cross-platform: SwiftUIIntrospect (reach AppKit
                // under SwiftUI), SFSafeSymbols (type-safe SF Symbols). (Pow was dropped with the last
                // `changeEffect` — MERIDIAN L3: status dots hard-cut, nothing glows at rest.)
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
                // PATH 4: the client-side file-transfer driver (`FileTransferClient`) the desktop
                // pane's dragging destination fires on a real file drop. Foundation+Network leaf, no
                // HW deps — does not widen the headless graph.
                "SlopDeskFileTransfer",
                // macOS-only: user-customizable global shortcuts + the recorder view.
                .product(
                    name: "KeyboardShortcuts",
                    package: "KeyboardShortcuts",
                    condition: .when(platforms: [.macOS]),
                ),
                // Type-safe UserDefaults — the `@Default(.key)` SwiftUI bindings in SettingsView (replacing
                // the stringly-typed `@AppStorage`). Same pure-Foundation `Defaults` product as the core.
                .product(name: "Defaults", package: "Defaults"),
                // `FuzzyMatcher` is a marshaller over `slopdesk_fuzzy_score` — fzf's `FuzzyMatchV2`
                // lives in `rust/slopdesk-fuzzy`, and every search field in the app ranks through it.
                "CSlopDeskFFI",
            ],

            linkerSettings: ffiCLibraries,
        ),

        // docs/56 stage C: the macOS APP SHELL. `Apps/ClientApp-macOS` links this and nothing else of
        // the UI; it is the only target that carries a macOS `@main`.
        //
        // Everything here is AppKit the way a Mac app is AppKit — `NSApplicationDelegate`, `NSWindow`
        // and its close gate, the `NSEvent` chord monitor's install site, the Dock tile, the satellite
        // windows, the menu bar — and NOT ONE `#if os(...)`. That absence is the point: a platform gate
        // inside a platform target means the file is in the wrong target (docs/56 §3).
        //
        // It sits ABOVE `SlopDeskClientUI` rather than beside it. Stage D rewrites the macOS surfaces in
        // AppKit and each one lands HERE as its SwiftUI original is deleted, so `SlopDeskClientUI`
        // drains from both ends: its macOS half moves up into this target, and what is left when the
        // last one goes is the phone's, which is then renamed `SlopDeskPhoneUI`. Until that day the two
        // shells share the SwiftUI view layer instead of each carrying a copy of it.
        .target(
            name: "SlopDeskMacUI",
            dependencies: [
                // The SwiftUI view layer both shells still stand on (Stage D drains it upward).
                "SlopDeskClientUI",
                // The design floor — the ONE ladder, in its native (NSColor/NSFont) spelling.
                "SlopDeskSlate",
                // `ClientComposition` — what the app IS, built once for both shells.
                "SlopDeskClientCore",
                "SlopDeskWorkspaceCore",
                "SlopDeskWorkspaceModel",
                // Live cell metrics for the `grid` window-size mode.
                "SlopDeskTerminal",
                // The peek card names the pending tool call the blocked agent is asking about, and
                // reads that agent's own status for the header's glyph.
                "SlopDeskInspector",
                "SlopDeskAgentDetect",
                // `MetadataClient` — the host RPC behind Open Quickly's Agents source.
                "SlopDeskProtocol",
                // Reach THIS scene's `NSWindow` from the SwiftUI `WindowGroup` (never an
                // `NSApplication.windows` scan).
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                // Fire-time reads of the Code Agent sound toggles in the attention sink.
                .product(name: "Defaults", package: "Defaults"),
                // The status marks and slot glyphs the navigator's rows draw are named as
                // `SFSymbol`s by `StatusPresentation`, and an `NSImage(systemSymbolName:)` needs the
                // name, not a stringly-typed guess at it.
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
            ],
        ),

        // docs/56 stage C: the iOS APP SHELL. `Apps/ClientApp-iOS` links this and nothing else of the
        // UI; it is the only target that carries an iOS `@main`.
        //
        // The whole target is guarded `#if os(iOS)` — the ONE allowed platform gate, because `swift
        // build` compiles every SwiftPM target on the host triple and this one has nothing to say
        // there. Inside that guard there is no second gate.
        //
        // The two shells ship the SAME product: every feature the Mac has, the phone and the iPad have,
        // laid out for the device. What is NOT owed is the same arrangement.
        .target(
            name: "SlopDeskPhoneUI",
            dependencies: [
                "SlopDeskClientUI",
                "SlopDeskSlate",
                "SlopDeskClientCore",
                "SlopDeskWorkspaceCore",
                "SlopDeskWorkspaceModel",
            ],
        ),

        // MARK: PATH 2 — GUI video path (Phase 4 / WF-9)

        // Cross-platform PURE wire format for the GUI video path: UDP frame packetizer/reassembler
        // (loss detect + recovery signalling), FEC (XOR parity, swappable for Reed-Solomon), cursor
        // side-channel codec, window-geometry codec, coordinate-mapping math (multi-monitor
        // Cocoa-flip + Retina), and the client->host input-event codec. ZERO platform dependency (no
        // ScreenCaptureKit/VideoToolbox/AppKit) → builds macOS + iOS, unit-testable in isolation.
        .target(
            name: "SlopDeskVideoProtocol",
            dependencies: ["SlopDeskArena", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

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
            // CSlopDeskFFI: the host's admission laws — the constant-QP AIMD and the recovery-IDR
            // token bucket — are `rust/slopdesk-video`, reached in process. Named directly rather
            // than inherited through SlopDeskVideoProtocol, so the link survives that target's deps
            // changing.
            // SlopDeskArena: the snapshot builder fills a text arena for `window_feed_pack`
            // (docs/55 §4c) and interns through the one implementation of that convention.
            dependencies: [
                "SlopDeskVideoProtocol", "CSlopDeskVirtualDisplay", "CSlopDeskFFI", "SlopDeskArena",
            ],
            // macOS-only: SCStream + VTCompressionSession + AX/CGEvent are macOS APIs.
            // (SlopDeskVideoProtocol stays cross-platform; only this host layer is gated.)
            swiftSettings: [],

            linkerSettings: ffiCLibraries,
        ),

        // macOS + iOS client decode + Metal render + client-side cursor. USES VideoToolbox (decode) /
        // Metal / CoreVideo / QuartzCore. COMPILED + reviewed; decode is MEASURED-safe (~0.9-1.1ms
        // synchronous) but per the hang-safety rule NO VTDecompressionSession is instantiated in tests.
        // CSlopDeskFFI: the client's presentation-depth laws — the one-way-delay spike detector and
        // the promote/demote policy — are `rust/slopdesk-video`'s `pacer_depth` through the door.
        .target(
            name: "SlopDeskVideoClient",
            dependencies: ["SlopDeskVideoProtocol", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // MARK: PATH 4 — dedicated file-transfer channel

        // Drag-and-drop file upload over its OWN reliable TCP connection — NOT the terminal mux (a
        // bulk body would stall the PTY data channel) and NOT the lossy UDP video path. A 4th path
        // that shares nothing with the other three (the "do not merge" rule): its own frame decoder,
        // codec, receive FSM, name-sanitizer, disk sink, listener, and client. Foundation + Network
        // leaf (no other SlopDesk module). The NWListener server + NWConnection client are COMPILED +
        // reviewed; the pure core (codec/decoder/FSM/sanitizer/disk-sink) is exercised over a loopback
        // channel + fake sink (hang-safety: no live socket / real disk in XCTest for the serve path).
        // PATH 4's codec is `rust/slopdesk-dropd`'s `client` module through the FFI door, so the
        // one dependency this leaf has is the shim.
        .target(
            name: "SlopDeskFileTransfer",
            dependencies: ["SlopDeskArena", "SlopDeskNet", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // The `slopdesk-superd` <-> `slopdesk-hostd` contract: SCM_RIGHTS fd passing, the frame, the
        // message set, and the pane registry. A Darwin + Foundation LEAF with zero package
        // dependencies — it has to be, since BOTH the daemon that outlives everything and the host
        // that restarts constantly link it (docs/51).
        //
        // ⚠️ This is the ONE protocol here that must tolerate VERSION SKEW. The three wire paths are
        // golden-pinned at version 1 with no negotiation because both ends ship together; superd is a
        // LaunchAgent that outlives hostd's BUILD, so this one negotiates. Append-only, version in
        // `hello`, unknown verbs answered `unsupported` — see SupervisorProtocol's doc comment before
        // changing anything in here.
        .target(
            name: "SlopDeskSupervisor",
            dependencies: ["SlopDeskTTY", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // hostd's END of the `slopdesk-screend` protocol: the request encoder, the reply
        // decoder, and a pooled synchronous client. The VT parser, the renderer and the
        // overprint collapser it addresses live ONCE, in `rust/slopdesk-screend` — this target
        // deliberately contains no screen logic at all. Depends on SlopDeskSupervisor for the
        // single `AF_UNIX` connect + `sockaddr_un` validation (one implementation, not two).
        // CSlopDeskFFI: the screend wire's layouts are `rust/slopdesk-screenwire`, which screend
        // itself decodes with — so hostd's end of the frame is a marshaller, not a second copy.
        .target(
            name: "SlopDeskScreen",
            dependencies: ["SlopDeskSupervisor", "SlopDeskTTY", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // MARK: Executables

        // Headless host daemon (PTY + transport). Sources under Sources/slopdesk-hostd.
        // SlopDeskFileTransfer: the daemon stands up the PATH-4 file-transfer listener on
        // `terminalPort &+ 2` after the terminal + inspector servers (non-fatal on bind failure).
        .executableTarget(name: "slopdesk-hostd", dependencies: ["SlopDeskHost", "SlopDeskFileTransfer"]),

        // NOTE: the agent-control CLI (`slopdesk-ctl`) and its pure core (`SlopDeskCtlCore`) are
        // GONE from this graph — it is Rust now (`rust/slopdesk-ctl`, `docs/DECISIONS.md`). Its cost
        // was process startup and nothing else; the port removed 3 ms of it per agent invocation.
        // The two NDJSON line helpers the `slopdesk` CLI still needed moved to
        // `SlopDeskWorkspaceCore/Control/ClientControlProtocol.swift`.

        // PURE, testable core of the user-facing `slopdesk` CLI (E20): the global-flag parser
        // (`CLIArgs`), the `version` summary builder (`CLIVersion`), the per-shell completion
        // generator (`CLICompletions`), and (later WIs) list formatting / watch-progress / jump
        // resolution. No socket I/O, no exit — Foundation-only, unit-testable without an AF_UNIX
        // socket or a GUI (hang-safety rule). Reuses `ClientControlProtocol`'s NDJSON line protocol; reads
        // `SlopDeskProtocol` for the wire-version summary and `SlopDeskWorkspaceCore` for the
        // frecency/progress reuse seams.
        .target(
            name: "SlopDeskCLICore",
            // SlopDeskAgentDetect supplies `ClaudeStatus`, which `WatchClaudeOutcome` (WI-8) maps to
            // the `watch:claude` exit codes. It is a transitive dep via SlopDeskWorkspaceCore, but
            // declared here so the `import` is explicit.
            // CSlopDeskFFI: the flags, the completion scripts, the config file and the tables are
            // `rust/slopdesk-cli`'s — this module is their Swift face (docs/55 §4).
            dependencies: [
                "SlopDeskProtocol",
                "SlopDeskWorkspaceCore",
                "SlopDeskAgentDetect",
                "CSlopDeskFFI",
                // docs/49: `slopdesk sidecars` keeps the previous release's MANIFEST.json in the
                // Application Support container, because Homebrew replaces the Cellar wholesale and
                // the old manifest is gone by the time anything could read it. `SlopDeskAppSupport`
                // is that container. Transitive via SlopDeskWorkspaceCore; declared so the `import`
                // is explicit, like SlopDeskAgentDetect above.
                "SlopDeskVideoProtocol",
                // SlopDeskArena: the `(offset, length)` convention docs/55 §4c spells, both ways —
                // the CLI builds an arena for `cli_parse` and reads one back out of it.
                "SlopDeskArena",
            ],

            linkerSettings: ffiCLibraries,
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
                "SlopDeskCLICore", "SlopDeskVideoProtocol", "SlopDeskWorkspaceCore",
                // The one `write(2)`-until-done loop, for the control-socket request.
                "SlopDeskTTY",
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

        // (The differential-parity oracle for the detect engine is `slopdesk-screend explain` —
        // docs/52. It was a Swift executable target here only because the rule ladder was in Swift;
        // the ladder moved, so scripts/herdr-differential.py drives the Rust binary directly.)

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

        // SwipeNavStatus push probe: a headless client that mints a real display session against a
        // RUNNING videohostd, primes the cursor socket, and reports whether type-3 SwipeNavStatus
        // datagrams (the swipe-peel eligibility push) actually arrive — the runtime proof the
        // kicker→registry→scheduler→cursor-flow chain is alive, which has no host-side logging.
        // Diagnostic-only, sibling of slopdesk-fake-client. `swift run slopdesk-swipestatus-probe`.
        .executableTarget(name: "slopdesk-swipestatus-probe", dependencies: ["SlopDeskVideoProtocol"]),

        // Nav-history AX probe: runs the REAL `HostNavHistory` reader (toolbar/menu strategy,
        // per-window cache currency) against a live app and prints canGoBack/canGoForward per
        // beat — the runtime proof for the swipe-nav history gate that unit tests cannot give
        // (hang-safety bars process-external AX from XCTest). Needs Accessibility TCC.
        // Diagnostic-only. `swift run slopdesk-navhistory-probe [bundle-id] [--seconds N]`.
        .executableTarget(name: "slopdesk-navhistory-probe", dependencies: ["SlopDeskVideoHost"]),

        // VD-120Hz DE-RISK probe: creates a headless CGVirtualDisplay advertising a >60Hz mode and
        // reports the refresh rate WindowServer actually grants — the make-or-break for the
        // "beat-free 60fps via a 120Hz virtual-display capture source" plan (a 60Hz panel can never
        // oversample; a 120Hz VD source can). Diagnostic-only; GUI+WindowServer-attached at runtime.
        .executableTarget(name: "slopdesk-vd-probe", dependencies: ["SlopDeskVideoHost"]),

        // Micro-benchmark for the Swift-level hot paths (frame hash, GF region multiply, RS FEC).
        .executableTarget(
            name: "slopdesk-bench",
            dependencies: [
                "SlopDeskVideoProtocol", "SlopDeskProtocol", "SlopDeskFileTransfer",
                "SlopDeskInspector",
            ],
        ),

        // Snapshot-replay composer benchmark: times `TerminalReplaySnapshot.compose` (the cold
        // reattach state-transfer render) over synthetic build/test churn at realistic history
        // sizes — the instrument for "how long does a reattach stall on the compose".
        // `swift run -c release slopdesk-replay-bench [mib...]`.
        .executableTarget(name: "slopdesk-replay-bench", dependencies: ["SlopDeskHost"]),

        // Fuzzy-match benchmark + parity validator: drives the vendored `FuzzyMatcher` (the in-tree fzf
        // FuzzyMatchV2 port behind the command palette) against the REAL `fzf --filter` binary and a
        // Bitap (Fuse-style) baseline on a shared corpus — reports ranking parity (match-set + top-K
        // agreement) and throughput. macOS dev instrument: shells out to `fzf` when present (skips that
        // comparison otherwise), so it is NOT part of `swift test`. Depends on SlopDeskClientUI for
        // `FuzzyMatcher`. `swift run -c release slopdesk-fuzzybench [scaleN]`.
        .executableTarget(name: "slopdesk-fuzzybench", dependencies: ["SlopDeskClientCore"]),

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
                "SlopDeskWorkspaceModel",
                "SlopDeskVideoProtocol",
                "SlopDeskVideoHost",
                "SlopDeskVideoClient",
            ],
        ),

        // MARK: Tests

        // The clock every ceiling bench measures with. A TEST-ONLY library — it lives under
        // `Tests/`, no product depends on it, and only bench targets do. It exists because four
        // copies of "time this loop" drifted into four ceilings that meant four different things,
        // and because the wall clock they all used made a bench under `make quick`'s parallel load
        // fail for reasons that had nothing to do with the code under it.
        .target(name: "SlopDeskBenchClock", path: "Tests/SlopDeskBenchClock"),

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

        .testTarget(name: "SlopDeskProtocolTests", dependencies: ["SlopDeskProtocol", "SlopDeskBenchClock"]),
        // W7: the pure detection core — state-machine transitions (incl. injected-clock
        // timeouts, idempotent/out-of-order signals), the conservative manifest matcher,
        // and the rollup most-urgent order. No GUI/socket/PTY — signals are fed directly.
        // `exclude: ["Fixtures"]` — the hook bodies are read off disk via `#filePath`, not bundled.
        .testTarget(
            name: "SlopDeskAgentDetectTests",
            dependencies: ["SlopDeskAgentDetect"],
            exclude: ["Fixtures"],
        ),
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
        // The workspace VALUE MODEL's own suite. Depends on the leaf and NOTHING else — that is the
        // point: if a tree/canvas/parser test needs a client, a transport or a store to compile, the
        // type under test does not belong in the leaf target.
        .testTarget(
            name: "SlopDeskWorkspaceModelTests",
            // `SlopDeskBenchClock` is the shared bench clock, test-only; it does not weaken the
            // "depends on the leaf and NOTHING else" rule above, because it is not a product.
            dependencies: ["SlopDeskWorkspaceModel", "SlopDeskBenchClock"],
        ),

        .testTarget(
            name: "SlopDeskWorkspaceCoreTests",
            dependencies: [
                "SlopDeskWorkspaceCore",
                "SlopDeskWorkspaceModel",
                "SlopDeskClient",
                "SlopDeskTransport",
                "SlopDeskHost",
                "SlopDeskInspector",
                "SlopDeskClaudeCode",
                "SlopDeskAgentDetect",
                "SlopDeskTerminal",
                "SlopDeskVideoProtocol",
                "SlopDeskBenchClock",
            ],
        ),
        // docs/56: the DESIGN FLOOR's own suite, moved out of `SlopDeskClientUITests` with the code.
        // Everything here is a VALUE the two renderers share — that the two spellings of a rung are
        // the same colour, that a project bed deals the same way twice, that the spinner's closed-form
        // integral really is its rate integrated, that a transcribed `d` string parses to the drawing
        // it was copied from. None of it mounts a view, which is exactly the line the target holds.
        .testTarget(
            name: "SlopDeskSlateTests",
            dependencies: [
                "SlopDeskSlate", "SlopDeskClientCore", "SlopDeskAgentDetect", "SlopDeskWorkspaceCore",
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
            dependencies: [
                "SlopDeskClientUI", "SlopDeskSlate", "SlopDeskWorkspaceCore", "SlopDeskProtocol",
                "SlopDeskTerminal",
            ],
        ),
        // docs/56 stage C: the macOS SHELL's own suite, moved out of `SlopDeskClientUITests` with the
        // code. All four are pure decisions the AppKit shims delegate to — should ⌘Q ask before
        // quitting, does the drain reply once and only once, does a `windowShouldClose` resolve, does
        // the chord monitor own the keyboard right now — so they run headlessly, without an `NSWindow`
        // (the key-window gate takes `AnyObject` for exactly that reason).
        .testTarget(
            name: "SlopDeskMacUITests",
            // `SlopDeskClientUI` is named because the chord suites drive the real `WorkspaceKeyDispatcher`
            // against seams the shared view target still owns (the code panel's first-responder hold).
            dependencies: [
                "SlopDeskMacUI", "SlopDeskClientUI", "SlopDeskSlate", "SlopDeskClientCore",
                "SlopDeskWorkspaceCore",
                "SlopDeskWorkspaceModel", "SlopDeskVideoProtocol",
                // `SlopDeskTransport` is named for ONE thing: the navigator snapshot mounts the real
                // column, which takes an `AppConnection`, which takes a `ConnectionRegistry`. The
                // fixture hands it one that always refuses, so no socket is ever opened.
                "SlopDeskTransport",
                // The band rollup's pixel probe draws the sidebar toggle and the search plate as
                // FOOTPRINTS (mounting the real ones would drag a store into a geometry fixture),
                // and both are named glyphs. Already transitive through `SlopDeskMacUI`; named here
                // for the same reason `SlopDeskClientUITests` names `SlopDeskTerminal`.
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
            ],
        ),

        // docs/56: the device panels' DOMAIN suite, moved out of `SlopDeskClientUITests` with the code
        // it covers. Every one of these already tested a wire format, a socket client, a gesture
        // recogniser or a device model — never a view — which is exactly why the code they cover could
        // leave the view target at all. `Network`/`CoreMedia` are named because two of the tests drive
        // an `NWConnection` framing seam and a `CMSampleBuffer` sink directly.
        .testTarget(
            name: "SlopDeskDevicePanelsTests",
            dependencies: ["SlopDeskDevicePanels", "SlopDeskProtocol", "SlopDeskTransport"],
        ),

        // docs/56: the client's presentation-logic suite, moved out of `SlopDeskClientUITests` with
        // the code it covers. What is left in the UI suite is what actually renders — a snapshot, a
        // layout, a mount — and the split is load-bearing rather than tidy: these run on a phone
        // build too, and a rule that only a Mac can test is a rule the iOS half will re-derive.
        .testTarget(
            name: "SlopDeskClientCoreTests",
            dependencies: [
                "SlopDeskClientCore", "SlopDeskWorkspaceCore", "SlopDeskWorkspaceModel",
                "SlopDeskProtocol", "SlopDeskClient",
            ],
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
        // PATH 4: the PURE file-transfer core — codec round-trip, streaming frame-decoder split/
        // partial/oversize/poison, the receive FSM (offer→chunk→finish happy path + chunk-before
        // -offer, byte overrun, over-cap, duplicate id, bad-name rejections), the path-traversal
        // name sanitizer, the collision-avoiding disk sink (in a temp dir), and the full serve↔client
        // upload over a LoopbackFileTransferChannel + fake sink. NO NWListener / live socket.
        .testTarget(name: "SlopDeskFileTransferTests", dependencies: ["SlopDeskFileTransfer"]),
        // The supervisor contract. A `socketpair(2)` is NOT a live listener — no bind, no accept, no
        // spawned daemon — so the hang-safety rule is satisfied while the load-bearing part (an fd
        // genuinely crossing a process-style boundary and still working) is exercised for real,
        // including against a live `openpty` master. Also pins the version-skew rules: an unknown
        // verb must DECODE and be answerable, and unknown fields must not fail a decode.
        .testTarget(name: "SlopDeskSupervisorTests", dependencies: ["SlopDeskSupervisor"]),
        .testTarget(name: "SlopDeskScreenTests", dependencies: ["SlopDeskScreen"]),
    ],
)
