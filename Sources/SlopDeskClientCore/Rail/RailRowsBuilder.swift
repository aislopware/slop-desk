// RailRowsBuilder — the pure mapping from the live WorkspaceStore tree → the rail's `[RailRow]` (V1
// "Panes" granularity: one row per visible pane of the active session's tabs). Kept pure + static so
// SlopDeskClientUITests can pin the mapping (selection, title/subtitle, agent status) without a view.

import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The data a single rail row binds to (derived from a pane within the active session's tabs). A pure value
/// type — kept with the builder logic rather than a view, since it carries no view/design-system coupling.
/// The native rail in L1+ rebuilds the row VIEW over this same model.
package struct RailRow: Identifiable, Equatable {
    package let id: PaneID
    package let tabID: TabID
    package let kind: PaneKind
    package let title: String
    /// The row's muted second line (the navigator row's subtitle). A terminal shows its cwd RELATIVE to
    /// its section's project key — and ONLY when it strayed from the project root (the git line moved
    /// up to the section header, and repeating the section's own path on every row is noise); a video
    /// pane keeps its kind-generic
    /// ``PaneLabel/railSubtitle(kind:title:video:cwd:liveTitle:projectKey:)``
    /// (host-app/window label). `nil` ⇒ a
    /// single-line row (the common at-root pane).
    package let subtitle: String?
    package let status: ClaudeStatus
    /// The 1-based CREATION-order tab number — split-tab panes share the same `#N` (it is a TAB
    /// number, not a pane number). NOT the ⌘1…⌘9 coordinate: the digits count PANES in the drawn
    /// order (``WorkspaceStore/displayOrderedPaneIDs()``), which diverges from creation order the
    /// moment sections regroup tabs.
    package let tabNumber: Int
    /// The single fused status badge for the row (``TabBadgeResolver``), or `nil` when all-clear.
    package let badge: TabBadgeKind?
    /// The coarse host-reported foreground-process name (wire type 26), shown trailing on the active row; `nil`
    /// when the host has not reported one.
    package let processLabel: String?
    /// Whether this pane's input gate is READ-ONLY — read from the store's convergent
    /// ``WorkspaceStore/paneReadOnly`` set so the sidebar lock indicator and the pane's `🔒 READ ONLY ×` pill
    /// share one source of truth. Drives the navigator row's trailing lock glyph.
    package let readOnly: Bool
    /// The pane's raw working directory (`pane/cwd`) — `nil` for a video pane. NOT rendered as chrome: it is the row's TOOLTIP (`.help`) text AND a hidden search key so
    /// an at-root row (whose visible subtitle is absent) stays searchable BY PATH and two same-named
    /// worktrees are told apart by their full cwd.
    package let cwd: String?
    /// Whether this row is in inline-RENAME mode: the store's ``WorkspaceStore/pendingTabRename``
    /// names this row's tab AND this pane is that tab's representative (active) pane — so exactly one row per
    /// pending tab opens its rename field. Consumed by the navigator row to swap the title for a field.
    package let isEditing: Bool
    /// Selected = the row's tab is active AND this pane is the tab's active pane.
    package let isSelected: Bool
    /// The pane's OWN By-Project key (``WorkspaceStore/paneProjectKey(_:)`` — the HOST-pushed
    /// `pane/projectKey` else cwd, plugin-dirs guarded out), carried per-ROW so
    /// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` buckets each pane by ITS project, not its
    /// tab's active-pane project. This is what makes a SPLIT tab's two panes land in their respective
    /// project sections AND stops the section header from flickering with focus. `nil` for a keyless /
    /// video pane (⇒ the "Other" bucket). Defaulted so the Equatable pins / completion-title call sites
    /// stay source-compatible.
    package var projectKey: String?

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
    package var leafIdentity: String {
        "\(id.raw.uuidString)|\(kind.rawValue)|\(cwd ?? "")"
    }

    /// A copy of this row with a new `title` (collision disambiguation) — every other field is
    /// carried verbatim. Kept here so ``RailRowsBuilder/disambiguated(_:)`` need not restate the memberwise init.
    package func retitled(_ newTitle: String) -> Self {
        Self(
            id: id, tabID: tabID, kind: kind, title: newTitle, subtitle: subtitle, status: status,
            tabNumber: tabNumber, badge: badge, processLabel: processLabel, readOnly: readOnly, cwd: cwd,
            isEditing: isEditing, isSelected: isSelected, projectKey: projectKey,
        )
    }
}

package enum RailRowsBuilder {
    /// Build the rail rows for the active session. One row per pane of each tab,
    /// in tab order then pre-order pane order. `selected` = the tab is active AND the pane is that tab's
    /// active pane. Agent status comes from the store's per-pane mirror (`.none` ⇒ plain terminal).
    ///
    /// EVERY kind is a row again (the full-desktop pivot): the retired right rail was the video
    /// panes' tracker; with it gone the navigator is the one sidebar, so desktop/window panes list
    /// here like any pane (their `chrome` resolution stays kind-aware — no git/process line).
    @MainActor
    package static func rows(for store: WorkspaceStore) -> [RailRow] {
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
    package struct RailRowChrome: Equatable {
        package let status: ClaudeStatus
        package let badge: TabBadgeKind?
        package let processLabel: String?
        package let subtitle: String?
        package let readOnly: Bool
        package let isEditing: Bool
        /// The host's blocking prompt (``WorkspaceStore/agentLabel(for:)``), non-nil ONLY while `status ==
        /// .needsPermission` AND the store has a non-empty label for this pane — kept OUT of ``subtitle``
        /// (and therefore out of the memoized, structural ``RailRow``) so a blocked row's search corpus never
        /// bakes in a stale question and a mid-block structural rebuild can never freeze one in. The row VIEW
        /// swaps its line-2 text to this over `subtitle` while non-nil; `subtitle`/`gitSummary` keep resolving
        /// as if the row were never blocked.
        package let question: String?
    }

    /// Resolve one pane's volatile chrome — the SINGLE resolution rule behind both ``rows(for:)`` (the full
    /// model build) and ``liveChrome(for:store:)`` (the per-row view's fresh read), so the two can't drift.
    ///
    /// Line 2 (``PaneSpec/railSubtitle(cwd:liveTitle:projectKey:)``): a terminal shows its cwd RELATIVE to its
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
    package static func chrome(
        paneID: PaneID, kind: PaneKind, spec: PaneSpec?, tabID: TabID,
        representativePane: PaneID?, manualBadge: TabBadgeKind?, store: WorkspaceStore,
        commandGates: CommandBadgeGates? = nil,
    ) -> RailRowChrome {
        // The host's coarse foreground-process name (wire type 26): the trailing row label, a
        // badge-resolver input, AND the pane-title fallback when the cwd is not known yet.
        let processLabel = store.paneForegroundProcess[paneID]
        // The rail DRAWS section headers, so it hands the key over and gets the shortened line.
        let subtitle = spec?.railSubtitle(
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
            // Read here for a single row, and ONCE for a whole list — see `liveChrome(for:store:)`
            // below, which is what a rail render calls. This is a global with no per-pane override,
            // so the two spellings cannot disagree; what differs is how often it is asked.
            commandGates: commandGates ?? store.commandBadgeGates,
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

    /// The row VIEW's entry: resolve `row`'s CURRENT volatile chrome from the live store (the cached
    /// ``RailRow`` a memoized sidebar carries is stale by design for these fields). Re-derives the tab's
    /// representative pane + manual badge override from the store, then delegates to ``chrome(...)``.
    @MainActor
    package static func liveChrome(for row: RailRow, store: WorkspaceStore) -> RailRowChrome {
        let session = store.tree.activeSession
        let tab = session?.tabs.first { $0.id == row.tabID }
        let representativePane = tab.flatMap { $0.activePane ?? $0.allPaneIDs().first }
        return chrome(
            paneID: row.id, kind: row.kind, spec: session?.specs[row.id], tabID: row.tabID,
            representativePane: representativePane,
            manualBadge: store.tabBadgeOverride(for: row.tabID), store: store,
        )
    }

    /// Every row's live chrome in ONE pass — what a rail render calls, instead of the single-row entry
    /// per row.
    ///
    /// Three things above are per-RENDER, not per-row, and asking for them per row is what this
    /// deletes. The command-badge gates are three `UserDefaults` reads behind a computed property with
    /// no per-pane override, so a list re-read the same three globals once per row; the agent gates
    /// are three more whenever the pane has no override, which is the ordinary case. Measured,
    /// `swiftc -O`, two runs agreeing inside 0.3%: one `UserDefaults` bool read is **305 ns**, the six
    /// a row asks for are **1.85 µs**, and a 24-row rail render spent **44.5 µs** re-reading two
    /// settings that cannot change while it draws. The active session and its tab list are the third —
    /// resolved once here rather than walked per row.
    ///
    /// The answer is positional: `result[i]` is `rows[i]`'s. A caller that only wants the badges maps
    /// `\.badge` over it, which is what both sidebar headers do.
    @MainActor
    package static func liveChrome(for rows: [RailRow], store: WorkspaceStore) -> [RailRowChrome] {
        guard !rows.isEmpty else { return [] }
        let session = store.tree.activeSession
        let commandGates = store.commandBadgeGates
        // A split tab contributes several rows and they all resolve the SAME representative pane, so
        // the tab walk is per tab rather than per row.
        var representative: [TabID: PaneID] = [:]
        for tab in session?.tabs ?? [] {
            // A tab with no pane at all is ABSENT rather than present-and-nil, which is the same
            // answer the single-row entry gives and keeps the lookup one optional deep.
            guard let pane = tab.activePane ?? tab.allPaneIDs().first else { continue }
            representative[tab.id] = pane
        }
        return rows.map { row in
            let pane = representative[row.tabID]
            return chrome(
                paneID: row.id, kind: row.kind, spec: session?.specs[row.id], tabID: row.tabID,
                representativePane: pane,
                manualBadge: store.tabBadgeOverride(for: row.tabID), store: store,
                commandGates: commandGates,
            )
        }
    }

    /// The title a row SHOWS right now — the whole live chain (rename → agent intent → structural →
    /// running command → last executed command → generic) resolved off the store in one call.
    ///
    /// Two surfaces render the same panes and must never disagree about what one is called: the
    /// sidebar's rows and the collapsed-sidebar TAB STRIP. The sidebar leaf keeps computing the
    /// intermediates it also needs for its tooltip; this is the same resolution for a caller that
    /// wants only the string.
    @MainActor
    package static func liveTitle(
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
    /// with a unique title, no cwd, or no parent are returned unchanged.
    /// `slopdesk_workspace::rail_list::disambiguated_label` — the SAME rule
    /// ``headerDisambiguated(_:)`` runs on the section headers.
    package static func disambiguated(_ rows: [RailRow]) -> [RailRow] {
        let qualified = disambiguatedLabels(rows.map { (text: $0.title, source: $0.cwd) })
        return rows.enumerated().map { index, row in
            let name = qualified[index]
            guard !name.isEmpty else { return row }
            return row.retitled(name)
        }
    }

    /// What every item should be CALLED once identical labels have been told apart, in list order,
    /// with an empty string for one to leave alone — the ONE collision rule, marshalled ONCE.
    ///
    /// A collision is a fact about the list rather than about one member, so the whole list has to
    /// cross to answer for any of it. This used to ask per index, which meant rebuilding the label
    /// array and every title's bytes `n` times per rail rebuild to answer `n` questions off one
    /// input — quadratic in marshalling on a list that is rebuilt whenever anything in it ticks.
    private static func disambiguatedLabels(
        _ items: [(text: String, source: String?)],
    ) -> [String] {
        var strings = WsStrings()
        var labels = items.map {
            SlopDeskWsRailLabel(text: strings.span($0.text), source: strings.span($0.source))
        }
        var blob = strings.bytes
        // The retry lives INSIDE the pointer scope: the two buffers are borrowed for exactly the
        // calls that read them, and asking again after the scope closed would hand the door a
        // pointer whose lifetime had already ended.
        let delivered: [UInt8] = blob.withUnsafeMutableBufferPointer { text in
            labels.withUnsafeMutableBufferPointer { held in
                // The two borrows are read out as plain values first: a closure that captured the
                // buffer bindings themselves would be capturing `inout` parameters, which Swift
                // refuses even where the closure never outlives the scope.
                let (rows, rowCount) = (held.baseAddress, held.count)
                let (bytes, byteCount) = (text.baseAddress, text.count)
                let door = { (out: UnsafeMutablePointer<UInt8>?, cap: Int) -> Int in
                    slopdesk_ws_rail_disambiguated_labels(rows, rowCount, bytes, byteCount, out, cap)
                }
                // Four bytes of prefix per answer, and most answers are empty — a list that fits is
                // the common case, and one that does not says how much it needs.
                var out = [UInt8](repeating: 0, count: items.count * 32)
                var written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
                guard written > 0 else { return [] }
                if written > out.count {
                    out = [UInt8](repeating: 0, count: written)
                    written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
                    guard written > 0, written <= out.count else { return [] }
                }
                return Array(out.prefix(written))
            }
        }
        return wsRuns(delivered, count: items.count)
    }

    /// The row's LINE-1 STRUCTURAL title — the identity a pane keeps between events.
    /// `slopdesk_workspace::rail_title::row_title`, which is where the precedence (rename, at-root
    /// program, folder name, process, generic) is decided and documented.
    ///
    /// The marshalling itself is ``PaneLabel/rowTitle(kind:specTitle:userRenamed:cwd:liveTitle:processLabel:projectKey:)``,
    /// beside the subtitle's, because the rail is not the only surface that names a pane — the
    /// Open-Quickly picker asks the same question of the same panes.
    ///
    /// The empty answer is REAL here and the door says so: an at-root idle shell yields "" on
    /// purpose, so the live chain below can speak for it. `nil` from the marshaller is that empty
    /// title, not a missing one.
    ///
    /// - Parameter processLabel: the pane's host-reported foreground process
    ///   (``WorkspaceStore/paneForegroundProcess``). Optional so the completion-title / test call
    ///   sites that do not thread the store's process map still resolve the cwd/rename precedence.
    /// - Parameter projectKey: the pane's By-Project section key (``WorkspaceStore/paneProjectKey(_:)``) —
    ///   supplied by the SIDEBAR builder only, where a section header already names the project. The
    ///   titlebar/window call sites omit it (no header there — the folder name stays the right title).
    package static func rowTitle(
        kind: PaneKind, spec: PaneSpec?, cwd: String? = nil, liveTitle: String? = nil,
        processLabel: String? = nil, projectKey: String? = nil,
    ) -> String {
        PaneLabel.rowTitle(
            kind: kind, specTitle: spec.map(\.title), userRenamed: spec?.userRenamed == true,
            cwd: cwd, liveTitle: liveTitle, processLabel: processLabel, projectKey: projectKey,
        )
    }

    /// The host foreground-process name (wire type 26) as a pane-TITLE fallback, or `nil` to skip
    /// that rung — a bare interactive shell is suppressed, a real program titles the pane.
    /// `slopdesk_workspace::rail_title::process_display_name`.
    package static func processDisplayName(_ label: String?) -> String? {
        withOptionalText(label) { bytes, len, present in
            wsAnswer { out, cap in slopdesk_ws_process_display_name(bytes, len, present, out, cap) }
        }
    }

    /// The trailing-SLOT label for a row (`SlateTabRow/processLabel`): the same basename cleanup with
    /// a bare shell KEPT — "zsh" says nothing as a pane title, yet in the metadata slot it answers
    /// "what is this pane running". `slopdesk_workspace::rail_title::slot_process_name`.
    package static func slotProcessName(_ label: String?) -> String? {
        withOptionalText(label) { bytes, len, present in
            wsAnswer { out, cap in slopdesk_ws_slot_process_name(bytes, len, present, out, cap) }
        }
    }

    /// Whether a resting slot label names a COMMAND (`make`, `vim`, `npm`) rather than the shell that
    /// pane is idling in (`zsh`) — the split that decides which register the slot sets it in
    /// (``StatusPresentation/slotNameInk(isCommand:)``, ``StatusPresentation/slotNameWeight``).
    /// `slopdesk_workspace::rail_title::slot_label_is_command`.
    package static func slotLabelIsCommand(_ label: String?) -> Bool {
        withOptionalText(label) { bytes, len, present in
            slopdesk_ws_slot_label_is_command(bytes, len, present)
        }
    }

    /// The canonical agent mark a normalized program title leads with — `✳` pinned to TEXT
    /// presentation (bare U+2733 renders as emoji on Apple platforms).
    ///
    /// ASKED for rather than transcribed: a copy pinned to a different presentation would draw a
    /// different glyph beside the same rows the crate marked.
    package static let agentTitleMark: String = wsAnswer { out, cap in
        slopdesk_ws_agent_title_mark(out, cap)
    } ?? "✳\u{FE0E}"

    /// `title` led with the agent mark unless it already leads with one.
    /// `slopdesk_workspace::rail_title::agent_marked_title`.
    package static func agentMarkedTitle(_ title: String) -> String {
        var title = title
        return title.withUTF8 { bytes in
            wsAnswer { out, cap in
                slopdesk_ws_agent_marked_title(bytes.baseAddress, bytes.count, out, cap)
            }
        } ?? title
    }

    /// A PROGRAM-SET pane title cleaned for the sidebar row: every frame of the agent's activity
    /// spinner folded onto the ONE static mark, any other leading symbol left as user content.
    /// `slopdesk_workspace::rail_title::normalized_program_title`.
    package static func normalizedProgramTitle(_ title: String?) -> String? {
        withOptionalText(title) { bytes, len, present in
            wsAnswer { out, cap in
                slopdesk_ws_normalized_program_title(bytes, len, present, out, cap)
            }
        }
    }

    /// A finished command must have RUN at least this long (host-measured C→D wall clock) to title an
    /// idle pane. Mirrors the busy-dot reveal default (1 s, ``SettingsKey/tabBadgeBusyDelaySecondsValue``):
    /// a command that earns the dot earns the title. From the crate that enforces it.
    package static let commandTitleMinDurationMS: UInt32 = slopdesk_ws_command_title_min_duration_ms()

    /// The idle shell's LAST-COMMAND title: the most recent finished block whose command ran long
    /// enough to matter, regardless of exit. `slopdesk_workspace::rail_title::last_command_title`.
    package static func lastCommandTitle(blocks: [CommandBlock]) -> String? {
        var strings = WsStrings()
        var records = blocks.map {
            SlopDeskWsCommandTitleBlock(
                text: strings.span($0.commandText),
                has_duration: $0.durationMS != nil,
                duration_ms: $0.durationMS ?? 0,
            )
        }
        var blob = strings.bytes
        return blob.withUnsafeMutableBufferPointer { text in
            records.withUnsafeMutableBufferPointer { held in
                wsAnswer { out, cap in
                    slopdesk_ws_last_command_title(
                        held.baseAddress, held.count, text.baseAddress, text.count, out, cap,
                    )
                }
            }
        }
    }

    // One flat rung list — a struct would only relabel the same nine inputs (the WindowSizeMath idiom).
    // swiftlint:disable function_parameter_count
    /// The live leaf's SHOWN title — ONE precedence rule shared by the macOS + iOS rows so the two
    /// can't drift. `slopdesk_workspace::rail_title::live_row_title`, which is where the chain
    /// (rename, agent intent, structural title, running command, program title, command history, cwd,
    /// generic) is decided and documented.
    ///
    /// The caller gates `runningCommand` on the busy-badge reveal, so the title upgrades with the
    /// spinner and a fast `ls` never flashes in — that gate is a VIEW's, which is why it stays here.
    package static func liveRowTitle(
        structuralTitle: String, userRenamed: Bool, isAgent: Bool, intent: String?,
        runningCommand: String?, programTitle: String? = nil, processTitle: String?,
        blocks: [CommandBlock], kind: PaneKind,
        cwdTitle: String? = nil,
        fallback: String,
    ) -> String {
        var strings = WsStrings()
        let inputs = SlopDeskWsLiveRowTitle(
            structural_title: strings.span(structuralTitle),
            user_renamed: userRenamed,
            is_agent: isAgent,
            intent: strings.span(intent),
            running_command: strings.span(runningCommand),
            program_title: strings.span(programTitle),
            process_title: strings.span(processTitle),
            kind: kind.ffiByte,
            cwd_title: strings.span(cwdTitle),
            fallback: strings.span(fallback),
        )
        var records = blocks.map {
            SlopDeskWsCommandTitleBlock(
                text: strings.span($0.commandText),
                has_duration: $0.durationMS != nil,
                duration_ms: $0.durationMS ?? 0,
            )
        }
        var blob = strings.bytes
        return blob.withUnsafeMutableBufferPointer { text in
            records.withUnsafeMutableBufferPointer { held in
                wsAnswer { out, cap in
                    slopdesk_ws_live_row_title(
                        inputs, held.baseAddress, held.count, text.baseAddress, text.count, out, cap,
                    )
                }
            }
        } ?? ""
    }

    // swiftlint:enable function_parameter_count

    /// Whether a row is an AGENT session — the classification that holds the row's TALL two-line shell
    /// for the WHOLE session (the height rung changes only at session boundaries, never on a status
    /// edge, so a question/done/error arriving can never move layout).
    /// `slopdesk_workspace::rail_title::is_agent_session`.
    package static func isAgentSession(status: ClaudeStatus, processLabel: String?) -> Bool {
        withOptionalText(processLabel) { bytes, len, present in
            slopdesk_ws_is_agent_session(status != .none, bytes, len, present)
        }
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
    package static func finishIsAgents(badge: TabBadgeKind?, status: ClaudeStatus, unseenDone: Bool) -> Bool {
        guard badge == .completed || badge == .finished else { return false }
        return status == .done || unseenDone
    }

    /// The trailing slot's RECEIPT for a finished command: the command's own name plus how it went.
    /// `nil` ⇒ the slot keeps its resting process label.
    package struct CommandReceipt: Equatable, Sendable {
        /// What ran — `make`, `npm`, `./deploy.sh` (``slotCommandName(_:)``), or the pane's
        /// foreground process when no block can name it.
        package let name: String
        package let outcome: CommandOutcome
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
    package static func commandReceipt(
        badge: TabBadgeKind?, agentFinish: Bool, blocks: [CommandBlock],
        failedBlock: CommandBlock?, processLabel: String?,
    ) -> CommandReceipt? {
        guard let outcome = TabBadgeReading.commandOutcome(badge: badge, agentFinish: agentFinish)
        else { return nil }
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
    package static func failedBlock(for id: PaneID, badge: TabBadgeKind?, store: WorkspaceStore) -> CommandBlock? {
        guard badge == .error, store.panePendingCompletion[id] == .failure else { return nil }
        return store.commandBlocks(for: id).last(where: \.isFailed)
    }

    // ``CommandOutcome`` and the badge → outcome rule are ``TabBadgeReading/commandOutcome(badge:agentFinish:)``
    // (`SlopDeskWorkspaceModel`). They left because `SlopDeskSlate` reads them and this builder is
    // welded to the store (``failedBlock(for:badge:store:)`` takes a `WorkspaceStore`), so the design
    // floor could not reach one without naming the other. What stays here is everything that needs a
    // BLOCK: the receipt above, and the name below.

    /// The command's NAME as the slot prints it: the first REAL word of the command line, basenamed
    /// (`/usr/bin/make -j8` → `make`). A leading `sudo` and leading `KEY=value` env assignments are
    /// skipped — neither is what ran, and `sudo` in the slot would also restate the privilege badge
    /// two glyphs away. The ARGUMENTS stay off: the slot is one narrow column beside a title that
    /// must truncate last, and the full line is one hover away in the tooltip. `nil` for a blank
    /// line. Pure + static so the trimming is unit-pinned.
    package static func slotCommandName(_ commandText: String?) -> String? {
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
    package static func cwdFolderName(_ cwd: String?) -> String? {
        PaneSpec.cwdDisplayName(cwd)
    }

    /// Filter rows by a search query (a blank one ⇒ all). Matches the visible title + subtitle AND
    /// the hidden keys — the raw `cwd` (a git-repo row's visible subtitle is the git line, not the
    /// path, so without this it would be unsearchable by path) and the foreground `processLabel`.
    /// `slopdesk_workspace::rail_list::row_matches`, which is where the corpus and the case fold live.
    package static func filtered(_ rows: [RailRow], query: String) -> [RailRow] {
        var needle = Array(query.utf8)
        return needle.withUnsafeMutableBufferPointer { q in
            rows.filter { row in
                var strings = WsStrings()
                let fields = SlopDeskWsRailRowFields(
                    title: strings.span(row.title),
                    subtitle: strings.span(row.subtitle),
                    cwd: strings.span(row.cwd),
                    process_label: strings.span(row.processLabel),
                )
                var blob = strings.bytes
                return blob.withUnsafeMutableBufferPointer { text in
                    slopdesk_ws_rail_row_matches(
                        fields, text.baseAddress, text.count, q.baseAddress, q.count,
                    )
                }
            }
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
    /// The bucketing is `slopdesk_workspace::rail_list::plan` — the SAME rule
    /// ``TabOrderingEngine/bucketedByProject(_:projectKey:)`` runs at tab granularity for the close
    /// rule, so focus after a close can only land where this drew something. One call answers both
    /// the section split and the within-section order: rows follow `tabOrder`, ties broken by pane
    /// pre-order, and a row whose tab is absent from `tabOrder` sorts last without vanishing.
    package static func sectionedByProject(_ rows: [RailRow], tabOrder: [TabID], query: String) -> [RailRowGroup] {
        let survivors = filtered(rows, query: query)
        let rank = Dictionary(tabOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var sections: [(key: String?, rows: [RailRow])] = []
        for place in wsRailPlan(
            keys: survivors.map(\.projectKey),
            tabRanks: survivors.map { rank[$0.tabID] ?? Int.max },
        ) {
            guard survivors.indices.contains(place.element) else { continue }
            let row = survivors[place.element]
            if place.section == sections.count - 1 {
                sections[place.section].rows.append(row)
            } else {
                sections.append((TabOrderingEngine.normalizedProjectKey(row.projectKey), [row]))
            }
        }
        return headerDisambiguated(sections.map {
            RailRowGroup(
                header: TabOrderingEngine.projectSectionHeader(for: $0.key),
                projectKey: $0.key,
                rows: $0.rows,
            )
        })
    }

    /// For any two sections whose basename HEADER collides (same-named worktrees — `/w/feature-a/myapp`
    /// vs `/w/feature-b/myapp` are two distinct keys, two sections, one basename), parent-qualify each
    /// colliding header from its KEY (`feature-a/myapp`). The header is the place identity (a row at
    /// its project root no longer repeats the folder name), so the worktree-distinctiveness break
    /// lives HERE, not on row titles — and it is ``disambiguated(_:)``'s rule applied to a different
    /// pair of fields, which is why both reach the one crate function.
    package static func headerDisambiguated(_ groups: [RailRowGroup]) -> [RailRowGroup] {
        let qualified = disambiguatedLabels(groups.map { (text: $0.header ?? "", source: $0.projectKey) })
        return groups.enumerated().map { index, group in
            guard group.header != nil, !qualified[index].isEmpty
            else { return group }
            return RailRowGroup(header: qualified[index], projectKey: group.projectKey, rows: group.rows)
        }
    }
}

/// One rendered sidebar section: an optional `header` (the group title), the section's NORMALIZED
/// By-Project key (`nil` ⇒ the "Other" bucket — the ``WorkspaceStore/projectGitSummary`` lookup key
/// for the header's git line), and the rows in render order. A pure value (`Equatable`) so
/// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` is pinnable headlessly; the navigator
/// wraps it in an `Identifiable` row for `ForEach`.
package struct RailRowGroup: Equatable {
    package let header: String?
    package let projectKey: String?
    package let rows: [RailRow]
}
