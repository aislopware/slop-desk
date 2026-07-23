// SlateTabRow — the sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// built on the shared `SlateListRow` shell and wired to the live store via the navigator. The resting row
// is the tab name on the sidebar ground; ACTIVE is the RAISED card (fill + 1px hairline, no shadow), hover
// is a flat plate, and a close `×` reveals on hover. No native list selection / vibrancy — this is a flat
// silhouette by design.
//
// Every row is the same TWO-LINE shape, FLUSH-LEFT: line 1 is [title][trailing lock/sync +
// status glyph + telemetry text], line 2 is the full-width readout. There is NO leading accessory
// column — a reserved gutter indented every title off the section header's left edge, so status
// moved into the line-1 trailing cluster as a TEXT glyph (``AsciiStatusBadge``: the AI-CLI pulse
// spinner for a working agent, braille for a running command, static `? !137 ok # ∞` otherwise),
// where `✻ 4m` reads like a CLI status line and a state edge swaps the reading. A RESTING
// row (no status, not active) RECEDES — its title drops to the secondary tone — so the unlabeled
// quiet state is dimness, and colour + full strength are earned by live state (the T3 recede).

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// One sidebar tab row. ACTIVE = the raised-card treatment; hover = flat plate + close `×`.
///
/// Line 1 carries the title + the [lock][sync][status glyph][telemetry] trailing cluster; line 2 is the READOUT
/// (question / todo scent / last assistant line / final line / error line / running command / strayed
/// cwd — resolved upstream by ``RailRowReadout``). Every row holds the two-line shell
/// (`reserveSubtitle`), so state edges swap text inside a fixed shape and the sidebar keeps one row
/// rhythm — no height ladder, no session-scoped rung.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// The row's second line — the resolved READOUT text (``RailRowReadout``). `nil`/empty ⇒ the
    /// reserved blank line (absence, no placeholder).
    var subtitle: String?
    /// Line-2 truncation, forwarded to the ``SlateListRow`` shell. `.middle` (default) suits the
    /// path-shaped strayed-cwd; every prose readout (question / scent / labels) passes `.tail` so the
    /// sentence keeps its head.
    var subtitleTruncation: Text.TruncationMode = .middle
    /// The single fused status glyph, rendered as an ``AsciiStatusBadge`` text reading in the line-1
    /// trailing cluster. `nil` ⇒ no glyph and the row recedes.
    var badge: TabBadgeKind?
    /// The failed command's exit code, forwarded into the error badge's `!<code>` reading. Only read
    /// when `badge == .error`; default `nil` keeps existing call sites source-compatible.
    var errorExitCode: Int32?
    /// The row's right-aligned telemetry value (blocked-age / turn-elapsed / percent / exit code —
    /// resolved upstream by ``RailRowTelemetry``). `nil` ⇒ nothing renders in the slot.
    var telemetry: RailTelemetryValue?
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
    /// Row-level hover, tracked here (in addition to the shell's) to lift the RECEDE — a receded
    /// title returns to full strength under the pointer, matching the shell's hover plate.
    @State private var rowHover = false
    /// The inline-rename draft text — seeded from `title` when the field opens.
    @State private var draft = ""
    /// Whether the inline rename has already been RESOLVED by Return (commit) or Escape (cancel) — so the
    /// focus-loss handler that fires when the field is torn down does NOT re-commit the draft (which would make
    /// Escape accidentally RENAME to the draft, and Return commit twice). A genuine click-away leaves this
    /// `false`, so that path still commits once. Reset per field-open via `.onAppear`.
    @State private var renameResolved = false
    @FocusState private var fieldFocused: Bool

    /// The hover close `×`'s footprint — both lines end with this reserve so their text truncates
    /// before the overlay instead of running under the revealed button.
    private static let closeReserve: CGFloat = 18

    var body: some View {
        // The row is the shared ``SlateListRow`` shell: the shell owns the height, padding, hover
        // plate and the active raised-card treatment; this view supplies the tab-specific slots — the
        // title/rename field, the line-1 trailing cluster (status glyph + telemetry), and the hover
        // close `×` overlay. NO leading accessory: the title sits flush on the sidebar's left edge.
        SlateListRow(
            active: active,
            subtitle: subtitle,
            subtitleTruncation: subtitleTruncation,
            reserveSubtitle: true,
            // The tap SELECTS — but only when NOT renaming, so a click inside the field lands in the field.
            onTap: { if !isEditing { onSelect() } },
            title: {
                if isEditing {
                    renameField
                } else {
                    Text(title)
                        .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                        .foregroundStyle(recedes ? Slate.Text.secondary : Slate.Text.primary)
                        .lineLimit(1)
                }
            },
            titleTrailing: { hovering in
                if !isEditing { lineOneTrailing(hovering: hovering) }
            },
            subtitleTrailing: { _ in
                // Line 2 ends with the close reserve only — the readout truncates before the hover `×`.
                if !isEditing { Color.clear.frame(width: Self.closeReserve, height: 1) }
            },
            trailingOverlay: { hovering in
                if !isEditing {
                    closeButton
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            },
        )
        .onHover { rowHover = $0 }
        .help(helpText ?? "")
    }

    /// Whether the row RECEDES — the resting state (no status, not active, no pointer) spends no
    /// colour and no full-strength ink; a live badge, the active card or hover restores it.
    private var recedes: Bool {
        badge == nil && !active && !rowHover
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

    /// LINE 1 trailing (right of the title): the read-only lock, the sync-input glyph, the STATUS
    /// text glyph (``AsciiStatusBadge`` — the spinner / `? !137 ok` reading), then the TELEMETRY value
    /// in the timestamp slot (blocked-age / turn-elapsed / percent / exit code — the T3 idiom: the
    /// row's one number lives where a timestamp would, so the pair reads `✻ 4m`). The cluster fades
    /// out under the hover `×` but KEEPS ITS WIDTH (opacity, not removal), so the fade never reflows
    /// the title; a minimum close-reserve width guarantees the `×` a landing zone even on a bare row.
    private func lineOneTrailing(hovering: Bool) -> some View {
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
            if let badge {
                AsciiStatusBadge(kind: badge, errorExitCode: errorExitCode)
            }
            if let telemetry {
                Text(telemetry.text)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(telemetryTone(telemetry.tone))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minWidth: Self.closeReserve, alignment: .trailing)
        .opacity(hovering ? 0 : 1)
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
