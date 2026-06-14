#if canImport(SwiftUI)
import SwiftUI

/// The terminal screen: hosts the ``TerminalRenderingView`` seam (production
/// `GhosttyTerminalView` via ``TerminalRendererFactory``, or the BUILD-STATUS placeholder),
/// full-bleed. Binds a ``TerminalViewModel``.
///
/// The view itself is renderer-agnostic — it just asks the factory for the rendering view. The
/// per-pane header (title + connection-status dot) is owned by ``PaneChromeView``, which wraps every
/// leaf, so this view no longer draws its own title/status strip (#25 — it overlaid live output). The
/// byte pipeline is driven by `observe(client:)`, started by the embedding scene (`AislopdeskClientApp`) so
/// this view can be reused inside the split layout.
public struct TerminalScreenView: View {
    @State private var model: TerminalViewModel
    /// The pane's workspace focus, threaded to the renderer so only the focused pane takes the macOS
    /// keyboard first responder (a plain `let`, NOT `@State`, so a focus change re-renders and updates
    /// the renderer; the model stays stable in `@State`). Defaults to `true` for the single-pane /
    /// preview callers that do not thread focus.
    private let isFocused: Bool

    public init(model: TerminalViewModel, isFocused: Bool = true) {
        _model = State(initialValue: model)
        self.isFocused = isFocused
    }

    public var body: some View {
        // #25: the inner title/status strip was REMOVED — it was dead weight that OVERLAID the live
        // terminal output (the `.top`-aligned HStack sat on top of the first rows). `PaneChromeView`
        // already owns the per-pane header (kind glyph + title + connection-status dot + split/zoom/
        // close buttons) and wraps every leaf, so this strip duplicated that chrome while obscuring
        // text. The renderer is now full-bleed; the ZStack is kept so future overlays (e.g. a bell
        // flash) have an anchor without reintroducing a layout shift.
        ZStack(alignment: .top) {
            // The renderer seam — production GhosttyTerminalView, or the placeholder.
            TerminalRendererFactory.make(model: model, isFocused: isFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Glitch caret (docs/31 #3): the dim "input received, echo pending" nudge.
            // A SwiftUI sibling overlay, never an NSView sublayer — libghostty owns the
            // renderer view's layer slot (the orphaned-CAMetalLayer freeze class), and
            // the C API exposes no cursor readback, so the honest v1 anchors to the
            // pane corner instead of pretending to know the cell.
            if model.glitchCaretVisible {
                GlitchCaretOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false) // the pane has a history of scroll-swallowing chrome
                    .transition(.opacity)
            }
        }
        // The visibility flips happen in plain (un-animated) model code — without an
        // animation bound to the VALUE the .transition above would be skipped and the
        // caret would pop. Scoped to this value so nothing else animates.
        .animation(.easeInOut(duration: 0.15), value: model.glitchCaretVisible)
    }
}

/// The glitch-window speculative caret (docs/17 §2.4): a dim pulsing bar, deliberately
/// distinct from libghostty's own block cursor — advisory "your keystroke was sent,
/// the echo is in flight", never a position claim.
struct GlitchCaretOverlay: View {
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.secondary.opacity(pulsing ? 0.45 : 0.18))
            .frame(width: 7, height: 15)
            .padding(12)
            .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

// `StatusDot` was removed with the inner status strip (#25). The shared, more capable
// ``PaneStatusDot`` (in `PaneStatusIndicator.swift`) is the one source of truth for the connection
// dot, used by `PaneChromeView` (per-pane header) and `TabSidebarView`.
#endif
