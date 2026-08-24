// SidebarRowReading — the near-side FACE of `slopdesk_workspace::sidebar_row`, plus the store walk
// that gathers one navigator row.
//
// Three surfaces render the same pane and may never disagree about it: the Mac's AppKit navigator
// (``SlopDeskMacUI/MacSidebarRowView``), the phone's SwiftUI list row, and — for the title alone —
// the collapsed-sidebar tab strip (which reads ``RailRowsBuilder/liveTitle(for:chrome:store:fallback:)``,
// the same chain this file's `title` comes off).
//
// It is a RESOLUTION, not a layout. Everything here is an answer the store already holds, gathered:
// which title wins, whose finish this is, whether the trailing slot prints a process name or a
// command's receipt, what the hover tooltip says. The two row bodies that used to gather it each
// spelled the whole chain out — twelve store reads, four resolvers and one badge-vs-status subtlety
// apiece — inside a `@ViewBuilder`, in one file, twice. That is precisely the shape that survives a
// framework split by breaking: the Mac's row is an `NSView` now and cannot see a SwiftUI leaf's call
// site at all.
//
// The GATHERING stays here — it is a `@MainActor` walk over live workspace state. What crossed is
// every rule over the gathered facts: the ink/weight ladder, the spoken state, the hover's two cuts,
// the last-command line, and the context menu's verb table.
//
// ⚠️ THE ONE SUBTLETY, stated once so neither half has to re-derive it: the WORKING reading is keyed
// on the raw ``ClaudeStatus`` and NOT on the fused badge. "Badge While Processing" (default OFF)
// masks `.working` out of the badge resolver, so a row that read the badge here would draw a
// thinking agent exactly like an idle shell on every default install. The toggle governs the badge
// GLYPH; the working reading is the row's own affordance.

import CSlopDeskFFI
import Defaults
import SlopDeskAgentDetect
import SlopDeskInspector // PendingToolSummary — the working row's todo-scent tooltip line
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - One row, read

/// Everything a navigator row draws, resolved off the store in one pass.
///
/// Volatile by nature — it is re-resolved per render of the row LEAF (never of the list), which is
/// the contract that keeps a per-pane status tick from re-running the whole rows + sectioning +
/// diff pass. `Equatable` so a renderer can skip a redraw that would change nothing.
package struct SidebarRowReading: Equatable, Sendable {
    /// The title the row SHOWS: rename → agent intent → structural → running command → last
    /// executed command → generic.
    package let title: String
    /// Whether the title wears the leading `✳` agent mark.
    package let agentMarker: Bool
    /// Whether this row's pane is the focused one — the raised chip.
    package let active: Bool
    /// The fused badge, busy tiers included.
    package let badge: TabBadgeKind?
    /// The terse working reading ("Agent working") — non-`nil` ⇒ a THINKING agent.
    package let workingLabel: String?
    /// A code agent present in this pane and at rest — the muted ring's only source.
    package let agentIdle: Bool
    /// Whether a finish on this row is the agent's turn ending rather than a command's clean exit.
    package let agentFinish: Bool
    /// The resting trailing label (the foreground process), `nil` on an agent row.
    package let processLabel: String?
    /// A finished command's receipt — outranks `processLabel` in the same slot.
    package let receipt: RailRowsBuilder.CommandReceipt?
    package let readOnly: Bool
    /// Whether the row's TAB is armed for synchronized input (⌘⇧I).
    package let syncInput: Bool
    /// Whether the row is in inline-rename mode.
    package let isEditing: Bool
    /// The ⌘-held digit, or `nil` at rest. Read LIVE (never memoized): closing a pane renumbers
    /// every pane after it without touching any surviving row's identity.
    package let shortcutHint: Int?
    /// The hover tooltip — the full cwd, the untruncated readout, the last command, the other
    /// clients looking at or holding this pane.
    package let tooltip: String?
    /// The MULTICLIENT lines ALONE — "Also open on <device>", "Held by <device>" — for a surface with
    /// no pointer to hang a tooltip off.
    ///
    /// It is a CUT of the tooltip and not a second reading: the rule writes those two lines once and
    /// the tooltip splices the SAME strings in, which is why they cross in ONE delivery — the phone's
    /// row and the Mac's hover can never name one fan-out two ways. The cut exists because the rest
    /// of the tooltip is overflow RECOVERY (the untruncated cwd, the clipped readout) — facts the row
    /// already shows, worth a hover and not worth a line — while this pair is the only thing in there
    /// that is not on screen anywhere else. On the device most likely to BE the second client, that
    /// made the one genuinely new fact the one fact it could not reach.
    package let presence: String?

    /// The RUNG the title's ink comes off, as a role — the palette is each framework's answer, the
    /// ladder is not.
    ///
    /// Urgency first: a row that is BROKEN or BLOCKED wears the mark's own hue across the whole
    /// title, and it outranks everything below including the active chip — a row you are standing on
    /// that just broke still reads as broken. Everything else keeps the neutral ladder: resting
    /// titles on the supporting ink, the active row and a THINKING agent stepping up to the primary.
    package var titleInk: RowTitleInk { RowTitleInk(code: UInt8(truncatingIfNeeded: titleReading)) }

    /// The WEIGHT the title is set at. A state that WAITS on you (a question, a failure, an unread
    /// finish) reads bolder than the active row's own step, so "needs you" outranks "you are here"
    /// on the one scale both spend — the mail idiom, where bold says *changed* and the mark's hue
    /// says what changed.
    package var titleWeight: RowTitleWeight { RowTitleWeight(code: UInt8(truncatingIfNeeded: titleReading >> 8)) }

    /// The state the row's INK and its (accessibility-hidden) mark speak visually, kept legible for
    /// VoiceOver: the working reading first, then an attention badge's own word. A row whose only
    /// news is that it is busy says nothing — busy is not a state anyone is waiting on.
    package var spokenState: String? {
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_sidebar_row_spoken_state(badgeCode, workingLabel != nil, out, cap))
        }
        return blob.isEmpty ? nil : wsRuns(blob, count: 1)[0]
    }

    /// Ink and weight in ONE answer — they share every input, and two doors would let a row take an
    /// urgent hue at a resting weight.
    private var titleReading: UInt16 {
        slopdesk_ws_sidebar_row_title(badgeCode, active, workingLabel != nil)
    }

    /// The badge as the doors take it: `-1` for an all-clear row.
    private var badgeCode: Int8 { badge.map { Int8($0.ffiByte) } ?? -1 }
}

/// The three rungs a row title's ink comes off.
package enum RowTitleInk: Equatable, Sendable {
    /// Wrong or stopped, and waiting on you — the mark's own hue, taken across the whole title.
    case urgent(AttentionRole)
    /// The focused row, and a thinking agent: a shade brighter than the rows that are doing nothing.
    case primary
    /// At rest.
    case secondary

    /// The rung a code names: the KIND in the high nibble, the urgent role in the low one.
    init(code: UInt8) {
        if code & 0xF0 == 0x10, let role = AttentionRole(urgentCode: code & 0x0F) {
            self = .urgent(role)
        } else {
            self = code & 0x0F == 1 ? .primary : .secondary
        }
    }
}

/// The three rungs a row title's WEIGHT comes off.
package enum RowTitleWeight: Equatable, Sendable {
    case resting
    /// The focused row.
    case active
    /// A state that waits on you — one step above `active`.
    case attention

    init(code: UInt8) {
        switch code {
        case 1: self = .active
        case 2: self = .attention
        default: self = .resting
        }
    }
}

private extension AttentionRole {
    /// The role the ink's low nibble names. Kept beside the ink because that nibble is the SAME
    /// index space `slopdesk_agent_badge_urgent` answers in.
    init?(urgentCode: UInt8) {
        switch urgentCode {
        case 1: self = .awaiting
        case 2: self = .failed
        case 3: self = .finished
        default: return nil
        }
    }
}

package enum SidebarRowPresentation {
    /// Resolve `row` against the live store.
    ///
    /// `fallbackTitle` is the KIND's generic name (`PaneChooserRegistry`), used when every rung of
    /// the title chain comes up empty.
    @MainActor
    package static func reading(
        for row: RailRow, store: WorkspaceStore, fallbackTitle: String,
    ) -> SidebarRowReading {
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        let blocks = store.commandBlocks(for: row.id)
        let agent = RailRowsBuilder.isAgentSession(
            status: chrome.status, processLabel: chrome.processLabel,
        )
        // The RUNNING command (busy non-agent shells): the host document's own open block, this
        // client's newest open block, then the coarse foreground-process label — one resolver, so
        // the title rung and the tooltip's command line cannot drift apart.
        let runningCommand: String? = (chrome.badge == .commandRunning || chrome.badge == .commandBusy)
            ? store.liveRunningCommand(
                for: row.id, processLabel: RailRowsBuilder.processDisplayName(chrome.processLabel),
            )
            : nil
        let title = RailRowsBuilder.liveRowTitle(
            structuralTitle: row.title,
            userRenamed: store.tree.activeSession?.specs[row.id]?.userRenamed == true,
            isAgent: agent,
            intent: store.paneAgentIntent[row.id],
            runningCommand: runningCommand,
            // The running PROGRAM's own OSC title, gated on the workspace document's `titleFresh`
            // verdict (agent glyphs stripped) — beats the raw command line wherever the running
            // rung would title the row.
            programTitle: RailRowsBuilder.normalizedProgramTitle(store.liveProgramTitle(for: row.id)),
            processTitle: RailRowsBuilder.processDisplayName(chrome.processLabel),
            blocks: blocks,
            kind: row.kind,
            cwdTitle: RailRowsBuilder.cwdFolderName(row.cwd),
            fallback: fallbackTitle,
        )
        // The failure the row's alarm may be blamed on — source-gated, so a live progress error is
        // never pinned on an older command. It names both the tooltip's error line and the trailing
        // slot's red receipt.
        let failedBlock = RailRowsBuilder.failedBlock(for: row.id, badge: chrome.badge, store: store)
        // Whose finish this is. ONE predicate feeds both consumers: the agent's FINAL assistant line
        // in the tooltip (a command's exit must never surface a stale agent line) and the trailing
        // mark's geometry (the agent's finish closes its ring; a command's takes a slot receipt).
        let agentFinish = RailRowsBuilder.finishIsAgents(
            badge: chrome.badge, status: chrome.status,
            unseenDone: store.paneUnseenDone.contains(row.id),
        )
        let working = chrome.status == .working
        let detail = RailRowReadout.resolve(
            question: chrome.question,
            scent: working ? todoScent(for: row.id, store: store) : nil,
            workingLabel: working ? store.agentLabel(for: row.id) : nil,
            // Done-unseen surfaces the agent's FINAL assistant line (the wire-27 label at `.done`).
            doneLine: agentFinish ? store.agentLabel(for: row.id) : nil,
            errorLine: RailRowReadout.errorLine(
                exitCode: failedBlock?.exitCode, commandText: failedBlock?.commandText,
            ),
            commandLine: runningCommand,
            title: title,
        )
        // The hover's two cuts in ONE crossing: the fan-out lines the phone prints under the title
        // and the whole tooltip the Mac hangs off the pointer are the same facts, written once.
        let hover = SidebarRowTooltip.hover(
            cwd: row.cwd,
            detail: detail,
            lastCommand: blocks.last(where: { $0.complete || $0.durationMS != nil })
                .flatMap(SidebarRowTooltip.commandLine),
            viewers: store.paneViewers(for: row.id),
            holders: store.paneHolders(for: row.id),
        )
        return SidebarRowReading(
            title: title,
            agentMarker: agent,
            active: row.id == store.tree.activeSession?.activeTab?.activePane,
            badge: chrome.badge,
            workingLabel: working ? TabBadgeReading.label(.running) : nil,
            // The `.idle` verdict is the detection's own "an agent is here, waiting for a prompt";
            // a plain shell never reaches it, however busy it is.
            agentIdle: chrome.status == .idle,
            agentFinish: agentFinish,
            // The slot names a real program (`vim`, `make`) AND a bare shell (`zsh`): unlike the
            // TITLE, where "zsh" says as little as "Terminal", the metadata slot answers "what is
            // this pane running", and an idle row with an empty slot reads as missing data. Only an
            // AGENT row leaves it empty — the `✳` and the mark already say it.
            processLabel: agent ? nil : RailRowsBuilder.slotProcessName(chrome.processLabel),
            receipt: RailRowsBuilder.commandReceipt(
                badge: chrome.badge, agentFinish: agentFinish, blocks: blocks,
                failedBlock: failedBlock, processLabel: chrome.processLabel,
            ),
            readOnly: chrome.readOnly,
            syncInput: store.syncInputArmed(for: row.id),
            isEditing: chrome.isEditing,
            shortcutHint: store.shortcutHintActive ? store.shortcutNumber(for: row.id) : nil,
            tooltip: hover.tooltip,
            presence: hover.presence,
        )
    }

    /// The todo SCENT — the tooltip's live line while an agent is WORKING with a live inspector feed
    /// reporting an in-flight todo. `nil` unless the feed is actually live: a stale todo list is a
    /// worse answer than no line at all.
    @MainActor
    private static func todoScent(for paneID: PaneID, store: WorkspaceStore) -> String? {
        guard let session = store.handle(for: paneID) as? LivePaneSession,
              let inspector = session.inspector, inspector.feedState == .live
        else { return nil }
        return PendingToolSummary.scent(todos: inspector.todos)
    }
}

// MARK: - The tooltip

/// The sidebar row tooltip's text assembly: the full raw cwd, the row's untruncated prose readout
/// (question / scent / label — overflow recovery for what the row itself cannot show), the last
/// command's `make check · 1.3s · exit 0` line, and who ELSE is on this pane.
package enum SidebarRowTooltip {
    /// The hover's two cuts, resolved together.
    package struct Hover: Equatable, Sendable {
        /// Who ELSE is on this pane, as the lines that say so: who has it ON SCREEN
        /// (``WorkspaceStore/paneViewers(for:)``) and who holds a CHANNEL on its PTY
        /// (``WorkspaceStore/paneHolders(for:)``). Two different facts, both useful — a client can be
        /// looking at a pane it does not hold, and holding one it is not showing. Viewing first: it
        /// is the softer claim.
        package let presenceLines: [String]
        /// The same lines as ONE line, for a surface with no pointer. `nil` for the common case
        /// (this client alone), so a row with nothing to report grows no second line.
        package let presence: String?
        /// The whole hover. `nil` when every part is empty.
        package let tooltip: String?
    }

    /// One crossing for both cuts. A door per spender would be the two-readings drift the rule exists
    /// to prevent: the presence lines the phone prints ARE the lines the tooltip splices.
    package static func hover(
        cwd: String?, detail: String?, lastCommand: String?, viewers: [String] = [],
        holders: [String] = [],
    ) -> Hover {
        var arena = WsStrings()
        let cwdSpan = arena.span(cwd)
        let detailSpan = arena.span(detail)
        let lastSpan = arena.span(lastCommand)
        // Viewers first for `viewers.count` entries, holders after — one lent list, one arena.
        let names = (viewers + holders).map { arena.span($0) }
        let blob = names.withUnsafeBufferPointer { lentNames in
            arena.bytes.withUnsafeBufferPointer { lent in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_sidebar_row_hover(
                        cwdSpan, detailSpan, lastSpan,
                        lentNames.baseAddress, viewers.count, holders.count,
                        lent.baseAddress, lent.count, out, cap,
                    ))
                }
            }
        }
        // `[u32 count]`, then that many presence lines, then the joined sentence and the tooltip.
        guard blob.count >= 4 else { return Hover(presenceLines: [], presence: nil, tooltip: nil) }
        let count = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        let runs = wsRuns(Array(blob.dropFirst(4)), count: count + 2)
        return Hover(
            presenceLines: Array(runs.prefix(count)),
            presence: runs[count].isEmpty ? nil : runs[count],
            tooltip: runs[count + 1].isEmpty ? nil : runs[count + 1],
        )
    }

    /// The tooltip's last-command line from a finished block: `command · duration · exit N` (parts
    /// missing on the block are simply omitted).
    package static func commandLine(_ block: CommandBlock) -> String? {
        var arena = WsStrings()
        let command = arena.span(block.commandText)
        let duration = arena.span(block.durationLabel)
        let status = arena.span(block.statusLabel)
        let blob = arena.bytes.withUnsafeBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_sidebar_row_command_line(
                    command, duration, status, lent.baseAddress, lent.count, out, cap,
                ))
            }
        }
        return blob.isEmpty ? nil : wsRuns(blob, count: 1)[0]
    }
}

// MARK: - Selecting a row

package enum SidebarSelection {
    /// The full tab-row SELECT path: switch to the owning tab, focus the pane, then AUTO-CLEAR every
    /// agent badge on the newly-focused tab (a badge auto-clears on tab focus). All three steps go
    /// through the store.
    ///
    /// Four surfaces select a rail row — the Mac's navigator, the collapsed-sidebar tab strip, the
    /// phone's list and the pane switcher — and "what clicking a row does" is one of them, not four.
    @MainActor
    package static func select(_ paneID: PaneID, in store: WorkspaceStore) {
        if let session = store.tree.activeSession,
           let index = owningTabIndex(of: paneID, in: session),
           index != session.activeTabIndex
        {
            store.selectTab(index)
        }
        store.focusPaneTree(paneID)
        // Runs AFTER focusPaneTree so the active tab is already the focused one.
        if let tab = store.tree.activeSession?.activeTab {
            for id in tab.allPaneIDs() {
                store.clearAgentBadge(id)
            }
        }
    }

    /// The index of the tab that OWNS `paneID`. A pane in a BACKGROUND tab still gets a rail row
    /// (``RailRowsBuilder`` enumerates `tab.allPaneIDs()`), so clicking its row must resolve the
    /// owning tab and `selectTab` it.
    package static func owningTabIndex(of paneID: PaneID, in session: Session) -> Int? {
        session.tabIndex(containing: paneID)
    }

    /// Commit an inline row rename: rename the PANE (so ``RailRowsBuilder/rowTitle`` — which reads
    /// the pane spec — surfaces it, winning over the folder name), then clear the pending state so
    /// the field closes. A blank draft renames nothing (`renamePane` no-ops), keeping the folder
    /// name; the pending state still clears so the field dismisses.
    @MainActor
    package static func commitRename(_ paneID: PaneID, to text: String, in store: WorkspaceStore) {
        store.renamePane(paneID, to: text)
        store.clearTabRenameRequest()
    }
}

// MARK: - The row's context menu

/// One entry of a rail row's right-click / long-press menu.
///
/// The menu is a VALUE because it is a verb table, and a verb table written twice diverges on the
/// first new verb — the failure mode that is silent in both halves until a user notices their phone's
/// menu is not their Mac's. The two renderers turn these into `NSMenuItem`s and `Button`/`Toggle`s.
package enum SidebarRowMenuEntry: Equatable, Sendable {
    /// A plain verb.
    case action(SidebarRowVerb)
    /// A checkbox, with the state it currently reads.
    case toggle(SidebarRowSwitch, isOn: Bool)
    case separator
}

/// The row menu's plain verbs.
package enum SidebarRowVerb: Equatable, Sendable {
    /// Open the inline rename on THIS row's tab (even a background one) — the mouse-reachable twin
    /// of ⌘R and the palette's "Rename Pane".
    case rename
    /// Acknowledge the pane's completion / attention badge.
    case clearBadge

    package var title: String { SidebarRowMenu.titles[index] }

    /// This verb's place in the ONE title delivery — the verbs lead it, the switches follow.
    var index: Int {
        switch self {
        case .rename: 0
        case .clearBadge: 1
        }
    }
}

/// The row menu's checkboxes. The three BADGE switches are PER-PANE overrides (seeded from the
/// pane's CURRENT effective gates, so the first flip preserves the other two — an absent override
/// follows the global Settings → Agents default). The two NOTIFY switches and the sleep assertion
/// are GLOBAL keys: notification fire-times and a host-local power assertion are not per-pane facts.
package enum SidebarRowSwitch: Equatable, Sendable {
    case badgeWhileProcessing
    case badgeWhenComplete
    case badgeWhenAwaitingInput
    case notifyTaskComplete
    case notifyAwaitInput
    /// The host-LOCAL `AgentPreferences` flag (rides the sidecar → applies on reconnect;
    /// default-OFF). Offered only when a live preferences store is threaded in.
    case preventSleep

    package var title: String { SidebarRowMenu.titles[SidebarRowVerb.clearBadge.index + 1 + index] }

    /// The switch's own index — the low nibble of the entry code, and its place in the delivery
    /// after the two verbs.
    var index: Int {
        switch self {
        case .badgeWhileProcessing: 0
        case .badgeWhenComplete: 1
        case .badgeWhenAwaitingInput: 2
        case .notifyTaskComplete: 3
        case .notifyAwaitInput: 4
        case .preventSleep: 5
        }
    }

    init?(index: UInt8) {
        switch index {
        case 0: self = .badgeWhileProcessing
        case 1: self = .badgeWhenComplete
        case 2: self = .badgeWhenAwaitingInput
        case 3: self = .notifyTaskComplete
        case 4: self = .notifyAwaitInput
        case 5: self = .preventSleep
        default: return nil
        }
    }
}

package enum SidebarRowMenu {
    /// Every title in ONE crossing, once per process: the two verbs, then the six switches.
    static let titles: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_sidebar_row_menu_titles(out, cap)) },
        count: 8,
    )

    /// The menu for `paneID`, with every switch already read. `preventSleep` is `nil` (a preview /
    /// pre-injection shell) ⇒ the sleep row and its separator are simply absent, never a dead
    /// control.
    ///
    /// The SHAPE — which entries, in which order, with which separators — is the far side's; the
    /// STATE each checkbox reads is the store's, and only the store can answer it.
    @MainActor
    package static func entries(
        for paneID: PaneID, store: WorkspaceStore, preventSleep: Bool?,
    ) -> [SidebarRowMenuEntry] {
        let gates = store.agentBadgeGates(for: paneID)
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_sidebar_row_menu(preventSleep != nil, out, cap))
        }
        guard blob.count >= 4 else { return [] }
        let count = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        return blob.dropFirst(4).prefix(count).compactMap { code -> SidebarRowMenuEntry? in
            switch code & 0xF0 {
            case 0x10:
                if code == 0x10 { .action(.rename) } else { .action(.clearBadge) }
            case 0x20:
                SidebarRowSwitch(index: code & 0x0F).map { flag in
                    .toggle(flag, isOn: state(of: flag, gates: gates, preventSleep: preventSleep))
                }
            default:
                if code == UInt8(slopdesk_ws_sidebar_row_separator_code()) { .separator } else { nil }
            }
        }
    }

    /// What one checkbox currently reads.
    @MainActor
    private static func state(
        of flag: SidebarRowSwitch, gates: AgentBadgeGates, preventSleep: Bool?,
    ) -> Bool {
        switch flag {
        case .badgeWhileProcessing: gates.badgeWhileProcessing
        case .badgeWhenComplete: gates.badgeWhenComplete
        case .badgeWhenAwaitingInput: gates.badgeWhenAwaitingInput
        case .notifyTaskComplete: Defaults[.agentNotifyTaskComplete]
        case .notifyAwaitInput: Defaults[.agentNotifyAwaitInput]
        case .preventSleep: preventSleep ?? false
        }
    }

    /// Run a verb.
    @MainActor
    package static func run(_ verb: SidebarRowVerb, row: RailRow, store: WorkspaceStore) {
        switch verb {
        case .rename: store.requestRenameTab(row.tabID)
        case .clearBadge: store.clearAgentBadge(row.id)
        }
    }

    /// Flip a switch. The badge gates are per-pane toggles the store owns and the notify keys are
    /// global `Defaults`, so both land here; the SLEEP flag is handed back through `togglePreventSleep`
    /// because the preferences store is the caller's — this layer never reaches a host-local
    /// sidecar preference.
    ///
    /// A badge gate is a per-pane OVERRIDE seeded from the pane's current EFFECTIVE gates, so the
    /// first flip preserves the other two rather than dropping them to the global default.
    @MainActor
    package static func flip(
        _ toggle: SidebarRowSwitch, paneID: PaneID, store: WorkspaceStore,
        togglePreventSleep: () -> Void,
    ) {
        switch toggle {
        case .badgeWhileProcessing: store.toggleAgentBadgeGate(.whileProcessing, for: paneID)
        case .badgeWhenComplete: store.toggleAgentBadgeGate(.whenComplete, for: paneID)
        case .badgeWhenAwaitingInput: store.toggleAgentBadgeGate(.whenAwaitingInput, for: paneID)
        case .notifyTaskComplete: Defaults[.agentNotifyTaskComplete].toggle()
        case .notifyAwaitInput: Defaults[.agentNotifyAwaitInput].toggle()
        case .preventSleep: togglePreventSleep()
        }
    }
}
