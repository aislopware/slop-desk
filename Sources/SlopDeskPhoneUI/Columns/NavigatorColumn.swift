// NavigatorColumn — the PHONE's sidebar navigator.
//
// A system `List(selection:)`, so `NavigationSplitView` pushes to the content column on a compact
// iPhone (a custom button list does not drive column navigation). It keeps the system `.searchable`
// field, grouped `Section`s and the trailing badge, themed to the same ladder the Mac's column reads.
//
// ⚠️ macOS LEFT THIS FILE (docs/56 stage D). The Mac's navigator is AppKit now —
// ``SlopDeskMacUI/MacNavigatorColumn`` — and everything the two halves could have disagreed about was
// lifted BELOW both first rather than mirrored: the row's whole resolution
// (``SidebarRowPresentation/reading(for:store:fallbackTitle:)``), the GIT DIALECT
// (``SidebarGitLine``), the section grouping (``SidebarSections``), the select path and the rename
// commit (``SidebarSelection``), and the context menu's verb table (``SidebarRowMenu``). Both bodies
// here now READ those; neither decides anything a phone and a Mac could answer differently.
//
// ## The four things a POINTER answered for the Mac and a thumb has to answer differently
//
// The rule is the user's: the phone differs in LAYOUT, never in what it can do. Four capabilities
// were reachable on the Mac only through a device this one does not have, so each is re-laid rather
// than re-decided (docs/56 increment 85):
//
//   1. THE GIT LINE. The Mac hangs it under the project name in a header it drew itself. Here it is
//      the `Section`'s header view, over the SAME ``SidebarGitLine`` runs, shed by the SAME ladder —
//      asked with `ViewThatFits` rather than by measuring strings, which is the question SwiftUI has
//      a container for. The sigils are never spelled here; a dead second Swift renderer once spelled
//      a conflict `=` where the dialect spells it `~` (docs/56 increment 45).
//   2. THE TOOLTIP'S ONE UNIQUE FACT. Most of ``SidebarRowReading/tooltip`` is overflow recovery for
//      what the row truncated — worth a hover, not worth a line. The multiclient pair is not: "Also
//      open on iPad" / "Held by mac-studio" appears nowhere else, on the device most likely to BE
//      that second client. It gets ``SidebarRowReading/presence``, a cut of the same assembly, as the
//      row's second line. The REST of the tooltip rides `.accessibilityHint`, which is the phone's
//      only hover.
//   3. THE CLOSE ×. A hover-revealed button has no thumb equivalent; `.swipeActions` is the one iOS
//      spells, and it needs the `List` this column already is. `allowsFullSwipe` is OFF on purpose —
//      the Mac's × costs a deliberate click on a target that had to be revealed first, and a pane
//      that closes on a fast flick past a row is a worse affordance than none.
//   4. THE COLLAPSE. `Section(isExpanded:)` under `.listStyle(.sidebar)` IS the disclosure, so the
//      work was wiring the key rather than drawing a chevron. The key is
//      ``SidebarSections/collapseKey(_:)`` and the set is `@State` — session-scoped, which is exactly
//      what `MacNavigatorColumn.collapsed` is. Neither half persists it, so a fresh launch opens
//      every group on both, and there is no second store to disagree with.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The app-global connection — the FOOTER island's model (user-directed 2026-08-09: the status
    /// came back, and with a vertical tab list its home is under that list). `nil` (previews / iOS,
    /// which mounts the cluster in its own toolbar) simply omits the footer.
    var connection: AppConnection?

    /// Opens the Connect-to-Host editor from the footer island. No-op default keeps the column
    /// standalone-mountable.
    var onConnect: () -> Void = {}

    /// The transient sidebar search query — narrows the rows via the pure
    /// ``RailRowsBuilder/filtered``. On iOS it feeds the system `.searchable`; on macOS the
    /// panel's own header search field (user-directed 2026-08-03: the header row IS the search
    /// bar — it replaced the caps "TABS" label). Session-scoped, never persisted.
    @State private var query = ""

    /// The memoized row model: the sidebar body reads its rows from HERE so a settled body
    /// registers NO Observation dependency on the store's volatile per-pane dicts — a status/git/progress
    /// tick then re-renders only the cheap ``IOSSidebarLiveRow`` leaves (which read their own pane's chrome
    /// live), never the whole rows + `disambiguated()` + sectioning + list-diff pass. Plain class in
    /// `@State` (NOT `@Observable`): its mutation during a body eval must not re-invalidate anything.
    @State private var rowsMemo = RailRowsMemo()

    /// The focused pane — the ONE volatile value the sidebar body watches, and only so the selection
    /// plate's morph has an animated transaction to ride (see the list's `.animation`).
    private var focusedPaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The COLLAPSED project groups, keyed by ``SidebarSections/collapseKey(_:)``. Session-scoped
    /// presentation state — a fresh launch opens every group.
    ///
    /// `@State`, and NOT a store field or a `Defaults` key, because that is what the Mac's
    /// `MacNavigatorColumn.collapsed` is: two collapse stores that can disagree about which groups are
    /// shut is a worse answer than the one both halves already give, which is "all of them are open".
    /// The key comes from ``SidebarSections`` rather than from a local copy — this file carried its own
    /// `collapseKey` for a while, spelling the same sentinel a second time, and nothing ever read it.
    @State private var collapsed: Set<String> = []

    /// The rows the sidebar renders this eval — ALWAYS the memoized structural rows. The query filter
    /// (``RailRowsBuilder/filtered``) applies DOWNSTREAM over these same rows
    /// (`sectionedByProject(_:tabOrder:query:)`), so search composes over the memo rather than bypassing it.
    /// Calling `RailRowsBuilder.rows(for: store)` directly for a non-empty query instead would re-register
    /// every volatile store dict as an Observation dependency of this body — while a query sat in the field
    /// (it is never auto-cleared) EVERY agent/progress/git tick on ANY pane would re-run the full O(panes)
    /// build + sectioning + list diff on the main thread: exactly the storm ``RailRowsMemo`` exists to kill.
    /// Trade-off accepted: the filter matches the CACHED copies of the volatile match fields (git-line
    /// subtitle / process label), which can be one memo generation stale — same staleness contract as the
    /// rest of the cached row chrome. The structural match fields (title / cwd) re-key the memo on every
    /// change, so they are never stale. Parity + memo-hit pinned in `RailRowsMemoTests`.
    private var renderedRows: [RailRow] {
        rowsMemo.rows(for: store)
    }

    /// The active tab's active pane — drives which row reads as selected. iOS-only consumer (the system
    /// `List(selection:)` binding); the Mac's AppKit rows read selection LIVE in their own leaf so a focus
    /// change repaints the two affected leaves directly — passing it down as an init param would leave the OLD
    /// selected row's raised card on screen (the same lazy-container stale-value class as the "row title
    /// frozen at first render" fix; see ``RailRow/leafIdentity``).
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    var body: some View {
        iosSidebar
    }

    /// A system `List(selection:)` so NavigationSplitView pushes to content on compact; themed to match. Gains
    /// the system `.searchable` field (keeps the `List` as the column root so the navigation push is unchanged),
    /// grouped `Section`s, and badge.
    private var iosSidebar: some View {
        let allRows = renderedRows
        let sections = SidebarSections.sections(
            allRows, tabOrder: store.flatOrderedTabIDs(), query: query,
        )
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            // The two zero states are ``SidebarSections/emptyLine(rows:sections:)``'s, not this
            // body's: "nothing open at all" and "nothing matching what you typed" are a distinction
            // the Mac's column already makes, and a second pair of strings here drifted from it (this
            // half said "No matches" where the Mac says "No matching tabs"). The GLYPH stays local —
            // an icon is layout, and the Mac's column draws none.
            if let line = SidebarSections.emptyLine(rows: allRows, sections: sections) {
                Label(line, systemSymbol: allRows.isEmpty ? .squareSplit2x1 : .magnifyingglass)
                    .foregroundStyle(Slate.Text.secondary)
            } else {
                ForEach(sections) { section in
                    let key = SidebarSections.collapseKey(section.projectKey)
                    // `Section(isExpanded:)` under `.listStyle(.sidebar)` IS the disclosure — the
                    // system draws and animates the chevron, so the phone spends no drawing on what
                    // the Mac's header had to build (a rotating glyph, a hand-run animation group).
                    Section(isExpanded: expansion(key)) {
                        ForEach(section.rows) { row in
                            iosRow(row)
                        }
                    } header: {
                        IOSSidebarSectionHeader(
                            store: store,
                            title: section.header ?? "Tabs",
                            projectKey: section.projectKey,
                            rows: section.rows,
                            collapsed: collapsed.contains(key),
                        )
                    }
                    // The group title is a PATH basename — a sidebar header would otherwise shout it
                    // in caps, which is a different name.
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Slate.Surface.field)
        .tint(Slate.State.accent)
        .searchable(text: $query, prompt: "Search tabs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.newTerminalPane(.newTab) } label: { Image(systemSymbol: .plus) }
            }
        }
    }

    /// One iOS list row: the system `Label` (navigation wiring via `.tag`) plus the trailing fused badge.
    /// The VOLATILE chrome (badge / lock / rename mode)
    /// is read inside ``IOSSidebarLiveRow``, so a pane's status tick re-renders that one leaf,
    /// not this sidebar body. The rename commit reuses ``commitRename(_:to:)`` so the iOS + macOS paths
    /// share the same semantics (rename the pane so the row title wins, then dismiss the field).
    private func iosRow(_ row: RailRow) -> some View {
        IOSSidebarLiveRow(
            store: store,
            row: row,
            fallbackTitle: defaultTitle(for: row.kind),
            symbol: Self.symbol(for: row.kind),
            onRename: { SidebarSelection.commitRename(row.id, to: $0, in: store) },
            onCancelRename: { store.clearTabRenameRequest() },
        )
        .tag(row.id)
        // Keys the leaf's identity on the memoized fields it renders (``RailRow/leafIdentity``) so a
        // structural rebuild that retitles this row (cwd landed / chooser resolved / rename) replaces
        // the leaf instead of leaving the first-render title on screen. Volatile chrome is read LIVE
        // inside the leaf; focus-only changes keep the same identity (no churn).
        .id(row.leafIdentity)
        .contextMenu { rowContextMenu(row) }
        // The close verb. The Mac reveals an × on hover; a thumb has no hover, and `.swipeActions` is
        // the gesture iOS already taught for "remove this row" — the same layout-differs/verb-is-one
        // trade the context menu above makes. It reaches ``WorkspaceStore/requestClosePaneTree(_:)``,
        // the SAME store verb the Mac's × fires, so the confirmation prompt and the tree teardown are
        // not decided twice.
        //
        // ⚠️ `allowsFullSwipe: false` deliberately. The Mac's × is a click on a target the pointer had
        // to sit on first; a full swipe closes a pane on one flick that never had to name it. Two
        // gestures here — reveal, then tap — is the same "you meant this" the hover already charged.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.requestClosePaneTree(row.id)
            } label: {
                Label("Close", systemSymbol: .xmark)
            }
        }
    }

    /// One group's disclosure state as a binding over the collapse SET — the wiring the `collapseKey`
    /// this file used to declare was missing. `isExpanded` is the negation because the set names what
    /// is SHUT (an empty set is every group open, which is the launch state both halves want).
    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(key) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(key) } else { collapsed.insert(key) }
            },
        )
    }

    // MARK: - Tab context menu

    /// The long-press menu for a sidebar row — the Agent-Behaviour switches surfaced on the tab.
    ///
    /// The TABLE is ``SidebarRowMenu``'s, not this view's: a verb list written twice diverges on the
    /// first new verb, and that failure is silent in both halves until someone notices their phone's
    /// menu is not their Mac's. This body only turns entries into `Button`s and `Toggle`s.
    @ViewBuilder
    private func rowContextMenu(_ row: RailRow) -> some View {
        let entries = SidebarRowMenu.entries(for: row.id, store: store)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case let .action(verb):
                Button(verb.title) { SidebarRowMenu.run(verb, row: row, store: store) }
            case let .toggle(flag, isOn):
                Toggle(flag.title, isOn: Binding(
                    get: { isOn },
                    set: { _ in SidebarRowMenu.flip(flag, paneID: row.id, store: store) },
                ))
            }
        }
    }

    /// Make the row's tab active (if it isn't) then focus its pane — ``SidebarSelection/select(_:in:)``,
    /// the one path all four rail surfaces take.
    private func select(_ paneID: PaneID) {
        SidebarSelection.select(paneID, in: store)
    }

    private func defaultTitle(for kind: PaneKind) -> String {
        PaneChooserRegistry.option(for: kind).title
    }

    /// Type-safe SF Symbol for a pane kind (iOS rows only; macOS rows are name-only). Reads the
    /// symbol *name* from the shared ``PaneChooserRegistry`` and wraps it in a type-safe `SFSymbol`.
    private static func symbol(for kind: PaneKind) -> SFSymbol {
        SFSymbol(rawValue: PaneChooserRegistry.option(for: kind).symbol)
    }
}

/// The sidebar row tooltip's pure text assembly, pulled out of the row body so it's
/// headlessly testable: the full raw cwd, the row's untruncated prose readout (question / scent /
/// label — overflow recovery for what line 2 clipped), and the last command's
/// `make check · 1.3s · exit 0` line. Only non-empty parts render; a raw `\(cwd)` interpolation of the
/// `String?` field would render the literal `Optional(...)` wrapper, so every part is unwrapped first.
/// One LIVE phone row.
///
/// The STRUCTURAL identity (pane id / title / cwd / kind) rides the memoized ``RailRow``; every
/// VOLATILE field is re-read HERE through ``SidebarRowPresentation/reading(for:store:fallbackTitle:)``,
/// the same one pass the Mac's row runs. Observation still invalidates a row body when any pane's
/// status dict ticks (dict-granularity tracking), but that re-renders these cheap leaves only — the
/// column above never rebuilds its rows + sections + list diff per tick.
private struct IOSSidebarLiveRow: View {
    let store: WorkspaceStore
    let row: RailRow
    /// The kind's generic title (``PaneChooserRegistry``) when the row title is empty.
    let fallbackTitle: String
    let symbol: SFSymbol
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        // The flash-decay tick, observed at ROW scope (not in the memoized rows build) so a quiet
        // completed pane still re-renders at the flash-window boundary — `completionFreshness` reads
        // the wall clock, not an `@Observable` dependency.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        let reading = SidebarRowPresentation.reading(
            for: row, store: store, fallbackTitle: fallbackTitle,
        )
        HStack(spacing: 8) {
            Label {
                if reading.isEditing {
                    // The phone's inline-rename field — commits on submit / blur (Escape is a
                    // hardware-keyboard verb the Mac's field owns).
                    InlineRenameField(seed: reading.title, onCommit: onRename, onCancel: onCancelRename)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        // The title stays NEUTRAL on the phone: at a thumb's distance the trailing
                        // mark is the state channel, and a list row recoloured mid-scroll reads as a
                        // rendering fault rather than as news. The AX value keeps it
                        // VoiceOver-legible.
                        Text(reading.title)
                            .foregroundStyle(Slate.Text.primary)
                            .lineLimit(1)
                            .accessibilityValue(reading.spokenState ?? "")
                            // The REST of the tooltip — the untruncated cwd, the clipped prose
                            // readout, the last command's receipt line — all of it overflow recovery
                            // for what this row already shows and had to shorten. On the Mac it costs
                            // a hover; VoiceOver reading it after the label is the same bargain.
                            // `.help()` is NOT that bargain: iOS renders it nowhere, which is how
                            // these strings came to be reachable only on the half with a pointer.
                            // Hung on the TITLE rather than on the row — the title is the row's
                            // accessibility element, and a hint on the raw stack lands on nothing.
                            .accessibilityHint(reading.tooltip ?? "")
                        // WHO ELSE is on this pane — the one fact the Mac's tooltip carries that is
                        // nowhere else on screen, and the one this device is most likely to be half
                        // of. It grows a line only when there IS a second client (docs/45), so the
                        // common single-client row is exactly as tall as it was.
                        //
                        // The instrument face at the caption size, on the supporting ink: it is
                        // metadata about the row, in the same register as the trailing slot's process
                        // name, and it must never compete with the title it hangs under.
                        if let presence = reading.presence {
                            Text(presence)
                                .font(Slate.Typeface.instrument(Slate.Typeface.small))
                                .foregroundStyle(Slate.Text.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } icon: {
                Image(systemSymbol: symbol)
            }
            Spacer(minLength: 6)
            if reading.readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
            }
            // A privilege marker, else a finished command's receipt — the two things that mount
            // trailing TEXT. Everything else is the mark's hue.
            if let badge = reading.badge, StatusPresentation.tabBadge(badge) != nil {
                TabBadgeView(kind: badge)
            } else if let receipt = reading.receipt {
                // ONE answer, never two — the bare tick alone for a clean exit, the name alone in red
                // for a failure. Both in the outcome's own ink, so the shorter slot is not a fainter
                // one.
                if let tick = StatusPresentation.outcomeSymbol(receipt.outcome) {
                    Image(systemSymbol: tick)
                        .font(.system(
                            size: StatusDot.receiptCheckSize, weight: StatusDot.receiptCheckWeight,
                        ))
                        .foregroundStyle(StatusPresentation.outcomeInk(receipt.outcome))
                        // The MARK's column box — a bare glyph is only as wide as itself, so flush
                        // right it misses the centre line every mark stands on.
                        .frame(width: StatusDot.footprint, height: StatusDot.footprint)
                        .accessibilityHidden(true)
                } else {
                    Text(receipt.name)
                        .font(Slate.Typeface.instrument(
                            Slate.Typeface.small, weight: StatusPresentation.slotNameWeight,
                        ))
                        .foregroundStyle(StatusPresentation.outcomeInk(receipt.outcome))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            // The trailing status mark — rightmost, so state reads down one fixed column here too.
            if let dot = StatusPresentation.statusDot(
                working: reading.workingLabel != nil, badge: reading.badge,
                agentIdle: reading.agentIdle, agentFinish: reading.agentFinish,
            ) {
                StatusDotView(style: dot)
            }
        }
    }
}

// MARK: - One project group's header

/// One project group's header: the FOLDER glyph, the group's NAME, and — while open — the live git
/// line beneath it. While COLLAPSED the git line folds away and the hidden-row COUNT takes the
/// trailing slot instead, wearing the strongest ATTENTION ink of the rows it hides, so folding a
/// group never mutes a waiting agent.
///
/// A separate `View` and not a `@ViewBuilder` on the column, for the reason ``IOSSidebarLiveRow`` is
/// one: it reads `projectGitSummary` and (while shut) every hidden row's live chrome, and those are
/// exactly the volatile store dicts the column's ``RailRowsMemo`` exists to keep OUT of the sections
/// + list-diff pass. Its own body means a git tick repaints this header and nothing else — the same
/// leaf-scope contract ``SlopDeskMacUI/MacSidebarHeaderView/refresh()`` keeps on the other half.
///
/// The CHEVRON is absent on purpose: the column's `Section(isExpanded:)` draws and turns the system
/// one. The Mac had to build that (a glyph rotated 0°↔90° inside a hand-run animation group) because
/// AppKit has no collapsing section; asking for a control the platform owns is the layout differing,
/// not the feature.
private struct IOSSidebarSectionHeader: View {
    let store: WorkspaceStore
    /// The group's display name — the basename, worktree-collision-qualified.
    let title: String
    let projectKey: String?
    /// The group's rows — read to fuse the hidden rows' badges into the collapsed count's roll-up ink.
    let rows: [RailRow]
    let collapsed: Bool

    var body: some View {
        let summary = projectKey.flatMap { store.projectGitSummary[$0] }
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: Slate.Metric.space1) {
                // The group is a PLACE. MONOCHROME even where the Mac's bed carries an identity hue:
                // this list has no bed to tint, so the glyph is the whole marker and a colour on it
                // would be a second vocabulary the phone never taught.
                Image(systemSymbol: .folderFill)
                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityHidden(true)
                // `nerdAware` — a project folder named with a nerd-font glyph draws it from the
                // bundled symbols face instead of a notdef box.
                Text.nerdAware(title, size: Slate.Typeface.footnote)
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
                Spacer(minLength: Slate.Metric.space1)
                if let trailing = SidebarGitLine.trailingCount(collapsed: collapsed, count: rows.count) {
                    // The count wears the loudest ATTENTION state among the rows this group is
                    // HIDING, ranked by ``TabBadgeReading/rollup(_:)`` so both halves pick the same
                    // one — folding a group must never mute a waiting agent. An OPEN group asks
                    // nothing: its rows are on screen wearing their own marks.
                    let rollup = TabBadgeReading.rollup(
                        RailRowsBuilder.liveChrome(for: rows, store: store).map(\.badge),
                    )
                    Text(trailing)
                        .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(rollup.map { Slate.attentionInk($0) } ?? Slate.Text.tertiary)
                }
            }
            if let detail = SidebarGitLine.detailSummary(collapsed: collapsed, summary: summary) {
                IOSGitLineView(summary: detail)
            }
        }
        // The Mac hangs this verb off the header's right-click. A long press is the phone's spelling
        // of the same reach, and the row beneath it already uses one for its own menu — so the two
        // menus sit where their subjects do rather than one of them going missing.
        .contextMenu {
            if let projectKey {
                Button("Refresh Git Status") { store.refreshGitSummary(forProject: projectKey) }
            }
        }
    }
}

// MARK: - The git line

/// The git line as it PAINTS on a phone-width column.
///
/// Roomy: the whole dialect inline, branch then counts. Tight: the counts fold to
/// ``SidebarGitLine/compactStatus(_:shedding:)``'s bare sigils pinned flush to the trailing edge, one
/// cluster with no gaps so they read as a single readout rather than a second sentence. Presence is
/// what a sigil reports — `!` says there is uncommitted work at any width — so the NUMBERS retreat
/// first, and the branch only truncates when even the worktree core cannot buy the name enough room.
///
/// The LADDER is `slopdesk_workspace::git_line`'s, asked for by rung; this view says how much room it
/// has and never which role should go. What differs from the Mac's mount is only WHO ASKS: AppKit has
/// no container that walks candidates, so ``SlopDeskMacUI/MacGitLineView`` measures the rungs itself
/// against its own width. `ViewThatFits` is that same question with the framework answering it, and
/// it is the shape the Mac's SwiftUI original used before the column crossed.
///
/// Each rung is ONE `Text` built by concatenation rather than a stack of labels, for the reason the
/// Mac builds one attributed string: a stack clips a whole run when it overflows, where a single line
/// truncates its tail — and the tail of this line is the part that matters least.
private struct IOSGitLineView: View {
    let summary: PaneGitSummary

    var body: some View {
        let segments = SidebarGitLine.segments(summary)
        let branch = segments.filter { $0.ink == .branch }
        let status = segments.filter { $0.ink != .branch }
        if status.isEmpty {
            // A clean repo is the branch alone — there is no readout to shed, so there is no ladder
            // to walk either.
            written(segments, separator: " ").lineLimit(1)
        } else {
            ViewThatFits(in: .horizontal) {
                written(segments, separator: " ").lineLimit(1)
                split(branch, shedding: 0)
                split(branch, shedding: 1)
                split(branch, shedding: 2)
                // The last candidate is the one `ViewThatFits` falls back to when none fit, which is
                // the Mac's escape hatch stated as a position: the worktree core stays whole and the
                // NAME truncates (tail — a long branch loses its end, the part that repeats).
                split(branch, shedding: 3)
            }
        }
    }

    /// One rung of the tight form: the branch left, the shed readout flush right. The gap is a
    /// `Spacer` whose IDEAL length is its `minLength`, which is what lets `ViewThatFits` measure this
    /// candidate at the width it would actually need — the one gap the tight form keeps, so the name
    /// never touches the readout however little room is left.
    private func split(_ branch: [GitSegment], shedding level: Int) -> some View {
        HStack(spacing: 0) {
            written(branch, separator: " ").lineLimit(1)
            Spacer(minLength: Slate.Metric.space1)
            written(SidebarGitLine.compactStatus(summary, shedding: level), separator: "")
                .lineLimit(1)
        }
    }

    /// The painted runs as one `Text`. Each run wears its OWN ink and weight: rendering all of them in
    /// one flat grey made the counts that matter (a conflict, unpushed work) read exactly like the
    /// ones that do not, and the weight is the second channel that survives the hue set's CVD
    /// collapse. The mono grid keeps the line from turning into confetti.
    private func written(_ segments: [GitSegment], separator: String) -> Text {
        segments.enumerated().reduce(Text(verbatim: "")) { line, run in
            line + Text(verbatim: run.offset == 0 ? run.element.text : separator + run.element.text)
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: weight(run.element)))
                .foregroundStyle(Color(slateNative: Slate.Native.gitInk(run.element.ink)))
        }
    }

    /// A run's three rungs, in the face's own units. The RUNG is the dialect's — it arrives on the
    /// segment — so this maps and never decides.
    private func weight(_ segment: GitSegment) -> Font.Weight {
        switch segment.weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

/// A small self-focusing inline rename `TextField` — owns its own draft `@State` so a `@ViewBuilder`
/// row helper (which cannot hold state) can drop it in. Seeds from `seed` on open and commits on
/// Return / focus-loss. A blank commit is a no-op rename downstream, so the field never blanks the row.
private struct InlineRenameField: View {
    let seed: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    /// Whether the rename was already RESOLVED by Return — so the focus-loss handler fired at field
    /// teardown does not re-commit it. A genuine tap-away leaves it `false` and still commits once.
    /// Reset per open via `.onAppear`.
    @State private var resolved = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Rename", text: $draft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            .onAppear {
                draft = seed
                resolved = false
                focused = true
            }
            .onSubmit {
                resolved = true
                // An untouched draft is a CANCEL, not a rename — committing the seed verbatim would
                // freeze the row's LIVE title (intent / running command / generic) as a sticky
                // `userRenamed` identity. The same guard the Mac's field keeps.
                if draft == seed { onCancel() } else { onCommit(draft) }
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused, !resolved else { return }
                if draft == seed { onCancel() } else { onCommit(draft) }
            }
    }
}
#endif
