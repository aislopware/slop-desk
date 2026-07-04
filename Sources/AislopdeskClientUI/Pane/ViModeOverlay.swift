// ViModeOverlay — the vi / copy-mode VIEW layer (E17 ES-E17-2/3 / WI-5): the per-pane ``ViModePill`` (the
// persistent mode badge with a live repeat-count + an `×` exit) and the on-demand ``ViKeyHintBar`` (the `⌘/`
// reference card). This is the copy-mode overlay that the REBUILD-V2 leaf was missing — it rides the EXISTING
// pure copy-mode engine in ``TerminalViewModel`` (WI-4): both views read the OBSERVABLE mirrors
// (``TerminalViewModel/viVisualMode`` / ``viPendingCount`` / ``showViKeyHints`` / ``copyModeBadgeActive``),
// never the `@ObservationIgnored` `isCopyMode` flag the renderer's keyDown path reads, so they re-render
// reactively without ever touching the keyDown intercept's AttributeGraph hazard.
//
// The vi pill renders inside the terminal pane itself. aislopdesk has NO persistent titlebar, so — like
// ``ReadOnlyPill`` — the pill floats in the pane's TOP-TRAILING overlay region; the key-hint bar floats along
// the pane BOTTOM. The leaf gates BOTH on `copyModeBadgeActive` and tears them down when copy-mode exits
// (``TerminalViewModel/exitCopyMode()`` clears the flag + resets the hint bar).
//
// NATIVE chrome (system semantic colors / text styles / materials — the 2026-07-03 native-chrome migration);
// the pill and hint bar float over the theme-driven terminal canvas. No libghostty / Metal / VideoToolbox is
// touched (CLAUDE.md rule #6): plain SwiftUI chips driven by the pane model's observables.
//
// HONESTY (the "nothing is a dead key" rule + the documented libghostty ceiling): the ``ViKeyHintBar`` lists
// ONLY the keys ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires in aislopdesk's copy-mode — a faithful
// SUBSET of full vi. Column / word / screen motions (`h`/`l`, `w`/`b`/`e`, `0`/`$`/`^`, `H`/`M`/`L`) AND the
// visual anchor-swap (`o`) are NOT wired — the pinned fork exposes no programmatic cursor-move / set-selection /
// swap-ends action (Binding.zig has `adjust_selection` + `select_all` but no swap-ends; see DECISIONS.md E17,
// which pins `o` as a documented NO-OP) — so they are deliberately omitted rather than advertised as dead keys.
// Hint Mode (`f`), by contrast, IS wired and IS listed: it does NOT depend on that cursor-move ceiling — it is a
// separate visible-viewport label overlay (E10) armed via ``TerminalViewModel/beginHint(_:)``, the same seam the
// ⌘⇧J chord uses — so `f` is an honest entry, not a faked motion.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// The vi-mode pill (E17 ES-E17-2 / WI-5) — the persistent badge shown in the pane's top-trailing overlay while
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
        HStack(spacing: 4) {
            Image(systemSymbol: .characterCursorIbeam)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(modeLabel)
                .font(.subheadline.weight(.semibold))
                .tracking(0.5) // the small-caps / uppercase spacing the visual labels share
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
            // The LIVE repeat-count: the accumulated digits the user typed before a motion (e.g. `5` before `j`).
            // Accent-toned + monospaced so the running count reads at a glance; absent when no count is pending.
            if let count = model.viPendingCount {
                Text(String(count))
                    .font(.subheadline.weight(.semibold).monospaced())
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            closeButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // The shared theme-tinted glass shell, but with `ringed: false` — this pill draws its OWN ring so a
        // visual selection can swap in the accent (below); plain navigation wears the standard glass ring tone.
        .glassPanel(radius: 6, shadowRadius: 6, ringed: false)
        .overlay(
            // Plain navigation wears the same subtle hairline as the read-only pill; a visual selection swaps in
            // the accent ring so the "I am selecting" state is unmistakable beside the count.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    inVisualMode ? AnyShapeStyle(Color.accentColor.opacity(0.5)) : AnyShapeStyle(GlassPanel.ring),
                    lineWidth: 1,
                ),
        )
        .animation(.easeOut(duration: 0.12), value: model.viPendingCount)
        .animation(.easeOut(duration: 0.12), value: model.viVisualMode)
        // Belt-and-suspenders Escape dismiss (C5): the primary exit is the renderer's `keyDown` →
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
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(
                    closeHover ? Color.primary.opacity(0.12) : .clear,
                    in: .rect(cornerRadius: 4),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
        .slateHelp("Exit vi mode")
    }
}

// MARK: - Key-hint bar

/// The vi key-hint bar (E17 ES-E17-2 / WI-5) — the on-demand reference card toggled by `⌘/` while in vi mode
/// (off by default; ``TerminalViewModel/showViKeyHints`` drives its visibility, flipped by
/// ``TerminalViewModel/toggleViKeyHints()``). Floats along the pane BOTTOM (the spec's likely position) and
/// lists, in compact columns, the keys aislopdesk's copy-mode ACTUALLY wires — a faithful subset of full vi
/// (see the file header for the honest-omission rationale). Pure presentation: no model reads, no state.
struct ViKeyHintBar: View {
    /// One reference entry: the key chip(s) and what they do.
    private struct Hint: Identifiable {
        let keys: [String]
        let label: String
        var id: String { keys.joined(separator: " ") + "|" + label }
    }

    private static let motion: [Hint] = [
        Hint(keys: ["j", "k"], label: "Scroll line"),
        Hint(keys: ["⌃d", "⌃u"], label: "Half page"),
        Hint(keys: ["⌃f", "⌃b"], label: "Full page"),
        Hint(keys: ["g", "G"], label: "Top / bottom"),
        Hint(keys: ["[", "]"], label: "Prev / next prompt"),
        Hint(keys: ["1", "…", "9"], label: "Repeat count"),
    ]

    // `o` (swap selection ends) is DELIBERATELY ABSENT: it is a documented NO-OP (the pinned libghostty fork
    // exposes no swap-ends / set-selection action — see the file header + DECISIONS.md E17), so listing it would
    // advertise a dead key, exactly the omission this bar makes for the other unwired vi motions (h/l/w/b/e/…).
    // `f` (Enter Hint Mode) IS listed — unlike the cursor motions it is wired (it rides the E10 Hint Mode
    // overlay via `beginHint`, NOT the blocked cursor-move action), so advertising it is honest, not a dead key.
    private static let selection: [Hint] = [
        Hint(keys: ["v"], label: "Visual"),
        Hint(keys: ["V"], label: "Visual line"),
        Hint(keys: ["⌃v"], label: "Visual block"),
        Hint(keys: ["y", "↩"], label: "Yank + exit"),
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
        HStack(alignment: .top, spacing: 16) {
            column("MOTION", Self.motion)
            column("SELECT", Self.selection)
            column("SEARCH", Self.search)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassPanel(radius: 6, shadowRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vi mode key hints")
    }

    /// One labelled column of hints (heading + rows).
    private func column(_ heading: String, _ hints: [Hint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            ForEach(hints) { hint in
                hintRow(hint)
            }
        }
    }

    /// One hint row — the key chip(s) followed by the description.
    private func hintRow(_ hint: Hint) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in
                keycap(key)
            }
            Text(hint.label)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        } else {
            Text(key)
                .font(.caption.weight(.medium).monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, 4)
                // The native keycap inset: a faint primary wash + hairline, on the material bar above.
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.separator, lineWidth: 1),
                )
        }
    }
}
#endif
