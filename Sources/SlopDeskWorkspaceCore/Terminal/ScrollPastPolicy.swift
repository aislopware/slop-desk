import Foundation

// MARK: - E8 WI-12 (I14/I15, ES-E8-5): scroll-past-last / scroll-past-first overscroll anchors

/// The PURE, headless decision behind **Scroll Past Last Line** (I14) and **Scroll Past First Line**
/// (I15): given the buffer geometry, the viewport size, and whether a full-screen program owns the screen,
/// what is the overscroll ANCHOR — the top-row index the viewport may scroll to past the normal clamp?
///
/// ## Why a policy (and a documented RENDERING ceiling)
/// The terminal renders in the CLIENT's libghostty, which OWNS the viewport and exposes **no
/// overscroll-margin / sub-row-render API** in the pinned fork (`Config.zig` has `scroll-to-bottom` but no
/// `scroll-past-*` / `smooth-scroll`). So the *blank-overscroll RENDERING* (floating the last/first content
/// row up/down with the terminal background filling the gap, per the `scroll-past-*` reference videos in
/// `docs/ui-shell/spec/terminal-features__scroll.md`) and the
/// *pixel-snap-on-gesture-end* cannot be actuated 1:1 — that rendering is a **deferred ceiling** recorded in
/// `docs/DECISIONS.md`, pending a libghostty viewport hook. What lands now is the SETTINGS, the alt-screen
/// suppression GATE, and this pure arithmetic that computes the anchor a future viewport hook would clamp to.
/// This enum is therefore the **testable heart** of the feature; the GUI surface (`GhosttyTerminalView`,
/// compile-only behind `#if canImport(CGhostty)`) documents the ceiling at its `scrollWheel` site.
///
/// ## The gate
/// **Scroll Past Last Line is automatically suppressed on the alternate screen** so full-screen TUIs (vim,
/// htop, less) keep their own bottom edge intact (`docs/ui-shell/spec/terminal-features__scroll.md`). Both directions take
/// `isAlternateScreen` and return `nil` (clamp / suppressed) when set — a TUI owns the viewport, never an
/// overscroll. `nil` is also returned for the ``ScrollPastLast/disabled`` / ``ScrollPastFirst/disabled``
/// modes (the defaults) and for a degenerate buffer (no content / non-positive viewport), so a `nil` result
/// uniformly means "clamp normally; no overscroll" and a non-`nil` value is the explicit anchor.
///
/// ## Coordinates
/// Rows are indexed `0 ..< contentRows` from the TOP of all content (active screen + scrollback); the
/// viewport shows the half-open range `[top, top + viewportRows)`. The NORMAL clamp keeps `top` in
/// `[0, max(0, contentRows − viewportRows)]` (buffer bottom at viewport bottom). Overscroll only EXTENDS that
/// range — past-last raises the MAX `top` (blank below), past-first lowers the MIN `top` below `0` (blank
/// above). Integer `+`/`−`/`/` only (terminal-row magnitudes never overflow); ordered `max(_:_:)` /
/// `min(_:_:)` clamps — no float, no fused multiply (this file is render-policy, not codec, but the project
/// float rules still forbid `addingProduct`/`fma`).
///
/// Pinned by `ScrollPastPolicyTests`: an implementation that dropped the alt-screen gate, clamped overscroll
/// away when content fits the viewport, or confused the cursor-line anchor with the last-content-row anchor
/// each fails a specific case.
public enum ScrollPastPolicy {
    /// The overscroll anchor for **Scroll Past Last Line** (I14): the MAXIMUM top-row index the viewport may
    /// scroll to past the last content line. Returns `nil` to clamp at the buffer bottom (the
    /// ``ScrollPastLast/disabled`` default, the alternate screen, or a degenerate buffer).
    ///
    /// - Parameters:
    ///   - mode: the live ``ScrollPastLast`` setting (``SettingsKey/scrollPastLastLine``, default
    ///     ``ScrollPastLast/disabled``).
    ///   - contentRows: total rows of content available to scroll through (active screen + scrollback), `≥ 0`.
    ///   - viewportRows: visible rows in the viewport, `≥ 1`.
    ///   - cursorRow: the cursor's absolute row index within the content (0-based from the top); used only by
    ///     ``ScrollPastLast/cursorLine``. Clamped defensively into `[0, contentRows − 1]`.
    ///   - isAlternateScreen: whether a full-screen / foreground program owns the screen — the GUI derives
    ///     this from the OSC-133 shell-activity the host streams (a TUI runs as `.running`). `true` ⇒ `nil`
    ///     (the suppression: the program keeps its own bottom edge).
    /// - Returns: the explicit max-top anchor, or `nil` (clamp normally / suppressed).
    public static func targetTopRow(
        mode: ScrollPastLast,
        contentRows: Int,
        viewportRows: Int,
        cursorRow: Int,
        isAlternateScreen: Bool,
    ) -> Int? {
        // Alt-screen suppression + a degenerate buffer / viewport → clamp normally (no overscroll).
        guard !isAlternateScreen, contentRows > 0, viewportRows > 0 else { return nil }

        // The normal clamp: the bottom-most top-row when the buffer bottom sits at the viewport bottom.
        // Overscroll only EXTENDS the range downward, so every enabled mode clamps UP to this (ordered max).
        let normalMaxTop = max(0, contentRows - viewportRows)

        switch mode {
        case .disabled:
            // Clamp at the buffer bottom — no overscroll.
            return nil
        case .lastLineWithContent:
            // The bottom-most content row (contentRows − 1) lands at the viewport TOP.
            return max(contentRows - 1, normalMaxTop)
        case .lastLineInMiddle:
            // The bottom-most content row lands at the vertical CENTRE (offset viewportRows/2 from the top).
            return max((contentRows - 1) - viewportRows / 2, normalMaxTop)
        case .cursorLine:
            // The cursor row lands at the TOP, even on a blank line; clamp the row into the buffer first.
            return max(min(max(cursorRow, 0), contentRows - 1), normalMaxTop)
        }
    }

    /// The overscroll anchor for **Scroll Past First Line** (I15): the MINIMUM top-row index (`≤ 0`, blank
    /// above) the viewport may scroll to past the first (oldest) scrollback line. Returns `nil` to clamp at
    /// the scrollback top (the ``ScrollPastFirst/disabled`` default, the alternate screen, or a degenerate
    /// buffer).
    ///
    /// ``ScrollPastFirst/sameAsLast`` is resolved HERE (via ``mirroredFirst(of:)``) so only one knob must be
    /// tuned: it mirrors `lastLineMode` into the symmetric top mode.
    ///
    /// - Parameters:
    ///   - mode: the live ``ScrollPastFirst`` setting (``SettingsKey/scrollPastFirstLine``, default
    ///     ``ScrollPastFirst/disabled``).
    ///   - lastLineMode: the live ``ScrollPastLast`` setting, consulted ONLY to resolve
    ///     ``ScrollPastFirst/sameAsLast``.
    ///   - contentRows: total rows of content (active screen + scrollback), `≥ 0`.
    ///   - viewportRows: visible rows in the viewport, `≥ 1`.
    ///   - isAlternateScreen: whether a full-screen program owns the screen — `true` ⇒ `nil` (suppression).
    /// - Returns: the explicit min-top anchor (`≤ 0`), or `nil` (clamp normally / suppressed).
    public static func minTopRow(
        mode: ScrollPastFirst,
        lastLineMode: ScrollPastLast,
        contentRows: Int,
        viewportRows: Int,
        isAlternateScreen: Bool,
    ) -> Int? {
        // Alt-screen suppression + a degenerate buffer / viewport → clamp normally (symmetric with the bottom).
        guard !isAlternateScreen, contentRows > 0, viewportRows > 0 else { return nil }

        // Resolve "Same as Scroll Past Last Line" into the symmetric top mode (the mirror knob);
        // `mirroredFirst(of:)` never yields `.sameAsLast`, so `effective` is one of the concrete top modes.
        let effective = mode == .sameAsLast ? mirroredFirst(of: lastLineMode) : mode

        switch effective {
        case .disabled,
             .sameAsLast:
            // Clamp at the scrollback top — no overscroll. (`.sameAsLast` is unreachable here — it is
            // resolved above — and is listed only for an exhaustive switch.)
            return nil
        case .firstLineWithContent:
            // The topmost history row (index 0) lands at the viewport BOTTOM (offset viewportRows − 1).
            return min(-(viewportRows - 1), 0)
        case .firstLineInMiddle:
            // The topmost history row lands at the vertical CENTRE (offset viewportRows/2 from the top).
            return min(-(viewportRows / 2), 0)
        }
    }

    /// The symmetric TOP mode for a bottom ``ScrollPastLast`` — the resolution of
    /// ``ScrollPastFirst/sameAsLast``. ``ScrollPastLast/cursorLine`` has no cursor at the top of history, so
    /// it maps to the closest analog ``ScrollPastFirst/firstLineWithContent``; ``ScrollPastLast/disabled``
    /// mirrors to ``ScrollPastFirst/disabled`` (a clamp).
    private static func mirroredFirst(of lastLineMode: ScrollPastLast) -> ScrollPastFirst {
        switch lastLineMode {
        case .disabled: .disabled
        case .lastLineWithContent: .firstLineWithContent
        case .lastLineInMiddle: .firstLineInMiddle
        case .cursorLine: .firstLineWithContent
        }
    }
}
