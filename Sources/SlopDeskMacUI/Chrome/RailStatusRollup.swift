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
// ⚠️ EACH MARK IS ITS OWN BUTTON, jumping into that state's OWN panes (``RailStatusRollupMount``'s
// `jump`). It shipped as one tap target calling the attention walk, which ranks needs-permission
// first — so clicking the spinner or the check silently landed on the blocked pane (user-reported).
// Three marks that all do one thing are one button wearing three faces.
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
// ⚠️ THE DERIVATION MUST STAY IN A LEAF. Resolving each row's chrome touches the store's volatile
// per-pane dicts, and reading the split's live column width touches a value that changes on every
// frame of a divider drag. Both happen in ``RailStatusRollupMount/refresh()`` and nowhere above it —
// which is the same rule the SwiftUI shape enforced by making the rollup a leaf VIEW, restated as
// the AppKit one: one ``ObservationFollow``, scoped to exactly what this cluster draws by,
// so nothing else in the window re-runs because a pane started thinking.
//
// WHY IT LIVES IN `SlopDeskMacUI` (docs/56 increment 36). It hangs off the TITLEBAR — beside the
// traffic lights, on the sidebar toggle's own band, parked against the navigator column's gutter.
// Every one of those is a macOS window's furniture, and there is nothing under this file the phone
// is missing: the capability it wraps is the PER-STATE jump — three marks each landing in its own
// state's panes — which both shells reach through the same store ops. This is the SAME feature laid
// out for a window, which is exactly the split the two shells are for.
//
// ⚠️ This paragraph used to cite ``WorkspaceStore/jumpToOldestAttentionPane()`` as the parity story,
// which is the ONE tap target the second cut above replaced after a user report: the attention walk
// ranks needs-permission first, so it silently landed on the blocked pane whichever mark was clicked.
// The rollup has not called it since; a header that named it as the shared capability was describing
// a version of this file that no longer exists.
//
// ⚠️ NOTHING HERE IS SwiftUI ANY MORE, and the last four things to go were a WRAPPER, a SEAM, a
// PLACE and a TRAVEL rather than a drawing. The marks crossed first (docs/56 stage D, kind 1's
// cheapest surface): ``MacRailStatusMarksView`` and its slots have been `NSView`s since then, and
// what stayed behind was `RailStatusRollup` (a `View` doing the derivation), `RailStatusMarks` (a
// `View` spending two modifiers on a rung and a width), `MarkCluster` (an `NSViewRepresentable`
// wrapping the AppKit cluster it already had) and `RailStatusRollupMount` (a `View` whose one job was
// a `.padding(.leading:)` and an `.animation`). All four are gone. What survives is what was
// underneath them the whole time: two namespaces of constants — ``RailStatusRollup`` and
// ``RailStatusMarks``, still the source of every number other files read — and two `NSView`s.
//
// The `.animation(Slate.Anim.columnSlide, value: chrome.sidebarCollapsed)` on the old mount became
// ``RailStatusRollupMount/travel(to:animated:)``, an `NSAnimationContext` on the SAME
// ``Slate/Motion/columnSlide`` rung the split animates its own column width on — which is what that
// modifier compiled down to and what the rest of this target already spells by hand
// (``MacTitlebarBand/travel(arriving:)``). The rung did not change; only who states it did.

import AppKit // the cluster and its slots are `NSView`s — see ``MacRailStatusMarksView``
import SlopDeskAgentDetect // ClaudeStatus — the raw agent status the working reading keys on
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The band's VOCABULARY and its DERIVATION — every pure function the three marks are resolved
/// through, and not one drawing.
///
/// A caseless enum rather than a view: it was a `struct … : View` only because the thing that mounted
/// it was one, and every member below except the deleted `body` was already `static`.
enum RailStatusRollup {
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
    static var disabledInk: SlateNativeColor {
        Slate.Native.Text.tertiary.withAlphaComponent(Slate.Opacity.dim)
    }

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
    /// gutter, the one ``NavigatorColumnViewController`` spends on both the search field's plate and
    /// the list of project islands. The band therefore ends on the same line every surface under it
    /// ends on.
    ///
    /// ⚠️ It was `space2 + projectIslandInset + islandRail` (the rows' mark column, 18pt further in)
    /// until 2026-08-11 — see this file's header for why that lost. The search plate reads THIS
    /// rather than spelling `8` again, so the band and the line it aligns to move together.
    static let trailingInset = Slate.Metric.space2

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

/// The cluster's own MEASUREMENTS, kept apart from the vocabulary because they are what the BAND
/// reads: ``MacTitlebarBand`` positions its tab strip past them and the mount positions the cluster
/// by them.
///
/// ⚠️ It was a `View` whose entire body was two modifiers — a `.frame(width:height:)` on the rung and
/// a `.padding(.top:)` — over an `NSViewRepresentable` over ``MacRailStatusMarksView``. The rung is a
/// constraint on the mount now and the width is the cluster's own `intrinsicContentSize`, so the view
/// and the seam are both deleted and what is left is the two numbers they were carrying.
enum RailStatusMarks {
    /// The gap between two marks. ⚠️ `space2`, not `space1` (user-reported 2026-08-11: "3 cái nút
    /// có vẻ hơi sát nhau"). At 4 the marks read as one object and — worse — two 14pt hit boxes 4pt
    /// apart is a target the pointer misses, which is how a click meant for the check landed on the
    /// hand. The hit boxes are the marks' own footprints, so the visual gap IS the dead zone.
    static let markGap = Slate.Metric.space2

    /// The cluster's own width — three footprints and two gaps. Read by the mount, which positions
    /// the cluster by its LEADING edge and so has to know how wide it is to land its trailing one on
    /// the column's gutter.
    static let width = StatusDot.footprint * 3 + markGap * 2
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
        // The mount constrains this view; it is no longer handed a frame by a representable.
        translatesAutoresizingMaskIntoConstraints = false
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

    /// Light `active`, and hand every slot the same click. Cheap enough to run on each refresh: a
    /// slot only repaints when its resolved ``StatusDotStyle`` actually changes
    /// (``MacStatusMarkView/style``), so a pass that lights nothing new costs three compares.
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

// MARK: - The mount

/// WHERE the cluster stands — the window-level mount, and the ONE place the rollup is drawn.
///
/// ⚠️ It moved OUT of ``MacNavigatorColumn`` on 2026-08-11 (user-directed: *"khi collapse thì 3 cái
/// nút trôi về cạnh nút collapse sidebar"*). Inside the column it simply left with the column, because
/// the split animates the item's width to zero — the marks vanished at exactly the moment the rail
/// under them stopped being readable, which is when an aggregate is worth most. It hangs off the
/// window's content view beside ``MacWindowSidebarToggleView`` and TRAVELS between two parking spots:
///
///  * **expanded** — trailing edge on the navigator's own gutter, i.e. flush with the search plate,
///    which is the alignment the previous round settled;
///  * **collapsed** — immediately right of the sidebar toggle, the only chrome left on that band.
///
/// ⚠️ This is NOT the pair-of-buttons mistake ``MacWindowSidebarToggleView``'s header describes. That
/// was TWO views cross-faded at one x, and any drift between them read as a flicker. This is ONE view
/// at two positions, interpolated by `columnSlide` — the same curve the split animates the column's
/// width on, so the cluster and the column edge it was standing on move together.
///
/// ⚠️ IT IS THE LEAF, and both of the volatile things it reads say why. ``WorkspaceChromeState/
/// navigatorWidth`` changes on every frame of a divider drag; the per-pane readings behind the marks
/// change on every agent tick. Both are read inside ``refresh()``'s one ``ObservationFollow`` and
/// nowhere else, so neither can wake anything above this view.
@MainActor
final class RailStatusRollupMount: NSView {
    /// THE COLUMN'S GUTTER, forwarded for the AppKit navigator (``MacNavigatorColumn``).
    ///
    /// The number is ``RailStatusRollup/trailingInset``'s and stays there — this is one name, not one
    /// more value. The navigator spends the same inset on its search plate and its island list, which
    /// is exactly why the band's marks, the field and the beds all close on one line; a column that
    /// picked its own would break that alignment silently.
    static var columnGutter: CGFloat { RailStatusRollup.trailingInset }

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

    private let store: WorkspaceStore
    private let chrome: WorkspaceChromeState
    private let cluster = MacRailStatusMarksView()

    /// ITS OWN memo, not the navigator's. The two views are siblings under the window's content view,
    /// and a memo threaded down from there would put the structural row build in the WINDOW's layout
    /// path — the one place ``RailRowsMemo`` exists to keep it out of. A second memo costs a
    /// structural-key compare per refresh and rebuilds only when the rail's shape actually changes,
    /// which is the same bargain the navigator already takes.
    ///
    /// ⚠️ `private let`, which is the house AppKit spelling (``MacTabStrip``) — it was `@State`
    /// because a SwiftUI view struct is rebuilt on every render and could not otherwise keep the
    /// cache alive. An `NSView` is built once, so ownership says the same thing without the wrapper.
    private let rowsMemo = RailRowsMemo()

    /// The cluster's leading constraint — the ONE thing the travel moves.
    private var leading: NSLayoutConstraint?
    /// The last collapse state actually travelled to, so the travel animates on the DISCONTINUOUS
    /// jump only. A divider drag re-runs `refresh()` on every frame and must land instantly: see
    /// ``travel(to:animated:)``.
    private var collapsed: Bool?

    init(store: WorkspaceStore, chrome: WorkspaceChromeState) {
        self.store = store
        self.chrome = chrome
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Scaffolding: the cluster below is the accessibility element, and this container must not
        // stand beside it in the tree as a second, nameless one.
        setAccessibilityElement(false)
        addSubview(cluster)
        let leading = cluster.leadingAnchor.constraint(equalTo: leadingAnchor)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            // The band's control rung: hung from `bandControlInset`, one control tall, so the marks'
            // centres land on the same line as the traffic lights and the sidebar toggle. These two
            // were the deleted `RailStatusMarks` view's `.padding(.top:)` and `.frame(height:)`.
            cluster.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.bandControlInset),
            cluster.heightAnchor.constraint(equalToConstant: Slate.Metric.heightControl),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The mount is a strip across the band's full width; the cluster inside it is what is one rung
    /// tall. Height only — the width is the window's.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Slate.Metric.titlebarHeight)
    }

    /// ⚠️ THE STRIP ITSELF TAKES NO HITS. It spans the whole band so the cluster can slide across it,
    /// and a container that wide would otherwise swallow every click meant for the titlebar under it
    /// — including the window drag. Only the slots answer, and an unlit one refuses too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // MARK: The reading

    /// Resolve the three marks and the cluster's parking spot, and re-arm.
    ///
    /// This is the deleted `RailStatusRollup.body` and the deleted mount's body, joined — which is
    /// correct rather than convenient: they were two views only because the outer one owned the memo
    /// and the inner one owned the volatile reads, and both are this object's now. Everything the
    /// tracked block touches is something the cluster's picture depends on, and nothing else in the
    /// window observes any of it.
    private func refresh() {
        ObservationFollow.arm(self) { mount in
            // The flash-decay tick, observed at CLUSTER scope exactly as a navigator row observes it:
            // a clean completion's badge decays off the wall clock, not off an `@Observable`
            // dependency, so without this the done mark would outlive the row's own.
            _ = mount.store.completionFlashTick
            let rows = mount.rowsMemo.rows(for: mount.store)
            // The BATCH entry, because this walk has the whole array in hand: the per-row one re-reads
            // `commandBadgeGates` and `agentBadgeGates` — six `UserDefaults` bools at 305 ns each —
            // and re-resolves the active session's tab list, once per row, for settings that cannot
            // change while a cluster draws.
            let sightings = zip(rows, RailRowsBuilder.liveChrome(for: rows, store: mount.store))
                .map { row, chrome in
                    (
                        pane: row.id,
                        reading: RailStatusRollup.Reading(
                            status: chrome.status, badge: chrome.badge,
                            unseenDone: mount.store.paneUnseenDone.contains(row.id),
                        ),
                    )
                }
            var panesByKind: [RailStatusRollup.Kind: [PaneID]] = [:]
            for kind in RailStatusRollup.order {
                panesByKind[kind] = sightings
                    .filter { RailStatusRollup.matches(kind, $0.reading) }
                    .map(\.pane)
            }
            let wantsCollapsed = mount.chrome.sidebarCollapsed
            return (
                active: RailStatusRollup.kinds(sightings.map(\.reading)),
                panesByKind: panesByKind,
                wantsCollapsed: wantsCollapsed,
                lead: Self.lead(
                    collapsed: wantsCollapsed,
                    // Before the split view has reported a width there is nothing to park against, so
                    // the design's own resting column stands in — which is what the divider will
                    // report anyway.
                    navigatorWidth: mount.chrome.navigatorWidth ?? Slate.Metric.sidebarWidth,
                ),
            )
        } apply: { mount, reading in
            // ⚠️ ONE call into the cluster, never two setters. The lit set and the click both decide
            // whether a slot takes a press, so applying them separately leaves a window in which a mark
            // is already lit and still inert, or the reverse. (This was the deleted representable's
            // single `updateNSView`, and the reason it was single.)
            mount.cluster.apply(active: reading.active) { [weak mount] kind in
                mount?.jump(kind, panes: reading.panesByKind[kind] ?? [])
            }
            // ⚠️ NO cross-fade on the MARKS, and that is not an omission.
            // `.animation(Slate.Anim.smallFade, value: kinds)` used to fade a slot's hue between
            // ``RailStatusRollup/disabledInk`` and the state's own; the AppKit alternative — a
            // `CATransition` over the mark's layer CONTENTS — would smear the working slot, which
            // repaints at display-link rate and would ride the transition for every tick inside its
            // duration. The rows and the tab chips have always taken the straight step for exactly
            // these marks; the band matches them.
            mount.travel(
                to: reading.lead,
                animated: mount.collapsed != nil && mount.collapsed != reading.wantsCollapsed,
            )
            mount.collapsed = reading.wantsCollapsed
        }
    }

    /// Slide the cluster to `lead`.
    ///
    /// ⚠️ ANIMATED ONLY ON THE COLLAPSE FLAG, never on a width change — the old mount said this with
    /// `.animation(_:value: chrome.sidebarCollapsed)` and it means the same thing here. A divider drag
    /// is already a continuous gesture; animating it too would make the cluster lag the edge it is
    /// supposed to be glued to. The collapse is the one discontinuous jump, and it takes the split's
    /// own ``Slate/Motion/columnSlide`` curve so the two arrive together.
    private func travel(to lead: CGFloat, animated: Bool) {
        guard let leading, leading.constant != lead else { return }
        guard animated else {
            leading.constant = lead
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.columnSlide.duration
            context.timingFunction = Slate.Motion.columnSlide.timingFunction
            leading.animator().constant = lead
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
    private func jump(_ kind: RailStatusRollup.Kind, panes: [PaneID]) {
        let focused = store.tree.activeSession?.activeTab?.activePane
        guard let target = RailStatusRollup.nextPane(in: panes, focused: focused) else { return }
        if kind != .working { store.clearAgentBadge(target) }
        store.jumpToPaneTree(target)
    }
}
