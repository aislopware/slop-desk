// HintModeOverlay — the Vimium-style Hint Mode VIEW layer (E10 WI-9 / ES-E10-6, `terminal-features__hint-mode`).
//
// A DECORATION overlay layered OVER the terminal surface in `TerminalLeafView` (never a content branch — the
// libghostty-freeze guardrail): while the pane model has an armed intent (``TerminalViewModel/hintMode``), it
// DIMS the surface (so labels pop), draws a yellow 2-letter badge at each detected target —
// mapped to points by the WI-2 ``TerminalCellMetrics`` (the SAME geometry seam the ⌘-hold underline uses) — and
// shows a `HINTS · <intent> · Esc Exit` badge top-trailing (the `hint-mode.png` chrome; aislopdesk has no
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

#if canImport(SwiftUI)
import AislopdeskTerminal
import AislopdeskWorkspaceCore
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
           metrics.cellWidth > 0, metrics.cellHeight > 0
        {
            let typed = model.hintTyped
            let labels = model.hintLabels
            let targets = model.hintTargets
            let matched = Set(HintLabelAssigner.filter(typed: typed, labels: labels).matched)

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
                    // CLAMP to the visible grid (FINDING 3 defence): a target whose first cell lands
                    // off-screen-right (a soft-wrap-shifted span) is SKIPPED, never anchored in the void.
                    if let rect = metrics.clampedRect(
                        row: pair.0.row, colStart: pair.0.colStart, colEnd: pair.0.colEnd,
                    ) {
                        HintLabelBadge(label: pair.1, typed: typed, dimmed: !matched.contains(pair.1))
                            .offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { model.confirmHintTarget(pair.0) } // iOS tap-on-label fallback
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                HintModeBadge(intent: intent, typed: typed, onExit: { model.cancelHintMode() })
                    .padding(Slate.Metric.space2)
            }
            // Belt-and-suspenders Escape dismiss (C4): the primary cancel is the renderer's `keyDown` →
            // `cancelHintMode()` once the terminal is first responder (the routing now nudges focus there). This
            // safety net — if Escape lands in the overlay's responder chain instead of the surface — still cancels
            // the mode (the same idiom PaletteView / OpenQuicklyView use: macOS `onExitCommand`, which is
            // unavailable on iOS, so the iOS slice uses the equivalent `.onKeyPress(.escape)`).
            #if os(macOS)
            .onExitCommand { model.cancelHintMode() }
            #else
            .onKeyPress(.escape, phases: .down) { _ in
                model.cancelHintMode()
                return .handled
            }
            #endif
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
            .frame(minHeight: 14)
            .background(Slate.Status.warn, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    // A thin dark hairline so the yellow plate reads on a light background too.
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: Slate.Metric.hairline),
            )
            .opacity(dimmed ? 0.2 : 1)
            .fixedSize()
            .accessibilityLabel("Hint \(label.uppercased())")
    }

    /// The 2 uppercase letters — already-typed letters faded (progress cue), the rest solid black. Black on the
    /// fixed-yellow plate is theme-independent + high-contrast (the hint-mode spec; the secure-input-pill rationale).
    private var labelText: Text {
        // Concatenate per-character `Text` runs left-to-right. `reduce` (not `out = out + …`) because SwiftUI's
        // `Text` defines `+` but no `+=`, so the shorthand the loop form would invite does not exist.
        Array(label.uppercased()).enumerated().reduce(Text(verbatim: "")) { accumulated, item in
            let faded = item.offset < typed.count
            let glyph = Text(String(item.element)).foregroundStyle(faded ? Color.black.opacity(0.35) : Color.black)
            return accumulated + glyph
        }
    }
}

// MARK: - Mode badge (top-trailing "HINTS · Esc Exit")

/// The `HINTS` mode badge (the `hint-mode.png` titlebar chip; floated in the pane's top-trailing region since
/// aislopdesk has no titlebar). Shows the active intent + the keys typed so far + an `×` to leave the mode.
private struct HintModeBadge: View {
    let intent: HintIntent
    let typed: String
    let onExit: () -> Void

    @State private var closeHover = false

    private var intentLabel: String {
        switch intent {
        case .open: "OPEN"
        case .copy: "COPY"
        case .reveal: "REVEAL"
        }
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text("HINTS")
                .font(.system(size: Slate.Typeface.footnote, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Color.black)
            Text(intentLabel)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color.black.opacity(0.6))
            if !typed.isEmpty {
                Text(typed.uppercased())
                    .font(.system(size: Slate.Typeface.footnote, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.black)
            }
            closeButton
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(Slate.Status.warn, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .shadow(color: Slate.State.shadow, radius: 4, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hint mode \(intentLabel)")
        .accessibilityHint("Press a label, or Escape to exit")
    }

    /// The `×` exit glyph — leaves hint mode (the same seam Esc / the dim-plate tap fire).
    private var closeButton: some View {
        Button(action: onExit) {
            Image(systemName: "xmark")
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Color.black.opacity(closeHover ? 1 : 0.6))
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp("Exit hint mode (Esc)")
    }
}
#endif
