// SlateTabRow — the sidebar tab row, a 1:1 port of otty's `TabsPanelRowView`, pixel-sampled off the
// LIVE otty app (grouped-sidebar build) at 1×: a 36pt line, title in the SYSTEM face (13pt) that
// rests on the SECONDARY ink and steps up to primary + medium only when active, an optional leading
// `✳` agent marker IN the title run (otty's agent integration literally prefixes the title string),
// and one fixed trailing slot that carries the resting SHELL LABEL (`zsh` — muted 11pt) or an
// attention-class badge (``TabBadgeView``), swapping to the close `×` under hover. BUSY rows keep
// the slot for the shell label — motion lives in the TITLE's working shimmer (``WorkingShimmer``),
// never a spinning glyph. ACTIVE is the raised card
// (fill + 1px hairline + the 4% cast shadow); hover is the flat plate. Nothing else rides the row:
// no subtitle, no readout, no telemetry — the richness lives in the hover tooltip and the context
// menu, which is the otty way.

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
    /// The fused status badge (``TabBadgeView``) — occupies the trailing slot when present. Busy
    /// tiers never land here: the caller passes them as ``workingLabel`` instead, so the slot keeps
    /// the shell label while a command runs.
    var badge: TabBadgeKind?
    /// Non-`nil` ⇒ the row is in a BUSY tier and the title wears the working shimmer (the stepped
    /// dark-band sweep — the title text IS the motion indicator; no glyph spins). The string is the
    /// terse state reading ("Agent working" / "Running"), carried as the title's accessibility value
    /// so VoiceOver keeps the state the spinner glyph used to speak.
    var workingLabel: String?
    /// The resting trailing label — the pane's foreground process (`zsh`, `vim`, `claude`), shown
    /// only when no badge outranks it. `nil` ⇒ the slot rests empty.
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
                    .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                    // The live-otty ink ladder: a resting title reads on the SECONDARY ink; only the
                    // active card's title steps up to primary (with the weight bump). A busy row
                    // shimmers the same ink — the stepped dark band sweeping the title is the whole
                    // "in motion" reading.
                    .workingShimmer(
                        workingLabel != nil,
                        ink: active ? Slate.Text.primary : Slate.Text.secondary,
                    )
                    .lineLimit(1)
                    .accessibilityValue(workingLabel ?? "")
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
        // The measured active-card lift: black 4% (light), radius 2, y 1 — hover/rest cast nothing.
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
                Group {
                    if let badge {
                        TabBadgeView(kind: badge)
                    } else if let processLabel {
                        Text(processLabel)
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.secondary)
                            .lineLimit(1)
                            .fixedSize()
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
                onRename(draft)
            }
            // Focus loss (click elsewhere) commits the draft — matches a Finder rename field — UNLESS the
            // rename was already resolved by Return/Escape (the field's teardown flips focus off, and re-firing
            // here would make Escape rename to the draft / Return commit twice).
            .onChange(of: fieldFocused) { _, focused in
                if !focused, !renameResolved { onRename(draft) }
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
