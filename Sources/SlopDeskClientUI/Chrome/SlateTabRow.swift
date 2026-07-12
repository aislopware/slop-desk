// SlateTabRow — the sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// built on the shared `SlateListRow` shell and wired to the live store via the navigator. The resting row
// is the tab name on the sidebar ground; ACTIVE is the RAISED card (fill + 1px hairline, no shadow), hover
// is a flat plate, and a close `×` reveals on hover. No native list selection / vibrancy — this is a flat
// silhouette by design.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// One sidebar tab row. ACTIVE = the raised-card treatment; hover = flat plate + close `×`.
///
/// The trailing accessories are split PER LINE: the foreground-process label ("zsh", ACTIVE row only) rides
/// LINE 1 beside the tab name, and the fused status `badge` sits ALONE on the compact LINE-2 subtitle
/// (a single-line row with no subtitle keeps
/// the badge on line 1). Heights ride the ladder via ``SlateListRow`` (`heightRow` name-only, `heightRowTall`
/// with a subtitle — `docs/ui-shell/screenshots/tab-badge.png`). Both clusters fade under the hover `×`.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// The row's muted truncating-middle second line (a terminal's git line / cwd, a video pane's host
    /// app). `nil`/empty ⇒ single-line.
    var subtitle: String?
    /// The pane's folded git state — when its cwd is a repo, the row's second line renders the git line with
    /// per-token STATUS colour (branch muted, `↑ahead` green, `↓behind` blue, `· N changed` amber) instead of
    /// the flat ``subtitle``. `nil` ⇒ no repo (or a non-terminal row) → the plain ``subtitle`` renders.
    var gitSummary: PaneGitSummary?
    /// The host's coarse foreground-process label ("zsh"), shown trailing on the ACTIVE row only.
    var processLabel: String?
    /// The single fused status badge (spinner / check / dot / error / hand / coffee / shield). `nil` ⇒ none.
    var badge: TabBadgeKind?
    /// Whether this pane's input gate is READ-ONLY — renders a small trailing lock glyph (the sidebar's
    /// read-only indicator, twin of the pane's `🔒 READ ONLY ×` pill). Default `false` keeps existing call
    /// sites source-compatible.
    var readOnly: Bool = false
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

    /// Whether the row carries a second line (cwd / git line / host app). Mirrors ``SlateListRow``'s own test
    /// so line-1 vs line-2 accessory placement stays in lock-step with where the shell actually draws line 2.
    private var hasSubtitle: Bool { !(subtitle ?? "").isEmpty }

    var body: some View {
        // The row is the shared ``SlateListRow`` shell: the shell owns the height ladder,
        // padding, hover plate and the active raised-card treatment; this view supplies only the
        // tab-specific slots — the title/rename field and the per-line trailing clusters (running-process
        // label pinned to line 1, the status badge alone on the compact line 2).
        SlateListRow(
            active: active,
            subtitle: subtitle,
            subtitleColored: gitSummary.flatMap(Self.gitLine),
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
            subtitleTrailing: { hovering in
                if !isEditing { lineTwoTrailing(hovering: hovering) }
            },
            trailingOverlay: { hovering in
                // The close `×` — centered over the whole row, revealed only on hover (the line-1/line-2 meta
                // fade out beneath it). Not shown while renaming.
                if !isEditing {
                    closeButton
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            },
        )
        .help(helpText ?? "")
    }

    /// The instrument-voice git line with per-token STATUS colour (MERIDIAN "colour = state, not ornament"),
    /// each state a SINGLE sigil + count (oh-my-zsh vocabulary). The branch stays MUTED (inherits the row's
    /// secondary — structure, not a signal); the tokens colour by meaning:
    ///   `↑`ahead / `+`staged → OK-green (outgoing / index work, ready to commit or push)
    ///   `↓`behind / `!`modified → warn-amber (behind upstream / unstaged edits — needs attention)
    ///   `?`untracked → info-blue (new files not yet tracked)
    ///   `=`conflicts → err-red (unmerged — must resolve)
    ///   `$`stash → muted secondary (parked work; the `$` sigil carries it, no alarm colour)
    /// A CLEAN repo is just the muted branch — nothing to flag. `nil` for a non-repo cwd. The rendered text is
    /// byte-identical to ``PaneGitSummary/compactLine`` so the plain fallback / search key / row height (all
    /// keyed on ``subtitle``) never diverge from what the coloured line shows.
    @MainActor
    static func gitLine(_ g: PaneGitSummary) -> AttributedString? {
        guard g.hasRepo else { return nil }
        func token(_ text: String, _ colour: Color?) -> AttributedString {
            var seg = AttributedString(text)
            seg.foregroundColor = colour // nil ⇒ inherits the row's secondary
            return seg
        }
        var line = AttributedString(g.branch.isEmpty ? "detached" : g.branch)
        if g.ahead > 0 { line += token(" ↑\(g.ahead)", Slate.Status.ok) }
        if g.behind > 0 { line += token(" ↓\(g.behind)", Slate.Status.warn) }
        if g.staged > 0 { line += token(" +\(g.staged)", Slate.Status.ok) }
        if g.modified > 0 { line += token(" !\(g.modified)", Slate.Status.warn) }
        if g.untracked > 0 { line += token(" ?\(g.untracked)", Slate.Status.info) }
        if g.conflicted > 0 { line += token(" =\(g.conflicted)", Slate.Status.err) }
        if g.stash > 0 { line += token(" $\(g.stash)", nil) }
        return line
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

    /// LINE 1 trailing (right of the title): the read-only lock (if locked) then the RUNNING-COMMAND label —
    /// on EVERY row, active or not, because a background tab's running command is exactly what you scan the
    /// sidebar for. A bare interactive shell (`zsh`/`bash`/`fish`/…) is suppressed via
    /// ``RailRowsBuilder/processDisplayName(_:)`` — "zsh" is not a running command, it is the resting state —
    /// which also basenames a path label (`/usr/bin/sudo` → `sudo`). A row with no second line (no cwd/git
    /// subtitle) has nowhere else to put the status badge, so it also carries the fused `badge` here; a
    /// two-line row moves the badge down to ``lineTwoTrailing`` instead. All muted, right-aligned; the whole
    /// cluster fades out under the centered hover `×` (the row's ``trailingOverlay``).
    /// No persistent `⌘N` switch-shortcut chip: the ⌘1…⌘9 chords still work, the row just doesn't advertise
    /// them.
    private func lineOneTrailing(hovering: Bool) -> some View {
        HStack(spacing: 6) {
            if readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
                    .help("Read only")
            }
            if let command = RailRowsBuilder.processDisplayName(processLabel) {
                Text(command)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
            }
            // Single-line rows (no subtitle) host the status badge here — reserve its FIXED box (`Color.clear`
            // reliably reserves; an empty conditional does not) so line 1 is the same height whether or not a
            // badge is showing.
            if !hasSubtitle {
                Color.clear
                    .frame(width: TabBadgeView.side, height: TabBadgeView.side)
                    .overlay { if let badge { TabBadgeView(kind: badge) } }
            }
        }
        // Fades out under the hover close `×` (the centered ``trailingOverlay``).
        .opacity(hovering ? 0 : 1)
    }

    /// LINE 2 trailing (right of the compact subtitle): the fused status `badge` alone — this is the "area now
    /// holds only status" the redesign asked for, keeping the second line minimal instead of a duplicate of
    /// line 1's meta. Rendered only when the row HAS a subtitle (else the badge stays on line 1); fades under
    /// the hover `×`.
    ///
    /// The badge box (`TabBadgeView.side`) is TALLER than the subtitle text, so a badge appearing (a command
    /// starting) would otherwise grow line 2 and re-centre the row content — reading as the tab getting taller.
    /// The badge's fixed box is RESERVED via a `Color.clear` slot that is ALWAYS present — an empty conditional
    /// + `.frame` does NOT reserve space in SwiftUI, so the slot must exist unconditionally; the badge draws
    /// into it via `.overlay` when present. So line 2 is the same height with or without a badge: zero shift.
    private func lineTwoTrailing(hovering: Bool) -> some View {
        Color.clear
            .frame(width: TabBadgeView.side, height: TabBadgeView.side)
            .overlay {
                if hasSubtitle, let badge {
                    TabBadgeView(kind: badge)
                        .opacity(hovering ? 0 : 1)
                }
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
