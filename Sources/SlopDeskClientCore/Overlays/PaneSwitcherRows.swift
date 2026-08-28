// PaneSwitcherRows — the near-side FACE of `slopdesk_workspace::pane_switcher`, plus the store reads
// that resolve one ⌃⇥ row off the live workspace.
//
// A row is a PANE, the same unit the sidebar lists and the same unit ⌘1…⌘9 lands on. The card is
// therefore the sidebar in recency order: one line per pane, carrying only what differs — the pane's
// identity, then a quiet note for the sub-path it strayed into. Identity comes from
// ``RailRowsBuilder/liveRowTitle(...)`` — the SAME chain the sidebar row and the window title read, so a
// pane is named identically wherever it is named, and a fix to the chain reaches all three. A TAB rename
// is deliberately NOT consulted: a tab is a container, and naming its pane after it is how three panes of
// one repo all came to read `slopdesk` (the bug this builder exists to answer).
//
// ⚠️ THE PROJECT RIDES THE ROW, it does not head a section. Section headers were the tab-era shape and
// they do not survive the unit change: the display order is the frozen ring's (recency), and a header is
// only worth its line when consecutive rows share it. Tabs came in project-sized runs; PANES interleave —
// walk between two repos and the ring reads slopdesk, otty, slopdesk, otty, which under a run-boundary
// rule is a caption above every single row. Re-sorting to fix that is worse still: the card's order is
// the order ⇥ steps in, so grouping would make the highlight jump around the list. So each row says its
// own place, on its own second line.
//
// TWO HALVES READ THIS FILE, and the second one arrived late. The Mac draws the rows in an `NSPanel`
// (`Sources/SlopDeskMacUI/Overlays/MacPaneSwitcher.swift`), the phone in a paper card
// (`Sources/SlopDeskPhoneUI/Overlays/PhonePaneSwitcherView.swift`) — and for a while the phone drew
// NOTHING, while the binding row that opens the gesture said `Platform::Both`. ⌃⇥ on an iPad therefore
// veiled every pane (``PaneFocusPolicy/showsSwitcherRecede(switcherIsOpen:isFocused:)`` reads the same
// store flag) behind a card that did not exist, with no way to step, commit or cancel. Everything the
// phone needed that the Mac did not — its width rung, and what a TAP on a row means — crossed with the
// rest, for the same reason the rows and the measurements did.
//
// What stays HERE is the `@MainActor` walk over the store: which panes the ring holds, what number each
// wears, and the chrome resolver that titles one. Those are reads of live workspace state, not rules.

import CoreGraphics
import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// One rendered switcher row: a pane.
package struct PaneSwitcherRow: Identifiable, Equatable {
    package let id: PaneID
    /// The pane's ⌘-number (1-based position in ``WorkspaceStore/flatOrderedPaneIDs()``) — the switcher
    /// doubles as a reminder that ⌘N jumps straight here.
    package let number: Int
    /// The pane's identity — the only thing on the line that has to be read.
    package let title: String
    /// The quiet remainder: the sub-path below the project. `nil` for the common at-root pane.
    package let note: String?
    /// The project this row sits in — the first half of its PLACE line. `nil` for a pane with no project
    /// at all (a video pane, a shell whose cwd has not landed), where the note stands alone.
    package let project: String?
    package let isHighlighted: Bool
}

/// How big the card is, as a function of the window it floats in.
///
/// A fixed width is wrong for this surface in a way it is not wrong for a dialog: the switcher's rows
/// carry LIVE text of wildly varying length (`zsh` … `nvim Sources/…/PaneSwitcherOverlay.swift`), so the
/// right measure depends on how much room the window can spare. The band the far side clamps into is
/// MEASURED rather than guessed, and its own header records the three sample measures.
///
/// The two rungs — desktop and compact — are separate functions rather than one with a flag, because
/// NEITHER desktop bound survives the move to a phone. That is arithmetic rather than taste: the floor
/// is wider than an iPhone's whole screen, and the ceiling would spend a third of that screen on ground
/// whose only job is to be not-the-card. Its premise is the workspace BEHIND, and a phone screen has no
/// behind; ``GlobalSearchMetrics`` records the same reading for the same reason one surface over.
package enum PaneSwitcherMetrics {
    package static func width(container: CGFloat) -> CGFloat {
        CGFloat(slopdesk_ws_pane_switcher_width(Double(container)))
    }

    /// An unmeasured container has NO ceiling — a first layout pass must not clamp the card to zero.
    package static func maxHeight(container: CGFloat) -> CGFloat {
        CGFloat(slopdesk_ws_pane_switcher_max_height(Double(container)))
    }

    /// The width the card takes on a COMPACT screen — the phone's rung of the same measure.
    ///
    /// It keeps exactly the one bound that was never about the window: past ~75 characters the eye loses
    /// the line, on any screen. The card takes the width it is offered, up to that cap — which binds on
    /// an iPad and never on a phone. The margin between the card and the screen edge is the presenter's,
    /// the same `Slate.Metric.space4` every phone card keeps.
    ///
    /// An unmeasured container (a first layout pass) yields the CAP rather than a floor: the phone's
    /// frame is a `maxWidth`, so the enclosing padding still bounds it, where a floor would ask a 390pt
    /// screen for a card wider than itself.
    package static func compactWidth(container: CGFloat) -> CGFloat {
        CGFloat(slopdesk_ws_pane_switcher_compact_width(Double(container)))
    }

    /// How tall the ROWS stand: their true height, capped at the ceiling past which they scroll.
    ///
    /// The Mac asks a laid-out `NSStackView` for its `fittingSize` and takes the smaller of that and the
    /// ceiling. SwiftUI cannot be asked: a `ScrollView` claims every point it is OFFERED along its axis,
    /// so a two-row card left to the framework stands 70% of the screen tall with its two rows at the
    /// top. The sum is exact rather than an estimate — the row is a fixed-height object in both halves
    /// (`Slate.Metric.heightRowStacked`), which is what makes the list's rhythm a constant beat — so the
    /// caller passes that height in and the arithmetic stays on one side of the boundary.
    package static func listHeight(rows: Int, rowHeight: CGFloat, container: CGFloat) -> CGFloat {
        CGFloat(slopdesk_ws_pane_switcher_list_height(rows, Double(rowHeight), Double(container)))
    }
}

// MARK: - What a TAP is

/// A walk around the frozen ring: how many single steps, and which way.
///
/// The unit is a STEP because that is the only verb the gesture has — see
/// ``PaneSwitcherRowsBuilder/walk(from:to:count:)`` for why a tap is spelled in it rather than in a jump.
package struct PaneSwitcherWalk: Equatable {
    /// The direction each step takes, in ``PaneSwitcher/step(forward:)``'s own sense.
    package let forward: Bool
    /// How many of them. Zero when the highlight is already on the target.
    package let steps: Int

    package init(forward: Bool, steps: Int) {
        self.forward = forward
        self.steps = steps
    }
}

/// The phone's WORDS for this surface. The Mac's readout has none — a card that lives for 200ms under a
/// held ⌃ is titled by the hand holding it up — and the phone's cannot borrow that silence: it stays up
/// with nothing held, in a family where every card names itself (``SlateCardTitle``).
package enum PaneSwitcherCopy {
    /// The card's title — the SAME words the palette row that opens it wears (`pane.switcher` in
    /// ``WorkspaceBindingRegistry``, and the phone's only touch entry point into the gesture). A surface
    /// and the command that summons it may not come to have two names.
    package static var title: String { words[0] }

    /// The honest zero state. The ring is frozen at open and its panes can close under it, so the rows
    /// CAN empty mid-gesture — and an empty card that still veils the workspace is the defect this
    /// surface exists to answer, said a second time.
    package static var noPanes: String { words[1] }

    /// The two step controls, for the reader who has no ⇥ to press. Named by what they MOVE, not by the
    /// ring's direction: "forward" is a fact about the frozen order, and nobody is holding it.
    package static var stepForward: String { words[2] }
    package static var stepBackward: String { words[3] }

    /// The join between a row's two place halves. ``PaneSwitcherRowsBuilder/PaneIdentity/placeLine``
    /// makes the same join for the surfaces that carry one subtitle slot; a half that draws the two
    /// registers separately (the switcher rows do, so the project can go a shade heavier) still spells
    /// the separator from here.
    package static var placeSeparator: String { words[4] }

    /// Every word in ONE crossing, once per process.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_pane_switcher_words(out, cap)) },
        count: 5,
    )
}

package enum PaneSwitcherRowsBuilder {
    /// The four store reads every part of a row needs, taken ONCE per row: what the pane is, where it
    /// is, which project owns it, and the title its program asserted.
    @MainActor
    private struct PaneFacts {
        package let pane: PaneID
        package let spec: PaneSpec?
        package let kind: PaneKind
        package let cwd: String?
        package let liveTitle: String?
        package let projectKey: String?

        package init(pane: PaneID, spec: PaneSpec?, store: WorkspaceStore) {
            self.pane = pane
            self.spec = spec
            kind = spec?.kind ?? .terminal
            cwd = store.paneCwd(for: pane)
            liveTitle = store.liveProgramTitle(for: pane)
            projectKey = kind == .terminal ? store.paneProjectKey(pane) : nil
        }
    }

    /// The highest pane the app binds a ⌘-digit to (⌘1–9). Past it a row has no shortcut to show.
    package static let highestShortcut = slopdesk_ws_pane_switcher_highest_shortcut()

    /// Resolve the frozen candidate ring into rows. The ORDER is the switcher's (recency), not the
    /// session's — that is the point of the surface; the NUMBER is the session's, because that is what
    /// ⌘N obeys. A candidate whose pane has been closed under the held ⌃ is dropped, matching
    /// ``WorkspaceStore/commitPaneSwitcher()``, which refuses to commit onto one.
    @MainActor
    package static func rows(for switcher: PaneSwitcher, store: WorkspaceStore) -> [PaneSwitcherRow] {
        guard let session = store.tree.activeSession else { return [] }
        // ONE pass over the session builds both sides of the join: which tab owns a pane (the chrome
        // resolver is tab-scoped) and what number it wears.
        var owner: [PaneID: SlopDeskWorkspaceModel.Tab] = [:]
        var number: [PaneID: Int] = [:]
        for tab in session.tabs {
            for id in tab.allPaneIDs() {
                owner[id] = tab
                number[id] = number.count + 1
            }
        }
        return switcher.candidates.enumerated().compactMap { index, id -> PaneSwitcherRow? in
            guard let tab = owner[id], let position = number[id] else { return nil }
            let ident = identity(pane: id, spec: session.specs[id], tab: tab, store: store)
            return PaneSwitcherRow(
                id: id,
                number: position,
                title: ident.title,
                note: ident.note,
                project: ident.project,
                isHighlighted: index == switcher.highlightIndex,
            )
        }
    }

    /// The WALK a tap is — the phone's commit rule, and the reason it is a walk rather than a jump.
    ///
    /// A Mac commits by releasing the ⌃ it is holding. A phone has no modifier to release, so the touch
    /// gesture that picks a pane is a tap on its row. What that tap must NOT become is a SECOND COMMIT
    /// DOOR: ``WorkspaceStore/commitPaneSwitcher()`` unwinds the follow-along preview before it stages
    /// focus (so the reveal starts from the focus the gesture began with) and refuses a candidate whose
    /// pane closed under the gesture, and a view reaching past it for
    /// ``WorkspaceStore/revealPaneTree(_:)`` would have neither guard — the identical pair of bugs the
    /// commit's own doc comment records. So a tap is spelled in the gesture's two existing verbs: STEP
    /// until the highlight is the tapped row, then COMMIT. That is what a Mac user does with ⇥⇥⇥ and a
    /// release; the phone just does it in one gesture.
    ///
    /// ⚠️ CANDIDATE INDEX SPACE, NOT ROW SPACE. ``rows(for:store:)`` drops a candidate whose pane closed
    /// under the held gesture, so the third ROW can be the fourth CANDIDATE — and the highlight
    /// ``PaneSwitcher/step(forward:)`` moves is the candidate's.
    package static func walk(from: Int, to: Int, count: Int) -> PaneSwitcherWalk {
        let answer = slopdesk_ws_pane_switcher_walk(max(0, from), max(0, to), max(0, count))
        return PaneSwitcherWalk(forward: answer.forward, steps: answer.steps)
    }

    /// The walk from the live highlight to `target`, over the ring `switcher` froze.
    ///
    /// `nil` when the ring no longer holds that pane — a row tapped in the same frame its pane closed
    /// must be a no-op, never a walk toward nowhere.
    package static func walk(to target: PaneID, in switcher: PaneSwitcher) -> PaneSwitcherWalk? {
        guard let index = switcher.candidates.firstIndex(of: target) else { return nil }
        return walk(from: switcher.highlightIndex, to: index, count: switcher.candidates.count)
    }

    /// One pane's display identity — the (title, project, note) triple a ⌃⇥ row carries. Exposed so the
    /// OTHER surfaces that name a pane (the ⌘⇧P Panes jump rows) resolve through this SAME chain: a pane
    /// is named identically wherever it is named, and a fix to the chain reaches every surface at once.
    package struct PaneIdentity {
        package let title: String
        package let project: String?
        package let note: String?
        /// The place line the switcher stacks under the title, as ONE string (`project › note`) — for
        /// surfaces that carry a single subtitle slot. `nil` when the pane has neither half.
        package let placeLine: String?

        package init(title: String, project: String?, note: String?, placeLine: String?) {
            self.title = title
            self.project = project
            self.note = note
            self.placeLine = placeLine
        }
    }

    /// Resolve one pane's ``PaneIdentity`` off the live store — the switcher rows and the palette's
    /// Panes rows both come through here.
    @MainActor
    package static func identity(
        pane: PaneID, spec: PaneSpec?, tab: SlopDeskWorkspaceModel.Tab, store: WorkspaceStore,
    ) -> PaneIdentity {
        let facts = PaneFacts(pane: pane, spec: spec, store: store)
        // The pane's volatile chrome through the sidebar's ONE resolver — the badge it returns is
        // what gates the running-command rung below (a fast `ls` must not flash into the title).
        // The representative pane + manual badge are resolved exactly as the rail resolves them,
        // so a manual `tab badge` lands on the same row in both surfaces.
        let chrome = RailRowsBuilder.chrome(
            paneID: pane, kind: facts.kind, spec: facts.spec, tabID: tab.id,
            representativePane: tab.activePane ?? tab.allPaneIDs().first,
            manualBadge: store.tabBadgeOverride(for: tab.id), store: store,
        )
        let structural = structuralTitle(facts: facts, chrome: chrome, store: store)
        // A NON-terminal pane has no project and takes the whole location as its note — there are no
        // section headers here, so no key to cut it against.
        guard facts.kind == .terminal else {
            let note = facts.spec?.railSubtitle(cwd: facts.cwd, liveTitle: facts.liveTitle, projectKey: nil)
            return marked(title: structural, project: nil, note: note, chrome: chrome)
        }
        // The row's three registers, resolved in one crossing off the pane's own four facts: the drawn
        // title (already yielded to the program if it only restated its place line), the project, the
        // note, and the two joined. Four doors would let a half join a project from one row with a note
        // from another.
        var arena = WsStrings()
        let title = arena.span(structural)
        let projectKey = arena.span(facts.projectKey)
        let cwd = arena.span(facts.cwd)
        let processLabel = arena.span(chrome.processLabel)
        let blob = arena.bytes.withUnsafeBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_pane_switcher_row(
                    title, projectKey, cwd, processLabel, lent.baseAddress, lent.count, out, cap,
                ))
            }
        }
        // An EMPTY run is "there is none": the rules never write a blank project or note, so an empty
        // one cannot collide with a real answer.
        let runs = wsRuns(blob, count: 4)
        return marked(
            title: runs[0],
            project: runs[1].isEmpty ? nil : runs[1],
            note: runs[2].isEmpty ? nil : runs[2],
            placeLine: runs[3].isEmpty ? nil : runs[3],
            chrome: chrome,
        )
    }

    /// The agent's ✳ mark rides the IDENTITY, not just the sidebar view: the rail row draws its own
    /// marker (`SlateTabRow.agentMarker`), so without this the switcher and the palette would show the
    /// same pane bare while the rail shows it marked. Whatever rung titled the row — intent, running
    /// command, normalized program title, folder — an agent session leads with the ONE static mark; a
    /// title already led by it (the normalized-title rung) keeps its own.
    @MainActor
    private static func marked(
        title: String, project: String?, note: String?, placeLine: String? = nil,
        chrome: RailRowsBuilder.RailRowChrome,
    ) -> PaneIdentity {
        let isAgent = RailRowsBuilder.isAgentSession(status: chrome.status, processLabel: chrome.processLabel)
        return PaneIdentity(
            title: isAgent ? RailRowsBuilder.agentMarkedTitle(title) : title,
            project: project,
            note: note,
            placeLine: placeLine ?? note,
        )
    }

    /// The row's LINE before the place line has had its say — the pane's live identity chain, the same
    /// one ``NavigatorColumn`` hands its rows, so the switcher and the sidebar can never call one pane
    /// two things.
    ///
    /// `projectKey` IS passed to the structural rung on purpose: at the project root that yields the
    /// PROGRAM rather than the folder name, and an idle shell's empty result then falls through to the
    /// running command / last command / folder name. That fall-through is what tells two panes of one
    /// repo apart. Whether the result then only RESTATES its place line is the far side's question.
    @MainActor
    private static func structuralTitle(
        facts: PaneFacts, chrome: RailRowsBuilder.RailRowChrome, store: WorkspaceStore,
    ) -> String {
        let structural = RailRowsBuilder.rowTitle(
            kind: facts.kind, spec: facts.spec, cwd: facts.cwd, liveTitle: facts.liveTitle,
            processLabel: chrome.processLabel, projectKey: facts.projectKey,
        )
        // Busy-badge-gated, exactly as the sidebar gates it: the command titles the row with the same
        // reveal that earns the busy mark, so sub-second chatter never renames anything.
        let running = chrome.badge == .commandRunning || chrome.badge == .commandBusy
            ? store.liveRunningCommand(
                for: facts.pane, processLabel: RailRowsBuilder.processDisplayName(chrome.processLabel),
            )
            : nil
        return RailRowsBuilder.liveRowTitle(
            structuralTitle: structural,
            userRenamed: facts.spec?.userRenamed == true,
            isAgent: RailRowsBuilder.isAgentSession(
                status: chrome.status, processLabel: chrome.processLabel,
            ),
            intent: store.paneAgentIntent[facts.pane],
            runningCommand: running,
            programTitle: RailRowsBuilder.normalizedProgramTitle(facts.liveTitle),
            processTitle: RailRowsBuilder.processDisplayName(chrome.processLabel),
            blocks: store.commandBlocks(for: facts.pane),
            kind: facts.kind,
            cwdTitle: RailRowsBuilder.cwdFolderName(facts.cwd),
            fallback: PaneChooserRegistry.option(for: facts.kind).title,
        )
    }
}
