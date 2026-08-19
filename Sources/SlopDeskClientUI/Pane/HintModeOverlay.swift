// HintModeOverlay — the Vimium-style Hint Mode VIEW layer (`terminal-features__hint-mode`).
//
// A DECORATION overlay layered OVER the terminal surface in `TerminalLeafView` (never a content branch — the
// libghostty-freeze guardrail): while the pane model has an armed intent (``TerminalViewModel/hintMode``), it
// DIMS the surface (so labels pop), draws a yellow 2-letter badge at each detected target —
// mapped to points by ``TerminalCellMetrics`` (the SAME geometry seam the ⌘-hold underline uses) — and
// shows a `HINTS · <intent> · Esc Exit` badge top-trailing (the `hint-mode.png` chrome; slopdesk has no
// titlebar, so it floats in the pane like the vi-mode / read-only pills).
//
// Keyboard (macOS): the renderer's `keyDown` routes keystrokes to ``TerminalViewModel/handleHintKey(_:)`` while
// hint mode is up (NOT to the PTY), which dims non-matching labels on the first letter and runs the action on the
// second — no Enter. This overlay only RENDERS that pure state (``HintLabelAssigner/filter(typed:labels:)``); it
// never captures keys itself.
//
// Tap (iOS soft-keyboard fallback, hint-mode spec): every badge is ALSO tappable — typing two keys on a soft
// keyboard while the overlay is up is awkward, so a tap resolves the target directly
// (``TerminalViewModel/confirmHintTarget(_:)``). The dim plate tap (and the badge `×`) cancels the mode.
//
// Honest ceiling: a headless / `BuildStatusPlaceholderView` surface does NOT conform to
// ``TerminalViewportSnapshotting`` (the real surface hangs without a window server — CLAUDE.md rule #6), so
// `cellMetrics()` is absent and the overlay renders nothing — labels are ABSENT, never wrong. The actuation
// itself is wired by ``TerminalLeafView`` (``TerminalViewModel/onHintConfirmed``).
//
// `Slate.*` tokens for chrome; the badge is a FIXED yellow plate with BLACK text (the hint-mode spec's "yellow
// background / black text" — theme-independent so it reads over any terminal background, the secure-input-pill
// rationale). check-ds-leaks forbids only raw font-size / radius literals, not these colours.
//
// Every DECISION and every WORD in this file is ``HintPresentation``'s (`SlopDeskClientCore`): the arm
// predicate, the per-letter fade rule, the uppercasing, the dim predicate over
// ``HintLabelAssigner/filter(typed:labels:)``, and the five strings. What is left here is the ink and the
// placement — which is the whole of what an AppKit half would differ in.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskTerminal
import SlopDeskWorkspaceCore
import SwiftUI

struct HintModeOverlay: View {
    /// The pane's terminal model — read for the OBSERVABLE armed intent (`hintMode`) + typed prefix
    /// (`hintTyped`), and dereferenced (non-reactively) for its `surface` viewport geometry at draw time.
    let model: TerminalViewModel

    var body: some View {
        // Reading `hintMode` / `hintTyped` registers observation, so the overlay reveals / clears + re-dims the
        // instant the mode arms / a letter is typed. The geometry read lives inside the active branch so the
        // dependency on the surface snapshot is only taken while hint mode is actually live.
        if let intent = model.hintMode,
           let snapshot = model.surface as? TerminalViewportSnapshotting,
           let metrics = snapshot.cellMetrics(),
           HintPresentation.isArmed(
               intent: intent, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
           )
        {
            let typed = model.hintTyped
            let labels = model.hintLabels
            let targets = model.hintTargets
            let matched = HintPresentation.matchedLabels(typed: typed, labels: labels)

            ZStack(alignment: .topLeading) {
                // Dim the surface so the labels pop — the SAME scrim token the modal overlays
                // use. Tapping the dim plate cancels the mode (and blocks stray clicks to the terminal while up).
                Rectangle()
                    .fill(Slate.State.shadow)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelHintMode() }

                // One yellow 2-letter badge per target, anchored at the target's first cell (top-leading origin
                // + `.offset` so each badge's top-left lands at its `(colStart, row)` cell — plain `*`/`+` cell
                // math lives in `TerminalCellMetrics.rect`). Dimmed when the typed first letter rules it out.
                ForEach(Array(zip(targets, labels).enumerated()), id: \.offset) { _, pair in
                    // CLAMP to the visible grid: a target whose first cell lands off-screen-right
                    // (a soft-wrap-shifted span) is SKIPPED, never anchored in the void.
                    if let rect = metrics.clampedRect(
                        row: pair.0.row, colStart: pair.0.colStart, colEnd: pair.0.colEnd,
                    ) {
                        HintLabelBadge(
                            label: pair.1, typed: typed,
                            dimmed: HintPresentation.dimmed(label: pair.1, matched: matched),
                        )
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture { model.confirmHintTarget(pair.0) } // iOS tap-on-label fallback
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                HintModeBadge(intent: intent, typed: typed, onExit: { model.cancelHintMode() })
                    .padding(Slate.Metric.space2)
            }
            // Belt-and-suspenders Escape dismiss: the primary cancel is the renderer's `keyDown` →
            // `cancelHintMode()` once the terminal is first responder (the key-routing nudges focus there). This
            // safety net — if Escape lands in the overlay's responder chain instead of the surface — still cancels
            // the mode. Which key route that is per platform is ``View/slateCancelKey(perform:)``'s.
            .slateCancelKey { model.cancelHintMode() }
            .transition(.opacity)
        }
    }
}

// MARK: - Label badge

/// A single yellow 2-letter hint badge positioned at a target's first cell. The already-typed first letter is
/// shown faded so the user sees which key to press next; a label ruled out by the typed prefix is dimmed.
private struct HintLabelBadge: View {
    let label: String
    let typed: String
    let dimmed: Bool

    var body: some View {
        labelText
            .font(.system(size: Slate.Typeface.small, weight: .bold, design: .monospaced))
            .padding(.horizontal, Slate.Metric.space1)
            // ⚠️ 14 is UNNAMED — the badge's minimum height, deliberately under the keycap's 18 because a
            // badge stands ON the grid rather than beside a label. Proposed `Slate.Metric.hintBadge`.
            .frame(minHeight: 14)
            .background(Slate.Status.warn, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    // A thin dark hairline so the yellow plate reads on a light background too.
                    .strokeBorder(Slate.Text.onWarn.opacity(Slate.Opacity.dim), lineWidth: Slate.Metric.hairline),
            )
            // ⚠️ 0.2 is UNNAMED — the ruled-out badge's opacity, a rung BELOW `Slate.Opacity.dim` (0.35)
            // because this dims a whole plate rather than ink on one. Proposed `Slate.Opacity.dimmedPlate`.
            .opacity(dimmed ? 0.2 : 1)
            .fixedSize()
            .accessibilityLabel(HintPresentation.labelAccessibility(label))
    }

    /// The 2 uppercase letters — already-typed letters faded (progress cue), the rest solid black. Black on the
    /// fixed-yellow plate is theme-independent + high-contrast (the hint-mode spec; the secure-input-pill rationale).
    /// WHICH letters are faded, and that the label is uppercased at all, are ``HintPresentation``'s.
    private var labelText: Text {
        // Splice the per-character `Text` runs left-to-right into one run (`Text.spliced`).
        Text.spliced(Array(HintPresentation.displayLabel(label)).enumerated().map { offset, element in
            let faded = HintPresentation.isFaded(offset: offset, typed: typed)
            let ink = faded ? Slate.Text.onWarn.opacity(Slate.Opacity.dim) : Slate.Text.onWarn
            return Text(String(element)).foregroundStyle(ink)
        })
    }
}

// MARK: - Mode badge (top-trailing "HINTS · Esc Exit")

/// The `HINTS` mode badge (the `hint-mode.png` titlebar chip; floated in the pane's top-trailing region since
/// slopdesk has no titlebar). Shows the active intent + the keys typed so far + an `×` to leave the mode.
private struct HintModeBadge: View {
    let intent: HintIntent
    let typed: String
    let onExit: () -> Void

    @State private var closeHover = false

    private var intentLabel: String { intent.badgeLabel }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text(HintPresentation.title)
                .font(.system(size: Slate.Typeface.footnote, weight: .bold))
                .tracking(Slate.Typeface.pillTracking)
                .foregroundStyle(Slate.Text.onWarn)
            Text(intentLabel)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.pillTracking)
                .foregroundStyle(Slate.Text.onWarn.opacity(Slate.Opacity.muted))
            if !typed.isEmpty {
                Text(HintPresentation.displayLabel(typed))
                    .font(.system(size: Slate.Typeface.footnote, weight: .bold, design: .monospaced))
                    .foregroundStyle(Slate.Text.onWarn)
            }
            closeButton
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(Slate.Status.warn, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .slateShadow(.chip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HintPresentation.badgeAccessibilityLabel(intent))
        .accessibilityHint(HintPresentation.badgeAccessibilityHint)
    }

    /// The `×` exit glyph — leaves hint mode (the same seam Esc / the dim-plate tap fire).
    private var closeButton: some View {
        Button(action: onExit) {
            Image(systemName: "xmark")
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Text.onWarn.opacity(closeHover ? 1 : Slate.Opacity.muted))
                // ⚠️ 16×16 is UNNAMED and spelled four times across this directory. Proposed
                // `Slate.Metric.glyphPlate`.
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp(HintPresentation.exitHelp)
    }
}
#endif
