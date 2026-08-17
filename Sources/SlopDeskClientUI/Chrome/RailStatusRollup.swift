// RailStatusRollup — the aggregate agent reading that stands in the sidebar's traffic-light band
// (user-directed 2026-08-11). It answers ONE question the rail below it can only answer row by row:
// *is anything at all waiting / working / finished right now* — with no counts, no names, no ranking.
//
// ⚠️ ALL THREE MARKS ARE ALWAYS DRAWN (user-directed, second cut). It shipped as a cluster that
// appeared and collapsed with the news, on the argument that a strip bare by design must stay bare;
// what that actually produced was a widget whose WIDTH and CONTENTS both moved, so the reader had to
// re-identify the marks every time one arrived — and the position of a mark said nothing, because
// which mark sat where depended on what else was lit. Three fixed slots make the cluster a LEGEND
// that is sometimes lit: the hand is always in the same place, and the eye learns it once. A state
// with no panes draws its mark ``disabledInk`` and FROZEN — nothing in an unlit slot moves, because
// motion is the loudest claim this band can make and an empty state has nothing to claim.
//
// ⚠️ EACH MARK IS ITS OWN BUTTON, jumping into that state's OWN panes (``jump(_:panes:)``). It
// shipped as one tap target calling the attention walk, which ranks needs-permission first — so
// clicking the spinner or the check silently landed on the blocked pane (user-reported). Three marks
// that all do one thing are one button wearing three faces.
//
// WHY THE TRAILING EDGE, not beside the sidebar toggle. The cluster hangs flush on the column's own
// gutter (``RailStatusRollup/trailingInset``) — the same edge the search field's plate and every
// project island end on, so the band closes on the one vertical line the whole column already ends
// against. ⚠️ It stood 18pt further in until 2026-08-11 (user-reported), aligned instead with the
// rows' MARK COLUMN on the argument that it read as the head of that column; on hardware it read as
// a cluster that had failed to reach the edge, because the search plate directly under it is the
// nearer and far stronger line. The band's leading half keeps its air: the lights and the toggle are
// the only things there — until the column collapses, when this cluster slides over to join them
// (``RailStatusRollupMount``, which owns the geometry and the travel).
//
// ⚠️ THIS IS NOT THE ROUND-11 TITLEBAR PIP COMING BACK (docs/DECISIONS.md, "attention leaves the
// titlebar"). That pip stood on the CONTENT side and restated, in a second vocabulary, what the
// visible rail was already naming pane by pane. This one stands on the navigator's own ground, in
// the rail's own column, in the rail's own marks, and it exists for the rows the column CANNOT
// show — the ones scrolled past the fold or hidden behind a live search query. It is deliberately
// not filtered by that query: a filter hiding a waiting agent is precisely when the rollup earns
// its place.
//
// ⚠️ IT MUST STAY A LEAF. Resolving each row's chrome touches the store's volatile per-pane dicts;
// doing that inside a container's body would register every one of them as a dependency of that
// body and bring back the re-render storm ``RailRowsMemo`` exists to kill (the same rule
// ``ConnectionStatusMount`` carries). The rows arrive as a STRUCTURAL parameter (the memo's array);
// only the volatile reads happen in here. Its mount is a leaf for the same reason against a
// DIFFERENT volatile source — the split's live column width.

#if canImport(SwiftUI)
import SlopDeskAgentDetect // ClaudeStatus — the raw agent status the working reading keys on
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

#if os(macOS)
struct RailStatusRollup: View {
    let store: WorkspaceStore
    /// The memoized structural rows — the SAME array the sidebar renders, so the cluster and the
    /// list can never disagree about which panes exist.
    let rows: [RailRow]

    /// One of the three states the band speaks. Presence only — the cluster never counts.
    enum Kind: Hashable, Sendable {
        /// An agent has raised its hand and is blocked on the user.
        case waiting
        /// An agent is thinking.
        case working
        /// An agent's own turn ended and the finish has not been seen yet.
        case done
    }

    /// The drawing order, PINNED BY VALUE (`RailStatusRollupTests`) — urgency first, exactly the
    /// order the unseen-attention queue ranks in, so the loudest state is the leftmost thing the eye
    /// meets. Deriving it from `allCases` instead would let a future reorder of the enum silently
    /// rewrite the band.
    static let order: [Kind] = [.waiting, .working, .done]

    /// One pane's volatile reading, reduced to the three inputs the rollup needs. A value type so
    /// the derivation is testable without a store.
    struct Reading: Equatable, Sendable {
        let status: ClaudeStatus
        let badge: TabBadgeKind?
        /// The client's unread agent-finish latch (``WorkspaceStore/paneUnseenDone``).
        let unseenDone: Bool
    }

    /// Whether ONE pane's reading is in state `kind` — the atom every other derivation here is built
    /// from, so which panes a mark JUMPS TO can never disagree with whether that mark is lit.
    ///
    /// Every branch reuses a predicate the ROW already renders by, so a mark can never appear up
    /// here that the row itself would not draw:
    /// - waiting — the `.awaitingInput` badge, the hand's own tier;
    /// - working — the RAW `.working` status (never the gated badge: "Badge while processing" is
    ///   OFF by default and masks `.working` out of the badge, which would leave a whole workspace
    ///   of thinking agents dark), plus the badge-routed `.running` tier that reads identically;
    /// - done — ``RailRowsBuilder/finishIsAgents(badge:status:unseenDone:)``, the SAME predicate
    ///   that decides whether a row's check belongs to the agent or to a command's clean exit. A
    ///   command finishing is NOT this cluster's news (round 24: the mark column is the agent's).
    static func matches(_ kind: Kind, _ reading: Reading) -> Bool {
        switch kind {
        case .waiting: reading.badge == .awaitingInput
        case .working: reading.status == .working || reading.badge == .running
        case .done: RailRowsBuilder.finishIsAgents(
                badge: reading.badge, status: reading.status, unseenDone: reading.unseenDone,
            )
        }
    }

    /// Which states are present across `readings`, in ``order``.
    static func kinds(_ readings: [Reading]) -> [Kind] {
        order.filter { kind in readings.contains { matches(kind, $0) } }
    }

    /// The pane a mark's click lands on: the one AFTER the focused pane in that state's own list,
    /// wrapping, or the first when focus is elsewhere. Repeated clicks therefore WALK the state
    /// instead of pinning its first pane — the same shape ⌘⇧U's walk has, without the walk's
    /// origin-and-pop bookkeeping, which belongs to a keyboard chord rather than to a mark you can
    /// see the whole list of.
    static func nextPane(in panes: [PaneID], focused: PaneID?) -> PaneID? {
        guard !panes.isEmpty else { return nil }
        guard let focused, let index = panes.firstIndex(of: focused) else { return panes[0] }
        return panes[(index + 1) % panes.count]
    }

    /// The mark a state draws when it IS happening — resolved through
    /// ``StatusPresentation/statusDot(working:badge:agentIdle:agentFinish:)`` rather than respelled
    /// here, so the band and the rows share ONE vocabulary: change a row's hue or silhouette and this
    /// follows without being touched.
    @MainActor
    static func style(for kind: Kind) -> StatusDotStyle? {
        switch kind {
        case .waiting: StatusPresentation.statusDot(working: false, badge: .awaitingInput)
        case .working: StatusPresentation.thinkingMark
        case .done: StatusPresentation.statusDot(working: false, badge: .completed, agentFinish: true)
        }
    }

    /// What an UNLIT slot is drawn in. The mark keeps its silhouette — that is the whole point of a
    /// fixed slot — and gives up both of the things that carry state: the hue and, for the spinner,
    /// the motion.
    ///
    /// ⚠️ Deliberately NEUTRAL, not the state's own hue faded. A dimmed amber is still amber, and a
    /// row of three washed-out hues reads as three states half-happening rather than as one legend
    /// with one entry lit. On the metadata rung at ``Slate/Opacity/dim`` — the "ruled-out hint
    /// letter" pairing, which is exactly this semantics — so the unlit slots sit under the quietest
    /// text in the column and cannot compete with a lit one.
    @MainActor
    static var disabledInk: Color { Slate.Text.tertiary.opacity(Slate.Opacity.dim) }

    /// The mark for one slot, lit or not — ONE function, so an unlit slot can never drift into a
    /// different silhouette from the lit one it stands in for.
    @MainActor
    static func style(for kind: Kind, active: Bool) -> StatusDotStyle? {
        guard let lit = style(for: kind) else { return nil }
        guard !active else { return lit }
        return StatusDotStyle(ink: disabledInk, mark: lit.mark, frozen: true)
    }

    /// The state's spoken name — the rows' own labels, so VoiceOver and the tooltip say here exactly
    /// what they say on the row this mark stands for.
    static func label(for kind: Kind) -> String {
        switch kind {
        case .waiting: StatusPresentation.tabBadgeLabel(.awaitingInput)
        case .working: StatusPresentation.tabBadgeLabel(.running)
        case .done: StatusPresentation.tabBadgeLabel(.finished)
        }
    }

    /// The distance from the navigator's trailing edge to the marks' trailing edge: the COLUMN's
    /// gutter, the one ``NavigatorColumn`` spends on both the search field's plate and the list of
    /// project islands. The band therefore ends on the same line every surface under it ends on.
    ///
    /// ⚠️ It was `space2 + projectIslandInset + islandRail` (the rows' mark column, 18pt further in)
    /// until 2026-08-11 — see this file's header for why that lost. The search plate reads THIS
    /// rather than spelling `8` again, so the band and the line it aligns to move together.
    static let trailingInset = Slate.Metric.space2

    var body: some View {
        // The flash-decay tick, observed at CLUSTER scope exactly as ``SidebarLiveRow`` observes it:
        // a clean completion's badge decays off the wall clock, not off an `@Observable` dependency,
        // so without this the done mark would outlive the row's own.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        let sightings = rows.map { row in
            let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
            return (
                pane: row.id,
                reading: Reading(
                    status: chrome.status, badge: chrome.badge,
                    unseenDone: store.paneUnseenDone.contains(row.id),
                ),
            )
        }
        let kinds = Self.kinds(sightings.map(\.reading))
        RailStatusMarks(active: kinds) { kind in
            jump(kind, panes: sightings.filter { Self.matches(kind, $0.reading) }.map(\.pane))
        }
        .help(Self.summary(kinds))
        // Only the LIT SET may animate. The marks themselves never move in or out any more —
        // three slots, always — so this is the hue crossing between `disabledInk` and the
        // state's own, which is the only thing left that changes.
        .animation(Slate.Anim.smallFade, value: kinds)
    }

    /// Walk to the next pane in `kind`'s own list.
    ///
    /// ⚠️ EACH MARK IS ITS OWN BUTTON, and this is why (user-reported 2026-08-11). The cluster
    /// shipped as one tap target over all three marks calling
    /// ``WorkspaceStore/jumpToOldestAttentionPane()``, which ranks needs-permission ABOVE done — so
    /// clicking the check, or the spinner, silently landed on the blocked pane. Three marks that all
    /// do the same thing are not three buttons; they are one button wearing three faces, and the
    /// face you aim at has to be the one that answers.
    ///
    /// The two ATTENTION states acknowledge on arrival (``WorkspaceStore/clearAgentBadge(_:)``,
    /// exactly as the walk does) — you have now seen it. A thinking pane has nothing to acknowledge,
    /// so working is a plain teleport; it is nonetheless actionable, because "take me to whatever is
    /// running" is a real request even though nothing is waiting on you.
    @MainActor
    private func jump(_ kind: Kind, panes: [PaneID]) {
        let focused = store.tree.activeSession?.activeTab?.activePane
        guard let target = Self.nextPane(in: panes, focused: focused) else { return }
        if kind != .working { store.clearAgentBadge(target) }
        store.jumpToPaneTree(target)
    }

    /// What the cluster SAYS — the lit states, or the resting phrase.
    ///
    /// ⚠️ The resting phrase is why this is no longer AX-hidden when nothing is lit. Three grey marks
    /// are on screen either way, so a VoiceOver reader who lands on them must be told they mean
    /// *nothing is running* rather than find an unlabelled element — the hidden branch was correct
    /// only while an empty cluster drew nothing at all.
    static func summary(_ kinds: [Kind]) -> String {
        guard !kinds.isEmpty else { return "No agents active" }
        return kinds.map(label(for:)).joined(separator: ", ")
    }
}

/// The rollup's DRAWING, split from its derivation so the marks can be rendered at true size
/// without a store behind them (the snapshot rig mounts this directly — the LIT SET is the whole
/// input). Pure SwiftUI, so `ImageRenderer` can capture it; a lit working mark keeps its own
/// wall-clock phase, an unlit one is frozen.
struct RailStatusMarks: View {
    /// Which states are happening. Every state in ``RailStatusRollup/order`` is drawn either way —
    /// this only decides which of them is LIT.
    let active: [RailStatusRollup.Kind]
    /// What a LIT mark's click does. `nil` (the snapshot rig) draws the cluster inert.
    var onPick: ((RailStatusRollup.Kind) -> Void)?

    /// The gap between two marks. ⚠️ `space2`, not `space1` (user-reported 2026-08-11: "3 cái nút
    /// có vẻ hơi sát nhau"). At 4 the marks read as one object and — worse — two 14pt hit boxes 4pt
    /// apart is a target the pointer misses, which is how a click meant for the check landed on the
    /// hand. The hit boxes are the marks' own footprints, so the visual gap IS the dead zone.
    static let markGap = Slate.Metric.space2

    /// The cluster's own width — three footprints and two gaps. Read by the mount, which positions
    /// the cluster by its LEADING edge and so has to know how wide it is to land its trailing one on
    /// the column's gutter.
    static let width = StatusDot.footprint * 3 + markGap * 2

    var body: some View {
        HStack(spacing: Self.markGap) {
            // `order`, never `active`: the slots are fixed, so a mark never changes place and the
            // cluster never changes width.
            ForEach(RailStatusRollup.order, id: \.self) { kind in
                mark(kind)
            }
        }
        // The band's control rung: hung from `bandControlInset`, one control tall, so the marks'
        // centres land on the same line as the traffic lights and the sidebar toggle.
        .frame(width: Self.width, height: Slate.Metric.heightControl)
        .padding(.top, Slate.Metric.bandControlInset)
    }

    /// One slot. Its hit area is the FULL BAND RUNG tall (`heightControl`) and one footprint wide —
    /// taller than the mark so the pointer does not have to find a 14pt square, but never wider, so
    /// the gap between two marks stays genuinely dead.
    @ViewBuilder
    private func mark(_ kind: RailStatusRollup.Kind) -> some View {
        let lit = active.contains(kind)
        if let style = RailStatusRollup.style(for: kind, active: lit) {
            StatusDotView(style: style)
                .frame(width: StatusDot.footprint, height: Slate.Metric.heightControl)
                .contentShape(.rect)
                .onTapGesture { onPick?(kind) }
                // An UNLIT slot is a legend entry, not a control: nothing to jump to, so it takes
                // no press and no hover.
                .allowsHitTesting(lit && onPick != nil)
                .help(RailStatusRollup.label(for: kind))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(RailStatusRollup.label(for: kind))
                .accessibilityAddTraits(lit ? .isButton : [])
                .accessibilityHidden(!lit)
        }
    }
}

/// WHERE the cluster stands — the window-level mount, and the ONE place ``RailStatusRollup`` is
/// hosted.
///
/// ⚠️ It moved OUT of ``NavigatorColumn`` on 2026-08-11 (user-directed: *"khi collapse thì 3 cái nút
/// trôi về cạnh nút collapse sidebar"*). Inside the column it simply left with the column, because
/// the split animates the item's width to zero — the marks vanished at exactly the moment the rail
/// under them stopped being readable, which is when an aggregate is worth most. It now hangs off the
/// window root beside ``WindowSidebarToggle`` and TRAVELS between two parking spots:
///
///  * **expanded** — trailing edge on the navigator's own gutter, i.e. flush with the search plate,
///    which is the alignment the previous round settled;
///  * **collapsed** — immediately right of the sidebar toggle, the only chrome left on that band.
///
/// ⚠️ This is NOT the pair-of-buttons mistake ``WindowSidebarToggle``'s header describes. That was
/// TWO views cross-faded at one x, and any drift between them read as a flicker. This is ONE view at
/// two positions, interpolated by `columnSlide` — the same curve the split animates the column's
/// width on, so the cluster and the column edge it was standing on move together.
///
/// ⚠️ It reads ``WorkspaceChromeState/navigatorWidth``, which changes on every frame of a divider
/// drag — so this view is a LEAF and must stay one. `RailStatusRollup` is a leaf for the store's
/// per-pane dicts; this is a leaf for the split's geometry. Two different volatile sources, the same
/// rule.
package struct RailStatusRollupMount: View {
    package let store: WorkspaceStore
    package let chrome: WorkspaceChromeState

    package init(store: WorkspaceStore, chrome: WorkspaceChromeState) {
        self.store = store
        self.chrome = chrome
    }

    /// ITS OWN memo, not the navigator's. The two views are siblings under the window root now, and
    /// a memo threaded down from there would put the structural row build in the ROOT's body — the
    /// one place ``RailRowsMemo`` exists to keep it out of. A second memo costs a structural-key
    /// compare per render and rebuilds only when the rail's shape actually changes, which is the
    /// same bargain the navigator already takes.
    @State private var rowsMemo = RailRowsMemo()

    /// Where the cluster parks while the navigator is COLLAPSED: one gap right of the sidebar
    /// toggle's plate, on the toggle's own leading measurement — so the two read as one row of
    /// chrome rather than as a button and a widget that happen to share a band.
    static let collapsedLead = Slate.Metric.windowControlsLead
        + Slate.Metric.plate
        + Slate.Metric.space2

    /// ⚠️ Where anything ELSE on that band may begin once the navigator is collapsed — the cluster's
    /// trailing edge plus one gap. ``SlateTitlebar`` reads this for the horizontal tab strip's
    /// leading inset, because the strip used to start at exactly ``collapsedLead`` (it was reserving
    /// the toggle's slot and nothing more) and the marks landed ON TOP of the first tab
    /// (user-reported 2026-08-11). The two constants have to be one sum, or the next control added
    /// to that band re-collides.
    static let collapsedTrailingEdge = collapsedLead + RailStatusMarks.width + Slate.Metric.space2

    /// The cluster's leading x for a given navigator width.
    ///
    /// Clamped at ``collapsedLead`` so a very narrow column can never slide the marks LEFT of the
    /// toggle and into the traffic lights — the split's own 220 floor makes that unreachable today,
    /// but the clamp is what keeps it unreachable if the floor ever moves.
    static func lead(collapsed: Bool, navigatorWidth: CGFloat) -> CGFloat {
        guard !collapsed else { return collapsedLead }
        let parked = navigatorWidth - RailStatusRollup.trailingInset - RailStatusMarks.width
        return Swift.max(collapsedLead, parked)
    }

    package var body: some View {
        let lead = Self.lead(
            collapsed: chrome.sidebarCollapsed,
            // Before the split view has reported a width there is nothing to park against, so the
            // design's own resting column stands in — which is what the divider will report anyway.
            navigatorWidth: chrome.navigatorWidth ?? Slate.Metric.sidebarWidth,
        )
        RailStatusRollup(store: store, rows: rowsMemo.rows(for: store))
            .padding(.leading, lead)
            .frame(height: Slate.Metric.titlebarHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⚠️ Animate ONLY on the collapse flag, never on `navigatorWidth`. A divider drag is
            // already a continuous gesture; animating it too would make the cluster lag the edge it
            // is supposed to be glued to. The collapse is the one discontinuous jump, and it takes
            // the split's own curve so the two arrive together.
            .animation(Slate.Anim.columnSlide, value: chrome.sidebarCollapsed)
    }
}
#endif

#endif
