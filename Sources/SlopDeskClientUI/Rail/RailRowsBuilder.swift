// RailRowsBuilder — the pure mapping from the live WorkspaceStore tree → the rail's `[RailRow]` (V1
// "Panes" granularity: one row per visible pane of the active session's tabs). Kept pure + static so
// SlopDeskClientUITests can pin the mapping (selection, title/subtitle, agent status) without a view.

import Foundation
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore

/// The data a single rail row binds to (derived from a pane within the active session's tabs). A pure value
/// type — kept with the builder logic rather than a view, since it carries no view/design-system coupling.
/// The native rail in L1+ rebuilds the row VIEW over this same model.
struct RailRow: Identifiable, Equatable {
    let id: PaneID
    let tabID: TabID
    let kind: PaneKind
    let title: String
    /// The row's muted second line (``SlateTabRow`` subtitle). Kind-generic ``PaneSpec/railSubtitle``:
    /// a terminal's cwd, or a video pane's host-app/window label; `nil` ⇒ a single-line row.
    let subtitle: String?
    let status: ClaudeStatus
    /// The 1-based tab shortcut number — the ⌘1…⌘9 target = tab index+1. Split-tab panes share
    /// the same `#N` (it is a TAB number, not a pane number), per the per-pane→per-tab mapping.
    let tabNumber: Int
    /// The single fused status badge for the row (``TabBadgeResolver``), or `nil` when all-clear.
    let badge: TabBadgeKind?
    /// The coarse host-reported foreground-process name (wire type 26), shown trailing on the active row; `nil`
    /// when the host has not reported one.
    let processLabel: String?
    /// Whether this pane's input gate is READ-ONLY — read from the store's convergent
    /// ``WorkspaceStore/paneReadOnly`` set so the sidebar lock indicator and the pane's `🔒 READ ONLY ×` pill
    /// share one source of truth. Drives ``SlateTabRow``'s trailing lock glyph.
    let readOnly: Bool
    /// The pane's raw last-known working directory — a terminal pane's `lastKnownCwd`, `nil` for a
    /// video pane. NOT rendered as chrome: it is the row's TOOLTIP (`.help`) text AND a hidden search key so a
    /// git-repo row (whose visible subtitle is the git line, not the path) stays searchable BY PATH and two
    /// same-named worktrees are told apart by their full cwd.
    let cwd: String?
    /// Whether this row is in inline-RENAME mode: the store's ``WorkspaceStore/pendingTabRename``
    /// names this row's tab AND this pane is that tab's representative (active) pane — so exactly one row per
    /// pending tab opens its rename field. Consumed by ``SlateTabRow`` to swap the title for a `TextField`.
    let isEditing: Bool
    /// Selected = the row's tab is active AND this pane is the tab's active pane.
    let isSelected: Bool
    /// The pane's folded git state (branch/ahead/behind/changed) when its cwd is a repo — carried as the pure
    /// domain value (no view coupling, so tests still pin the mapping) so the VIEW renders the git line with
    /// per-token STATUS colour, while `subtitle` keeps the plain single-colour string for height/search/
    /// fallback. `nil` for a non-repo cwd or a video pane. Default keeps the direct-construction call sites
    /// (the Equatable pins) source-compatible.
    var gitSummary: PaneGitSummary?
    /// The pane's OWN By-Project key (``WorkspaceStore/paneProjectKey(_:)`` — the HOST-pushed
    /// ``PaneSpec/projectKey`` else cwd, plugin-dirs guarded out), carried per-ROW so
    /// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` buckets each pane by ITS project, not its
    /// tab's active-pane project. This is what makes a SPLIT tab's two panes land in their respective
    /// project sections AND stops the section header from flickering with focus. `nil` for a keyless /
    /// video pane (⇒ the "Other" bucket). Defaulted so the Equatable pins / completion-title call sites
    /// stay source-compatible.
    var projectKey: String?

    /// The SwiftUI view identity for this row's LEAF view (`SidebarLiveRow` / `IOSSidebarLiveRow`) —
    /// the pane id plus every MEMOIZED field the leaf renders from this row value (title / kind / cwd
    /// tooltip). Inside the sidebar's lazy container, a leaf whose Observation deps (the volatile chrome
    /// dicts) fire re-renders with the row value it was CREATED with — a structural rebuild that changes
    /// this row's title (cwd landed, a chooser resolved to a terminal, a rename) updates the memoized
    /// model but would never repaint the leaf without this, so the rail would show "New Pane"/a stale
    /// folder name forever while its subtitle stayed live. Keying the leaf's `.id(_:)` on this string
    /// forces a fresh leaf whenever a rendered-from-row field changes; volatile chrome keeps flowing
    /// through `liveChrome` unchanged.
    var leafIdentity: String {
        "\(id.raw.uuidString)|\(title)|\(kind.rawValue)|\(cwd ?? "")"
    }

    /// A copy of this row with a new `title` (collision disambiguation) — every other field is
    /// carried verbatim. Kept here so ``RailRowsBuilder/disambiguated(_:)`` need not restate the memberwise init.
    func retitled(_ newTitle: String) -> Self {
        Self(
            id: id, tabID: tabID, kind: kind, title: newTitle, subtitle: subtitle, status: status,
            tabNumber: tabNumber, badge: badge, processLabel: processLabel, readOnly: readOnly, cwd: cwd,
            isEditing: isEditing, isSelected: isSelected, gitSummary: gitSummary, projectKey: projectKey,
        )
    }
}

enum RailRowsBuilder {
    /// Build the rail rows for the active session. One row per pane of each tab,
    /// in tab order then pre-order pane order. `selected` = the tab is active AND the pane is that tab's
    /// active pane. Agent status comes from the store's per-pane mirror (`.none` ⇒ plain terminal).
    ///
    /// `.remoteGUI` panes are NOT rows: the left rail tracks the TERMINAL workspace only — an open
    /// remote window's home is the RIGHT rail (``HostWindowsColumn``), where its host-window row carries
    /// the streamed marker/focus state and clicking/dragging it acts on the existing pane. Listing it
    /// here too made the same pane answer to two sidebars. (The ⌘K jump palette enumerates panes
    /// itself, so window panes stay jumpable.)
    @MainActor
    static func rows(for store: WorkspaceStore) -> [RailRow] {
        guard let session = store.tree.activeSession else { return [] }
        // Observe the flash-decay tick so the rail re-renders ONCE at the completion flash-window
        // boundary. `completionFreshness(forPane:)` below reads the wall clock at build time (NOT an
        // `@Observable` dependency); without this read a quiet completed pane would never re-render and its
        // brief `.completed` checkmark would stick. The store bumps the tick after `completedFlashWindow`
        // to invalidate the observing rail, so the row decays to the `.finished` dot on its own.
        _ = store.completionFlashTick
        let activeTabIndex = session.activeTabIndex
        var out: [RailRow] = []
        for (tabIndex, tab) in session.tabs.enumerated() {
            let tabIsActive = tabIndex == activeTabIndex
            // A MANUAL `tab badge --kind` override (if any) is rendered on the tab's
            // REPRESENTATIVE (active) pane row — the badge is per-tab, so it lands on the one row that
            // stands in for the tab (the same representative `tab list` reports). Resolved once per tab.
            let representativePane = tab.activePane ?? tab.allPaneIDs().first
            let manualBadge = store.tabBadgeOverride(for: tab.id)
            // Enumerate the tab's full pane set (`tab.allPaneIDs()`, pre-order DFS) — matching OpenQuickly.
            for paneID in tab.allPaneIDs() {
                let spec = session.specs[paneID]
                let kind = spec?.kind ?? .terminal
                // Remote windows are the right rail's rows — see the builder doc above.
                if kind == .remoteGUI { continue }
                // The row's VOLATILE chrome (status / badge / git line / process / lock / rename mode) —
                // resolved by the SAME `chrome(...)` the live row views read directly. The sidebar body
                // memoizes these rows and each row VIEW re-reads its own chrome fresh, so the resolution
                // rule must have exactly one home or the two paths drift.
                let chrome = Self.chrome(
                    paneID: paneID, kind: kind, spec: spec, tabID: tab.id,
                    representativePane: representativePane, manualBadge: manualBadge, store: store,
                )
                // A TERMINAL row's line 1 is its cwd's FOLDER NAME (`slopdesk`), not the generic
                // "Terminal" / raw shell title — an explicit user rename still wins (see `rowTitle`); a
                // cwd-less pane falls back to its foreground program before the generic chain.
                let title = Self.rowTitle(kind: kind, spec: spec, processLabel: chrome.processLabel)
                let isSelected = tabIsActive && tab.activePane == paneID
                out.append(RailRow(
                    id: paneID,
                    tabID: tab.id,
                    kind: kind,
                    title: title,
                    subtitle: chrome.subtitle,
                    status: chrome.status,
                    tabNumber: tabIndex + 1,
                    badge: chrome.badge,
                    processLabel: chrome.processLabel,
                    readOnly: chrome.readOnly,
                    cwd: kind == .terminal ? spec?.lastKnownCwd : nil,
                    isEditing: chrome.isEditing,
                    isSelected: isSelected,
                    gitSummary: chrome.gitSummary,
                    // The pane's OWN project key (guarded host-pushed key / cwd) drives per-pane
                    // By-Project sectioning; a video pane has no project (⇒ "Other").
                    projectKey: kind == .terminal ? store.paneProjectKey(paneID) : nil,
                ))
            }
        }
        // Disambiguate any two VISIBLE rows that collide on a folder-name title by prefixing the
        // parent path segment (`feature-a/myapp` vs `feature-b/myapp`) so same-named worktrees are told apart.
        return disambiguated(out)
    }

    /// The VOLATILE per-row chrome — every field of a rail row that ticks with pane activity rather than
    /// with workspace STRUCTURE: agent status, the fused badge, the git line / subtitle, the foreground
    /// process, the read-only lock, and the inline-rename mode. Split out so the row VIEW can
    /// read its own pane's chrome fresh from the store while the sidebar body renders MEMOIZED structural
    /// rows (``RailRowsMemo``) — a status tick then re-renders one cheap leaf row body instead of
    /// rebuilding the whole rows/section model. `Equatable` so tests pin builder ↔ live parity.
    struct RailRowChrome: Equatable {
        let status: ClaudeStatus
        let badge: TabBadgeKind?
        let processLabel: String?
        let gitSummary: PaneGitSummary?
        let subtitle: String?
        let readOnly: Bool
        let isEditing: Bool
        /// The host's blocking prompt (``WorkspaceStore/agentLabel(for:)``), non-nil ONLY while `status ==
        /// .needsPermission` AND the store has a non-empty label for this pane — kept OUT of ``subtitle``
        /// (and therefore out of the memoized, structural ``RailRow``) so a blocked row's search corpus never
        /// bakes in a stale question and a mid-block structural rebuild can never freeze one in. The row VIEW
        /// swaps its line-2 text to this over `subtitle` while non-nil; `subtitle`/`gitSummary` keep resolving
        /// as if the row were never blocked.
        let question: String?
    }

    /// Resolve one pane's volatile chrome — the SINGLE resolution rule behind both ``rows(for:)`` (the full
    /// model build) and ``liveChrome(for:store:)`` (the per-row view's fresh read), so the two can't drift.
    ///
    /// Line 2: a terminal shows its git line (branch ↑/↓ · N changed) when the store has a summary for a
    /// repo cwd, else the kind-generic ``PaneSpec/railSubtitle`` — a terminal's plain cwd, or (for a
    /// `.remoteGUI`/`.systemDialog` video pane, which has no shell cwd) the host-side window's owning app
    /// name (falling back to the window title). So a remote window reads as a labelled WINDOW rather than a
    /// bare single line. (The coarse video-CONNECTION dot is deferred as a follow-up.)
    ///
    /// Badge: the SOURCE-AWARE gating masks the resolver inputs by source so
    /// the agent toggles (per-pane override beats the global default) and the command "TAB BADGE" toggles
    /// gate their OWN badge families independently — a program's busy / OSC 9;4 progress spinner and an
    /// OSC 9;4;2 progress error are never silenced by an agent toggle. Freshness decays the clean-completion
    /// badge (store owns the clock); the resolver stays pure. An explicit `tab badge --kind`
    /// override wins for the tab's REPRESENTATIVE row, bypassing the agent-badge gates (it is an explicit
    /// CLI affordance, not an agent signal).
    ///
    /// Rename mode: the row opens its inline rename field when the store's pending-rename names
    /// this TAB and this pane is the tab's representative (active) pane — one editing row per pending tab.
    @MainActor
    static func chrome(
        paneID: PaneID, kind: PaneKind, spec: PaneSpec?, tabID: TabID,
        representativePane: PaneID?, manualBadge: TabBadgeKind?, store: WorkspaceStore,
    ) -> RailRowChrome {
        // The host's coarse foreground-process name (wire type 26): the trailing row label, a
        // badge-resolver input, AND the pane-title fallback when the cwd is not known yet.
        let processLabel = store.paneForegroundProcess[paneID]
        let gitSummary = kind == .terminal ? store.paneGitSummary[paneID] : nil
        let subtitle = gitSummary?.compactLine ?? spec?.railSubtitle
        let status = store.paneAgentStatus[paneID] ?? .none
        let gatedBadge = TabBadgeGating.resolve(
            agent: status,
            completion: store.panePendingCompletion[paneID],
            // Reveal-thresholded (default 3 s) so a fast `ls` never flashes the busy dot; must match
            // the `unseenAttentionPanes` input (the two resolution sites may never disagree).
            isBusy: store.paneShowsBusyDot(paneID),
            foregroundProcess: processLabel,
            completionFreshness: store.completionFreshness(forPane: paneID),
            progress: store.progress(for: paneID),
            agentGates: store.agentBadgeGates(for: paneID),
            commandGates: store.commandBadgeGates,
        )
        // The blocked-row question: the host's blocking prompt, gated on the SAME predicate the
        // row view uses to pick its `.tail` truncation — status == .needsPermission AND a non-empty label —
        // so a block whose label hasn't landed yet (the race window) keeps the plain git/cwd subtitle instead
        // of a blank/absent line.
        let question = status == .needsPermission ? store.agentLabel(for: paneID) : nil
        return RailRowChrome(
            status: status,
            badge: (paneID == representativePane ? manualBadge : nil) ?? gatedBadge,
            processLabel: processLabel,
            gitSummary: gitSummary,
            subtitle: subtitle,
            readOnly: store.isReadOnly(for: paneID),
            isEditing: store.pendingTabRename == tabID && paneID == representativePane,
            question: question,
        )
    }

    /// The row VIEW's entry: resolve `row`'s CURRENT volatile chrome from the live store (the cached
    /// ``RailRow`` a memoized sidebar carries is stale by design for these fields). Re-derives the tab's
    /// representative pane + manual badge override from the store, then delegates to ``chrome(...)``.
    @MainActor
    static func liveChrome(for row: RailRow, store: WorkspaceStore) -> RailRowChrome {
        let session = store.tree.activeSession
        let tab = session?.tabs.first { $0.id == row.tabID }
        let representativePane = tab.flatMap { $0.activePane ?? $0.allPaneIDs().first }
        return chrome(
            paneID: row.id, kind: row.kind, spec: session?.specs[row.id], tabID: row.tabID,
            representativePane: representativePane,
            manualBadge: store.tabBadgeOverride(for: row.tabID), store: store,
        )
    }

    /// For any TITLE shared by more than one row, replace each colliding row's folder-name title
    /// with its parent-qualified form (`parent/leaf`). Only folder-derived titles are rewritten (an explicit
    /// rename that happens to collide is left verbatim), and only when a distinct parent segment exists; rows
    /// with a unique title, no cwd, or no parent are returned unchanged. Pure so the collision rule is pinned
    /// headlessly.
    static func disambiguated(_ rows: [RailRow]) -> [RailRow] {
        var counts: [String: Int] = [:]
        for row in rows { counts[row.title, default: 0] += 1 }
        return rows.map { row in
            guard (counts[row.title] ?? 0) > 1,
                  let qualified = parentQualifiedTitle(cwd: row.cwd, title: row.title)
            else { return row }
            return row.retitled(qualified)
        }
    }

    /// The parent-qualified title `parent/leaf` for a folder-name row, or `nil` when it should be left alone:
    /// the title is NOT the cwd's folder name (i.e. it is an explicit rename), the cwd is `nil`/blank, or the
    /// path has no parent segment above the leaf. Pure + static so the collision rewrite is unit-pinned.
    static func parentQualifiedTitle(cwd: String?, title: String) -> String? {
        guard let cwd, cwdFolderName(cwd) == title else { return nil }
        var path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return nil }
        return "\(comps[comps.count - 2])/\(title)"
    }

    /// The row's LINE-1 title. A `.terminal` pane titles itself by its working directory's FOLDER NAME
    /// (`/Volumes/…/slopdesk` → `slopdesk`) — the identity a coding tool actually navigates by — with two
    /// escapes: an EXPLICIT user rename always wins (gated on ``PaneSpec/userRenamed``), and a pane
    /// with no known cwd yet falls back to the host FOREGROUND-PROCESS name (`processLabel`, wire type
    /// 26 — a real program like `vim`/`npm`, a bare login shell suppressed) before the generic shell-title
    /// chain. Non-terminal kinds keep the `lastKnownTitle ?? title` chain unchanged. Pure + static so
    /// the mapping is unit-pinned without a view.
    ///
    /// - Parameter processLabel: the pane's host-reported foreground process (``WorkspaceStore/paneForegroundProcess``),
    ///   used ONLY as the no-cwd fallback. Optional so the completion-title / test call sites that do not
    ///   thread the store's process map still resolve the cwd/rename precedence.
    static func rowTitle(kind: PaneKind, spec: PaneSpec?, processLabel: String? = nil) -> String {
        let fallback = spec?.lastKnownTitle ?? spec?.title ?? ""
        guard kind == .terminal, let spec else { return fallback }
        // An EXPLICIT user rename (⌘R / palette / inline field) always wins — gated on the unambiguous
        // `userRenamed` flag, NOT a `title != lastKnownTitle` heuristic: that would latch a stale
        // load-time-promoted title as a phantom "rename" the moment a shell emits a SECOND OSC title.
        if spec.userRenamed, !spec.title.isEmpty {
            return spec.title
        }
        // Folder name is the primary identity; when the cwd is not known yet (no OSC-7, host pull not
        // landed) the pane is titled by its live foreground program before the generic "Terminal" chain.
        return cwdFolderName(spec.lastKnownCwd)
            ?? processDisplayName(processLabel)
            ?? fallback
    }

    /// The host foreground-process name (wire type 26) as a pane-TITLE fallback, or `nil` to skip it.
    /// Basenames the label and drops the leading `-` of a login-shell argv0, then SUPPRESSES a bare
    /// interactive shell (`zsh`/`bash`/`fish`/…) — titling a pane "zsh" is no more useful than "Terminal",
    /// so those fall through to the generic chain, while a real foreground program (`vim`, `npm`, `ssh`)
    /// titles the pane. Pure + static so the fallback is unit-pinned.
    static func processDisplayName(_ label: String?) -> String? {
        guard let label else { return nil }
        var name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("-") { name.removeFirst() } // login-shell argv0 convention (`-zsh`)
        name = name.split(separator: "/").last.map(String.init) ?? name
        guard !name.isEmpty, !loginShellNames.contains(name.lowercased()) else { return nil }
        return name
    }

    /// Bare interactive-shell basenames that must NOT title a pane — titling by the shell is no more
    /// informative than the generic default, so the row keeps the cwd/generic chain instead.
    private static let loginShellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "login",
    ]

    /// The display folder name of a cwd: its last path component (`/a/b/repo` → `repo`, trailing-slash
    /// tolerant), the root as `/`, a bare `~` kept as-is. `nil` for `nil`/blank so the caller falls back
    /// — never an empty title. Delegates to ``PaneSpec/cwdDisplayName(_:)`` (WorkspaceCore, the single
    /// source of truth) so the rail row and ``PaneSpec/completionNotificationTitle`` derive the same
    /// folder name; kept here as the builder's local name so the existing call sites + tests are stable.
    static func cwdFolderName(_ cwd: String?) -> String? {
        PaneSpec.cwdDisplayName(cwd)
    }

    /// Filter rows by a lower-cased search query (empty query ⇒ all). Matches the visible title + subtitle AND
    /// the hidden keys — the raw `cwd` (a git-repo row's visible subtitle is the git line, not the
    /// path, so without this it would be unsearchable by path) and the foreground `processLabel`.
    static func filtered(_ rows: [RailRow], query: String) -> [RailRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q)
                || ($0.subtitle?.lowercased().contains(q) ?? false)
                || ($0.cwd?.lowercased().contains(q) ?? false)
                || ($0.processLabel?.lowercased().contains(q) ?? false)
        }
    }

    /// The PER-PANE By-Project sectioning — the sidebar's ONE render path (every other grouping/sort mode
    /// has been removed). Buckets each PANE ROW by ITS OWN ``RailRow/projectKey`` (not its
    /// tab's active-pane project). Consequences:
    ///   • a split tab's two panes land in their RESPECTIVE project sections (the user's "group correctly"),
    ///   • the section a pane sits in no longer depends on which pane is focused (no header flicker —
    ///     `projectKey` is a per-pane value, not `tab.activePane`),
    ///   • a single-pane tab's one pane == the tab's project.
    /// Section ORDER is STABLE: first appearance of each project key while walking rows in their natural
    /// CREATION order (`rows` are emitted in `session.tabs` order then pane pre-order) — so a section never
    /// jumps position when you switch tabs. WITHIN each section rows follow `tabOrder`
    /// (``WorkspaceStore/flatOrderedTabIDs()`` — the same creation order) then pane pre-order. The keyless
    /// "Other" bucket (video / cwd-less panes) takes its first-appearance slot too. Query filter composes
    /// first; an all-filtered section is DROPPED. Pure + static so the per-pane grouping rule is
    /// unit-pinned without a SwiftUI view.
    static func sectionedByProject(_ rows: [RailRow], tabOrder: [TabID], query: String) -> [RailRowGroup] {
        let survivors = filtered(rows, query: query)
        // Pass 1 — bucket in CREATION order; `order` fixes the (stable) section sequence.
        var order: [String?] = []
        var buckets: [String?: [RailRow]] = [:]
        for row in survivors {
            let key = TabOrderingEngine.normalizedProjectKey(row.projectKey)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }
        // Pass 2 — order rows WITHIN each section by the sorted tab order (respects "Sort By"), pane pre-order
        // as the stable tiebreak. A row whose tab isn't in `tabOrder` (shouldn't happen) sorts last, stably.
        let rank = Dictionary(tabOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return order.map { key in
            let sorted = (buckets[key] ?? []).enumerated()
                .sorted { lhs, rhs in
                    let lRank = rank[lhs.element.tabID] ?? Int.max
                    let rRank = rank[rhs.element.tabID] ?? Int.max
                    if lRank != rRank { return lRank < rRank }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            return RailRowGroup(header: TabOrderingEngine.projectSectionHeader(for: key), rows: sorted)
        }
    }
}

/// One rendered sidebar section: an optional `header` (the group title) and the rows in render order. A
/// pure value (`Equatable`) so ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` is pinnable
/// headlessly; the navigator wraps it in an `Identifiable` row for `ForEach`.
struct RailRowGroup: Equatable {
    let header: String?
    let rows: [RailRow]
}
