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
// body and bring back the re-render storm ``RailRowsMemo`` exists to kill (the same rule the
// connection island carries, which is why its telemetry is read at ITS leaf and not in whatever
// mounts it). The rows arrive as a STRUCTURAL parameter (the memo's array);
// only the volatile reads happen in here. Its mount is a leaf for the same reason against a
// DIFFERENT volatile source — the split's live column width.
//
// WHY IT LIVES IN `SlopDeskMacUI` (docs/56 increment 36). It hangs off the TITLEBAR — beside the
// traffic lights, on the sidebar toggle's own band, parked against the navigator column's gutter.
// Every one of those is a macOS window's furniture, and there is nothing under this file the phone
// is missing: the capability it wraps is the PER-STATE jump — ``jump(_:panes:)``, three marks each
// landing in its own state's panes — which both shells reach through the same store ops. This is the
// SAME feature laid out for a window, which is exactly the split the two shells are for. It arrived
// here as SwiftUI hosted by ``MacTitlebarBand``; when that mount becomes AppKit this file goes with it.
//
// ⚠️ This paragraph used to cite ``WorkspaceStore/jumpToOldestAttentionPane()`` as the parity story,
// which is the ONE tap target the second cut above replaced after a user report: the attention walk
// ranks needs-permission first, so it silently landed on the blocked pane whichever mark was clicked.
// The rollup has not called it since; a header that named it as the shared capability was describing
// a version of this file that no longer exists.
//
// ⚠️ THE MARKS ARE ALREADY APPKIT (docs/56 stage D, kind 1's cheapest surface). What is still SwiftUI
// in this file is the derivation above and the cluster's PLACE on the band — the rung it hangs from
// and the width the mount positions by — because the mount itself is still SwiftUI, and geometry that
// has to agree across a hosting boundary belongs on the boundary's own side. Nothing under
// ``RailStatusMarks`` is painted by SwiftUI any more: the three marks are ``MacStatusMarkView``s
// inside ``MacRailStatusMarksView``, the SAME renderer the navigator's rows and the band's tab chips
// mount. That is what deleted this file's `SlopDeskClientUI` import — it existed for `StatusDotView`
// and for nothing else, and it was the last thing `SlopDeskMacUI` took from the phone's half of the
// mark. The values did not move: ``style(for:active:)`` and ``label(for:)`` below are still the one
// source of what a slot draws and what it says.

import AppKit // the cluster and its slots are `NSView`s — see ``MacRailStatusMarksView``
import SlopDeskAgentDetect // ClaudeStatus — the raw agent status the working reading keys on
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

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
        // The flash-decay tick, observed at CLUSTER scope exactly as a navigator row observes it:
        // a clean completion's badge decays off the wall clock, not off an `@Observable` dependency,
        // so without this the done mark would outlive the row's own.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        // The BATCH entry, because this walk has the whole array in hand: the per-row one re-reads
        // `commandBadgeGates` and `agentBadgeGates` — six `UserDefaults` bools at 305 ns each — and
        // re-resolves the active session's tab list, once per row, for settings that cannot change
        // while a cluster draws.
        let sightings = zip(rows, RailRowsBuilder.liveChrome(for: rows, store: store)).map { row, chrome in
            (
                pane: row.id,
                reading: Reading(
                    status: chrome.status, badge: chrome.badge,
                    unseenDone: store.paneUnseenDone.contains(row.id),
                ),
            )
        }
        let kinds = Self.kinds(sightings.map(\.reading))
        // ⚠️ NO `.help` and NO `.animation` here any more, and neither is an omission.
        //  * The cluster's SUMMARY tooltip moved INSIDE (``MacRailStatusMarksView``), because a
        //    SwiftUI `.help` wrapped around a hosted `NSView` is a tooltip rect the AppKit tooltip
        //    manager resolves against the deepest view under the pointer — which is now always one
        //    of the marks or their own container, never the SwiftUI layer above them. It is set on
        //    the same value (``summary(_:)``) at the same scope; only the framework changed.
        //  * `.animation(Slate.Anim.smallFade, value: kinds)` used to cross-fade a slot's hue
        //    between ``disabledInk`` and the state's own. A SwiftUI animation cannot reach inside a
        //    representable, and the AppKit alternative — a `CATransition` over the mark's layer
        //    CONTENTS — would smear the working slot, which repaints at display-link rate and would
        //    ride the transition for every tick inside its duration. The rows and the tab chips have
        //    always taken the straight step for exactly these marks; the band now matches them
        //    instead of being the one surface that fades.
        RailStatusMarks(active: kinds) { kind in
            jump(kind, panes: sightings.filter { Self.matches(kind, $0.reading) }.map(\.pane))
        }
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
/// input). A lit working mark keeps its own wall-clock phase, an unlit one is frozen.
///
/// ⚠️ WHAT IS LEFT IN SWIFTUI HERE IS THE CLUSTER'S PLACE, not its picture: the band's control rung
/// and the width ``RailStatusRollupMount`` positions by, which are read on both sides of the hosting
/// boundary and so are spelled on the SwiftUI side of it. Everything inside that box — the three
/// marks, their hit boxes, the tooltips and what VoiceOver hears — is ``MacRailStatusMarksView``.
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
        MarkCluster(active: active, onPick: onPick)
            // The band's control rung: hung from `bandControlInset`, one control tall, so the marks'
            // centres land on the same line as the traffic lights and the sidebar toggle.
            .frame(width: Self.width, height: Slate.Metric.heightControl)
            .padding(.top, Slate.Metric.bandControlInset)
    }
}

/// THE HOSTING SEAM, and nothing else: no geometry, no state, no decision. It exists because
/// ``RailStatusRollupMount`` is still SwiftUI; when that mount becomes AppKit this type disappears
/// and the window hands ``MacRailStatusMarksView`` straight to its band.
private struct MarkCluster: NSViewRepresentable {
    let active: [RailStatusRollup.Kind]
    let onPick: ((RailStatusRollup.Kind) -> Void)?

    func makeNSView(context _: Context) -> MacRailStatusMarksView { MacRailStatusMarksView() }

    /// ONE call, never two setters. The lit set and the click both decide whether a slot takes a
    /// press, so applying them separately leaves a window — one `updateNSView` wide — in which a
    /// mark is already lit and still inert, or the reverse.
    func updateNSView(_ view: MacRailStatusMarksView, context _: Context) {
        view.apply(active: active, onPick: onPick)
    }
}

// MARK: - The cluster, in AppKit

/// The three fixed slots, one ``RailStatusMarks/markGap`` apart, on the band's control rung.
///
/// ⚠️ IT SPEAKS FOR THE WHOLE BAND, and its slots speak for themselves. The cluster carries
/// ``RailStatusRollup/summary(_:)`` — the resting phrase included, which is why a band with nothing
/// lit is not silent — and a LIT slot overrides it with its own state's name. An UNLIT slot refuses
/// the hit entirely (``MacRailStatusMarkSlot/hitTest(_:)``), so the pointer falls through to the
/// cluster and reads the summary there: the legend entry never pretends to be a control, and the
/// dead gap between two marks answers the same way the dead slots do.
@MainActor
final class MacRailStatusMarksView: NSView {
    private let slots: [MacRailStatusMarkSlot]

    init() {
        // `order`, never the lit set: the slots are fixed, so a mark never changes place and the
        // cluster never changes width. Built once, in that order, and only ever re-inked.
        slots = RailStatusRollup.order.map { MacRailStatusMarkSlot(kind: $0) }
        super.init(frame: .zero)
        for (index, slot) in slots.enumerated() {
            addSubview(slot)
            NSLayoutConstraint.activate([
                // The FULL BAND RUNG tall — taller than the 14pt mark so the pointer does not have
                // to find a 14pt square. The WIDTH is the slot's own business and is exactly one
                // footprint, which is what keeps the gap between two marks genuinely dead.
                slot.topAnchor.constraint(equalTo: topAnchor),
                slot.bottomAnchor.constraint(equalTo: bottomAnchor),
                index == 0
                    ? slot.leadingAnchor.constraint(equalTo: leadingAnchor)
                    : slot.leadingAnchor.constraint(
                        equalTo: slots[index - 1].trailingAnchor, constant: RailStatusMarks.markGap,
                    ),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(active: [], onPick: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: RailStatusMarks.width, height: Slate.Metric.heightControl)
    }

    /// Light `active`, and hand every slot the same click. Cheap enough to run on each
    /// `updateNSView`: a slot only repaints when its resolved ``StatusDotStyle`` actually changes
    /// (``MacStatusMarkView/style``), so a render pass that lights nothing new costs three compares.
    func apply(active: [RailStatusRollup.Kind], onPick: ((RailStatusRollup.Kind) -> Void)?) {
        for slot in slots {
            slot.apply(lit: active.contains(slot.kind), onPick: onPick)
        }
        let summary = RailStatusRollup.summary(active)
        toolTip = summary
        setAccessibilityLabel(summary)
    }
}

/// ONE slot: a mark centred in a hit box that is one ``StatusDot/footprint`` wide and one band rung
/// tall, lit or not.
///
/// ⚠️ AN UNLIT SLOT IS A LEGEND ENTRY, NOT A CONTROL. It keeps its silhouette (that is the whole
/// point of a fixed slot) and gives up everything a control has: no press, no hover, no tooltip of
/// its own, and nothing in the accessibility tree — because a mark that is not lit has no panes to
/// jump to, and an element that announces itself as a button and then does nothing is worse than one
/// that is not there. All three of those follow from the single refusal in ``hitTest(_:)``.
@MainActor
private final class MacRailStatusMarkSlot: NSView {
    let kind: RailStatusRollup.Kind

    private let mark = MacStatusMarkView()
    private var lit = false
    private var onPick: ((RailStatusRollup.Kind) -> Void)?

    init(kind: RailStatusRollup.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            // NEVER wider than the mark it holds — see the cluster's note on the dead gap.
            widthAnchor.constraint(equalToConstant: StatusDot.footprint),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The state's spoken name, in BOTH registers, from the one function that answers it — the
        // tooltip and VoiceOver can therefore never disagree about what this mark means.
        toolTip = RailStatusRollup.label(for: kind)
        setAccessibilityLabel(RailStatusRollup.label(for: kind))
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    func apply(lit: Bool, onPick: ((RailStatusRollup.Kind) -> Void)?) {
        self.lit = lit
        self.onPick = onPick
        mark.style = RailStatusRollup.style(for: kind, active: lit)
        setAccessibilityElement(lit)
    }

    // MARK: The refusal

    /// ⚠️ `self` OR NOTHING — never `super.hitTest`, which would hand the event to the
    /// ``MacStatusMarkView`` inside and lose the click, since that view is a drawing and has no
    /// action. Returning `nil` for an unlit slot (or for the snapshot rig's `onPick == nil`) is what
    /// makes the legend entry inert down to the tooltip: AppKit resolves both the press and the tip
    /// against the deepest view that accepts the point, so one refusal covers both.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard lit, onPick != nil else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// Swallowed so the slot stays the click's owner and ``mouseUp(with:)`` is delivered here — an
    /// unhandled `mouseDown` walks up the responder chain and the release never comes back.
    override func mouseDown(with _: NSEvent) {}

    /// The jump fires on RELEASE INSIDE, which is the tap gesture this slot replaced and the one
    /// every other control on this band keeps: a press that slides off the mark is a change of mind.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick?(kind)
    }

    override func accessibilityPerformPress() -> Bool {
        guard lit, let onPick else { return false }
        onPick(kind)
        return true
    }
}

/// WHERE the cluster stands — the window-level mount, and the ONE place ``RailStatusRollup`` is
/// hosted.
///
/// ⚠️ It moved OUT of ``NavigatorColumn`` on 2026-08-11 (user-directed: *"khi collapse thì 3 cái nút
/// trôi về cạnh nút collapse sidebar"*). Inside the column it simply left with the column, because
/// the split animates the item's width to zero — the marks vanished at exactly the moment the rail
/// under them stopped being readable, which is when an aggregate is worth most. It now hangs off the
/// window root beside ``MacWindowSidebarToggle`` and TRAVELS between two parking spots:
///
///  * **expanded** — trailing edge on the navigator's own gutter, i.e. flush with the search plate,
///    which is the alignment the previous round settled;
///  * **collapsed** — immediately right of the sidebar toggle, the only chrome left on that band.
///
/// ⚠️ This is NOT the pair-of-buttons mistake ``MacWindowSidebarToggle``'s header describes. That was
/// TWO views cross-faded at one x, and any drift between them read as a flicker. This is ONE view at
/// two positions, interpolated by `columnSlide` — the same curve the split animates the column's
/// width on, so the cluster and the column edge it was standing on move together.
///
/// ⚠️ It reads ``WorkspaceChromeState/navigatorWidth``, which changes on every frame of a divider
/// drag — so this view is a LEAF and must stay one. `RailStatusRollup` is a leaf for the store's
/// per-pane dicts; this is a leaf for the split's geometry. Two different volatile sources, the same
/// rule.
struct RailStatusRollupMount: View {
    let store: WorkspaceStore
    let chrome: WorkspaceChromeState

    init(store: WorkspaceStore, chrome: WorkspaceChromeState) {
        self.store = store
        self.chrome = chrome
    }

    /// THE COLUMN'S GUTTER, forwarded for the AppKit navigator (``MacNavigatorColumn``).
    ///
    /// The number is ``RailStatusRollup/trailingInset``'s and stays there — this is one name, not one
    /// more value. The navigator spends the same inset on its search plate and its island list, which
    /// is exactly why the band's marks, the field and the beds all close on one line; a column that
    /// picked its own would break that alignment silently.
    static var columnGutter: CGFloat { RailStatusRollup.trailingInset }

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
    /// trailing edge plus one gap. ``MacTitlebarBand`` reads this for the horizontal tab
    /// strip's leading inset, because the strip used to start at exactly ``collapsedLead`` (it was
    /// reserving the toggle's slot and nothing more) and the marks landed ON TOP of the first tab
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

    var body: some View {
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
