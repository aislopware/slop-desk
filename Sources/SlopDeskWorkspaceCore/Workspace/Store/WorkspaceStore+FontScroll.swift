import CSlopDeskFFI
import Foundation

// MARK: - FontSizeStep (the ⌘+ / ⌘- / ⌘0 font-zoom intent the active-pane hooks route through)

/// The three font-zoom intents ⌘+/⌘-/⌘0 fire. The store routes them through ``WorkspaceStore/onFontSizeStep``
/// to the live ``PreferencesStore`` (the single source of truth for `terminal.fontSize`), so the Settings
/// "Size" stepper stays in sync — never an internal font-size state the stepper can't see (the deleted
/// fork carried one; the live renderer draws only the size ``TerminalConfigBroadcaster`` hands it).
public enum FontSizeStep: Equatable, Sendable {
    /// ⌘+ / ⌘= — one step larger.
    case increase
    /// ⌘- — one step smaller.
    case decrease
    /// ⌘0 — reset to the configured default size.
    case reset
}

// MARK: - ScrollAction (the named viewport-scroll the ⇧PageUp/Down + ⇧Home/End chords route through)

/// The four viewport-scroll intents the keymap binds to the named scroll keys (⇧PageUp/PageDown →
/// page up/down, ⇧Home/End → buffer top/bottom). A framework-neutral enum (no AppKit / no renderer
/// import) so the routing + the store hook stay headless; the binding-action string each maps to (owned
/// by Rust, per ``TerminalSurfaceActions/performBindingAction(_:)``) is the single source of the mapping
/// (``ScrollAction/wire``).
///
/// Scroll-sign convention (the deleted fork's libghostty `Binding.zig`, mirrored by
/// ``TerminalViewModel/handleCopyModeKey(_:)``):
/// NEGATIVE = UP toward OLDER scrollback. So `.pageUp` is `scroll_page_fractional:-0.9` and `.pageDown` is
/// `scroll_page_fractional:0.9`. `0.9` (≈ one page minus a sliver of overlap context) is the same "≈ a page"
/// fraction the plan pins — distinct from copy-mode's half-page `±0.5` (Ctrl-D/U), which is a different
/// gesture.
public enum ScrollAction: Equatable, Sendable {
    /// ⇧PageUp — one page toward OLDER scrollback (negative sign).
    case pageUp
    /// ⇧PageDown — one page toward NEWER output (positive sign).
    case pageDown
    /// ⇧Home — jump to the very top of the scrollback buffer.
    case top
    /// ⇧End — jump to the very bottom (newest) of the scrollback buffer.
    case bottom

    /// The discriminant this scroll crosses as — `slopdesk_workspace::store_shape::ScrollAction`'s
    /// own order, which is this case list's. The cases stay in Swift because a `switch` in the
    /// routing reads them; the STRINGS do not, for the reason ``wire`` gives.
    private var ffiByte: UInt8 {
        switch self {
        case .pageUp: 0
        case .pageDown: 1
        case .top: 2
        case .bottom: 3
        }
    }

    /// The binding action this scroll intent fires through
    /// ``TerminalSurfaceActions/performBindingAction(_:)`` — the SINGLE source of the intent→action
    /// mapping (so the store hook and any test pin the same string), and it is
    /// `slopdesk_workspace::store_shape::ScrollAction::action`. Two conventions live in those four
    /// strings and neither survives being written twice: the SIGN (negative is up, toward older
    /// scrollback) and the FRACTION (`0.9` ≈ a page minus a sliver of overlap — deliberately not copy
    /// mode's half page, which is a different gesture on a different key). Both are Rust's; this side
    /// only names the intent and carries the answer.
    var wire: String {
        TerminalActionBuffer.read { out, capacity in
            slopdesk_ws_scroll_action(ffiByte, out, capacity)
        }
    }
}

// MARK: - WorkspaceStore × Font size + viewport scroll (store hooks)

/// The active-pane font-size + viewport-scroll store hooks, split into their own extension so the
/// (already large) ``WorkspaceStore`` body stays under the lint type-body ceiling — the same reason
/// ``WorkspaceStore+Blocks`` exists. Each one mirrors ``WorkspaceStore/jumpToBlockInActivePane(delta:)``:
/// resolve the active pane's live ``TerminalViewModel`` (``activeTerminalModel``), probe its `surface` for
/// the ``TerminalSurfaceActions`` capability seam, and fire the matching binding action.
///
/// All four are a clean no-op for a non-terminal active pane (`.desktop`), an empty
/// shell, or a headless / placeholder surface that does not conform to ``TerminalSurfaceActions`` (no seam) —
/// the same graceful degradation the block hooks use. None instantiate a renderer, so the whole surface is
/// unit-testable against a recording ``TerminalSurfaceActions`` fake (the hang-safety rule: no real
/// `TerminalSurface` in a test).
public extension WorkspaceStore {
    /// ⌘= (and the auto-shifted ⌘+) — bumps the terminal render font size one step. Routes through the
    /// ``onFontSizeStep`` seam to the live ``PreferencesStore`` (`terminal.fontSize`, the SINGLE source of
    /// truth) — NOT the deleted fork's own `increase_font_size` responder action, which desynced from the
    /// Settings "Size" stepper because the stepper could not observe it. A larger font fits FEWER cells in
    /// the same pane pixel box, so the PTY grid
    /// (cols/rows) shrinks and the remote PTY IS reflowed via SIGWINCH — a font-SIZE step is NOT
    /// grid-preserving (only font FAMILY/STYLE rebuilds are). A no-op for a non-terminal active pane / no seam.
    func increaseFontInActivePane() {
        stepActivePaneFontSize(.increase)
    }

    /// ⌘- — shrinks the terminal render font size one step. Same source-of-truth + reflow property as
    /// ``increaseFontInActivePane()`` (a smaller font fits MORE cells → the grid grows → SIGWINCH).
    func decreaseFontInActivePane() {
        stepActivePaneFontSize(.decrease)
    }

    /// ⌘0 — resets the terminal render font size to the configured default. Same source-of-truth path as
    /// ``increaseFontInActivePane()``.
    func resetFontInActivePane() {
        stepActivePaneFontSize(.reset)
    }

    /// Fire `step` at the ``onFontSizeStep`` seam, but ONLY when the active pane is a TERMINAL — preserving the
    /// no-op-off-terminal contract the surface-action hooks held (a `.desktop` / empty /
    /// headless pane has no `activeTerminalModel`, so ⌘± does nothing there, exactly as before).
    private func stepActivePaneFontSize(_ step: FontSizeStep) {
        guard activeTerminalModel != nil else { return }
        onFontSizeStep?(step)
    }

    /// Scrolls the active pane's viewport per the named ``ScrollAction`` (⇧PageUp/Down → page up/down,
    /// ⇧Home/End → buffer top/bottom). Routes the action's ``ScrollAction/wire`` string through
    /// the active surface's ``TerminalSurfaceActions`` seam — the SAME lever jump-to-prompt / copy-mode scroll
    /// use. A no-op for a non-terminal pane, an empty shell, or a headless / placeholder surface (no seam).
    func scrollActivePane(_ action: ScrollAction) {
        performActiveSurfaceAction(action.wire)
    }

    /// The shared resolve-then-fire used by the font + scroll hooks: resolve the active terminal model,
    /// probe its `surface` for ``TerminalSurfaceActions``, and fire `action`. Mirrors
    /// ``WorkspaceStore/jumpToBlockInActivePane(delta:)`` exactly so the font/scroll path can't drift from the
    /// block-jump path on how it reaches the seam. A no-op when any link is absent (non-terminal / no seam).
    private func performActiveSurfaceAction(_ action: String) {
        guard let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions else { return }
        actions.performBindingAction(action)
    }
}
