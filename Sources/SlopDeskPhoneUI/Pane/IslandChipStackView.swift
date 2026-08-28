// IslandChipStackView — the transient + durable chips that stand at the FOOT OF THE CANVAS, in UIKit
// (docs/62 stage E).
//
// These three used to hang off the window root, which put them at the bottom centre of the WINDOW — a
// point that includes the navigator and the code panel, so the stack drifted off the terminal it was
// talking about, and its window inset parked it on the canvas's bottom edge, over the live prompt line
// (user-reported 2026-08-09). Mounted on the pane canvas instead, the stack is centred on the PANES and
// stands clear of their foot; ``Slate/Metric/islandChipInset`` is the whole of that clearance, and on
// this platform it is measured from the SAFE AREA rather than from the raw bottom edge — see
// ``PaneCanvasView``, which owns the constraint.
//
// ⚠️ THE TWO TRANSIENT CHIPS ARE PAPER; THE DURABLE ONE IS GLASS, and the line between them is DURATION.
// A notice ARRIVES and leaves — it is a message from the app, so it wears the floating family's paper
// capsule (``SlatePaperCapsuleView``, which carries the measurements and the polarity override). The
// connection chip LIVES here for as long as a pane is unhealthy, and a cream plate glowing over the
// terminal for minutes is the glare the transient pair is small and short-lived enough to avoid — so it
// stays in the glass's own vocabulary, where a persistent object belongs.
//
// THREE THINGS THE SWIFTUI STACK GOT FROM MODIFIERS AND THIS FILE HAS TO STATE:
//
//   1. THE HIT-TRANSPARENCY IS PER CHIP, NEVER ON THE STACK. `isUserInteractionEnabled = false` on the
//      stack deafens everything inside it, so a flag here would also silence the connection chip's tap.
//      And the opposite mistake is just as real in UIKit as in AppKit: a container that hit-tests to
//      ITSELF swallows every touch inside its bounds even where no chip is drawn — which over a terminal
//      is a dead rectangle at the prompt. So the stack answers `nil` for itself, each paper capsule
//      refuses touches, and only the alert chip takes one.
//   2. THE DWELL IS A TIMER, not a `.task(id:)`. Keyed on the WHOLE value (the receipt, the notice's
//      epoch): a hand-off between the two receipt owners can carry the same epoch, and a cancelled sleep
//      must never expire, or the successor's dwell dies with its predecessor's.
//   3. THE FADE IS EXPLICIT. `.transition(.opacity)` + `.animation(_:value:)` became one
//      opacity-and-remove helper, because UIKit has no render pass to notice the difference.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

// MARK: - The stack

@MainActor
final class IslandChipStackView: UIStackView {
    private let store: WorkspaceStore
    /// The scene overlay reducer — owns the window-level copy receipt + the transient notice. `nil`
    /// (previews) leaves the stack with the connection chip alone.
    private let coordinator: OverlayCoordinator?
    private let chrome: WorkspaceChromeState?

    private var receiptChip: PaneNoticeChipView?
    private var noticeChip: PaneNoticeChipView?
    private var alertChip: ConnectionAlertChipView?

    private var generation = 0

    init(store: WorkspaceStore, coordinator: OverlayCoordinator?, chrome: WorkspaceChromeState?) {
        self.store = store
        self.coordinator = coordinator
        self.chrome = chrome
        super.init(frame: .zero)
        axis = .vertical
        alignment = .center
        spacing = Slate.Metric.space2
        translatesAutoresizingMaskIntoConstraints = false
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// See the header's point 1: everywhere the stack is not a CHIP it is not there at all.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: The live read

    /// ONE tracked pass over everything the three chips turn on.
    ///
    /// Reading `store.connectionAlert()` registers observation on each pane's connection status, so the
    /// durable chip appears, re-counts and disappears as panes drop and recover.
    ///
    /// THE COPY RECEIPT is whichever of the two owners has one (user-directed 2026-08-11): pane-scoped
    /// copies publish on the active pane's model and pane-less ones (palette "Copy Path") on the
    /// coordinator, but both surface HERE. The coordinator wins a tie because it is the later, more
    /// deliberate act — a pane-less copy is an explicit palette command, while a pane receipt may be
    /// seconds-stale.
    private func follow() {
        generation &+= 1
        let generation = generation

        var receipt: CopyReceipt?
        var notice: ChipNotice?
        var alert: WorkspaceConnectionAlert?

        withObservationTracking {
            receipt = coordinator?.copyReceipt ?? store.activePaneCopyReceipt()
            notice = coordinator?.notice
            // The durable indicator shows ONLY with the tabs panel collapsed — an open sidebar is the
            // user's normal per-pane surface, and the chip would be saying it twice.
            alert = chrome?.sidebarCollapsed == true ? store.connectionAlert() : nil
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }

        applyReceipt(receipt)
        applyNotice(notice)
        applyAlert(alert)
    }

    private func applyReceipt(_ receipt: CopyReceipt?) {
        guard let receipt else {
            // Stopped BEFORE the fade, not in a `deinit`: the chip outlives this call by the length of
            // the fade, and a timer that fires in that window would clear an owner that has already
            // published its successor.
            receiptChip?.stopDwell()
            ChipFade.remove(receiptChip, from: self)
            receiptChip = nil
            return
        }
        let chip = receiptChip ?? {
            let made = PaneNoticeChipView()
            receiptChip = made
            ChipFade.insert(made, into: self, at: 0)
            return made
        }()
        // Keyed on the WHOLE receipt, not on `epoch` alone: the single mount is fed by two independent
        // counters, so two different copies can carry the same epoch and the chip would inherit the dead
        // one's nearly-elapsed timer — the exact bug epoch exists to prevent, arriving by a new route.
        // `CopyReceipt` is `Equatable` over its counts too, so a hand-off only fails to restart when the
        // two receipts are indistinguishable, where restarting would change nothing.
        chip.present(
            label: "Copied", keycap: nil, detail: receipt.detail, accessibility: receipt.label,
            identity: AnyHashable(receipt), dwell: CopyReceipt.dwell,
        ) { [weak self] in self?.clearCopyReceipt() }
    }

    private func applyNotice(_ notice: ChipNotice?) {
        guard let notice else {
            noticeChip?.stopDwell()
            ChipFade.remove(noticeChip, from: self)
            noticeChip = nil
            return
        }
        let chip = noticeChip ?? {
            let made = PaneNoticeChipView()
            noticeChip = made
            ChipFade.insert(made, into: self, at: receiptChip == nil ? 0 : 1)
            return made
        }()
        chip.present(
            label: notice.label, keycap: notice.keycap, detail: notice.detail,
            accessibility: notice.accessibilityText, identity: AnyHashable(notice.epoch),
            dwell: notice.dwell,
        ) { [weak self] in self?.coordinator?.clearNotice() }
    }

    private func applyAlert(_ alert: WorkspaceConnectionAlert?) {
        guard let alert else {
            ChipFade.remove(alertChip, from: self)
            alertChip = nil
            return
        }
        let chip = alertChip ?? {
            let made = ConnectionAlertChipView()
            alertChip = made
            // ALWAYS LAST: the durable member stands at the foot of the column, under whatever transient
            // chip is passing through above it.
            ChipFade.insert(made, into: self, at: arrangedSubviews.count)
            return made
        }()
        chip.present(alert) { [weak self] in self?.store.jumpToPaneTree(alert.worstPane) }
    }

    /// Expiry clears BOTH owners. Each is idempotent and only one can be non-nil at a time in practice,
    /// so this cannot strand a receipt the other owner still wants shown — while clearing only the winner
    /// would leave the loser's stale receipt to pop straight back the moment the chip faded out.
    private func clearCopyReceipt() {
        coordinator?.clearCopyReceipt()
        store.clearActivePaneCopyReceipt()
    }

    /// Every dwell stopped and every chip dropped. Called when the canvas around it comes down, so no
    /// timer outlives the scene holding it.
    func teardown() {
        generation &+= 1
        for chip in [receiptChip, noticeChip] { chip?.stopDwell() }
        for chip in arrangedSubviews {
            removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        receiptChip = nil
        noticeChip = nil
        alertChip = nil
    }
}

// MARK: - The fade

/// The one arrive/leave the stack's members share — `.transition(.opacity)` plus the family's short
/// curve, stated because UIKit has no render pass to infer it from.
///
/// A LEAVING chip is removed in the completion, never before: removing it first would collapse the stack
/// in one frame and animate a view that is no longer in it.
///
/// `layer.opacity` under a `CATransaction` rather than `UIView.animate`, for the reason ``PaneFade``
/// records: the animation block can carry this rung's duration but not its bezier.
@MainActor
private enum ChipFade {
    static func insert(_ view: UIView, into stack: UIStackView, at index: Int) {
        view.layer.opacity = 0
        stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        stack.layoutIfNeeded()
        PaneFade.set(view, shown: true, curve: Slate.Motion.smallFade)
    }

    static func remove(_ view: UIView?, from stack: UIStackView) {
        guard let view, view.superview === stack else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
        CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        CATransaction.setCompletionBlock {
            // Core Animation runs a transaction's completion on the main thread without saying so in
            // the type.
            MainActor.assumeIsolated {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        view.layer.opacity = 0
        CATransaction.commit()
    }
}

// MARK: - The paper capsule (both transient chips)

/// `label · detail` on the floating family's paper capsule — the single view behind BOTH transient chips,
/// so the copy receipt and every notice can never drift apart in type, ink, spacing or surface.
///
/// THE SURFACE IS NOT REBUILT HERE. ``SlatePaperCapsuleView`` already owns the capsule's inset, its
/// `overrideUserInterfaceStyle` (this is the one paper surface mounted inside a subtree the glass has
/// forced dark, so its ink has to climb back OUT), its rim, its cast and its `shadowPath`. What this view
/// adds is the ROW and the dwell — the two things that are about a NOTICE rather than about a capsule.
/// `MacNoticeCapsuleView` spells the surface out because AppKit's side has no such component; copying its
/// body across would have minted the second one.
///
/// HIERARCHY IS SIZE AND WEIGHT IN ONE VOICE, never ink alone. The DETAIL is the dominant half in every
/// notice this family carries: the count is what answers "did I get the whole thing?", the chord is what
/// answers "how do I undo that?". The label is the frame around the answer, so it takes the quieter rung.
@MainActor
final class PaneNoticeChipView: UIView {
    private let labelView = UILabel()
    private let separator = UILabel()
    private let detailView = UILabel()
    private let keycap = SlateKeycapView(label: "")
    private let row = UIStackView()
    private let capsule: SlatePaperCapsuleView

    /// What is on screen now, so a re-apply that changes nothing does not restart a running dwell.
    private var identity: AnyHashable?
    private var dwellTimer: Timer?
    /// Held rather than captured: a `Timer` block is `@Sendable`, and a bare closure is not `Sendable`
    /// even when this `@MainActor` class is. Reaching it back through `self` is what keeps the obligation
    /// where it belongs.
    private var onExpire: () -> Void = {}

    init() {
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        capsule = SlatePaperCapsuleView(content: row)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Hit-transparent, per the file header's point 1: this chip has nothing to press, and a rectangle
        // of dead touch over the prompt line is what the deleted half's `allowsHitTesting(false)` bought.
        isUserInteractionEnabled = false

        for label in [labelView, separator, detailView] {
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
        }
        labelView.font = .systemFont(ofSize: Slate.Typeface.base)
        labelView.textColor = Slate.Native.Overlay.secondary
        separator.text = "·"
        separator.font = .systemFont(ofSize: Slate.Typeface.base)
        separator.textColor = Slate.Native.Overlay.tertiary
        for view in [labelView, keycap, separator, detailView] { row.addArrangedSubview(view) }

        addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Re-targets the chip and restarts its dwell when `identity` changed; a re-apply carrying the same
    /// identity leaves the running clock alone.
    func present(
        label: String,
        keycap chord: String?,
        detail: String,
        accessibility: String,
        identity: AnyHashable,
        dwell: Duration,
        onExpire: @escaping () -> Void,
    ) {
        labelView.text = label
        keycap.text = chord
        keycap.isHidden = chord == nil
        detailView.text = detail
        detailView.isHidden = detail.isEmpty
        // The dot appears ONLY without a cap — a keycap is its own boundary object, so a dot beside one
        // is a second separator doing the first one's job.
        separator.isHidden = chord != nil || detail.isEmpty
        // With a cap the emphasis has already been spent ON the cap, so the trailing verb drops to the
        // label's rung and the sentence has ONE hero. Without one, the detail IS the answer.
        detailView.font = .systemFont(
            ofSize: Slate.Typeface.base, weight: chord == nil ? .semibold : .regular,
        )
        detailView.textColor = chord == nil
            ? Slate.Native.Overlay.primary
            : Slate.Native.Overlay.secondary
        isAccessibilityElement = true
        accessibilityLabel = accessibility

        self.onExpire = onExpire
        guard identity != self.identity else { return }
        self.identity = identity
        restartDwell(dwell)
    }

    func stopDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    /// One shot, restarted per identity. A `Timer` rather than a `Task`, so a chip that is re-targeted
    /// mid-dwell cannot leave a cancelled sleep to fire the OLD owner's expiry — the failure the deleted
    /// SwiftUI half spent its `guard await (try? …) != nil` on.
    private func restartDwell(_ dwell: Duration) {
        stopDwell()
        let seconds = Double(dwell.components.seconds)
            + Double(dwell.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            // Foundation fires a scheduled timer on the main run loop without saying so in the type.
            MainActor.assumeIsolated { self?.onExpire() }
        }
    }
}

// MARK: - The durable connection chip

/// The compact connection-health chip: an amber/red status dot + a count label ("1 reconnecting" /
/// "2 disconnected"), shown at the canvas's foot while the tabs panel is collapsed and some pane is
/// unhealthy. Tappable — unlike the transient pair — so a tap focuses the worst-affected pane.
///
/// ONE SILHOUETTE, TWO MATERIALS. It shares the notice capsule's shape, size and rhythm — same capsule,
/// same padding, same type size — so the column reads as one family; it keeps the GLASS's own palette
/// because it is the DURABLE member. Matching the shape is what keeps that material difference reading as
/// a ROLE rather than as two unrelated chips stacked by accident.
///
/// ⚠️ Its label is ``Slate/Native/Terminal/ink``, not `ink2`. The comment ink measures 2.19 : 1 on this
/// plate — the very number that sent the transient chips to paper — and this chip carried it too,
/// unnoticed, while saying that a connection is DOWN. On the glass the primary ink is the only rung that
/// clears the plate (9.16 : 1), and a durable alarm has no excuse to whisper.
@MainActor
final class ConnectionAlertChipView: UIView {
    private let dot = ConnectionAlertDotView()
    private let label = UILabel()
    private var onTap: () -> Void = {}

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.borderWidth = Slate.Metric.hairline
        backgroundColor = Slate.Native.Terminal.raised

        label.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        label.textColor = Slate.Native.Terminal.ink
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space1
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        reink()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (chip: Self, _) in chip.reink() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A true capsule: the corner follows the height rather than naming a radius. `.circular`, not
        // `.continuous` — a squircle at half the height is no longer a capsule.
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .circular
    }

    func present(_ alert: WorkspaceConnectionAlert, onTap: @escaping () -> Void) {
        self.onTap = onTap
        label.text = alert.label
        dot.tint(for: alert.worst)
        accessibilityLabel = "\(alert.label). Tap to focus the affected pane."
    }

    @objc private func handleTap() {
        onTap()
    }

    /// ``Slate/Native/Terminal/rim``, never `edge` — `edge` matches the plate's own tone and draws nothing
    /// (the 2026-08-10 invisible-border fix, which this chip shares). The FILL is view-level and follows
    /// the appearance by itself; only the border is a `CGColor`.
    private func reink() {
        layer.borderColor = Slate.Native.Terminal.rim.resolvedColor(with: traitCollection).cgColor
    }
}

/// The chip's one point of colour — a disc sized off the grid, matched to the capsule's type rather than
/// picked.
@MainActor
private final class ConnectionAlertDotView: UIView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.space2 / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Slate.Metric.space2),
            heightAnchor.constraint(equalToConstant: Slate.Metric.space2),
        ])
        tint(for: .reconnecting)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Amber while a drop is recovering, red once it is down — the same status roles the toolbar
    /// connection pill (`StatusPresentation`) uses. A dynamic `UIColor` on the view, so a theme flip needs
    /// no re-ink pass.
    func tint(for severity: WorkspaceConnectionAlert.Severity) {
        backgroundColor = switch severity {
        case .reconnecting: Slate.Native.Status.warn
        case .failed,
             .unreachable: Slate.Native.Status.err
        }
    }
}
#endif
