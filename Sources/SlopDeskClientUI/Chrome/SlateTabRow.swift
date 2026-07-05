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
/// E6 WI-4 grew the row from a name-only plate to its full chrome: an optional second-line cwd subtitle
/// and a trailing cluster of the fused status `badge` and — on the ACTIVE row — the foreground-process
/// label ("zsh"). Heights ride the ladder via ``SlateListRow`` (`heightRow` name-only, `heightRowTall`
/// with a subtitle — `docs/ui-shell/screenshots/tab-badge.png`). The trailing cluster fades under hover `×`.
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
    /// E17 ES-E17-1 / WI-3: whether this pane's input gate is READ-ONLY — renders a small trailing lock glyph
    /// (the sidebar's read-only indicator, twin of the pane's `🔒 READ ONLY ×` pill). Default `false` keeps
    /// existing call sites source-compatible.
    var readOnly: Bool = false
    /// C3 BUG B: whether the row is in inline-RENAME mode — swaps the title `Text` for a committing
    /// `TextField`. Default `false` keeps existing call sites source-compatible.
    var isEditing: Bool = false
    /// C3 BUG A: the row's tooltip text (the full cwd) — shown on hover via `.help`. Empty/`nil` ⇒ no tooltip.
    var helpText: String?
    var onSelect: () -> Void
    var onClose: () -> Void
    /// C3 BUG B: commit the inline rename with the field's current text. No-op default keeps call sites compatible.
    var onRename: (String) -> Void = { _ in }
    /// C3 BUG B: dismiss the inline rename without renaming (escape / focus loss). No-op default.
    var onCancelRename: () -> Void = {}

    @State private var closeHover = false
    /// The inline-rename draft text (C3 BUG B) — seeded from `title` when the field opens.
    @State private var draft = ""
    /// Whether the inline rename has already been RESOLVED by Return (commit) or Escape (cancel) — so the
    /// focus-loss handler that fires when the field is torn down does NOT re-commit the draft (which would make
    /// Escape accidentally RENAME to the draft, and Return commit twice). A genuine click-away leaves this
    /// `false`, so that path still commits once. Reset per field-open via `.onAppear`.
    @State private var renameResolved = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        // The row is the shared ``SlateListRow`` shell (MERIDIAN C2): the shell owns the height ladder,
        // padding, hover plate and the active raised-card treatment; this view supplies only the
        // tab-specific slots — the title/rename field and the hover-swapped trailing cluster.
        SlateListRow(
            active: active,
            subtitle: subtitle,
            subtitleColored: gitSummary.flatMap(Self.gitLine),
            // The tap SELECTS — but only when NOT renaming, so a click inside the field lands in the field.
            onTap: { if !isEditing { onSelect() } },
        ) {
            if isEditing {
                renameField
            } else {
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
            }
        } trailing: { hovering in
            if !isEditing {
                ZStack(alignment: .trailing) {
                    trailingMeta.opacity(hovering ? 0 : 1)
                    closeButton
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            }
        }
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

    /// The inline-rename `TextField` (C3 BUG B): seeded from the current title on open, auto-focused, commits
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

    /// The trailing status cluster: the read-only lock (if locked), the fused `badge` (if any), then the
    /// foreground-process label on the ACTIVE row — all muted, right-aligned. Fades under the hover `×`.
    /// (The persistent `⌘N` switch-shortcut chip is REMOVED per user feedback — the ⌘1…⌘9 chords still
    /// work; the row just no longer advertises them.)
    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
                    .help("Read only")
            }
            if let badge {
                TabBadgeView(kind: badge)
            }
            if active, let processLabel, !processLabel.isEmpty {
                Text(processLabel)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
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

/// The sidebar hamburger — a sort/group popover (`SortMenuButton`). E6 WI-5 made it write the STORE (the
/// single source of truth for row order, persisted) instead of local `@State`: each GROUP row sets
/// ``WorkspaceStore/setTabGrouping(_:)`` and each ORDER row ``WorkspaceStore/setTabSort(_:)``; the checkmarks
/// READ the store. (Carryover binding constraint: "mutate the store order, not local `@State`.") The row is
/// the flat-icon button beside the "TABS" header.
struct SlateSortMenuButton: View {
    /// The live store — owns ``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` (the persisted row
    /// order). Read in the popover (so the `@Observable` store ticks the checkmarks) and written by the rows.
    let store: WorkspaceStore

    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            // The "decrease" variant (three bars narrowing top→bottom) reads as sort/filter, not as a
            // navigation hamburger — per user feedback.
            Image(systemSymbol: .line3HorizontalDecrease)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    // The popover speaks the shared ``SlatePopoverSection``/``SlatePopoverRow``/``SlatePopoverDivider``
    // vocabulary (MERIDIAN C3) — one menu chrome across the app, no per-popover drift.
    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlatePopoverSection("GROUP")
            groupRow("No Grouping", "list.bullet", .none)
            groupRow("By Project", "folder", .byProject)
            groupRow("By Date", "calendar", .byDate)
            SlatePopoverDivider()
            SlatePopoverSection("ORDER")
            orderRow("Created Time", "clock", .created)
            orderRow("Updated Time", "clock.arrow.circlepath", .updated)
            orderRow("Manual", "arrow.up.arrow.down", .manual)
        }
        .padding(.vertical, 6)
        .frame(width: 210)
    }

    /// A GROUP row whose checkmark READS ``WorkspaceStore/tabGrouping`` and whose tap WRITES it (persisted).
    private func groupRow(_ title: String, _ icon: String, _ value: TabGrouping) -> some View {
        SlatePopoverRow(title, icon: icon, checked: store.tabGrouping == value) { store.setTabGrouping(value) }
    }

    /// An ORDER row whose checkmark READS ``WorkspaceStore/tabSort`` and whose tap WRITES it (persisted).
    private func orderRow(_ title: String, _ icon: String, _ value: TabSort) -> some View {
        SlatePopoverRow(title, icon: icon, checked: store.tabSort == value) { store.setTabSort(value) }
    }
}
#endif
