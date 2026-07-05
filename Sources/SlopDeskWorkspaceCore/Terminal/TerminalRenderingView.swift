#if canImport(SwiftUI)
import SlopDeskTerminal
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
}
#endif
