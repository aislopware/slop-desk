// SlateTabRow — the sidebar tab row, descended from otty's `TabsPanelRowView` but on the house
// ladder: one `heightTabRow` line, title in the SYSTEM face (13pt) resting on the SECONDARY ink,
// an optional leading `✳` agent marker IN the title run, and one fixed trailing slot that carries
// the resting SHELL LABEL (`zsh` — the mono metadata voice) or a privilege marker
// (``TabBadgeView`` — `#`/`∞`) plus the STATUS DOT at the right edge, swapping to the close `×`
// under hover.
//
// Status speaks TWICE, in agreement (the T3 Code pairing — dot + tinted label): the title's own
// ink and weight carry the words (``StatusPresentation/attentionInk(_:)`` — amber = a question
// waits; red = failed; green = unread finish, cleared on visit — plus the `.medium` step the
// active card uses), and the trailing ``StatusDotView`` repeats the SAME ink as one flat circle
// in a fixed right-edge column, so the two can never disagree about one pane. A WORKING AGENT's
// motion is the title's shimmer (``WorkingShimmer``) plus the dot's accent pulse; a running
// COMMAND's title stands still while the dot pulses muted; an IDLE row mounts no dot at all. The
// ink stays IN the title run and the dot — no row wash, no tinted fill: the rail is monochrome
// except the marks that carry state. ACTIVE is the raised card (fill + 1px hairline; the cast
// shadow is light-theme-only). Nothing else rides the row: no subtitle, no readout, no telemetry
// — the richness lives in the hover tooltip and the context menu.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// One sidebar tab row. ACTIVE = the raised card; hover = flat plate + close `×` in the trailing slot.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// Whether the title wears the leading `✳` AGENT marker (an agent session's row, the otty
    /// integration's title prefix). Display-only — the rename field seeds from the bare `title`.
    var agentMarker: Bool = false
    /// The fused status kind for the row — the FULL resolver output, busy tiers included.
    /// Attention kinds recolour the TITLE's ink (the ink dialect) and ink the trailing status
    /// dot; the busy tiers feed the dot's muted pulse; only the privilege markers (`#`/`∞`)
    /// occupy the slot as TEXT (``TabBadgeView``).
    var badge: TabBadgeKind?
    /// Non-`nil` ⇒ a WORKING AGENT row: the title wears the working shimmer (the stepped dark-band
    /// sweep — the title text IS the motion indicator; no glyph spins) on the primary ink. The
    /// string is the terse state reading ("Agent working"), carried as the title's accessibility
    /// value so VoiceOver keeps the state the spinner glyph used to speak. A running COMMAND never
    /// sets this — its title (the command text) stands still.
    var workingLabel: String?
    /// The resting trailing label — the pane's foreground process (`zsh`, `vim`), shown only when
    /// no privilege marker outranks it. `nil` ⇒ the slot rests empty (an AGENT row always passes
    /// `nil`: the `✳` marker and the shimmer already say everything a trailing label would repeat).
    var processLabel: String?
    /// Whether this pane's input gate is READ-ONLY — a small trailing lock glyph (the sidebar's
    /// read-only indicator, twin of the pane's `🔒 READ ONLY ×` pill).
    var readOnly: Bool = false
    /// Whether this pane's TAB is armed for synchronized input (⌘⇧I) — the fixed sync-amber grouped-
    /// panes glyph, so an armed tab is visible even from the rail.
    var syncInput: Bool = false
    /// Whether the row is in inline-RENAME mode — swaps the title `Text` for a committing `TextField`.
    var isEditing: Bool = false
    /// The row's tooltip text (full cwd / live agent line / last command) — shown on hover via `.help`.
    var helpText: String?
    var onSelect: () -> Void
    var onClose: () -> Void
    /// Commit the inline rename with the field's current text. No-op default keeps call sites compatible.
    var onRename: (String) -> Void = { _ in }
    /// Dismiss the inline rename without renaming (escape / focus loss). No-op default.
    var onCancelRename: () -> Void = {}
    /// Open the inline rename field — the double-click affordance (the Finder idiom), twin of the
    /// context-menu "Rename" / ⌘R. No-op default keeps call sites compatible.
    var onBeginRename: () -> Void = {}

    @State private var hovering = false
    @State private var closeHover = false
    /// The inline-rename draft text — seeded from `title` when the field opens.
    @State private var draft = ""
    /// Whether the inline rename has already been RESOLVED by Return (commit) or Escape (cancel) — so the
    /// focus-loss handler that fires when the field is torn down does NOT re-commit the draft (which would make
    /// Escape accidentally RENAME to the draft, and Return commit twice). A genuine click-away leaves this
    /// `false`, so that path still commits once. Reset per field-open via `.onAppear`.
    @State private var renameResolved = false
    @FocusState private var fieldFocused: Bool

    /// The trailing slot's minimum footprint (the otty 28×18 reserve) — the title truncates before
    /// the slot, and the hover `×` always has a landing zone even on a bare row.
    private static let slotMinWidth: CGFloat = 28
    private static let slotHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                renameField
            } else {
                // `\u{FE0E}` pins the ✳ to TEXT presentation — bare U+2733 renders as emoji on
                // Apple platforms, which would break the ink-only title run.
                Text(agentMarker ? "✳\u{FE0E} \(title)" : title)
                    // Attention pairs WEIGHT with the ink (the Slack/tmux idiom: bold says
                    // "something changed", the hue says what) — the same `.medium` step the
                    // active card takes, so the two signals share one scale.
                    .font(.system(
                        size: Slate.Typeface.body,
                        weight: active || attentionLabel != nil ? .medium : .regular,
                    ))
                    .workingShimmer(workingLabel != nil, ink: titleInk)
                    .lineLimit(1)
                    // The state the title's ink/motion speaks visually, kept legible for VoiceOver
                    // (the trailing slot carries no lifecycle glyph to label).
                    .accessibilityValue(workingLabel ?? attentionLabel ?? "")
            }
            Spacer(minLength: 6)
            if !isEditing { trailing }
        }
        .padding(.horizontal, Slate.Metric.tabRowInset)
        .frame(height: Slate.Metric.heightTabRow)
        .background(rowBackground, in: .rect(cornerRadius: Slate.Metric.radiusTab))
        .overlay { if active { RoundedRectangle(cornerRadius: Slate.Metric.radiusTab).strokeBorder(
            Slate.Line.card,
            lineWidth: Slate.Metric.cardBorderWidth,
        ) } }
        // The active-card lift: black 4%, radius 2, y 1 on a LIGHT theme; dark themes cast nothing
        // (`cardShadow` resolves clear — fill + hairline carry the lift). Hover/rest cast nothing.
        .shadow(color: active ? Slate.State.cardShadow : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        // The tap SELECTS — but only when NOT renaming, so a click inside the field lands in the
        // field — and a DOUBLE-click opens the inline rename (the Finder idiom). The single-tap arm
        // rides `simultaneousGesture` so selection fires on the FIRST click (never waiting out a
        // double-click window); the second click then opens the field on the already-selected row.
        .gesture(TapGesture(count: 2).onEnded { if !isEditing { onBeginRename() } })
        .simultaneousGesture(TapGesture().onEnded { if !isEditing { onSelect() } })
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .animation(Slate.Anim.smallFade, value: active)
        .help(helpText ?? "")
    }

    private var rowBackground: Color {
        if active { Slate.Surface.raised }
        else if hovering { Slate.State.hover }
        else { .clear }
    }

    /// The title's ink. An ATTENTION state recolours the whole title run (marker included) on the
    /// hue budget — the ink dialect's entire rendering. Otherwise the live-otty ladder: a resting
    /// title reads on the SECONDARY ink; the active card's title steps up to primary (with the
    /// weight bump), and a THINKING agent's title also steps up — the brighter base gives the
    /// shimmer's dark band its full contrast range.
    private var titleInk: Color {
        if let badge, let ink = StatusPresentation.attentionInk(badge) { return ink }
        return active || workingLabel != nil ? Slate.Text.primary : Slate.Text.secondary
    }

    /// The AX value for an attention-inked title ("Awaiting input" / "Error" / "Finished"), so the
    /// colour-spoken state stays VoiceOver-legible.
    private var attentionLabel: String? {
        guard let badge, StatusPresentation.attentionInk(badge) != nil else { return nil }
        return StatusPresentation.tabBadgeLabel(badge)
    }

    /// The trailing cluster: the rare mode glyphs (lock / sync) ride OUTSIDE the swap slot so a mode
    /// never vanishes under hover; the slot itself holds badge-or-shell-label at rest and the close
    /// `×` under hover (an opacity swap in a fixed reserve — the fade never reflows the title).
    private var trailing: some View {
        HStack(spacing: 6) {
            if readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
                    .help("Read only")
            }
            if syncInput {
                // The FIXED sync-amber (NOT the muted secondary tone the lock uses): sync input is a
                // fan-out mode, and its rail indicator must be as unmissable as the pane pill.
                Image(systemSymbol: .rectangle3Group)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Status.syncInput)
                    .accessibilityLabel("Sync input")
                    .help("Sync input — keystrokes mirror to every pane in this tab")
            }
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    Group {
                        // Only a PRIVILEGE marker occupies the slot as text — attention states
                        // render as the title's ink, so their rows keep the shell label here.
                        if let badge, StatusPresentation.tabBadge(badge) != nil {
                            TabBadgeView(kind: badge)
                        } else if let processLabel {
                            // The metadata voice (MERIDIAN L2): a process name is DATA, so it reads
                            // in the instrument mono at the caption size on the tertiary ink — one
                            // register with the git line, counts and telemetry.
                            Text(processLabel)
                                .font(Slate.Typeface.instrument(Slate.Typeface.small))
                                .foregroundStyle(Slate.Text.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    // The status dot — RIGHTMOST, so state reads down one fixed column no matter
                    // how wide the label beside it runs (the T3 Code pairing: dot + tinted text).
                    if let dot = StatusPresentation.statusDot(
                        working: workingLabel != nil, badge: badge,
                    ) {
                        StatusDotView(style: dot)
                    }
                }
                .opacity(hovering ? 0 : 1)
                closeButton
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .frame(minWidth: Self.slotMinWidth, alignment: .trailing)
            .frame(height: Self.slotHeight)
        }
    }

    /// The inline-rename `TextField`: seeded from the current title on open, auto-focused, commits
    /// on Return (`onSubmit` → `onRename`) and cancels on Escape (`onExitCommand` → `onCancelRename`). A blank
    /// commit is a no-op rename (the store keeps the folder-name title), so the field never blanks the row.
    ///
    /// An UNTOUCHED draft (still exactly the seed title) resolves as a CANCEL, not a commit: the seed
    /// is the row's LIVE title (intent / running command / generic fallback), and committing it verbatim
    /// would freeze that snapshot as a sticky `userRenamed` identity — a double-click followed by a
    /// click-away must leave the live title chain in charge. Only an edit expresses a rename.
    private var renameField: some View {
        let field = TextField("Rename", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
            .foregroundStyle(Slate.Text.primary)
            .tint(Slate.State.accent)
            .lineLimit(1)
            .focused($fieldFocused)
            .onAppear {
                draft = title
                renameResolved = false
                fieldFocused = true
            }
            .onSubmit {
                renameResolved = true
                if draft == title { onCancelRename() } else { onRename(draft) }
            }
            // Focus loss (click elsewhere) commits the draft — matches a Finder rename field — UNLESS the
            // rename was already resolved by Return/Escape (the field's teardown flips focus off, and re-firing
            // here would make Escape rename to the draft / Return commit twice).
            .onChange(of: fieldFocused) { _, focused in
                guard !focused, !renameResolved else { return }
                if draft == title { onCancelRename() } else { onRename(draft) }
            }
        // Escape cancels the rename — `onExitCommand` is macOS/tvOS-only, so guard it off iOS.
        #if os(macOS)
        return field.onExitCommand {
            renameResolved = true
            onCancelRename()
        }
        #else
        return field
        #endif
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: 18, height: 18)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
    }
}
#endif
