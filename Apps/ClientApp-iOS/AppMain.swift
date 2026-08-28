// AppMain (iOS) — the `@main` shell for `ClientApp-iOS`, over the `PhoneAppDelegate` in the
// `SlopDeskPhoneUI` library (docs/56 §2: each app links exactly one UI target and neither imports the
// other's). The macOS shell is its own file under `Apps/ClientApp-macOS`; the two were ONE file for as long
// as one `@main` could serve both scenes, which stopped being true when the scene split.
//
// The iOS half stopped being a SCENE at all in docs/62 stage A: there is no `App` and no `WindowGroup`
// here any more, only an app delegate and the scene delegate it names. What this file does is
// unchanged — the seam registrations below, then hand off — because the seams were never the scene's.
//
// The SEAM types (`TerminalRendererFactory`,
// `VideoWindowFactory`, `RemoteWindowDiscovery`, `RemoteWindowSummary`) live in
// `SlopDeskWorkspaceCore`; the seam registrations below stay PRESERVED — only the production renderer/video/discovery
// closures are injected here (the GUI app target links libghostty/SlopDeskVideoClientPhone; the
// cross-platform UI library cannot). This file is part of the xcodegen Xcode app target (NOT
// `swift build`).
import SlopDeskPhoneUI
import SlopDeskWorkspaceCore
import SwiftUI

// TWO MODULES, ONE GATE (docs/56 §3, the video carve). `SlopDeskVideoClient` is the platform-free
// engine — session, pipeline, connection, discovery — and `SlopDeskVideoClientPhone` is the UIKit
// HALF that draws it. The Mac shell links `SlopDeskVideoClientMac` instead and NEITHER half is
// importable from the other, which is the whole point: the two-armed `#if os(macOS)` file this
// replaced could not be read without holding both platforms in your head at once.
//
// The gate keys on the HALF, not the engine, because the half is what this shell actually names —
// and the half declares `SlopDeskVideoClient` as a dependency, so importable-half implies
// importable-engine. Gating on the engine would compile a shell that can reach the pipeline but not
// the view that mounts it.
#if canImport(SlopDeskVideoClientPhone)
import SlopDeskVideoClient
import SlopDeskVideoClientPhone
#endif

/// The `@main` entry for the iOS Xcode app target.
///
/// The whole app object lives in the `SlopDeskPhoneUI` SwiftPM library (`PhoneAppDelegate`); this
/// shell only attaches `@main` and, when the libghostty xcframework is present, registers the
/// production terminal renderer with ``TerminalRendererFactory``. Until the xcframework is
/// built, no factory is registered and the BUILD-STATUS placeholder shows (libghostty-only
/// policy — there is NO fallback VT renderer).
///
/// ## Wiring the production renderer (once the xcframework exists)
/// 1. Build it: `ThirdParty/ghostty/build-libghostty.sh` → `libghostty.xcframework`.
/// 2. Add the xcframework to this app target (project.yml `dependencies:` / Xcode "Frameworks").
/// 3. Add `ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift` +
///    the `CGhostty` module map to this target's sources/headers.
/// 4. Add a `GhosttyTerminalView: TerminalRenderingView` (a `UIViewRepresentable` /
///    `NSViewRepresentable` hosting a Metal view that owns a `GhosttySurface`, attaching it to
///    `model.surface` and feeding `model`'s output).
/// 5. Register it in `init()` below:
///        TerminalRendererFactory.shared = { model in AnyView(GhosttyTerminalView(model: model)) }
@main
struct ClientAppMain {
    // `main()` performs the five seam registrations (the load-bearing wiring that injects the production
    // renderer/video/discovery closures the cross-platform UI library cannot reference) and then hands the
    // process to ``PhoneAppDelegate``. This app target is NOT in `swift build`.
    static func main() {
        // PATH 1 (terminal, libghostty-only): register the production renderer. The
        // cross-platform `SlopDeskClientUI` view layer cannot reference `GhosttyTerminalView`
        // (it would force linking `libghostty.xcframework` + the `CGhostty` clang module
        // into the headless `swift build`/tests), so the GUI app target injects it here.
        //
        // GATED on `#if canImport(CGhostty)`: the `CGhostty` module exists only once the
        // xcframework is built and added to this app target (see the wiring notes above +
        // docs/21-HANDOFF.md). Until then this block compiles to NOTHING and the seam
        // shows the gated `BuildStatusPlaceholderView` (libghostty-only policy — no
        // fallback VT renderer).
        //
        // ONE CALL, BOTH SHAPES OF THE SEAM (docs/56 stage F, risk 2). `shared` is the SwiftUI shape
        // and iOS's ONLY shape — the phone has no `NSView` — and `nativeShared` is the AppKit one the
        // Mac canvas adds as a subview rather than burying under an `NSHostingView` that would claim
        // the hit-test over the one surface that must take every keystroke. Registering only half of
        // it ships a renderer whose terminal is the BUILD-STATUS placeholder, which is why the two
        // assignments live behind one installer in the embedder instead of being spelled here twice.
        #if canImport(CGhostty)
        MainActor.assumeIsolated { GhosttyRendererSeam.install() }
        #endif

        // PATH 2 (GUI video path, doc 17 §3): register the production remote-GUI-window
        // view. The cross-platform view layer cannot reference
        // `SlopDeskVideoClientPhone.VideoWindowView` directly (it would pull VideoToolbox + Metal
        // into the headless `swift build`/tests), so the GUI app target — which links
        // `SlopDeskVideoClientPhone` — injects it here at launch. With no registration the seam
        // shows the gated `RemoteWindowPlaceholderView`.
        #if canImport(SlopDeskVideoClientPhone)
        VideoWindowFactory.shared = { descriptor, paneContext in
            // LIVE path when the descriptor carries a full endpoint (host + media/cursor
            // ports), entered via the Remote-window panel: build the VideoWindowConnection
            // and the orchestrator-backed VideoWindowView(title:connection:). Otherwise the
            // chrome-only initializer (no live decode) — the seam's preview/placeholder path.
            //
            // `paneContext` (active state + the read-only `inputEnabled` gate + activate/canvas-
            // scroll callbacks) is destructured into primitives here — `SlopDeskVideoClient` cannot import
            // `SlopDeskClientUI` (the seam exists for exactly that reason), so the context type stays on the
            // `SlopDeskClientUI` side and only its Bools + closures cross into `VideoWindowView`.
            if descriptor.hasEndpoint {
                let connection = VideoWindowConnection(
                    host: descriptor.host,
                    mediaPort: descriptor.mediaPort,
                    cursorPort: descriptor.cursorPort,
                    windowID: descriptor.windowID,
                    displayID: descriptor.displayID, // full-desktop pane → wire helloDisplay
                )
                return AnyView(VideoWindowView(
                    title: descriptor.title,
                    // Smart-zoom ⌘0 gate (`PinchZeroPolicy`): the pane's app display name rides
                    // the descriptor (client seam, not wire); empty (desktop pane) fails open.
                    targetAppName: descriptor.appName,
                    connection: connection,
                    isActive: paneContext.isActive,
                    inputEnabled: paneContext.inputEnabled,
                    backgroundPointer: paneContext.backgroundPointer,
                    onActivate: paneContext.onActivate,
                    onCanvasScroll: paneContext.onCanvasScroll,
                    onStreamNativeSize: paneContext.onStreamNativeSize,
                    onKeyInjectorReady: paneContext.onKeyInjectorReady,
                    onResizeInjectorReady: paneContext.onResizeInjectorReady,
                    onViewportInjectorReady: paneContext.onViewportInjectorReady,
                    onInputReleaseReady: paneContext.onInputReleaseReady,
                    onWindowGeometryReady: paneContext.onWindowGeometryChanged,
                    onStreamCadenceReady: paneContext.onStreamCadenceChanged,
                    onStreamBitrateReady: paneContext.onStreamBitrateChanged,
                    // NETWORK-STATS MIRROR + LIVE STREAM SETTINGS + HOST AUDIO: the pane's stats
                    // overlay / tune popover / speaker toggle forward path. Defaults are nil, so
                    // forgetting these threads compiles headlessly but leaves the real app's controls
                    // dead — they must ride the factory like every other seam callback.
                    //
                    // `onSystemKeyInjectorReady` is the ONE the Mac shell threads and this one cannot:
                    // `VideoWindowView`'s phone initializer does not take it, because the sink carries
                    // raw `NSEvent.ModifierFlags` bits produced only by a `CGEventTap`, and iOS has
                    // neither. `PaneImmersiveCapture.isSupported` is already `false` here, so the phone
                    // footer draws no immersive chip to feed it. Absent from the SIGNATURE rather than
                    // passed-and-swallowed, so this cannot rot into a sink someone believes is live.
                    onNetworkStatsReady: paneContext.onNetworkStats,
                    onStreamSettingsInjectorReady: paneContext.onStreamSettingsInjectorReady,
                    onAudioInjectorReady: paneContext.onAudioInjectorReady,
                    onPrivacyInjectorReady: paneContext.onPrivacyInjectorReady,
                    onStreamStallChanged: paneContext.onStreamStallChanged,
                    // TERMINAL REJECTION: host refused the session — the seam routes it to
                    // `RemoteWindowModel.noteSessionRejected()` (picker + error, no rebuild loop).
                    onSessionRejected: paneContext.onSessionRejected,
                ))
            }
            return AnyView(VideoWindowView(title: descriptor.title))
        }
        // UDP-mux: install the per-host shared-flow registry on the video pipeline. Panes targeting the
        // same host share ONE UDP flow (one flow per host, N panes); the host's `slopdesk-videohostd`
        // speaks the matching 19-byte channelID-prefixed wire — the only video wire there is now.
        MainActor.assumeIsolated { VideoMuxInstaller.install() }

        // Remote-window PICKER discovery seam (docs/31): inject the host-window query so the
        // cross-platform UI lists windows instead of making the user type a CGWindowID. Maps the
        // video-protocol `WindowSummary` → the UI's `RemoteWindowSummary`. `nil` (no video module) ⇒ the
        // picker falls back to manual entry.
        MainActor.assumeIsolated {
            RemoteWindowDiscovery.shared = { host, mediaPort, cursorPort in
                let windows = await VideoWindowDiscovery.discoverWindows(
                    host: host, mediaPort: mediaPort, cursorPort: cursorPort,
                )
                return windows.map {
                    RemoteWindowSummary(
                        windowID: $0.windowID,
                        appName: $0.appName,
                        title: $0.title,
                        width: $0.width,
                        height: $0.height,
                    )
                }
            }
        }

        // Display-list discovery seam (the desktop pane's display switcher): same shape as the
        // window-picker seam above — the `listDisplays` ↔ `displayList` session-less pair, mapped to
        // the UI's `RemoteDisplaySummary`. `nil` (no video module) ⇒ the switcher is inert.
        MainActor.assumeIsolated {
            RemoteDisplayDiscovery.shared = { host, mediaPort, cursorPort in
                let displays = await VideoWindowDiscovery.discoverDisplays(
                    host: host, mediaPort: mediaPort, cursorPort: cursorPort,
                )
                return displays.map {
                    RemoteDisplaySummary(
                        displayID: $0.displayID,
                        width: $0.width,
                        height: $0.height,
                        isMain: $0.isMain,
                    )
                }
            }
        }

        // `WindowFeedChannel` conforms to `HostWindowFeedLink` via the retroactive extension at the
        // bottom of this file — see there for why the conformance lives outside the video module. It
        // must stay declared BEFORE the closure below so that closure's return type erases cleanly.

        // Host-window FEED seam (docs/45 rail): inject the persistent-lane opener so the
        // cross-platform `HostWindowFeed` loop can subscribe — and receive Phase-2 PUSHES between
        // renewals — WITHOUT importing the gated video module. Maps the wire `HostWindowRecord` →
        // the UI's `HostWindowInfo`. `nil` (no video module) ⇒ the rail shows its unavailable state.
        MainActor.assumeIsolated {
            HostWindowFeedQuery.openLink = { host, mediaPort, cursorPort, onAnswer in
                WindowFeedChannel(host: host, mediaPort: mediaPort, cursorPort: cursorPort) { answer in
                    switch answer {
                    case let .current(generation):
                        onAnswer(.current(generation: generation))
                    case let .snapshot(generation, records):
                        onAnswer(.snapshot(generation: generation, windows: records.map {
                            HostWindowInfo(
                                windowID: $0.windowID,
                                bundleID: $0.bundleID,
                                appName: $0.appName,
                                title: $0.title,
                                widthPt: Int($0.widthPt),
                                heightPt: Int($0.heightPt),
                                displayIndex: Int($0.displayIndex),
                                isOnScreen: $0.flags.contains(.onScreen),
                                isMinimized: $0.flags.contains(.minimized),
                                isAppHidden: $0.flags.contains(.appHidden),
                                isFrontmostApp: $0.flags.contains(.frontmostApp),
                                isFocused: $0.flags.contains(.focusedWindow),
                            )
                        }))
                    }
                }
            }
        }
        #endif

        // Launch the app. `UIApplicationDelegate.main()` names THIS class to `UIApplicationMain` and
        // runs the run loop; it never returns. The scene delegate is not named in `Info.plist` —
        // ``PhoneAppDelegate`` returns it from `configurationForConnecting`, so the class is a symbol
        // rather than a module-qualified string XcodeGen would have to carry.
        PhoneAppDelegate.main()
    }
}

#if canImport(SlopDeskVideoClientPhone)
/// The video module's persistent feed lane IS the WorkspaceCore seam's link — both halves are
/// `@MainActor` with matching shapes. The conformance lives HERE (retroactive) because the video
/// module deliberately never imports `SlopDeskWorkspaceCore` (the seam-split discipline).
extension WindowFeedChannel: @retroactive HostWindowFeedLink {}
#endif
