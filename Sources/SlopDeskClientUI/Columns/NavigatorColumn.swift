// NavigatorColumn — the PHONE's sidebar navigator.
//
// A system `List(selection:)`, so `NavigationSplitView` pushes to the content column on a compact
// iPhone (a custom button list does not drive column navigation). It keeps the system `.searchable`
// field, grouped `Section`s and the trailing badge, themed to the same ladder the Mac's column reads.
//
// ⚠️ macOS LEFT THIS FILE (docs/56 stage D). The Mac's navigator is AppKit now —
// ``SlopDeskMacUI/MacNavigatorColumn`` — and everything the two halves could have disagreed about was
// lifted BELOW both first rather than mirrored: the row's whole resolution
// (``SidebarRowPresentation/reading(for:store:fallbackTitle:)``), the section grouping
// (``SidebarSections``), the select path and the rename commit (``SidebarSelection``), and the
// context menu's verb table (``SidebarRowMenu``). Both bodies here now READ those; neither decides
// anything a phone and a Mac could answer differently.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskVideoProtocol // AgentPreferences — the `preventSleep` flag the tab context menu toggles
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

    /// The live ``PreferencesStore`` — threaded in so the tab context menu can surface the host-LOCAL
    /// **Prevent Sleep While Processing** flag (`docs/ui-shell/screenshots/open-code-agent-history.png`
    /// shows it on the tab menu). The macOS sidebar is hosted in a SEPARATE `NSHostingController` that does not
    /// inherit the WindowGroup environment, so the split-view host passes it explicitly (`nil` on a preview /
    /// pre-injection ⇒ the Prevent-Sleep row is hidden, never a dead control). iOS inherits it via the
    /// `NavigationSplitView` but still passes it explicitly for parity.
    var preferences: PreferencesStore?

    /// The cross-container pane-drag rendezvous — makes every sidebar row a DROP TARGET for a live pane
    /// drag (the pane moves BESIDE that row's pane, its tab revealed) and mounts the New-Tab drop slot
    /// while a drag is in flight. Threaded in like `preferences` (the sidebar's `NSHostingController`
    /// inherits no environment); `nil` (previews / iOS) leaves the rows plain.
    var paneDrag: PaneDragCoordinator?

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

    /// The collapse-set key for a section: its normalized project key, or the sentinel for the
    /// keyless "Other" bucket (whose `projectKey` is `nil` but which still collapses).
    static func collapseKey(_ projectKey: String?) -> String {
        projectKey ?? "\u{2205}other"
    }

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
            if allRows.isEmpty {
                Label("No tabs open", systemSymbol: .squareSplit2x1)
                    .foregroundStyle(Slate.Text.secondary)
            } else if sections.isEmpty {
                Label("No matches", systemSymbol: .magnifyingglass)
                    .foregroundStyle(Slate.Text.secondary)
            } else {
                ForEach(sections) { section in
                    Section(section.header ?? "Tabs") {
                        ForEach(section.rows) { row in
                            iosRow(row)
                        }
                    }
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
    }

    // MARK: - Tab context menu

    /// The long-press menu for a sidebar row — the Agent-Behaviour switches surfaced on the tab.
    ///
    /// The TABLE is ``SidebarRowMenu``'s, not this view's: a verb list written twice diverges on the
    /// first new verb, and that failure is silent in both halves until someone notices their phone's
    /// menu is not their Mac's. This body only turns entries into `Button`s and `Toggle`s.
    @ViewBuilder
    private func rowContextMenu(_ row: RailRow) -> some View {
        let entries = SidebarRowMenu.entries(
            for: row.id, store: store,
            // `?? false` mirrors the daemon's default-OFF (`nil` ⇒ unset). A `nil` STORE (preview /
            // pre-injection) drops the row entirely rather than offering a dead control.
            preventSleep: preferences.map { $0.agent.preventSleep ?? false },
        )
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case let .action(verb):
                Button(verb.title) { SidebarRowMenu.run(verb, row: row, store: store) }
            case let .toggle(flag, isOn):
                Toggle(flag.title, isOn: Binding(
                    get: { isOn },
                    set: { _ in
                        SidebarRowMenu.flip(flag, paneID: row.id, store: store) {
                            guard let preferences else { return }
                            preferences.agent.preventSleep = !(preferences.agent.preventSleep ?? false)
                        }
                    },
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
                    // The title stays NEUTRAL on the phone: at a thumb's distance the trailing mark
                    // is the state channel, and a list row recoloured mid-scroll reads as a rendering
                    // fault rather than as news. The AX value keeps it VoiceOver-legible.
                    Text(reading.title)
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                        .accessibilityValue(reading.spokenState ?? "")
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
