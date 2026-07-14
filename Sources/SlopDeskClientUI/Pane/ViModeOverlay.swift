// ViModeOverlay — the vi / copy-mode VIEW layer: the per-pane ``ViModePill`` (the
// persistent mode badge with a live repeat-count + an `×` exit) and the on-demand ``ViKeyHintBar`` (the `⌘/`
// reference card). This is the copy-mode overlay that the REBUILD-V2 leaf was missing — it rides the EXISTING
// pure copy-mode engine in ``TerminalViewModel``: both views read the OBSERVABLE mirrors
// (``TerminalViewModel/viVisualMode`` / ``viPendingCount`` / ``showViKeyHints`` / ``copyModeBadgeActive``),
// never the `@ObservationIgnored` `isCopyMode` flag the renderer's keyDown path reads, so they re-render
// reactively without ever touching the keyDown intercept's AttributeGraph hazard.
//
// The vi pill renders inside the terminal pane itself. slopdesk has NO persistent titlebar, so — like
// ``ReadOnlyPill`` — the pill floats in the pane's TOP-TRAILING overlay region; the key-hint bar floats along
// the pane BOTTOM. The leaf gates BOTH on `copyModeBadgeActive` and tears them down when copy-mode exits
// (``TerminalViewModel/exitCopyMode()`` clears the flag + resets the hint bar).
//
// `Slate.*` tokens ONLY — raw font / radius / colour literals fail `scripts/check-ds-leaks.sh`. No libghostty /
// Metal / VideoToolbox is touched (CLAUDE.md rule #6): plain SwiftUI chips driven by the pane model's
// observables.
//
// HONESTY (the "nothing is a dead key" rule): the ``ViKeyHintBar`` lists ONLY the keys
// ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires in slopdesk's copy-mode — a faithful subset of
// full vi. Since the E17 ceiling LIFT (DECISIONS.md 2026-07-14: the fork gained a set-selection /
// viewport-info ABI) that subset includes the CURSOR motions — `h`/`l`, `w`/`b`/`e`, `0`/`^`/`$` — plus the
// visual anchor-swap `o` and the `Y` line-yank, all of which were previously omitted as unwired. Still
// deliberately absent: `H`/`M`/`L` (screen-relative jumps, not wired). Hint Mode (`f`) is a separate
// visible-viewport label overlay armed via ``TerminalViewModel/beginHint(_:)``, the same seam the ⌘⇧J
// chord uses.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// The vi-mode pill — the persistent badge shown in the pane's top-trailing overlay while
/// the pane is in vi / copy-mode. Faithful to the vi-mode spec's pill description: the current MODE label
/// (`VI` for plain scrollback navigation, `VISUAL` / `VISUAL LINE` / `VISUAL BLOCK` in a visual selection) + the
/// LIVE pending repeat-count digits (shown in the accent tone as the user types `5` before a motion) + an `×`
/// control that exits vi mode.
///
/// Reads the pane model's OBSERVABLE mirrors directly (``TerminalViewModel`` is `@Observable`), so the label
/// swaps and the count appears / clears reactively as ``TerminalViewModel/handleCopyModeKey(_:)`` mutates the
/// pure state and syncs the twins. The `×` calls ``onExit`` — ``TerminalLeafView`` wires it to the model's
/// ``TerminalViewModel/exitCopyMode()`` (the single exit seam, which also resets the count / visual mode / hint
/// bar), so the pill, the `Esc`/`q` keys, and a programmatic dismiss all converge on one state.
struct ViModePill: View {
    /// The pane's terminal model — the observable source of the mode label + the live repeat-count.
    let model: TerminalViewModel
    /// Called when the user clicks `×` to leave vi mode — the leaf routes it to ``TerminalViewModel/exitCopyMode()``.
    let onExit: () -> Void

    @State private var closeHover = false

    /// The mode label: a visual mode's own label, else the bare `VI` (plain scrollback navigation).
    private var modeLabel: String { model.viVisualMode.pillLabel ?? "VI" }

    /// Whether a visual selection mode is active (drives the accent ring — the pill stands out while selecting).
    private var inVisualMode: Bool { model.viVisualMode != .none }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .characterCursorIbeam)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Text(modeLabel)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .tracking(0.5) // the small-caps / uppercase spacing the visual labels share
                .foregroundStyle(Slate.Text.primary)
                .lineLimit(1)
                .fixedSize()
            // The LIVE repeat-count: the accumulated digits the user typed before a motion (e.g. `5` before `j`).
            // Accent-toned + monospaced so the running count reads at a glance; absent when no count is pending.
            if let count = model.viPendingCount {
                Text(String(count))
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Slate.State.accent)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            closeButton
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(
            // Plain navigation wears the same subtle hairline as the read-only pill; a visual selection swaps in
            // the accent ring so the "I am selecting" state is unmistakable beside the count.
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(
                    inVisualMode ? Slate.State.accent.opacity(0.5) : Slate.Line.subtle,
                    lineWidth: Slate.Metric.hairline,
                ),
        )
        .shadow(color: Slate.State.shadow, radius: 4, x: 0, y: 1)
        .animation(Slate.Anim.smallFade, value: model.viPendingCount)
        .animation(Slate.Anim.smallFade, value: model.viVisualMode)
        // Belt-and-suspenders Escape dismiss: the primary exit is the renderer's `keyDown` →
        // `exitCopyMode()` once the terminal is first responder (the routing now nudges focus there on arm).
        // This safety net — if Escape lands in the pill's responder chain instead of the surface — still leaves
        // vi/copy-mode via the SAME `onExit` seam the `×` fires (macOS `onExitCommand`, which is unavailable on
        // iOS, so the iOS slice uses the equivalent `.onKeyPress(.escape)`).
        #if os(macOS)
            .onExitCommand { onExit() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                onExit()
                return .handled
            }
        #endif
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Exit vi mode")
    }

    /// The combined a11y label — the mode plus any pending count, so VoiceOver reads "Vi mode VISUAL 5".
    private var accessibilityLabel: String {
        var parts = ["Vi mode", modeLabel]
        if let count = model.viPendingCount { parts.append(String(count)) }
        return parts.joined(separator: " ")
    }

    /// The `×` exit glyph — LIGHTER than the label (the ``ReadOnlyPill`` close-button idiom), with the subtle
    /// hover plate. Leaves vi mode via ``onExit``.
    private var closeButton: some View {
        Button(action: onExit) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.secondary)
                .frame(width: 16, height: 16)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp("Exit vi mode")
    }
}

// MARK: - Key-hint bar

/// The vi key-hint bar — the on-demand reference card toggled by `⌘/` while in vi mode
/// (off by default; ``TerminalViewModel/showViKeyHints`` drives its visibility, flipped by
/// ``TerminalViewModel/toggleViKeyHints()``). Floats along the pane BOTTOM (the spec's likely position) and
/// lists, in compact columns, the keys slopdesk's copy-mode ACTUALLY wires — a faithful subset of full vi
/// (see the file header for the honest-omission rationale). Pure presentation: no model reads, no state.
struct ViKeyHintBar: View {
    /// One reference entry: the key chip(s) and what they do.
    private struct Hint: Identifiable {
        let keys: [String]
        let label: String
        var id: String { keys.joined(separator: " ") + "|" + label }
    }

    private static let motion: [Hint] = [
        Hint(keys: ["h", "j", "k", "l"], label: "Move cursor"),
        Hint(keys: ["w", "b", "e"], label: "Word motions"),
        Hint(keys: ["0", "^", "$"], label: "Line start / end"),
        Hint(keys: ["⌃d", "⌃u"], label: "Half page"),
        Hint(keys: ["⌃f", "⌃b"], label: "Full page"),
        Hint(keys: ["g", "G"], label: "Top / bottom"),
        Hint(keys: ["[", "]"], label: "Prev / next prompt"),
        Hint(keys: ["1", "…", "9"], label: "Repeat count"),
    ]

    // Every row here is WIRED (the honesty rule): the cursor motions + `o` + `Y` joined the bar with the
    // E17 ceiling lift (see the file header); `f` rides the Hint Mode overlay via `beginHint`, its own seam.
    private static let selection: [Hint] = [
        Hint(keys: ["v"], label: "Visual"),
        Hint(keys: ["V"], label: "Visual line"),
        Hint(keys: ["⌃v"], label: "Visual block"),
        Hint(keys: ["o"], label: "Swap ends"),
        Hint(keys: ["y", "↩"], label: "Yank + exit"),
        Hint(keys: ["Y"], label: "Yank line"),
        Hint(keys: ["f"], label: "Hint links"),
    ]

    private static let search: [Hint] = [
        Hint(keys: ["/"], label: "Find forward"),
        Hint(keys: ["?"], label: "Find backward"),
        Hint(keys: ["n", "N"], label: "Next / prev match"),
        Hint(keys: ["Esc", "q"], label: "Exit vi mode"),
        Hint(keys: ["⌘/"], label: "Toggle this bar"),
    ]

    /// Every key chip the bar advertises, flattened across all columns (separator tokens like `…` excluded) —
    /// the honesty surface a test reads to prove the bar lists ONLY wired keys (e.g. never the dead `o`). The
    /// view body renders from the SAME static arrays, so this can never drift from what is shown.
    static var advertisedKeys: [String] {
        (motion + selection + search).flatMap(\.keys).filter { $0 != "…" }
    }

    var body: some View {
        // RESPONSIVE: the reference card re-flows to the pane's width instead of clipping — three
        // columns side-by-side when they fit, else MOTION beside a stacked SELECT+SEARCH, else one
        // tall column (a narrow split pane still gets the whole card). `ViewThatFits` proposes the
        // pane width; the `fixedSize()` rows keep each layout's intrinsic width honest so the first
        // layout that truly fits wins.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Slate.Metric.space4) {
                column("MOTION", Self.motion)
                column("SELECT", Self.selection)
                column("SEARCH", Self.search)
            }
            HStack(alignment: .top, spacing: Slate.Metric.space4) {
                column("MOTION", Self.motion)
                VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                    column("SELECT", Self.selection)
                    column("SEARCH", Self.search)
                }
            }
            VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                column("MOTION", Self.motion)
                column("SELECT", Self.selection)
                column("SEARCH", Self.search)
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, Slate.Metric.space2)
        .background(Slate.Surface.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
        .shadow(color: Slate.State.shadow, radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vi mode key hints")
    }

    /// One labelled column of hints (heading + rows).
    private func column(_ heading: String, _ hints: [Hint]) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(heading)
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Slate.Text.tertiary)
                .padding(.bottom, Slate.Metric.space1)
            ForEach(hints) { hint in
                hintRow(hint)
            }
        }
    }

    /// One hint row — the key chip(s) followed by the description.
    private func hintRow(_ hint: Hint) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in
                keycap(key)
            }
            Text(hint.label)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// A single key chip — mirrors the keyboard cheat sheet's `keycapChip` so the two reference surfaces read
    /// identically. A separator token (`…`) renders as bare text (no plate) so `1 … 9` reads as a range.
    @ViewBuilder
    private func keycap(_ key: String) -> some View {
        if key == "…" {
            Text(key)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.tertiary)
        } else {
            Text(key)
                .font(.system(size: Slate.Typeface.small, weight: .medium, design: .monospaced))
                .foregroundStyle(Slate.Text.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, Slate.Metric.space1)
                .background(Slate.Surface.face, in: .rect(cornerRadius: Slate.Metric.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                        .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                )
        }
    }
}
#endif
