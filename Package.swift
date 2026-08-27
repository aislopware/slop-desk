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
// AppKit joins them for the same reason and by the same mechanism. `slopdesk-apple-cursor` reads the
// displayed cursor and renders its PNG, and the one thing in that path the linker has to resolve is
// `NSDeviceRGBColorSpace` — an extern CONSTANT, not a class. Classes cost nothing here: `objc2` looks
// them up through the runtime at first use, which is why the four `slopdesk-apple-*` crates before
// this one needed no framework naming at all. A constant is a symbol, and one object per crate means
// every product that calls any door needs it resolvable even though only the video host ever reads a
// cursor. `-dead_strip` removes what none of them reach.
// VideoToolbox, CoreMedia and CoreVideo join for a THIRD reason, and it is the one that bites
// hardest. `slopdesk-apple-vt` calls `VTCompressionSessionCreate` and the `CMBlockBuffer` readers —
// plain C FUNCTIONS, not classes and not constants, so nothing resolves them at runtime — and it names
// the three `kCVImageBuffer*_ITU_R_709_2` colour tags, which are extern constants like AppKit's above.
// `objc2-video-toolbox` carries its own `#[link(name = "VideoToolbox", kind = "framework")]`, but that
// attribute travels in the rlib's metadata and does NOT survive `xcodebuild -create-xcframework`,
// which packages a plain static archive. Naming them here is the only thing that puts them on the link
// line. They were implicit until the encoder collapsed: `VideoEncoder.swift` used to
// `import VideoToolbox` itself.
//
// And those three are UNGATED, which is the one line here that is not macOS-only. The crate's two
// framework areas have opposite audiences — only the host compresses, every client DECOMPRESSES —
// so `slopdesk-apple-vt` ships on the iOS slices too, and `VTDecompressionSessionCreate` is as much
// a bare C function there as its compression twin is here. The failure this prevents is the one
// `docs/57` §5 warns about, and it is not subtle: four undefined symbols at the FINAL link of the
// iOS app, long after both the crate and `just ffi` are green, because `import VideoToolbox` used
// to be what put the framework on that link line and `VideoDecoder.swift` no longer imports it.
let ffiCLibraries: [LinkerSetting] = [
    .linkedLibrary("iconv", .when(platforms: [.macOS])),
    .linkedFramework("Security", .when(platforms: [.macOS])),
    .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
    .linkedFramework("AppKit", .when(platforms: [.macOS])),
    .linkedFramework("VideoToolbox"),
    .linkedFramework("CoreMedia"),
    .linkedFramework("CoreVideo"),
    // ScreenCaptureKit, for the AppKit reason above and macOS-only for the strongest reason in this
    // list: the framework does not exist on iOS at all. `slopdesk-apple-sck` reads
    // `SCStreamFrameInfoStatus` — an extern CONSTANT, not a class — to tell a frame carrying new
    // pixels from the framework's idle-skip, and one object per crate means every macOS product that
    // calls any door needs it resolvable even though only the video host ever captures anything.
    // `-dead_strip` removes what none of them reach. It was implicit until the capturer collapsed:
    // `WindowCapturer.swift` used to `import ScreenCaptureKit` itself.
    .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
    // The audio row's two, and UNGATED for the VideoToolbox reason: `slopdesk-apple-audio` splits
    // its encoder from its decoder the way `slopdesk-apple-vt` does, so both iOS slices link the
    // decoder half. AudioToolbox carries the `AudioConverter` calls AND — through its AudioUnit
    // umbrella — the `AudioComponentFindNext`/`AudioUnitRender` pair `cpal` opens the output stream
    // with; CoreAudio carries the device enumeration. These were implicit until the audio row
    // collapsed: `AudioStreamEncoder.swift`, `AudioStreamDecoder.swift` and
    // `AudioPlaybackEngine.swift` each used to `import AudioToolbox` themselves.
    //
    // `AudioUnit` is NOT listed, and the omission is load-bearing rather than an oversight: macOS
    // ships a standalone `AudioUnit.framework` and iOS does not — it is a header group inside
    // AudioToolbox there — so naming it links on the Mac and fails the iOS app's FINAL link with
    // `ld: framework 'AudioUnit' not found`, long after `just ffi` and every test are green. This is
    // the `docs/57` §5 failure mode again, in its other direction.
    .linkedFramework("AudioToolbox"),
    .linkedFramework("CoreAudio"),
]
let package = Package(
    name: "SlopDesk",
    platforms: [
        // PackageDescription 6.2 makes the `.v26` enum available for the macOS 26 / iOS 26 floor.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        // No `SlopDeskHost` and no `CSlopDeskFFI` product. `docs/60` stage F.9 deleted the Swift
        // host outright — `slopdesk-hostd` is `rust/slopdesk-hostd`, a cargo binary — and the only
        // thing that ever needed the doors vended on their own was the menu-bar app that supervised
        // it. The host is driven from the CLI now, so no Xcode target imports a Rust door directly.
        .library(name: "SlopDeskProtocol", targets: ["SlopDeskProtocol"]),
        .library(name: "SlopDeskTransport", targets: ["SlopDeskTransport"]),
        .library(name: "SlopDeskClient", targets: ["SlopDeskClient"]),
        .library(name: "SlopDeskTerminal", targets: ["SlopDeskTerminal"]),
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
        // docs/56 stage C: the two APP SHELLS. Each Xcode app target links exactly one of them, and
        // neither imports the other — the products exist so the two `@main`s can be linked apart.
        .library(name: "SlopDeskMacUI", targets: ["SlopDeskMacUI"]),
        .library(name: "SlopDeskPhoneUI", targets: ["SlopDeskPhoneUI"]),
        // PATH 2 (GUI video path, Phase 4 / WF-9).
        .library(name: "SlopDeskVideoProtocol", targets: ["SlopDeskVideoProtocol"]),
        .library(name: "SlopDeskVideoHost", targets: ["SlopDeskVideoHost"]),
        .library(name: "SlopDeskVideoClient", targets: ["SlopDeskVideoClient"]),
        // …and its two VIEW halves (docs/56 §3, the video carve). `SlopDeskVideoClient` is the decode
        // + pace + transport engine and holds no views; these are the AppKit and UIKit surfaces over
        // it, and each app shell links exactly one — the same shape as the two UI shells above, for
        // the same reason. Products rather than bare targets because the shells are Xcode targets
        // consuming this package by `product:`.
        .library(name: "SlopDeskVideoClientMac", targets: ["SlopDeskVideoClientMac"]),
        .library(name: "SlopDeskVideoClientPhone", targets: ["SlopDeskVideoClientPhone"]),
        // PATH 4 (dedicated drag-drop file-transfer channel).
        .library(name: "SlopDeskFileTransfer", targets: ["SlopDeskFileTransfer"]),
        // NO executable product at all any more, and that is the whole shape of `docs/60` F.9.
        // `slopdesk-hostd` was the last one — a product rather than just a target because the
        // release tarball needs `swift build --product`, which only exists for a declared one — and
        // the daemon is now `rust/slopdesk-hostd`, built by `just hostd` out of
        // `rust/target/release`. `slopdesk` and `slopdesk-ctl` went the same way earlier
        // (`rust/slopdesk-cli`, `rust/slopdesk-ctl`, built by `just cli`/`just ctl`). What is left
        // below is executableTargets only, every one a dev or bench tool: `swift build` builds them
        // and nothing ships them.
    ],
    // External UI deps — attach ONLY to the UI targets so the headless core + wire/codec/controller
    // targets stay dependency-free (`swift test` / golden never fetch). Trades "clean checkout builds
    // with no prerequisite" for SPM resolution; versions pinned in Package.resolved.
    // `KeyboardShortcuts` left with the settings GUI (docs/58): its only caller was the chord
    // recorder, and a config file has no recorder.
    dependencies: [
        .package(url: "https://github.com/siteline/swiftui-introspect.git", from: "26.0.1"),
        .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols.git", from: "7.0.0"),
        // Type-safe UserDefaults for the global `SettingsKey` namespace. Depend ONLY on the `Defaults`
        // product — the macro/swift-syntax targets (`DefaultsMacros`) are not linked. Exempt from the
        // "UI deps attach only to ClientUI" rule: it's not UI, and lands on the headless
        // `SlopDeskWorkspaceCore` only. Since the settings GUI was deleted (docs/58) it holds STATE
        // and nothing else — four keys: the code sidebar's collapse + width, the opened code projects
        // and the saved window frame. Every SETTING is `config.toml`, read through `AppConfig`.
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

        // The system pasteboard ↔ `MetadataCodec.ClipboardClip` conversion, both directions, for the
        // CLIENT end. The host end left this graph with `docs/60` stage F — it is
        // `rust/slopdesk-hostserver/src/clipsync.rs` over `slopdesk-apple-pasteboard` now — so what
        // this target answers for is the Mac app's `NSPasteboard` and the phone's `UIPasteboard`,
        // live on both triples rather than compiling empty on one. Still a leaf below
        // SlopDeskProtocol, which is the wire and has no business importing AppKit.
        .target(name: "SlopDeskPasteboard", dependencies: ["SlopDeskProtocol"]),

        // The Rust logic the Swift clients call in-process, as three arm64 static slices.
        //
        // Built by `just ffi` — `slopdesk-gate ffi`, which any `just build`/`test`/`check` runs first — and
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

        // NOTE: the macOS host (`SlopDeskHost`) and the `slopdesk-hostd` executableTarget are GONE
        // from this graph. `docs/60` stage F ported the daemon whole — PTY relay, mux session,
        // workspace document, inspector server, agent fold, the sidecar seams — into the seven
        // `rust/slopdesk-host*` crates, and stage F.9 deleted the Swift, per `CLAUDE.md`'s
        // one-implementation rule. What survives here is the CLIENT half of each seam and nothing
        // else: `SlopDeskPasteboard` is the clip conversion the sync engine reads,
        // `SlopDeskWorkspaceModel` the value model the client mirrors the host document into.
        // Batch B took the last two host-side targets with it — see the NOTE further down.

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
        // `CSlopDeskFFI` is not a step back from that. It is the static archive `just ffi` builds
        // (docs/55), the same one hostd and both clients already link, and it carries the SOLVERS this
        // module used to hold a second copy of — focus, send-keys, the sidebar's ordering. The leaf is
        // still a leaf: it names no other target here, and hostd links the archive regardless.
        // `SlopDeskAgentDetect` arrived with the READINGS below and does not break the rule above: its
        // own dependency list is `CSlopDeskFFI` and nothing else, and hostd names it directly already
        // (see its block), so the daemon graph is the same graph it was.
        .target(
            name: "SlopDeskWorkspaceModel",
            dependencies: ["SlopDeskArena", "CSlopDeskFFI", "SlopDeskAgentDetect"],
            linkerSettings: ffiCLibraries,
        ),

        // The bundled FACES: the Symbols Nerd Font (the SAME fallback face ghostty gives the terminal
        // grid) and JetBrains Mono (the face libghostty falls back to when "SF Mono" does not resolve,
        // which on a stock system it does not). Foundation + CoreText, no package dependency, and the
        // 2.9 MB of TTF is the whole reason it is a target rather than a file.
        //
        // It used to live in `SlopDeskClientCore`, and could not stay there once `SlopDeskSlate`
        // needed it: the nerd splice reads `NerdSymbolFont.registered`, which is a `Bundle.module`
        // lookup, so the TYPE cannot be split from the RESOURCE. The obvious sink — the workspace
        // value model — is linked by `slopdesk-hostd`, the `slopdesk` CLI and two bench targets, and a
        // daemon's value-model leaf is the wrong home for a font payload even though `Bundle.module`
        // is lazy and none of them would ever touch it. A leaf that only the two shells, the design
        // floor and the presentation layer link keeps the bytes where they are drawn.
        //
        // MIT / OFL-1.1, licences beside the TTFs. The code sidebar injects the same bytes as
        // @font-face data URIs — the webview's WebContent process cannot see a `CTFontManager`
        // process-scope registration — which is why the URLs are public API here and not just the
        // registration.
        // ⚠️ IT NAMES `CSlopDeskFFI` FOR ONE TABLE, and the table is why. `isPrivateUse` classifies
        // the codepoints this face exists to draw, and `rust/slopdesk-sanitize` classifies the SAME
        // codepoints to strip them for an agent — one Unicode fact, two opposite uses. It was typed
        // on both sides until 2026-08-26 and the copies disagreed about plane 16, so the ranges now
        // cross once per process through `slopdesk_private_use_ranges` and the predicate stays local.
        // The edge widens no graph: every target that links this one already links the archive.
        .target(
            name: "SlopDeskFontFaces",
            dependencies: ["CSlopDeskFFI"],
            resources: [.copy("Resources/Fonts")],
            linkerSettings: ffiCLibraries,
        ),

        // Shared client: connection mgr, reconnect, input encoding. (WF-4.)
        // CSlopDeskFFI: the DECISIONS here — which output seq is new, what may be acked, whether a
        // transport may be adopted, how long the next retry waits — are `slopdesk_clientsession`.
        // The actor keeps its transport, its four background tasks and its inbox; what came out is
        // the table of cases underneath them, whose every failure is silent rather than visible.
        .target(name: "SlopDeskClient", dependencies: ["SlopDeskTransport", "SlopDeskProtocol", "CSlopDeskFFI"]),

        // TerminalSurface protocol + HeadlessTerminalSurface. The libghostty-backed GhosttySurface
        // lives in the GUI app target (WF-5) and conforms to the same protocol.
        //
        // CSlopDeskFFI: the GEOMETRY here — where a cell span draws, where a grid the client did not
        // choose is letterboxed — is `slopdesk_terminal::geometry`. It was the one drift pair docs/55
        // §8 left deliberately open, because `rect` alone did not justify linking an archive into a
        // target whose whole dependency list was `SlopDeskProtocol`. The letterbox beside it did.
        .target(
            name: "SlopDeskTerminal",
            dependencies: ["CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

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
        // launch env + auth resolution are the daemon's half of the WF-7 seam and are Rust.
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
                // The client's own pasteboard↔clip conversion. The host's half is Rust
                // (`slopdesk-hostserver`'s `clipsync`), so the two ends agree by the WIRE and by
                // `clipsync.rs`'s four restated rules — not by sharing a file any more.
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
                // `ffiAnswerText`/`ffiLend` — the simulator's route table and its input dialect are
                // delivery doors, and docs/55 §4's retry is spelled once for the whole tree.
                "SlopDeskArena",
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
        // The files that name a framework name it as an ACTUATOR, not a view:
        // `SecureKeyboardEntryController` (Carbon `EnableSecureEventInput` + the app-frontmost edge),
        // `SystemKeyCaptureController` (the immersive `CGEvent` tap), `CodeSidebarFontSchemeHandler`
        // (a `WKScriptMessageHandler`) and `WorkspaceControlBackend` (`NSFontManager`, for
        // `font list`). A framework call is not a view; a `some View` is — which is also why the
        // count above is no longer spelled: it was wrong before `SystemKeyCaptureController`
        // descended, and a number maintained beside a list is a number that goes stale.
        .target(
            name: "SlopDeskClientCore",
            dependencies: [
                // The store, the connection, the settings keys, the terminal — what this layer
                // presents.
                "SlopDeskWorkspaceCore",
                // Pane specs, `PaneID`, `ShellQuoting`.
                "SlopDeskWorkspaceModel",
                // `TerminalCellMetrics` / `TerminalViewportSnapshotting` — the cell-grid decorations
                // (the ⌘-hold underline, the copy-mode block cursor, the prompt-jump flash) are pure
                // geometry over the viewport seam, so the DECISION lives here and only the drawing is
                // per-framework. Transitive via WorkspaceCore, but a direct `import` needs it declared
                // here (same rationale as Protocol/Inspector/Transport).
                "SlopDeskTerminal",
                // The palette + the rail read host metadata (process / port / dir / git-file).
                "SlopDeskProtocol",
                // The rail's rows and the palette's agent entries are keyed by agent state.
                "SlopDeskAgentDetect",
                // `PendingToolSummary` — the todo SCENT a working row's tooltip carries.
                "SlopDeskInspector",
                // `SessionResumeOutcome` — the fresh-vs-resumed reconnect verdict a toast reports.
                "SlopDeskClient",
                // The client control server answers over a mux channel and writes with `write(2)`.
                "SlopDeskTransport",
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
                // The bundled faces. They moved OUT of this target with `NerdSymbolFont` (which the
                // design floor reads and so had to descend); the code sidebar's @font-face dressing
                // and the titlebar's symbol strip still ask for them from here.
                "SlopDeskFontFaces",
            ],
            linkerSettings: ffiCLibraries,
        ),

        // docs/56: the DESIGN FLOOR. It exists because `SlopDeskClientUI` was the DRAINING target and
        // the token ladder could not ride its rename: `SlopDeskMacUI` reads ~200 of these constants,
        // and an AppKit target importing the phone's would be exactly the common view ancestor
        // docs/56 §3 forbids. So the floor is its own target, BELOW both halves. The rename landed in
        // increment 63 and the floor did not move, which is the whole of why it was carved out.
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
        // It reads TEN vocabularies from below and used to reach every one of them through
        // `SlopDeskClientCore`, which put the design-token floor ABOVE the presentation layer, the
        // transport, the file-transfer channel and the CLI's core — a target invalidated by a
        // transport change. The readings themselves had no such tie: `AgentReading`/`AgentInk`,
        // `PaneStatusPill`, `TabBadgeReading`/`AttentionRole`/`CommandOutcome`, `PaneDropRegister`,
        // `TabBadgeKind`, `GitInk`, `ConnectionAlarm` and `ToastMarkRung` are enums over a status and
        // a badge, so they descended to `SlopDeskWorkspaceModel` and the floor came down with them
        // (closure 19 → 4, level 7 → 3). The two that could NOT descend are named in their own
        // files: `TabBadgeResolver` needs the store's badge gates, `RailRowsBuilder` needs a
        // `WorkspaceStore`.
        .target(
            name: "SlopDeskSlate",
            dependencies: [
                // `AgentReading` / `TabBadgeReading` / `PaneStatusPillInk` — the readings this ladder
                // resolves an ink and a silhouette for, decided one floor further down.
                "SlopDeskWorkspaceModel",
                "SlopDeskAgentDetect",
                // `NerdSymbolFont.registered` — the nerd splice's AppKit half asks whether the
                // bundled face resolved before it splices a run into it.
                "SlopDeskFontFaces",
                // The marks are named as `SFSymbol`s, so both renderers ask for the same artwork.
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
            ],
        ),

        // docs/56 stage C: the iOS APP SHELL, and THE FOLD LANDED HERE (increment 63). `Apps/ClientApp-iOS`
        // links this and nothing else of the UI; it is the only target that carries an iOS `@main`.
        //
        // It used to be two targets. `SlopDeskClientUI` was the shared SwiftUI view layer both shells
        // rendered, and `SlopDeskPhoneUI` was a five-line scene sitting on top of it. Stage D rewrote
        // every macOS surface in AppKit and each one landed in `SlopDeskMacUI` as its SwiftUI original
        // was deleted, so the shared target drained from both ends until nothing in it was shared —
        // at which point "the phone's views" and "the phone's scene" were two names for one thing.
        // Increment 61 cut the last dependency edge, 62 cut the last test edge, and this target is
        // what the two of them collapsed into. There is no draining floor left to drain.
        //
        // The two shells ship the SAME product: every feature the Mac has, the phone and the iPad have,
        // laid out for the device. What is NOT owed is the same arrangement.
        //
        // Every file is guarded `#if os(iOS)` — the ONE allowed platform gate (docs/56 §3), because
        // `swift build` compiles every SwiftPM target on the host triple and this one has nothing to
        // say there. Inside that guard there is no second gate.
        .target(
            name: "SlopDeskPhoneUI",
            dependencies: [
                "SlopDeskWorkspaceCore",
                // docs/56: the design floor both halves render.
                "SlopDeskSlate",
                // docs/56: the simulator + Android panel domain, which this target now only RENDERS.
                "SlopDeskDevicePanels",
                // docs/56: the presentation logic this target now only DRAWS.
                "SlopDeskClientCore",
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
                // The bundled nerd face, for `Text.nerdAware`'s SwiftUI splice.
                "SlopDeskFontFaces",
                // L8: external UI libraries (chrome). Cross-platform: SwiftUIIntrospect (reach AppKit
                // under SwiftUI), SFSafeSymbols (type-safe SF Symbols). (Pow was dropped with the last
                // `changeEffect` — MERIDIAN L3: status dots hard-cut, nothing glows at rest.)
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
                // PATH 4: the client-side file-transfer driver (`FileTransferClient`) the desktop
                // pane's dragging destination fires on a real file drop. Foundation+Network leaf, no
                // HW deps — does not widen the headless graph.
                "SlopDeskFileTransfer",
                // Type-safe UserDefaults — the `@Default(.key)` SwiftUI bindings over the four STATE
                // keys that survived the settings teardown. Same pure-Foundation product as the core.
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
        // IT SAT ABOVE `SlopDeskClientUI` UNTIL INCREMENT 61, AND NOW IT DOES NOT DEPEND ON IT AT ALL.
        // Stage D rewrote the macOS surfaces in AppKit and each one landed HERE as its SwiftUI original
        // was deleted, so `SlopDeskClientUI` drained from both ends: its macOS half moved up into this
        // target, and what is left is the phone's. The last edge was the pane canvas, reached two ways
        // — hosted in the content column and hosted in a satellite window — and wave R's R11 and R12
        // closed both.
        //
        // THE EDGE IS CUT IN THE MANIFEST, not just in the imports, and that is the difference between
        // a convention and a fact. A `check-supervisor` census of `import` lines is a good ratchet and
        // it is still there; a dependency the graph does not contain is a line that cannot compile. The
        // fold (`SlopDeskClientUI` → `SlopDeskPhoneUI`) landed in increment 63, unblocked by this.
        .target(
            name: "SlopDeskMacUI",
            dependencies: [
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
        //
        // The private `CGVirtualDisplay*` classes used to need a clang-module shim target here, to
        // declare four `@interface`s and `weak_import` them. They do not any more: they are
        // Objective-C CLASSES in the PUBLIC CoreGraphics framework, so
        // `rust/slopdesk-apple-cgvirtualdisplay` reaches them by NAME through the Objective-C
        // runtime — which makes the linkage attribute and the `NSClassFromString` gate one lookup —
        // and the whole area arrives through `CSlopDeskFFI` with everything else. Nothing links
        // them, so there is no `linkerSettings` row to keep either.
        .target(
            name: "SlopDeskVideoHost",
            // CSlopDeskFFI: the host's admission laws — the constant-QP AIMD and the recovery-IDR
            // token bucket — are `rust/slopdesk-video`, reached in process. Named directly rather
            // than inherited through SlopDeskVideoProtocol, so the link survives that target's deps
            // changing.
            // SlopDeskArena: the snapshot builder fills a text arena for `window_feed_pack`
            // (docs/55 §4c) and interns through the one implementation of that convention.
            dependencies: [
                "SlopDeskVideoProtocol", "CSlopDeskFFI", "SlopDeskArena",
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
            // `SlopDeskArena` is SPELLED, not inherited. `VideoClientSessionLogic.swift` imports it
            // directly, and until the video carve this target compiled only because
            // `SlopDeskVideoProtocol` happens to pull it in — §4c's convention is that a target which
            // crosses the arena boundary names it. check-supervisor asserts exactly that, and it had
            // been passing on a coincidence: its `grep -A 24` window started at the `.library(…)`
            // PRODUCT line and ran far enough to catch a NEIGHBOUR's `SlopDeskArena`. Adding two
            // product lines for the halves pushed that coincidence out of the window and the gate
            // reported what had been true all along.
            dependencies: ["SlopDeskVideoProtocol", "SlopDeskArena", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),

        // THE TWO VIEW HALVES of the video pane (docs/56 §3, the video carve). Until this split
        // `VideoWindowView.swift` was a 2,898-line file whose middle 2,514 lines were an
        // `#if os(macOS)` / `#elseif os(iOS)` two-armed conditional: an AppKit implementation and a
        // UIKit one, linked by both shells, with a live parity gap hiding in the fold (the swipe-peel
        // chip was mounted on both platforms and driven on one).
        //
        // ⚠️ NEITHER OF THESE IS A DEPENDENCY OF `SlopDeskMacUI` / `SlopDeskPhoneUI`, and that is the
        // whole reason they are separate targets rather than folders inside the two UI halves. The
        // `VideoWindowFactory` seam (SlopDeskWorkspaceCore) exists so the view layer never NAMES a
        // VideoToolbox/Metal type — putting these surfaces in the UI targets would pull both
        // frameworks into the headless `swift build`/test graph, which is the exact property the seam
        // was built to hold. Each app shell links its own half and registers the factory; the UI
        // targets go on seeing an `AnyView` and an `NSView`.
        .target(
            name: "SlopDeskVideoClientMac",
            dependencies: ["SlopDeskVideoClient", "SlopDeskVideoProtocol", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
        ),
        // iOS-ONLY, and it declares that the way every `SlopDeskPhoneUI` file does: one whole-file
        // `#if os(iOS)` per file. SwiftPM compiles every target on the host triple, so on macOS this
        // one compiles to nothing — which is what lets it live in the same package as its Mac twin
        // without a platform condition here.
        .target(
            name: "SlopDeskVideoClientPhone",
            dependencies: ["SlopDeskVideoClient", "SlopDeskVideoProtocol", "CSlopDeskFFI"],
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

        // NOTE: `SlopDeskSupervisor` and `SlopDeskScreen` are GONE from this graph, with the four
        // `slopdesk_supervisor_*` FFI modules that existed only to serve them (`docs/60` Batch B).
        // They were hostd's ends of the superd and screend wires, and hostd is `rust/slopdesk-hostd`
        // now: it dials superd through `slopdesk-superclient` and screend through
        // `slopdesk-screenclient`, in-process, with no C boundary in between. Nothing in this package
        // had imported either target since stage F.9 — they compiled, tested green, and were a second
        // spelling of two protocols whose only real spelling is `slopdesk-superwire` and
        // `slopdesk-screenwire`. That is the drift `CLAUDE.md`'s one-implementation rule names.

        // MARK: Executables

        // NOTE: the agent-control CLI (`slopdesk-ctl`) and its pure core (`SlopDeskCtlCore`) are
        // GONE from this graph — it is Rust now (`rust/slopdesk-ctl`, `docs/DECISIONS.md`). Its cost
        // was process startup and nothing else; the port removed 3 ms of it per agent invocation.
        // The two NDJSON line helpers the `slopdesk` CLI still needed moved to
        // `SlopDeskWorkspaceCore/Control/ClientControlProtocol.swift`.

        // NOTE: the user-facing `slopdesk` CLI and its pure core (`SlopDeskCLICore`) are GONE from
        // this graph too — both are Rust now (`rust/slopdesk-cli`, `docs/DECISIONS.md`). The core
        // had already been a Swift FACE over that crate through `CSlopDeskFFI`; what the executable
        // added on top was a socket, a GUI launch and a thousand lines that ended in `exit()`, so no
        // test could reach any of it. The Rust `shell` module reaches the app through a `Control`
        // trait and RETURNS an exit code, which is what made the whole surface testable.

        // Interactive remote terminal client. Sources under Sources/slopdesk-client.
        .executableTarget(
            name: "slopdesk-client",
            // `CSlopDeskFFI` because the local terminal's raw mode, its window size and the
            // `write(2)`-until-done loop are `rust/slopdesk-posix`'s now — `main.swift` calls
            // `slopdesk_tty_*`/`slopdesk_fd_write_all` directly, so the shim has to be linked here
            // rather than reached transitively.
            dependencies: ["SlopDeskClient", "SlopDeskTransport", "SlopDeskTerminal", "CSlopDeskFFI"],
            linkerSettings: ffiCLibraries,
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
        // the ladder moved, so `slopdesk-herdr differential` drives the Rust binary directly.)

        // (The closed-loop video harness is `rust/slopdesk-loopback-validate` — `make
        // loopback-validate`, docs/46. It was a Swift executable target here only because the
        // encoder, the wire and every controller it drives were reachable from Swift; they are
        // Rust's now, so the harness drives them directly.)

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

        // Golden-vector dumper: regenerates the EMITTED half of `golden/golden_vectors.json` from the
        // `SlopDeskVideoProtocol` codecs and the pure controllers, so `slopdesk-gate golden` can diff
        // the live codecs against the committed bytes. Pure value types only — it constructs NO
        // SCStream and no encoder, so it touches neither GUI nor TCC.
        //
        // ⚠️ NEVER `>` OVER THE CORPUS. It also holds the FROZEN keys this target does not emit, and a
        // redirect drops every one of them — which `slopdesk-gate golden` then fails on by design.
        // Regenerate to a scratch file and merge the emitted keys in.
        //
        // ⚠️ Run with NO `SLOPDESK_*` env set, so the controllers resolve their default tunables. The
        // Rust crates pin those same defaults as compile-time consts, and an env-shifted run silently
        // records a corpus that no default build reproduces.
        .executableTarget(
            name: "slopdesk-corevectors",
            dependencies: [
                "SlopDeskProtocol",
                "SlopDeskWorkspaceModel",
                // `LoopbackWorkspaceDocument` — the Swift half of the versioning ladder
                // `workspaceDocumentVersioning` pins against `rust/slopdesk-hostserver`'s document.
                // The vector runs the REAL class rather than a transcription of its ~30 lines,
                // which is the only way the pin can catch this side drifting. No cycle (this is a
                // leaf executable) and no GUI: the target holds the workspace DOMAIN and links no
                // view framework.
                "SlopDeskWorkspaceCore",
                "SlopDeskVideoProtocol",
                "SlopDeskVideoClient",
            ],
        ),

        // MARK: Tests

        // The clock every ceiling bench measures with. A TEST-ONLY library — it lives under
        // `Tests/`, no product depends on it, and only bench targets do. It exists because four
        // copies of "time this loop" drifted into four ceilings that meant four different things,
        // and because the wall clock they all used made a bench under `just quick`'s parallel load
        // fail for reasons that had nothing to do with the code under it.
        .target(name: "SlopDeskBenchClock", path: "Tests/SlopDeskBenchClock"),

        // How a test says "run this on a machine whose config file says X". A TEST-ONLY library, for
        // `SlopDeskBenchClock`'s reasons and one more: it installs a PROCESS-GLOBAL (`AppConfig.current`)
        // and registers the restore itself, so the discipline is in one place instead of being
        // re-remembered in every suite that needs a non-default setting. Linking `XCTest`, it can
        // never be reached from a product.
        .target(
            name: "SlopDeskTestSupport",
            dependencies: ["SlopDeskVideoProtocol"],
            path: "Tests/SlopDeskTestSupport",
        ),

        // (No `SlopDeskCLITests`. Every suite it held tested a Swift face over `rust/slopdesk-cli`,
        // and both the face and the executable are gone — the tests live in that crate now, where
        // they can drive a whole subcommand's exit code against a canned response.)

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
        // (No `SlopDeskHostTests`. Every suite it held tested the Swift host `docs/60` F.9 deleted;
        // the seven `rust/slopdesk-host*` crates carry their own, where a decision can be driven
        // without standing up a listener.)
        .testTarget(
            name: "SlopDeskClientTests",
            dependencies: [
                "SlopDeskClient",
                "SlopDeskTransport",
                "SlopDeskTerminal",
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
        // WF-7 logic: the mode sniffer / dedup ring / input-box model. Byte-sequence + fixture
        // based; the sniffer tests feed the SAME stream at adversarial split boundaries and assert
        // identical results. (The env/auth half was the Swift host's and is Rust now.)
        .testTarget(
            name: "SlopDeskClaudeCodeTests",
            dependencies: ["SlopDeskClaudeCode", "SlopDeskProtocol"],
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
                "SlopDeskInspector",
                "SlopDeskClaudeCode",
                "SlopDeskAgentDetect",
                "SlopDeskTerminal",
                "SlopDeskVideoProtocol",
                "SlopDeskBenchClock",
                "SlopDeskTestSupport",
            ],
        ),
        // docs/56: the DESIGN FLOOR's own suite, moved out of `SlopDeskClientUITests` with the code.
        // Everything here is a VALUE the two renderers share — that the two spellings of a rung are
        // the same colour, that a project bed deals the same way twice, that the spinner's closed-form
        // integral really is its rate integrated, that a transcribed `d` string parses to the drawing
        // it was copied from. None of it mounts a view, which is exactly the line the target holds.
        // It named `SlopDeskClientCore` + `SlopDeskWorkspaceCore` only to reach the readings the ink
        // tables are keyed on (`PaneStatusPillInk`, `TabBadgeKind`, `ConnectionAlarm`,
        // `ToastMarkRung`, `CommandOutcome`). All five descended with the floor, so the suite now
        // names exactly what the target under test names.
        .testTarget(
            name: "SlopDeskSlateTests",
            dependencies: [
                "SlopDeskSlate", "SlopDeskAgentDetect", "SlopDeskWorkspaceModel",
            ],
        ),
        // ⚠️ THERE IS NO `SlopDeskPhoneUITests` HERE, and its absence is a consequence, not an omission
        // (docs/56, increment 63). `SlopDeskPhoneUI` is iOS-only — every file in it is inside the one
        // allowed `#if os(iOS)` — and SwiftPM compiles every target on the HOST triple. So on macOS
        // that module compiles to NOTHING, and a `@testable import` of it yields an empty module: a
        // suite here could only ever be a set of files that either fail to compile or, once guarded to
        // match, assert nothing. Neither is a test. The phone's suite lives in the iOS bundle that can
        // actually run it — `Apps/ClientApp-iOS/Tests/`, driven by `make check-ios-tests` on a booted
        // simulator — and that is the ONLY place a phone view is exercised.
        //
        // This is the same trap increment 62 found the first time: normalising the guard silently
        // removes files from `just check` while every gate stays green, because a test that does not
        // COMPILE INTO the run is indistinguishable from a test that ran and passed. The suite was
        // drained deliberately rather than guarded in place, so that nothing is left claiming coverage
        // it does not have.
        // docs/56 stage C: the macOS SHELL's own suite, moved out of `SlopDeskClientUITests` with the
        // code. All four are pure decisions the AppKit shims delegate to — should ⌘Q ask before
        // quitting, does the drain reply once and only once, does a `windowShouldClose` resolve, does
        // the chord monitor own the keyboard right now — so they run headlessly, without an `NSWindow`
        // (the key-window gate takes `AnyObject` for exactly that reason).
        .testTarget(
            name: "SlopDeskMacUITests",
            // ⚠️ `SlopDeskPhoneUI` IS NOT NAMED, and the omission is the point (docs/56 fold, F3). It
            // used to be, for a chord suite that drove `WorkspaceKeyDispatcher` against seams the
            // shared view target owned — that dispatcher is `SlopDeskMacUI`'s now, and increment 62
            // paid the last two crossings (the two snapshot rigs, which drew the phone's project bed
            // and field plate). With the edge cut in the MANIFEST, a rig reaching back for one
            // `some View` is a compile error rather than a convention, the same way the source edge
            // was made a fact in increment 61. The target was called `SlopDeskClientUI` when that edge
            // was cut; increment 63 renamed it, and the gate below follows the NAME rather than the
            // history, or it would guard a target that no longer exists.
            dependencies: [
                "SlopDeskMacUI", "SlopDeskSlate", "SlopDeskClientCore",
                "SlopDeskWorkspaceCore",
                "SlopDeskWorkspaceModel", "SlopDeskVideoProtocol", "SlopDeskTestSupport",
                // `SlopDeskTransport` is named for ONE thing: the navigator snapshot mounts the real
                // column, which takes an `AppConnection`, which takes a `ConnectionRegistry`. The
                // fixture hands it one that always refuses, so no socket is ever opened.
                "SlopDeskTransport",
                // The band rollup's pixel probe draws the sidebar toggle and the search plate as
                // FOOTPRINTS (mounting the real ones would drag a store into a geometry fixture),
                // and both are named glyphs. Already transitive through `SlopDeskMacUI`; named here
                // for the same reason the phone app's own bundle names `SlopDeskTerminal`.
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
            // `SlopDeskTerminal`: `TerminalFindBarModelTests` conforms an in-memory fake to
            // `TerminalSurface`/`TerminalSurfaceActions` (the scrollback-mirror + bind-action seam) to
            // drive the find bar's view-model headlessly. It arrived with increment 54.
            dependencies: [
                "SlopDeskClientCore", "SlopDeskWorkspaceCore", "SlopDeskWorkspaceModel",
                "SlopDeskProtocol", "SlopDeskClient", "SlopDeskTerminal", "SlopDeskTestSupport",
                // `NerdSymbolFontTests` and `CodeSidebarPageDressingTests` read the BUNDLE — the
                // registration and the three TTF URLs the sidebar injects as data URIs.
                "SlopDeskFontFaces",
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
    ],
)
