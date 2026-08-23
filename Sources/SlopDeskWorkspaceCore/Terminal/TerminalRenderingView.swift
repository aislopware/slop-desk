#if canImport(SwiftUI)
#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// The **seam** between the SwiftUI client and the terminal pixels.
///
/// PATH 1 streams raw VT bytes; *how* they become pixels is hidden behind this protocol so
/// the cross-platform UI compiles and is testable **without** libghostty. There are exactly
/// two conformers:
///
/// 1. ``BuildStatusPlaceholderView`` — the no-framework case. It renders a clearly-labelled
///    BUILD-STATUS panel ("libghostty renderer not built — run
///    ThirdParty/ghostty/build-libghostty.sh"). It shows build status, not emulated text —
///    libghostty is the renderer (DECISIONS / doc 17), so the placeholder is telemetry, not
///    a terminal.
///
/// 2. `GhosttyTerminalView` (the documented extension point) — the production renderer: a
///    Metal-hosted ``SlopDeskTerminal/TerminalSurface`` conformer wrapping the gated
///    `GhosttySurface` (`ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift`).
///    It lives in the **Xcode app target**, which links `libghostty.xcframework` and imports
///    the `CGhostty` clang module — so a headless `swift build` never sees it. See
///    ``TerminalRendererFactory`` for where the app injects it.
///
/// The view is given the ``TerminalViewModel`` so the production conformer can attach its
/// `GhosttySurface` to the model's surface feed; the placeholder just reads connection state.
public protocol TerminalRenderingView: View {
    init(model: TerminalViewModel)
}

// L0 / A2 SEAM SPLIT: the SwiftUI `BuildStatusPlaceholderView` body has been DELETED from the headless
// `SlopDeskWorkspaceCore`. The rebuilt `SlopDeskClientUI` provides the real placeholder/renderer
// bodies; the Xcode app target injects the production `GhosttyTerminalView` via `TerminalRendererFactory`.
// `make(model:isFocused:)` returns an `EmptyView` when no factory is registered (the headless build).

/// Injects the production terminal renderer when the app target provides one.
///
/// The cross-platform library cannot reference `GhosttyTerminalView` (it would force linking
/// libghostty into the headless `swift build`). Instead the Xcode app target sets
/// ``shared`` at launch to a factory that builds its Metal-hosted `GhosttyTerminalView`; the
/// library calls ``make(model:)`` and falls back to the ``BuildStatusPlaceholderView`` when no
/// factory was registered. This is the documented extension point.
///
/// The seam has TWO shapes, and which one a caller takes is decided by the framework it draws in, not by
/// which arrived first: ``shared``/``make(model:isFocused:)`` hand back a `View` (SwiftUI, and the ONLY
/// shape iOS can use — the phone has no `NSView`), while ``nativeShared``/``makeNative(model:isFocused:)``
/// hand back the `NSView` itself for an AppKit canvas to add as a subview. Both resolve to the same
/// renderer and the same libghostty surface; see ``nativeShared`` for why the AppKit half does not simply
/// wrap the `AnyView`.
@preconcurrency
@MainActor
public final class TerminalRendererFactory {
    /// The app-registered factory (set once at launch). `nil` → use the placeholder.
    ///
    /// `isFocused` is the pane's workspace focus (the active tab's `focusedPane`). The production
    /// renderer uses it to drive the macOS first responder from WORKSPACE INTENT — only the focused
    /// pane takes the keyboard — instead of every pane stealing it on mount (the multi-pane
    /// focus-stealing bug). It does NOT gate render-liveness: every visible pane stays render-focused so
    /// an unfocused pane in a split keeps repainting its remote output.
    public static var shared: ((TerminalViewModel, Bool) -> AnyView)?

    /// Builds the terminal rendering view: the registered production renderer if present,
    /// else an empty view (the headless build registers no factory). `isFocused` reflects the
    /// pane's workspace focus. The rebuilt `SlopDeskClientUI`/app target always registers a
    /// factory, so the empty fallback only occurs in the headless library / tests.
    public static func make(model: TerminalViewModel, isFocused: Bool) -> AnyView {
        if let factory = shared {
            return factory(model, isFocused)
        }
        return AnyView(EmptyView())
    }

    #if canImport(AppKit)
    /// The **native** half of the same seam — the app-registered factory that hands back the terminal's
    /// `NSView` DIRECTLY instead of wrapping it in an `AnyView`. `nil` → no native renderer (the headless
    /// build, and every build before the app target calls its installer).
    ///
    /// WHY this exists and is not simply the SwiftUI slot with an `NSHostingView` around it: the production
    /// renderer already IS an `NSView` (`GhosttyLayerBackedView`, a LAYER-HOSTING view libghostty installs
    /// its own `IOSurfaceLayer` into), and ``shared`` only exists because neither UI target may *name* that
    /// type. An AppKit canvas that mounted ``make(model:isFocused:)`` would put an `NSHostingView` between
    /// its own view tree and that view: a full-bleed hosting layer over the ONE surface that must take every
    /// keystroke, which is exactly the hit-claim docs/56 stage D spent five increments removing. So the seam
    /// widens instead of the canvas thickening — the AppKit half asks for the view it is going to add as a
    /// subview, and the SwiftUI half keeps asking for a `View`.
    ///
    /// ADDITIVE, permanently. ``shared`` is not deprecated by this and must not be: the phone has no
    /// `NSView`, so iOS's leaf keeps crossing as a `View` over `UIViewRepresentable`. One seam, two shapes,
    /// picked by which framework is drawing — not by which is newer.
    ///
    /// `@MainActor` on the closure TYPE, unlike ``shared``: this one builds and returns an `NSView`, and
    /// `NSView` is main-actor isolated, so the factory could not be written at all without it (the same
    /// reason ``RemoteWindowDiscovery/shared`` carries it).
    public static var nativeShared: (@MainActor (TerminalViewModel, Bool) -> TerminalSurfaceHosting)?

    /// Builds the native terminal surface host, or `nil` when no native renderer was registered. `isFocused`
    /// is the pane's workspace focus at MOUNT time; every later change goes through
    /// ``TerminalSurfaceHosting/setPaneFocused(_:)`` — an AppKit canvas has no `updateNSView` to be re-run
    /// for it, so the push is explicit.
    public static func makeNative(model: TerminalViewModel, isFocused: Bool) -> TerminalSurfaceHosting? {
        guard let factory = nativeShared else { return nil }
        return factory(model, isFocused)
    }
    #endif
}

#if canImport(AppKit)
/// What an AppKit canvas may ask of the terminal surface it just mounted.
///
/// The three members are the AppKit spellings of what SwiftUI gets for free from the representable
/// lifecycle: `makeNSView` (the view itself), `updateNSView` (re-push the pane's focus) and
/// `dismantleNSView` (drop the libghostty surface). They are deliberately the WHOLE protocol — anything
/// richer would be the canvas reaching into the renderer, and the renderer is the one thing on this seam
/// neither UI target may name.
///
/// ⚠️ The only conformer is `GhosttyLayerBackedView`, in
/// `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — a file NO `Package.swift`
/// target compiles (it joins the Xcode app target via `slopdesk-ops enable-renderer macos`). A grep over
/// `Sources/` and `Tests/` alone reads this protocol as unimplemented, and it is not. Same trap as
/// ``TerminalViewModel/makeCopyModeKey(event:)``.
@preconcurrency
@MainActor
public protocol TerminalSurfaceHosting: AnyObject {
    /// The layer-hosting view to add as a subview. Add it, size it, and otherwise leave it alone: it owns
    /// its `layer` slot (libghostty installs an `IOSurfaceLayer` there) and sizes that layer in `layout()`.
    var surfaceView: NSView { get }

    /// Re-push the pane's WORKSPACE focus. Drives the keyboard first responder and libghostty's render
    /// focus (solid vs hollow cursor); it does NOT gate render-liveness, so an unfocused split sibling
    /// keeps repainting. Idempotent — the renderer dedupes and coalesces.
    func setPaneFocused(_ isFocused: Bool)

    /// Drop the libghostty surface (the AppKit twin of `dismantleNSView`). Removing the view from its
    /// superview is NOT enough: the surface owns renderer/io threads that must be torn down explicitly.
    func detachSurface()
}
#endif

/// The MODAL POINTER SHIELD — whether a modal overlay card (command palette / Open Quickly /
/// connect / cheat sheet / Peek & Reply) is floating over the workspace, read by the production
/// renderer's `mouseMoved`/`mouseEntered` before it forwards a pointer position to libghostty.
///
/// The shield exists because an AppKit `NSTrackingArea` is RECT-based: it keeps firing no matter
/// what is composited above it, so with the palette open the terminal underneath kept feeding
/// cursor positions to a mouse-reporting TUI (hover highlights tracked the pointer THROUGH the
/// card) and focus-follows-mouse could steal the workspace focus mid-palette. Clicks never had
/// this problem — the card's dismiss floor takes them via ordinary hit-testing — so this closure
/// makes the pointer's hover traffic obey the same occlusion its clicks already do.
///
/// Same injection idiom as ``TerminalRendererFactory/shared``: the app root binds it once to the
/// live overlay coordinator's modal flag; the default (headless / tests / previews) is never
/// shielded. The SwiftUI chrome columns gate the same flag through `allowsHitTesting` — one flag,
/// two event systems.
@preconcurrency
@MainActor
public enum TerminalPointerShield {
    /// Whether pointer traffic into the terminal is currently shielded by a modal overlay.
    public static var isActive: () -> Bool = { false }
}
#endif
