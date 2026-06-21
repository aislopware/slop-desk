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

    /// W14 #5: whether the ⌘F find bar is showing over this pane. Owned here as VIEW state (not the tree);
    /// ⌘F / the right-click "Find…" flip it through ``TerminalViewModel/onRequestFind`` (wired below).
    @State private var isFindPresented = false

    /// WB2: whether the Command Navigator popover is showing over this pane. VIEW state (not the tree);
    /// ⌃⌘O / the chrome chip flip it through ``TerminalViewModel/onRequestBlockNavigator`` (wired below).
    @State private var isNavigatorPresented = false

    /// P5b: whether the modal copy-mode hint bar is showing over this pane. VIEW state (not the tree); ⌘⇧C /
    /// the Pane menu flip it through ``TerminalViewModel/onRequestCopyMode`` (wired below). Toggling it also
    /// flips `model.isCopyMode`, which arms the keyDown intercept that routes keys to copy-mode dispatch.
    @State private var isCopyModePresented = false

    /// P5b: a transient "copied" toast flag, flipped by ``TerminalViewModel/onCopyConfirmation`` and
    /// auto-cleared after <=0.9s (off the keystroke path). Shown inside the copy-mode hint bar.
    @State private var copyConfirmationVisible = false

    /// P5b: monotonic generation token for the "copied" toast. Each copy bumps it and the auto-clear task
    /// only clears if it is still the CURRENT generation — so rapid `y` presses can't have an early task
    /// clear a later toast (the un-cancelled-overlapping-Task flicker). View state, not the tree.
    @State private var copyConfirmationGeneration = 0

    /// WB2: whether to draw the slim ``StickyCommandHeader`` overlay at the top of each pane. DEFAULT-OFF
    /// so panes are CHROME-LESS like Muxy (the block info is still reachable via the ⌃⌘O Command Navigator
    /// below — only the always-on top strip is gone, which also stops it overlaying the terminal's top
    /// rows). Opt back in with `AISLOPDESK_STICKY_BLOCK_HEADER=1` (default-OFF idiom: only "1" enables).
    private static let stickyHeaderEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_STICKY_BLOCK_HEADER"] == "1"

    /// P5 disappearing-chrome: the user toggle (Settings ▸ Terminal, default ON) that lets the block
    /// divider/header recede on demand. It gates the ``StickyCommandHeader`` ADDITIVELY with the env opt-in
    /// (`stickyHeaderEnabled`) — the header shows only when the env opt-in is set AND this toggle is ON — so
    /// the Muxy-clean default (env unset ⇒ no header) is preserved while a user who opted in can still hide
    /// it. `@AppStorage` so a Settings flip applies on the next render.
    @AppStorage(SettingsKey.showBlockDividers) private var showBlockDividers = true

    /// Reduce-Motion gate: the overlay appear/dismiss drivers (find bar, copy-mode panel, glitch caret) route
    /// through ``DSMotion/resolve(_:reduceMotion:)`` so a motion-sensitive user gets the near-instant crossfade
    /// instead of an `.easeInOut` slide. The `.move` TRANSLATE transitions also collapse to opacity-only under
    /// the system preference (a sliding find-bar/copy-mode panel is exactly what the spec forbids there).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // WB2: the sticky command header — a slim overlay pinned at the TOP showing the CURRENT block's
            // command + running spinner / exit badge. DEFAULT-OFF (Muxy-clean panes); the block info lives
            // in the ⌃⌘O Command Navigator. Opt back in with AISLOPDESK_STICKY_BLOCK_HEADER=1.
            if Self.stickyHeaderEnabled, showBlockDividers {
                StickyCommandHeader(model: model)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            // W14 #5: the find-in-terminal bar, top-trailing so it doesn't cover the prompt.
            if isFindPresented {
                TerminalFindBar(model: model, isPresented: $isFindPresented)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    // Reduce Motion → opacity-only (no slide); otherwise the slide-down appear.
                    .transition(overlayTransition)
            }
            // P5b: the modal copy-mode hint bar, pinned top-leading (so it never collides with the
            // top-trailing find bar, which copy-mode's `/` can open simultaneously). Documents the ABI
            // ceiling: no rendered char/line/rect visual-select — copy reads the mouse-made libghostty
            // selection or the visible scrollback.
            if isCopyModePresented {
                CopyModeOverlay(copied: copyConfirmationVisible)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Reduce Motion → opacity-only (no slide); otherwise the slide-down appear.
                    .transition(overlayTransition)
            }
        }
        // WB2: the Command Navigator popover (⌃⌘O / the chrome chip). A popover on macOS anchors near the
        // pane; on iOS SwiftUI presents it as a sheet automatically. Pure-block-list content; the surface
        // jump + copy-output flows are exercised on real hardware.
        .popover(isPresented: $isNavigatorPresented, arrowEdge: .top) {
            CommandNavigatorView(model: model, isPresented: $isNavigatorPresented)
        }
        // The visibility flips happen in plain (un-animated) model code — without an
        // animation bound to the VALUE the .transition above would be skipped and the
        // caret/bar would pop. Scoped to each value so nothing else animates. P5 MOTION: each driver routes
        // through DSMotion.appear, Reduce-Motion-gated to the near-instant crossfade so a motion-sensitive
        // user gets an instant state swap (and the `.move` translates above collapse to opacity-only). The
        // value-scoped `.animation` is KEPT (not dropped) so the `.transition` still fires.
        .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: model.glitchCaretVisible)
        .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: isFindPresented)
        .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: isCopyModePresented)
        .onAppear {
            // ⌘F / right-click "Find…" toggle the bar through the model's find request (set here so the
            // closure captures THIS pane's @State; the leaf's onRequestFind is set on the same model).
            model.onRequestFind = { isFindPresented.toggle() }
            // WB2: ⌃⌘O / the chrome chip toggle the Command Navigator through the model's request hook
            // (same pattern — captures THIS pane's @State on the same model the store reaches).
            model.onRequestBlockNavigator = { isNavigatorPresented.toggle() }
            // P5b: ⌘⇧C / the Pane menu "Copy Mode" hook. The MODEL is the single source of truth: entry/exit
            // flip `model.isCopyMode` (via enter/exitCopyMode in the store route + q/Esc dispatch) and fire
            // this hook; the overlay @State just MIRRORS the model — never an independent inverting toggle that
            // could desync and re-arm on q/Esc (a fresh @State after a remount would invert false→true). SET,
            // don't toggle, so the overlay always agrees with the keyDown-read flag.
            model.onRequestCopyMode = {
                isCopyModePresented = model.isCopyMode
            }
            // P5b: a successful y/Enter copy flashes a brief "copied" toast inside the hint bar. A generation
            // token gates the auto-clear so a rapid second `y` can't have the FIRST task clear the LATER toast.
            model.onCopyConfirmation = {
                copyConfirmationGeneration += 1
                let generation = copyConfirmationGeneration
                copyConfirmationVisible = true
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    if copyConfirmationGeneration == generation { copyConfirmationVisible = false }
                }
            }
        }
        // P5b: a modal mode must not survive an un-mount. If TerminalScreenView re-mounts while the model
        // outlives it (panes are normally kept mounted, but identity passes still recreate the representable),
        // a fresh `isCopyModePresented` would reset to false while `model.isCopyMode` stayed armed — the keyDown
        // intercept would then keep swallowing keystrokes with NO visible overlay. Clear both on disappear so a
        // backgrounded/re-mounted pane is never left silently armed.
        .onDisappear {
            model.isCopyMode = false
            isCopyModePresented = false
        }
    }

    /// The overlay appear/dismiss transition for the find bar + copy-mode panel: a slide-down-from-top
    /// combined with opacity normally, collapsing to opacity-ONLY under Reduce Motion (the spec's "EVERY
    /// translate gated → near-instant crossfade" rule — a sliding panel is exactly what a motion-sensitive
    /// user must not get). Paired with the `DSMotion.resolve(DSMotion.appear, …)` driver above.
    private var overlayTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

/// The glitch-window speculative caret (docs/17 §2.4): a dim pulsing bar, deliberately
/// distinct from libghostty's own block cursor — advisory "your keystroke was sent,
/// the echo is in flight", never a position claim.
struct GlitchCaretOverlay: View {
    @State private var pulsing = false
    /// Reduce-Motion gate: under the system preference the continuously-repeating breathe is DROPPED — the
    /// caret rests at a fixed mid opacity (legible, never pulsing), matching the ``AttentionPulse`` /
    /// ``WorkingPulse`` steady-branch pattern (a `repeatForever` cannot be made near-instant; resting steady
    /// is the correct fallback).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Reduce Motion: a steady caret at a fixed opacity — no repeatForever breathe.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.secondary.opacity(0.3))
                .frame(width: 7, height: 15)
                .padding(12)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.secondary.opacity(pulsing ? 0.45 : 0.18))
                .frame(width: 7, height: 15)
                .padding(12)
                .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .accessibilityHidden(true)
        }
    }
}

/// P5b: the modal copy-mode hint bar — a slim, top-leading strip shown while the pane is in keyboard
/// copy-mode (⌘⇧C). It documents the achievable keymap AND the ABI ceiling (no rendered char/line/rect
/// visual-select — copy reads the mouse-made libghostty selection or the visible scrollback). A transient
/// "copied" pill replaces the hint for ~0.9s after a successful `y`/Enter copy. All sizes route through
/// `UIMetrics`; colours through `AislopdeskTheme`. Pure chrome — the dispatch is on `TerminalViewModel`.
struct CopyModeOverlay: View {
    /// Flipped true for ~0.9s right after a copy so the bar flashes "copied".
    let copied: Bool

    var body: some View {
        HStack(spacing: AislopdeskTheme.Space.s) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: UIMetrics.fontMicro, weight: .semibold))
            if copied {
                Text("copied")
                    .font(.system(size: UIMetrics.fontMicro, weight: .semibold))
            } else {
                Text("COPY")
                    .font(.system(size: UIMetrics.fontMicro, weight: .bold))
                Text(
                    "j/k scroll · ⌃D/⌃U half-page · g/G top/bottom · [ ] prompt · / search (n/N after) · y copy · q quit",
                )
                .font(.system(size: UIMetrics.fontMicro))
                .foregroundStyle(AislopdeskTheme.fgMuted)
                .lineLimit(1)
            }
        }
        .foregroundStyle(AislopdeskTheme.accent)
        .padding(.horizontal, AislopdeskTheme.Space.m)
        .padding(.vertical, AislopdeskTheme.Space.s)
        .background(
            RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.md)
                .fill(AislopdeskTheme.bgRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.md)
                        .strokeBorder(AislopdeskTheme.border, lineWidth: 1),
                ),
        )
        .padding(AislopdeskTheme.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Copy mode")
    }
}

// `StatusDot` was removed with the inner status strip (#25). The shared, more capable
// ``PaneStatusDot`` (in `PaneStatusIndicator.swift`) is the one source of truth for the connection
// dot, used by `PaneChromeView` (per-pane header) and `TabSidebarView`.
#endif
