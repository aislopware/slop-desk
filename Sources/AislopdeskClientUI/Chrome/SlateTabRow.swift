// SlateTabRow — the sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// built on the `Slate` tokens and wired to the live store via the navigator. The resting row is the tab
// name on the warm sidebar; ACTIVE is a WHITE CARD (radius-7 fill + 1px cardBorder + faint shadow), hover
// is a flat plate, and a close `×` reveals on hover. No native list selection / vibrancy — this is a flat
// silhouette by design.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// One sidebar tab row. ACTIVE = white card treatment; hover = flat plate + close `×`.
///
/// E6 WI-4 grew the row from a name-only plate to its full chrome: an optional second-line cwd subtitle
/// and a trailing cluster of the fused status `badge`, the monospaced light-gray `⌘N` SWITCH-SHORTCUT badge,
/// and — on the ACTIVE row — the foreground-process label ("zsh"). Name-only rows stay ~34pt; a subtitle grows
/// the row to ~44pt (`docs/ui-shell/screenshots/tab-badge.png`). The trailing cluster fades under hover `×`.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// The row's muted truncating-middle second line (a terminal's git line / cwd, a video pane's host
    /// app). `nil`/empty ⇒ single-line.
    var subtitle: String?
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

    @State private var hovering = false
    @State private var closeHover = false
    /// The inline-rename draft text (C3 BUG B) — seeded from `title` when the field opens.
    @State private var draft = ""
    /// Whether the inline rename has already been RESOLVED by Return (commit) or Escape (cancel) — so the
    /// focus-loss handler that fires when the field is torn down does NOT re-commit the draft (which would make
    /// Escape accidentally RENAME to the draft, and Return commit twice). A genuine click-away leaves this
    /// `false`, so that path still commits once. Reset per field-open via `.onAppear`.
    @State private var renameResolved = false
    @FocusState private var fieldFocused: Bool

    private var hasSubtitle: Bool { !(subtitle ?? "").isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    renameField
                } else {
                    Text(title)
                        .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                }
                if hasSubtitle {
                    // MERIDIAN L2: the technical second line (cwd / git line / host-app) speaks the
                    // INSTRUMENT voice — data, not prose. The title above stays in the system face.
                    Text(subtitle ?? "")
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if !isEditing {
                trailingMeta
                    .opacity(hovering ? 0 : 1)
            }
        }
        .overlay(alignment: .trailing) {
            if !isEditing {
                closeButton
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: hasSubtitle ? 44 : 34)
        .background(rowBackground, in: .rect(cornerRadius: Slate.Metric.radiusTab))
        .overlay { if active { RoundedRectangle(cornerRadius: Slate.Metric.radiusTab).strokeBorder(
            Slate.Line.card,
            lineWidth: 1,
        ) } }
        .shadow(color: active ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        // The tap SELECTS — but only when NOT renaming, so a click inside the field lands in the field.
        .onTapGesture { if !isEditing { onSelect() } }
        .onHover { hovering = $0 }
        .help(helpText ?? "")
        .animation(Slate.Anim.smallFade, value: hovering)
        .animation(Slate.Anim.smallFade, value: active)
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

    private var rowBackground: Color {
        if active { Slate.Surface.selectedCard }
        else if hovering { Slate.State.hover }
        else { .clear }
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

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            SortSection("GROUP")
            groupRow("No Grouping", "list.bullet", .none)
            groupRow("By Project", "folder", .byProject)
            groupRow("By Date", "calendar", .byDate)
            SortDivider()
            SortSection("ORDER")
            orderRow("Created Time", "clock", .created)
            orderRow("Updated Time", "clock.arrow.circlepath", .updated)
            orderRow("Manual", "arrow.up.arrow.down", .manual)
        }
        .padding(.vertical, 6)
        .frame(width: 210)
    }

    /// A GROUP row whose checkmark READS ``WorkspaceStore/tabGrouping`` and whose tap WRITES it (persisted).
    private func groupRow(_ title: String, _ icon: String, _ value: TabGrouping) -> some View {
        SortRow(title, icon: icon, on: store.tabGrouping == value) { store.setTabGrouping(value) }
    }

    /// An ORDER row whose checkmark READS ``WorkspaceStore/tabSort`` and whose tap WRITES it (persisted).
    private func orderRow(_ title: String, _ icon: String, _ value: TabSort) -> some View {
        SortRow(title, icon: icon, on: store.tabSort == value) { store.setTabSort(value) }
    }
}

private struct SortSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
            .tracking(Slate.Typeface.instrumentTracking)
            .foregroundStyle(Slate.State.header)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SortDivider: View {
    var body: some View {
        Rectangle().fill(Slate.Line.divider).frame(height: 1)
            .padding(.vertical, 5).padding(.horizontal, 10)
    }
}

private struct SortRow: View {
    let title: String
    let icon: String
    let on: Bool
    var action: () -> Void

    init(_ title: String, icon: String, on: Bool, _ action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.on = on
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: Slate.Typeface.base)).foregroundStyle(Slate.Text.primary)
                Spacer()
                if on {
                    Image(systemSymbol: .checkmark).font(.system(size: Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Text.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(hovering ? Slate.State.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
