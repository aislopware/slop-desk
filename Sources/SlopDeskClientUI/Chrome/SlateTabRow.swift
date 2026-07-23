// SlateTabRow — the sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// built on the shared `SlateListRow` shell and wired to the live store via the navigator. The resting row
// is the tab name on the sidebar ground; ACTIVE is the RAISED card (fill + 1px hairline, no shadow), hover
// is a flat plate, and a close `×` reveals on hover. No native list selection / vibrancy — this is a flat
// silhouette by design.
//
// Every row shares ONE grid, left→right: [2pt attention-tick gutter][content][4ch telemetry][16pt badge
// rail]. The tick, telemetry column and badge rail are ALL unconditional reservations — the rail rides a
// full-height trailing overlay at a constant x AND constant vertical anchor (never per-line), so no state
// change moves a pixel and the badge column is one continuous scan line down the sidebar.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// One sidebar tab row. ACTIVE = the raised-card treatment; hover = flat plate + close `×`.
///
/// Line 1 carries the title + the [lock][sync][command] cluster; line 2 is the agent READOUT
/// (question / todo scent / last assistant line / final line / error line / strayed cwd — resolved
/// upstream by ``RailRowReadout``). The telemetry value and the status badge live OUTSIDE the lines, on
/// the full-height trailing rail. Heights ride the ladder via ``SlateListRow`` — `heightRow` name-only,
/// `heightRowTall` with a line 2, and an AGENT row HOLDS the tall shell for its whole session
/// (`isAgentSession` → `reserveSubtitle`), so a question/done/error edge swaps text inside a fixed
/// shell instead of growing the row. All trailing meta fades under the hover `×`; the leading
/// attention tick never fades.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// The row's second line — the resolved READOUT text (``RailRowReadout``). `nil`/empty ⇒ no line 2
    /// (a non-agent row collapses to single-line; an agent row keeps the reserved blank).
    var subtitle: String?
    /// Line-2 truncation, forwarded to the ``SlateListRow`` shell. `.middle` (default) suits the
    /// path-shaped strayed-cwd; every prose readout (question / scent / labels) passes `.tail` so the
    /// sentence keeps its head.
    var subtitleTruncation: Text.TruncationMode = .middle
    /// The host's coarse foreground-process label ("make") — rendered on COMMAND rows only: an
    /// agent-session row suppresses it (the working ring already says agent; "claude" next to it is
    /// noise), sharpening command ≠ agent.
    var processLabel: String?
    /// The single fused status badge, rendered as a ``StatusRing`` reading on the trailing rail.
    /// `nil` ⇒ the rail's badge box stays reserved-empty.
    var badge: TabBadgeKind?
    /// The row's right-aligned telemetry value (blocked-age / turn-elapsed / percent / exit code —
    /// resolved upstream by ``RailRowTelemetry``). `nil` ⇒ the column stays reserved-empty.
    var telemetry: RailTelemetryValue?
    /// Whether this row is an AGENT session — holds the tall two-line shell for the whole session so
    /// lifecycle edges never move layout (the rung changes only at session boundaries).
    var isAgentSession = false
    /// Whether this pane's input gate is READ-ONLY — renders a small trailing lock glyph (the sidebar's
    /// read-only indicator, twin of the pane's `🔒 READ ONLY ×` pill). Default `false` keeps existing call
    /// sites source-compatible.
    var readOnly: Bool = false
    /// Whether this pane's TAB is armed for synchronized input (⌘⇧I) — renders a small trailing amber
    /// grouped-panes glyph (the sidebar twin of the pane's `⚠ SYNC INPUT ×` pill), so an armed tab is
    /// visible even from the rail. Default `false` keeps existing call sites source-compatible.
    var syncInput: Bool = false
    /// Whether the row is in inline-RENAME mode — swaps the title `Text` for a committing `TextField`.
    /// Default `false` keeps existing call sites source-compatible.
    var isEditing: Bool = false
    /// The row's tooltip text (the full cwd) — shown on hover via `.help`. Empty/`nil` ⇒ no tooltip.
    var helpText: String?
    var onSelect: () -> Void
    var onClose: () -> Void
    /// Commit the inline rename with the field's current text. No-op default keeps call sites compatible.
    var onRename: (String) -> Void = { _ in }
    /// Dismiss the inline rename without renaming (escape / focus loss). No-op default.
    var onCancelRename: () -> Void = {}

    @State private var closeHover = false
    /// The inline-rename draft text — seeded from `title` when the field opens.
    @State private var draft = ""
    /// Whether the inline rename has already been RESOLVED by Return (commit) or Escape (cancel) — so the
    /// focus-loss handler that fires when the field is torn down does NOT re-commit the draft (which would make
    /// Escape accidentally RENAME to the draft, and Return commit twice). A genuine click-away leaves this
    /// `false`, so that path still commits once. Reset per field-open via `.onAppear`.
    @State private var renameResolved = false
    @FocusState private var fieldFocused: Bool

    /// The rail's total reserved width — the telemetry column + a breath + the badge box. Reserved on
    /// BOTH lines (width-only spacers) so text can never run under the full-height rail overlay.
    private static let railReserve: CGFloat =
        Slate.Metric.telemetryCol + Slate.Metric.space1 + TabBadgeView.side

    var body: some View {
        // The row is the shared ``SlateListRow`` shell: the shell owns the height ladder,
        // padding, hover plate and the active raised-card treatment; this view supplies the tab-specific
        // slots — the title/rename field, the line-1 meta cluster, and the full-height trailing RAIL
        // (telemetry + badge) with the hover `×` over it.
        SlateListRow(
            active: active,
            subtitle: subtitle,
            subtitleTruncation: subtitleTruncation,
            reserveSubtitle: isAgentSession,
            // The tap SELECTS — but only when NOT renaming, so a click inside the field lands in the field.
            onTap: { if !isEditing { onSelect() } },
            title: {
                if isEditing {
                    renameField
                } else {
                    Text(title)
                        .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                }
            },
            titleTrailing: { hovering in
                if !isEditing { lineOneTrailing(hovering: hovering) }
            },
            subtitleTrailing: { _ in
                // Line 2 carries no accessory of its own anymore — only the rail gutter reserve, so the
                // readout text stops short of the overlay rail.
                if !isEditing { railGutterReserve }
            },
            trailingOverlay: { hovering in
                // The full-height trailing RAIL — [telemetry][badge], vertically centered over the whole
                // row at a constant x, faded out under the hover `×` (which reveals in its place).
                if !isEditing {
                    ZStack(alignment: .trailing) {
                        rail
                            .opacity(hovering ? 0 : 1)
                        closeButton
                            .opacity(hovering ? 1 : 0)
                            .allowsHitTesting(hovering)
                    }
                }
            },
        )
        // The leading ATTENTION TICK — act-now states only (amber = a question waits, red = broken),
        // a hard-cut motionless bar in the leading gutter, OUTSIDE the hover fade (it never hides).
        .overlay(alignment: .leading) {
            if let tickColor {
                Capsule()
                    .fill(tickColor)
                    .frame(width: Slate.Metric.attentionTick)
                    .padding(.vertical, 5)
            }
        }
        .help(helpText ?? "")
    }

    /// The act-now tick colour: amber while a question waits, red while broken; nothing otherwise.
    private var tickColor: Color? {
        switch badge {
        case .awaitingInput: Slate.Status.warn
        case .error: Slate.Status.err
        default: nil
        }
    }

    /// The full-height trailing rail: the right-aligned telemetry value in its fixed column, then the
    /// badge box. Both slots are unconditional `Color.clear` reservations (an empty conditional + frame
    /// does NOT reserve in SwiftUI) so a value/badge appearing changes pixels, never layout.
    private var rail: some View {
        HStack(spacing: Slate.Metric.space1) {
            Color.clear
                .frame(width: Slate.Metric.telemetryCol, height: TabBadgeView.side)
                .overlay(alignment: .trailing) {
                    if let telemetry {
                        Text(telemetry.text)
                            .font(Slate.Typeface.instrument(Slate.Typeface.small))
                            .foregroundStyle(telemetryTone(telemetry.tone))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            Color.clear
                .frame(width: TabBadgeView.side, height: TabBadgeView.side)
                .overlay { if let badge { TabBadgeView(kind: badge) } }
        }
    }

    /// The telemetry tone ladder: amber = the one coloured number (blocked-age), secondary = every
    /// other value, primary = the ≥10-minute working escalation (one luminance step up).
    private func telemetryTone(_ tone: RailTelemetryTone) -> Color {
        switch tone {
        case .amber: Slate.Status.warn
        case .secondary: Slate.Text.secondary
        case .primary: Slate.Text.primary
        }
    }

    /// The rail gutter reserve — a width-only spacer both lines end with, so their text truncates
    /// BEFORE the overlay rail instead of running under it.
    private var railGutterReserve: some View {
        Color.clear.frame(width: Self.railReserve, height: 1)
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

    /// LINE 1 trailing (right of the title): the read-only lock, the sync-input glyph, then the
    /// RUNNING-COMMAND label — on EVERY row, active or not, because a background tab's running command is
    /// exactly what you scan the sidebar for. A bare interactive shell (`zsh`/`bash`/`fish`/…) is
    /// suppressed via ``RailRowsBuilder/processDisplayName(_:)`` — "zsh" is not a running command, it is
    /// the resting state — and an AGENT-session row suppresses the label entirely (the working ring
    /// already says agent; the label is a commands-only voice). The status badge does NOT live here — it
    /// rides the full-height rail. The cluster ends with the rail gutter reserve and fades out under the
    /// centered hover `×`.
    /// No persistent `⌘N` switch-shortcut chip: the ⌘1…⌘9 chords still work, the row just doesn't
    /// advertise them.
    private func lineOneTrailing(hovering: Bool) -> some View {
        HStack(spacing: 6) {
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
                if !isAgentSession, let command = RailRowsBuilder.processDisplayName(processLabel) {
                    Text(command)
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                }
            }
            // Fades out under the hover close `×` (the centered ``trailingOverlay``); the gutter
            // reserve outside stays put so the fade never reflows the line.
            .opacity(hovering ? 0 : 1)
            railGutterReserve
        }
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
