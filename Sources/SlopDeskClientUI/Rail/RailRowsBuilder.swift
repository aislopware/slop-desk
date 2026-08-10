// RailRowsBuilder — the pure mapping from the live WorkspaceStore tree → the rail's `[RailRow]` (V1
// "Panes" granularity: one row per visible pane of the active session's tabs). Kept pure + static so
// SlopDeskClientUITests can pin the mapping (selection, title/subtitle, agent status) without a view.

import Foundation
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The data a single rail row binds to (derived from a pane within the active session's tabs). A pure value
/// type — kept with the builder logic rather than a view, since it carries no view/design-system coupling.
/// The native rail in L1+ rebuilds the row VIEW over this same model.
struct RailRow: Identifiable, Equatable {
    let id: PaneID
    let tabID: TabID
    let kind: PaneKind
    let title: String
    /// The row's muted second line (``SlateTabRow`` subtitle). A terminal shows its cwd RELATIVE to
    /// its section's project key — and ONLY when it strayed from the project root (the git line moved
    /// up to the section header, and repeating the section's own path on every row is noise); a video
    /// pane keeps its kind-generic ``PaneLabel/railSubtitle(kind:title:video:cwd:liveTitle:)``
    /// (host-app/window label). `nil` ⇒ a
    /// single-line row (the common at-root pane).
    let subtitle: String?
    let status: ClaudeStatus
    /// The 1-based CREATION-order tab number — split-tab panes share the same `#N` (it is a TAB
    /// number, not a pane number). NOT the ⌘1…⌘9 coordinate: the digits count PANES in the drawn
    /// order (``WorkspaceStore/displayOrderedPaneIDs()``), which diverges from creation order the
    /// moment sections regroup tabs.
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
    /// The pane's raw working directory (`pane/cwd`) — `nil` for a video pane. NOT rendered as chrome: it is the row's TOOLTIP (`.help`) text AND a hidden search key so
    /// an at-root row (whose visible subtitle is absent) stays searchable BY PATH and two same-named
    /// worktrees are told apart by their full cwd.
    let cwd: String?
    /// Whether this row is in inline-RENAME mode: the store's ``WorkspaceStore/pendingTabRename``
    /// names this row's tab AND this pane is that tab's representative (active) pane — so exactly one row per
    /// pending tab opens its rename field. Consumed by ``SlateTabRow`` to swap the title for a `TextField`.
    let isEditing: Bool
    /// Selected = the row's tab is active AND this pane is the tab's active pane.
    let isSelected: Bool
    /// The pane's OWN By-Project key (``WorkspaceStore/paneProjectKey(_:)`` — the HOST-pushed
    /// `pane/projectKey` else cwd, plugin-dirs guarded out), carried per-ROW so
    /// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` buckets each pane by ITS project, not its
    /// tab's active-pane project. This is what makes a SPLIT tab's two panes land in their respective
    /// project sections AND stops the section header from flickering with focus. `nil` for a keyless /
    /// video pane (⇒ the "Other" bucket). Defaulted so the Equatable pins / completion-title call sites
    /// stay source-compatible.
    var projectKey: String?

    /// The SwiftUI view identity for this row's LEAF view (`SidebarLiveRow` / `IOSSidebarLiveRow`) —
    /// the pane id plus the memoized fields whose change means this leaf is standing for a DIFFERENT
    /// thing (its kind, its place on disk). Inside the sidebar's lazy container a leaf whose
    /// Observation deps (the volatile chrome dicts) fire re-renders with the row value it was CREATED
    /// with, so a structural rebuild that never reaches the leaf would leave stale chrome on screen.
    ///
    /// ⚠️ The TITLE is deliberately NOT here, and this is measured rather than reasoned. A pane's
    /// structural title is its foreground PROCESS whenever the pane titles by program (the at-root
    /// rung), so it flips `sleep 5` → `sleep` → `sleep 5` across one command — and with the title in
    /// this key that is a leaf REPLACEMENT on every command edge: the rail row visibly blinks its
    /// chrome as SwiftUI tears one leaf down and stands another up. Instrumented on hardware
    /// (`[ROW] … leaf=37353` → `leaf=63174` at the exit instant, with no hover, badge or selection
    /// change anywhere near it) — the blink and the swap are the same event.
    ///
    /// Dropping it is safe because the memo's own fingerprint already covers it: ``RailStructureKey``
    /// carries the spec, the cwd, the freshness-gated live title AND the title's process fallback, so
    /// a retitle is always a cache MISS — the navigator body re-runs and hands the leaf the new row.
    /// The identity was a second guard against a case the first one cannot let through, and it cost a
    /// flash per command to stand there.
    var leafIdentity: String {
        "\(id.raw.uuidString)|\(kind.rawValue)|\(cwd ?? "")"
    }

    /// A copy of this row with a new `title` (collision disambiguation) — every other field is
    /// carried verbatim. Kept here so ``RailRowsBuilder/disambiguated(_:)`` need not restate the memberwise init.
    func retitled(_ newTitle: String) -> Self {
        Self(
            id: id, tabID: tabID, kind: kind, title: newTitle, subtitle: subtitle, status: status,
            tabNumber: tabNumber, badge: badge, processLabel: processLabel, readOnly: readOnly, cwd: cwd,
            isEditing: isEditing, isSelected: isSelected, projectKey: projectKey,
        )
    }
}

enum RailRowsBuilder {
    /// Build the rail rows for the active session. One row per pane of each tab,
    /// in tab order then pre-order pane order. `selected` = the tab is active AND the pane is that tab's
    /// active pane. Agent status comes from the store's per-pane mirror (`.none` ⇒ plain terminal).
    ///
    /// EVERY kind is a row again (the full-desktop pivot): the retired right rail was the video
    /// panes' tracker; with it gone the navigator is the one sidebar, so desktop/window panes list
    /// here like any pane (their `chrome` resolution stays kind-aware — no git/process line).
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
                // The two per-pane FACTS the tree does not carry (docs/45 §5.3): where the shell is,
                // and the freshness-gated title the running program asserted.
                let cwd = store.paneCwd(for: paneID)
                let liveTitle = store.liveProgramTitle(for: paneID)
                // The row's VOLATILE chrome (status / badge / git line / process / lock / rename mode) —
                // resolved by the SAME `chrome(...)` the live row views read directly. The sidebar body
                // memoizes these rows and each row VIEW re-reads its own chrome fresh, so the resolution
                // rule must have exactly one home or the two paths drift.
                let chrome = Self.chrome(
                    paneID: paneID, kind: kind, spec: spec, tabID: tab.id,
                    representativePane: representativePane, manualBadge: manualBadge, store: store,
                )
                // The pane's OWN project key (guarded host-pushed key / cwd) — the By-Project section
                // bucket AND the title's at-root test (a row at its project root titles by program,
                // not by the folder name the section header already carries).
                let projectKey = kind == .terminal ? store.paneProjectKey(paneID) : nil
                // A TERMINAL row's line 1 is its cwd's FOLDER NAME (`slopdesk`), not the generic
                // "Terminal" / raw shell title — an explicit user rename still wins (see `rowTitle`); an
                // at-root pane titles by its foreground program (the section header names the folder); a
                // cwd-less pane falls back to its foreground program before the generic chain.
                let title = Self.rowTitle(
                    kind: kind, spec: spec, cwd: cwd, liveTitle: liveTitle,
                    processLabel: chrome.processLabel, projectKey: projectKey,
                )
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
                    cwd: kind == .terminal ? cwd : nil,
                    isEditing: chrome.isEditing,
                    isSelected: isSelected,
                    projectKey: projectKey,
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
    /// Line 2 (``paneSubtitle(kind:spec:cwd:liveTitle:projectKey:)``): a terminal shows its cwd RELATIVE to its
    /// section's project key, and only when it differs (the git line lives on the section header now —
    /// the one per-pane fact left is "this pane strayed from the project root"); a
    /// `.desktop` video pane (no shell cwd) keeps the host-side target's owning app
    /// name (falling back to the window title), so a remote window reads as a labelled WINDOW rather
    /// than a bare single line.
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
        let subtitle = Self.paneSubtitle(
            kind: kind, spec: spec,
            cwd: store.paneCwd(for: paneID), liveTitle: store.liveProgramTitle(for: paneID),
            projectKey: kind == .terminal ? store.paneProjectKey(paneID) : nil,
        )
        let status = store.paneAgentStatus[paneID] ?? .none
        let gatedBadge = TabBadgeGating.resolve(
            agent: status,
            completion: store.panePendingCompletion[paneID],
            // Reveal-thresholded (default 1 s) so a fast `ls` never flashes the busy dot; must match
            // the `unseenAttentionPanes` input (the two resolution sites may never disagree).
            isBusy: store.paneShowsBusyDot(paneID),
            foregroundProcess: processLabel,
            completionFreshness: store.completionFreshness(forPane: paneID),
            progress: store.progress(for: paneID),
            unseenAgentDone: store.paneUnseenDone.contains(paneID),
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
            subtitle: subtitle,
            readOnly: store.isReadOnly(for: paneID),
            isEditing: store.pendingTabRename == tabID && paneID == representativePane,
            question: question,
        )
    }

    /// The row's LINE-2 resolution: a terminal pane's cwd RELATIVE to its section key —
    /// `nil` when the pane sits AT the project root (the section header already names the place; a
    /// subtitle repeating it on every row is noise, and the row collapses to single-line height), the
    /// relative path (`packages/api`) when it strayed INTO the project's subtree, and the kind-generic
    /// kind-generic subtitle (the full cwd) when the cwd is OUTSIDE the key's subtree — a stale
    /// key across an un-re-pushed `cd`, where a relative path can't be formed and hiding the location
    /// would lie. Non-terminal kinds always keep the kind-generic subtitle (video host-app label).
    /// Pure + static so the rule is unit-pinned without a view.
    static func paneSubtitle(
        kind: PaneKind, spec: PaneSpec?, cwd paneCwd: String?, liveTitle: String?, projectKey: String?,
    ) -> String? {
        let generic = spec?.railSubtitle(cwd: paneCwd, liveTitle: liveTitle)
        guard kind == .terminal, spec != nil else { return generic }
        guard let key = TabOrderingEngine.normalizedProjectKey(projectKey),
              var cwd = paneCwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty
        else { return generic }
        while cwd.count > 1, cwd.hasSuffix("/") { cwd.removeLast() }
        if cwd == key { return nil }
        if cwd.hasPrefix(key + "/") { return String(cwd.dropFirst(key.count + 1)) }
        return generic
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

    /// The title a row SHOWS right now — the whole live chain (rename → agent intent → structural →
    /// running command → last executed command → generic) resolved off the store in one call.
    ///
    /// Two surfaces render the same panes and must never disagree about what one is called: the
    /// sidebar's rows and the collapsed-sidebar TAB STRIP. The sidebar leaf keeps computing the
    /// intermediates it also needs for its tooltip; this is the same resolution for a caller that
    /// wants only the string.
    @MainActor
    static func liveTitle(
        for row: RailRow, chrome: RailRowChrome, store: WorkspaceStore, fallback: String,
    ) -> String {
        let runningCommand: String? = (chrome.badge == .commandRunning || chrome.badge == .commandBusy)
            ? store.liveRunningCommand(
                for: row.id, processLabel: processDisplayName(chrome.processLabel),
            )
            : nil
        return liveRowTitle(
            structuralTitle: row.title,
            userRenamed: store.tree.activeSession?.specs[row.id]?.userRenamed == true,
            isAgent: isAgentSession(status: chrome.status, processLabel: chrome.processLabel),
            intent: store.paneAgentIntent[row.id],
            runningCommand: runningCommand,
            programTitle: normalizedProgramTitle(store.liveProgramTitle(for: row.id)),
            processTitle: processDisplayName(chrome.processLabel),
            blocks: store.commandBlocks(for: row.id),
            kind: row.kind,
            cwdTitle: cwdFolderName(row.cwd),
            fallback: fallback,
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
    /// (`/Volumes/…/slopdesk` → `slopdesk`) — the identity a coding tool actually navigates by — with
    /// three escapes: an EXPLICIT user rename always wins (gated on ``PaneSpec/userRenamed``); a pane
    /// sitting AT its project root (under By-Project grouping, via `projectKey`) titles by its
    /// foreground PROGRAM instead — the folder name would restate the section header verbatim, so the
    /// header says WHERE and line 1 says WHO (`claude` / `vim` / `make`, the tmux idiom), an idle shell
    /// yielding "" so the VIEW's fallback reads — the pane's last long-running command
    /// (``lastCommandTitle(blocks:)``), then the cwd folder name (``liveRowTitle``'s `cwdTitle` rung —
    /// the basepath still beats the meaningless kind-generic "Terminal") — rather than an OSC shell
    /// title restating the place; and a pane with no known cwd yet falls back to the host FOREGROUND-PROCESS name
    /// (`processLabel`, wire type 26 — a real program, a bare login shell suppressed) before the generic
    /// shell-title chain. Non-terminal kinds keep the `liveTitle ?? title` chain unchanged. Pure +
    /// static so the mapping is unit-pinned without a view.
    ///
    /// - Parameter processLabel: the pane's host-reported foreground process (``WorkspaceStore/paneForegroundProcess``),
    ///   used as the at-root title and the no-cwd fallback. Optional so the completion-title / test call
    ///   sites that do not thread the store's process map still resolve the cwd/rename precedence.
    /// - Parameter projectKey: the pane's By-Project section key (``WorkspaceStore/paneProjectKey(_:)``) —
    ///   supplied by the SIDEBAR builder only, where a section header already names the project. The
    ///   titlebar/window call sites omit it (no header there — the folder name stays the right title).
    static func rowTitle(
        kind: PaneKind, spec: PaneSpec?, cwd: String? = nil, liveTitle: String? = nil,
        processLabel: String? = nil, projectKey: String? = nil,
    ) -> String {
        let fallback = liveTitle ?? spec?.title ?? ""
        guard kind == .terminal, let spec else { return fallback }
        // An EXPLICIT user rename (⌘R / palette / inline field) always wins — gated on the unambiguous
        // `userRenamed` flag, NOT a `title != liveTitle` heuristic: that would latch a stale
        // load-time-promoted title as a phantom "rename" the moment a shell emits a SECOND OSC title.
        if spec.userRenamed, !spec.title.isEmpty {
            return spec.title
        }
        // At the project root the folder name repeats the section header — title by the program.
        if let key = TabOrderingEngine.normalizedProjectKey(projectKey),
           TabOrderingEngine.normalizedProjectKey(cwd) == key
        {
            return processDisplayName(processLabel) ?? ""
        }
        // Folder name is the primary identity; when the cwd is not known yet (no OSC-7, host pull not
        // landed) the pane is titled by its live foreground program before the generic "Terminal" chain.
        return cwdFolderName(cwd)
            ?? processDisplayName(processLabel)
            ?? fallback
    }

    /// The host foreground-process name (wire type 26) as a pane-TITLE fallback, or `nil` to skip it.
    /// Basenames the label and drops the leading `-` of a login-shell argv0
    /// (``slotProcessName(_:)``), then SUPPRESSES a bare interactive shell (`zsh`/`bash`/`fish`/…) —
    /// titling a pane "zsh" is no more useful than "Terminal", so those fall through to the generic
    /// chain, while a real foreground program (`vim`, `npm`, `ssh`) titles the pane. Pure + static
    /// so the fallback is unit-pinned.
    static func processDisplayName(_ label: String?) -> String? {
        guard let name = slotProcessName(label), !loginShellNames.contains(name.lowercased())
        else { return nil }
        return name
    }

    /// The trailing-SLOT label for a row (`SlateTabRow/processLabel`): the same basename cleanup as
    /// ``processDisplayName(_:)`` but a bare interactive shell KEEPS its name — "zsh" says nothing
    /// as a pane TITLE, yet in the metadata slot it answers "what is this pane running" for an idle
    /// shell row (an empty slot there reads as missing data, not quiet). Pure + static so the slot
    /// mapping is unit-pinned.
    static func slotProcessName(_ label: String?) -> String? {
        guard let label else { return nil }
        var name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("-") { name.removeFirst() } // login-shell argv0 convention (`-zsh`)
        name = name.split(separator: "/").last.map(String.init) ?? name
        return name.isEmpty ? nil : name
    }

    /// A PROGRAM-SET pane title cleaned for the sidebar row: one leading agent-activity glyph (any
    /// braille spinner frame U+2800–U+28FF, or one of `·✢✳✶✻✽`, an optional variation selector, then
    /// whitespace/end) is stripped — the glyph is claude's activity channel, already spoken by the
    /// ring mark/badge — while any other leading symbol (`★ prod`) is user content and stays. Whitespace
    /// trimmed; empty → `nil` so the caller's chain falls through. The herdr `stripped_terminal_title`
    /// rule. Pure + static so the cleanup is unit-pinned.
    /// The canonical agent mark a normalized program title leads with — `✳` pinned to TEXT
    /// presentation (`\u{FE0E}`; bare U+2733 renders as emoji on Apple platforms).
    static let agentTitleMark = "✳\u{FE0E}"

    /// `title` led with the agent mark unless it already leads with one. The dedupe compares the
    /// first SCALAR against U+2733, never `hasPrefix("✳")`: the variation selector rides the ✳'s
    /// own grapheme cluster, so against the normalized `✳\u{FE0E}` lead that character-wise prefix
    /// check answered FALSE — and a fresh agent whose program title still carried its own glyph
    /// ("✳ Claude Code", no intent asserted yet) wore the mark TWICE on every surface that adds it.
    static func agentMarkedTitle(_ title: String) -> String {
        title.unicodeScalars.first == "✳" ? title : "\(agentTitleMark) \(title)"
    }

    static func normalizedProgramTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, let scalar = first.unicodeScalars.first,
           (0x2800...0x28FF).contains(scalar.value) || "·✢✳✶✻✽".unicodeScalars.contains(scalar)
        {
            let rest = text.dropFirst()
            if rest.isEmpty || rest.first?.isWhitespace == true {
                // NORMALIZE, don't drop: every frame of the agent's spinner family (braille frames,
                // the ✢✳✶✻✽· asterisk cycle) maps to the ONE static ✳ mark, so the mark shows
                // WITHOUT the title's text changing on every animation tick (the churn that made
                // rows flash and SwiftUI replace leaves — the reason this used to strip).
                let body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                text = body.isEmpty ? "" : "\(agentTitleMark) \(body)"
            }
        }
        return text.isEmpty ? nil : text
    }

    /// A finished command must have RUN at least this long (host-measured C→D wall clock) to title an
    /// idle pane — sub-second `ls`/`cd` chatter never takes the title, so the resting title doesn't
    /// churn with every trivial command. Mirrors the busy-dot reveal default (1 s,
    /// ``SettingsKey/tabBadgeBusyDelaySeconds``): a command that earns the dot earns the title.
    static let commandTitleMinDurationMS: UInt32 = 1000

    /// The idle shell's LAST-COMMAND title: the most recent finished block whose command ran long
    /// enough to matter (``commandTitleMinDurationMS``) — the pane's HISTORY identity ("the shell I
    /// just ran `make check` in"), REGARDLESS of exit (status is the badge's + tooltip's story; the
    /// title only says WHAT). Short/quick blocks are SKIPPED, not title-clearing — a `ls` after a
    /// long build leaves the build's title standing rather than flashing the row back to the
    /// generic "Terminal". A running block (no duration yet) never titles HERE — the live RUNNING
    /// rung of ``liveRowTitle`` reads it from the open block instead; `nil` when no block
    /// qualifies, so the caller keeps the kind-generic fallback. Pure + static so the rule is
    /// unit-pinned.
    static func lastCommandTitle(blocks: [CommandBlock]) -> String? {
        for block in blocks.reversed() {
            guard let duration = block.durationMS, duration >= commandTitleMinDurationMS
            else { continue }
            let command = block.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { return command }
        }
        return nil
    }

    // One flat rung list — a struct would only relabel the same nine inputs (the WindowSizeMath idiom).
    // swiftlint:disable function_parameter_count
    /// The live leaf's SHOWN title — ONE precedence rule shared by the macOS + iOS rows so the two
    /// can't drift: an explicit user RENAME always wins; an AGENT session then titles by its
    /// host-latched session INTENT (wire type 36 — the session's first prompt, the task identity)
    /// over the structural folder/process title every agent row shares ("claude" ×4 says nothing);
    /// a non-empty structural title reads next — EXCEPT that a bare foreground-PROGRAM title (the
    /// at-root running pane, whose structural rung titles by `processDisplayName`) upgrades in
    /// place to the full RUNNING command line when one is known ("sleep" → "sleep 30 && make",
    /// the same fact with the arguments back; a FOLDER title is an identity and never yields); an
    /// EMPTY structural title (the at-root idle shell) reads the running command, then the last
    /// executed command (``lastCommandTitle(blocks:)`` — exit-agnostic history), then the pane's
    /// cwd FOLDER NAME (`cwdTitle` — the basepath is still an identity, even when it restates the
    /// section header); only a pane with NO cwd yet reads the kind-generic fallback. The caller
    /// gates `runningCommand` on the busy-badge reveal, so the title upgrades with the spinner
    /// and a fast `ls` never flashes in. Wherever the RUNNING command would title the row, a FRESH
    /// `programTitle` (an OSC title the running program itself asserted —
    /// ``WorkspaceStore/liveProgramTitle(for:)`` + `normalizedProgramTitle`) out-ranks it: nvim's
    /// "main.swift - NVIM" says more than `vi .` (a program that sets no title keeps the command
    /// line; a FOLDER structural title is an identity and never yields). Pure + static so the
    /// chain is unit-pinned without a view.
    static func liveRowTitle(
        structuralTitle: String, userRenamed: Bool, isAgent: Bool, intent: String?,
        runningCommand: String?, programTitle: String? = nil, processTitle: String?,
        blocks: [CommandBlock], kind: PaneKind,
        cwdTitle: String? = nil,
        fallback: String,
    ) -> String {
        // A "rename" that equals the kind-generic fallback carries no identity — it can only be an
        // accidentally committed seed (the pre-guard inline field committed its unedited draft on
        // blur, freezing "Terminal" as a sticky rename in persisted specs). Yielding here heals
        // those panes without a migration; a rename to any REAL name still wins unconditionally.
        if userRenamed, !structuralTitle.isEmpty, structuralTitle != fallback { return structuralTitle }
        if isAgent, let intent = intent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !intent.isEmpty
        {
            return intent
        }
        let running = runningCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !structuralTitle.isEmpty {
            if kind == .terminal, let running, !running.isEmpty, structuralTitle == processTitle {
                return programTitle ?? running
            }
            return structuralTitle
        }
        guard kind == .terminal else { return fallback }
        if let running, !running.isEmpty { return programTitle ?? running }
        return lastCommandTitle(blocks: blocks) ?? cwdTitle ?? fallback
    }

    // swiftlint:enable function_parameter_count

    /// Bare interactive-shell basenames that must NOT title a pane — titling by the shell is no more
    /// informative than the generic default, so the row keeps the cwd/generic chain instead.
    private static let loginShellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "login",
    ]

    /// Agent-CLI basenames — a pane fronted by one of these is an AGENT session even before any status
    /// verdict lands. A small allow-set matched against the cleaned ``processDisplayName(_:)`` (basename,
    /// login-`-` stripped), never `contains`.
    static let agentProcessNames: Set<String> = [
        "claude", "codex", "gemini", "opencode", "aider", "goose", "amp",
    ]

    /// Whether a row is an AGENT session — the classification that holds the row's TALL two-line shell
    /// for the WHOLE session (the height rung changes only at session boundaries, never on a status
    /// edge, so a question/done/error arriving can never move layout). True when the pane carries ANY
    /// agent-status verdict (`.idle` included — an agent resting at its prompt is still a session) OR
    /// its foreground process is a known agent CLI (covers the pre-verdict window). Pure + static so the
    /// rung rule is unit-pinned.
    static func isAgentSession(status: ClaudeStatus, processLabel: String?) -> Bool {
        if status != .none { return true }
        guard let name = processDisplayName(processLabel)?.lowercased() else { return false }
        return agentProcessNames.contains(name)
    }

    /// Whether a row's finish badge is the AGENT's TURN ENDING rather than a plain command's clean
    /// exit. The resolver fuses both into one ``TabBadgeKind/completed``/``TabBadgeKind/finished``,
    /// so the badge alone cannot say which — this pairs it with the agent verdict: a live
    /// ``ClaudeStatus/done``, or the client's unread latch that outlives the host's own done→idle
    /// decay (`WorkspaceStore.paneUnseenDone`).
    ///
    /// ONE predicate for both consumers, deliberately: it gates the row's agent FINAL LINE (a plain
    /// command's exit must never surface a stale assistant line) AND which VOICE the finish speaks in
    /// (the agent's closes its ring in the mark column; a command's is the trailing slot's receipt).
    /// Sharing it means the row that shows the agent's last words is exactly the row that draws the
    /// closed ring. Pure + static so the rule is unit-pinned without a view.
    static func finishIsAgents(badge: TabBadgeKind?, status: ClaudeStatus, unseenDone: Bool) -> Bool {
        guard badge == .completed || badge == .finished else { return false }
        return status == .done || unseenDone
    }

    /// A finished command's OUTCOME — the two readings the trailing slot has (docs/DECISIONS.md
    /// round 24). Kept here beside ``finishIsAgents(badge:status:unseenDone:)`` rather than in the
    /// design system: which outcome a row has is a fact about its command blocks, and only the INK
    /// it reads in (``StatusPresentation/outcomeInk(_:)``) is a view decision.
    enum CommandOutcome: Equatable, Sendable {
        /// Exit 0 (or a completion the shell reported no code for).
        case succeeded
        /// A non-zero exit, or a held-red `OSC 9;4;2`.
        case failed
    }

    /// The trailing slot's RECEIPT for a finished command: the command's own name plus how it went.
    /// `nil` ⇒ the slot keeps its resting process label.
    struct CommandReceipt: Equatable, Sendable {
        /// What ran — `make`, `npm`, `./deploy.sh` (``slotCommandName(_:)``), or the pane's
        /// foreground process when no block can name it.
        let name: String
        let outcome: CommandOutcome
    }

    /// The row's outcome receipt — what the trailing slot prints once a command has finished.
    ///
    /// The NAME comes from the command's own block: the attributed FAILURE for a red receipt (the
    /// caller gates it, see ``failedBlock(for:badge:store:)`` — a live progress error must not be
    /// pinned on an older, unrelated command), the newest CLOSED block for a clean one. A row whose
    /// blocks cannot name it (no OSC-133 segmentation, or an `OSC 9;4;2` error raised inside a
    /// still-open block) falls back to the foreground process, so the outcome is never mute — and if
    /// even that is unknown there is no receipt, because a nameless "something finished" is what the
    /// disc used to say and is exactly what round 24 dropped.
    ///
    /// Pure + static so the whole reading is unit-pinned without a view or a store.
    static func commandReceipt(
        badge: TabBadgeKind?, agentFinish: Bool, blocks: [CommandBlock],
        failedBlock: CommandBlock?, processLabel: String?,
    ) -> CommandReceipt? {
        guard let outcome = commandOutcome(badge: badge, agentFinish: agentFinish) else { return nil }
        let text = outcome == .failed
            ? failedBlock?.commandText
            : blocks.last(where: { $0.complete || $0.durationMS != nil })?.commandText
        guard let name = slotCommandName(text) ?? slotProcessName(processLabel) else { return nil }
        return CommandReceipt(name: name, outcome: outcome)
    }

    /// The failure a row's `.error` badge may be BLAMED on — the newest closed failed block, or
    /// `nil` when the badge cannot be attributed to one.
    ///
    /// ⚠️ The gate is the badge's SOURCE, not just its tier: `.error` is reachable from a finished
    /// `.failure` completion OR a LIVE `OSC 9;4;2` progress error, and in the live case the alarming
    /// command's block is still OPEN (never `isFailed`), so the newest closed failure would be an
    /// OLDER, unrelated command. Only a `.failure` completion may name a block; a progress error
    /// stays anonymous (the receipt falls back to the foreground process, the tooltip to silence).
    @MainActor
    static func failedBlock(for id: PaneID, badge: TabBadgeKind?, store: WorkspaceStore) -> CommandBlock? {
        guard badge == .error, store.panePendingCompletion[id] == .failure else { return nil }
        return store.commandBlocks(for: id).last(where: \.isFailed)
    }

    /// Whether a badge is a COMMAND's outcome, and which one. The finish tiers fuse both speakers,
    /// so `agentFinish` decides: the agent's turn ending is the mark column's check, a command's exit
    /// is the slot's. `.error` is always a command's — `ClaudeStatus` has no error case. Pure +
    /// static; ``StatusPresentation/commandOutcome(badge:agentFinish:)`` is the view-side alias so
    /// the mark resolver and this one read the same rule.
    static func commandOutcome(badge: TabBadgeKind?, agentFinish: Bool) -> CommandOutcome? {
        switch badge {
        case .error: .failed
        case .completed,
             .finished: agentFinish ? nil : .succeeded
        case .awaitingInput,
             .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo,
             nil: nil
        }
    }

    /// The command's NAME as the slot prints it: the first REAL word of the command line, basenamed
    /// (`/usr/bin/make -j8` → `make`). A leading `sudo` and leading `KEY=value` env assignments are
    /// skipped — neither is what ran, and `sudo` in the slot would also restate the privilege badge
    /// two glyphs away. The ARGUMENTS stay off: the slot is one narrow column beside a title that
    /// must truncate last, and the full line is one hover away in the tooltip. `nil` for a blank
    /// line. Pure + static so the trimming is unit-pinned.
    static func slotCommandName(_ commandText: String?) -> String? {
        guard let commandText else { return nil }
        for token in commandText.split(whereSeparator: \.isWhitespace) {
            if token.contains("=") { continue } // `FOO=bar make` — the assignment is not the command
            if token == "sudo" { continue }
            return slotProcessName(String(token))
        }
        return nil
    }

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
    /// Section ORDER is ALPHABETICAL by header and STABLE with it (``TabOrderingEngine/sectionPrecedes(_:_:)``):
    /// a section's slot is a fact about its NAME, so it never jumps when you switch tabs or open a new one.
    /// WITHIN each section rows follow `tabOrder` (``WorkspaceStore/flatOrderedTabIDs()`` — creation order)
    /// then pane pre-order. The keyless "Other" bucket (video / cwd-less panes) sorts LAST. Query filter
    /// composes first; an all-filtered section is DROPPED. Pure + static so the per-pane grouping rule is
    /// unit-pinned without a SwiftUI view.
    ///
    /// Sorting happens in the bucketing rather than here, so the close rule's tab-level reading
    /// (``TabOrderingEngine/projectGroupedTabOrder(_:projectKey:)``) moves with it — "the neighbouring tab"
    /// has to mean adjacent on SCREEN. The one thing it cannot see is
    /// ``headerDisambiguated(_:)`` below, which runs after: a parent-qualified header (`feature-a/myapp`)
    /// sorts under its BASENAME (`myapp`), with the parent segment breaking the tie — colliding worktrees
    /// stay adjacent instead of scattering to wherever their parent folders happen to fall in the alphabet.
    ///
    /// The bucketing is ``TabOrderingEngine/bucketedByProject(_:projectKey:)`` — the SAME code the close
    /// rule reads at tab granularity, so focus after a close can only land where this drew something.
    static func sectionedByProject(_ rows: [RailRow], tabOrder: [TabID], query: String) -> [RailRowGroup] {
        let survivors = filtered(rows, query: query)
        let sections = TabOrderingEngine.bucketedByProject(survivors, projectKey: \.projectKey)
        // Order rows WITHIN each section by the tab order, pane pre-order as the stable tiebreak.
        // A row whose tab isn't in `tabOrder` (shouldn't happen) sorts last, stably.
        let rank = Dictionary(tabOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let groups = sections.map { section in
            let sorted = section.elements.enumerated()
                .sorted { lhs, rhs in
                    let lRank = rank[lhs.element.tabID] ?? Int.max
                    let rRank = rank[rhs.element.tabID] ?? Int.max
                    if lRank != rRank { return lRank < rRank }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            return RailRowGroup(
                header: TabOrderingEngine.projectSectionHeader(for: section.key),
                projectKey: section.key,
                rows: sorted,
            )
        }
        return headerDisambiguated(groups)
    }

    /// For any two sections whose basename HEADER collides (same-named worktrees — `/w/feature-a/myapp`
    /// vs `/w/feature-b/myapp` are two distinct keys, two sections, one basename), parent-qualify each
    /// colliding header from its KEY (`feature-a/myapp`). The header is the place identity (a row at
    /// its project root no longer repeats the folder name), so the worktree-distinctiveness break
    /// lives HERE, not on row titles. Pure + static so the rule is unit-pinned.
    static func headerDisambiguated(_ groups: [RailRowGroup]) -> [RailRowGroup] {
        var counts: [String: Int] = [:]
        for group in groups {
            if let header = group.header { counts[header, default: 0] += 1 }
        }
        return groups.map { group in
            guard let header = group.header, (counts[header] ?? 0) > 1,
                  let qualified = parentQualifiedTitle(cwd: group.projectKey, title: header)
            else { return group }
            return RailRowGroup(header: qualified, projectKey: group.projectKey, rows: group.rows)
        }
    }
}

/// One rendered sidebar section: an optional `header` (the group title), the section's NORMALIZED
/// By-Project key (`nil` ⇒ the "Other" bucket — the ``WorkspaceStore/projectGitSummary`` lookup key
/// for the header's git line), and the rows in render order. A pure value (`Equatable`) so
/// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` is pinnable headlessly; the navigator
/// wraps it in an `Identifiable` row for `ForEach`.
struct RailRowGroup: Equatable {
    let header: String?
    let projectKey: String?
    let rows: [RailRow]
}
