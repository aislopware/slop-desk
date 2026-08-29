// MacIslandChipStack — the transient + durable chips that stand at the FOOT OF THE ISLAND, in AppKit
// (docs/56 wave R, R12).
//
// These three used to hang off the window root, which put them at the bottom centre of the WINDOW — a
// point that includes the navigator and the code panel, so the stack drifted off the terminal it was
// talking about, and its window inset parked it on the island's bottom edge, over the live prompt line
// (user-reported 2026-08-09). Mounted on the pane canvas instead, the stack is centred on the ISLAND
// and stands clear of its foot; ``Slate/Metric/islandChipInset`` is the whole of that clearance.
//
// ⚠️ THE TWO TRANSIENT CHIPS ARE PAPER; THE DURABLE ONE IS GLASS, and the line between them is DURATION.
// A notice ARRIVES and leaves — it is a message from the app, so it wears the floating family's paper
// capsule (``MacNoticeCapsuleView``, which carries the measurements). The connection chip LIVES here for
// as long as a pane is unhealthy, and a cream plate glowing over the terminal for minutes is the glare
// the transient pair is small and short-lived enough to avoid — so it stays in the glass's own
// vocabulary, where a persistent object belongs.
//
// THREE THINGS THE SWIFTUI STACK GOT FROM MODIFIERS AND THIS FILE HAS TO STATE:
//
//   1. THE HIT-TRANSPARENCY IS PER CHIP, NEVER ON THE STACK. `allowsHitTesting(false)` on an ancestor
//      deafens everything composed into it, so a flag here would also silence the connection chip's
//      click. In AppKit the same mistake has a second face: a container whose `hitTest` returns SELF
//      swallows every point inside its bounds even where no chip is drawn — which over a terminal is
//      a dead rectangle at the prompt. So the stack answers `nil` for itself, each paper capsule
//      answers `nil` for itself, and only the alert chip answers with a view.
//   2. THE DWELL IS A TIMER, not a `.task(id:)`. Keyed on the WHOLE value (the receipt, the notice's
//      epoch): a hand-off between the two receipt owners can carry the same epoch, and a cancelled
//      sleep must never expire, or the successor's dwell dies with its predecessor's.
//   3. THE FADE IS EXPLICIT. `.transition(.opacity)` + `.animation(_:value:)` became one
//      alpha-and-remove helper, because AppKit has no render pass to notice the difference.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - The stack

@MainActor
final class MacIslandChipStack: NSStackView {
    private let store: WorkspaceStore
    /// The scene overlay reducer — owns the window-level copy receipt + the transient notice. `nil`
    /// (previews / a satellite) leaves the stack with the connection chip alone.
    private let coordinator: OverlayCoordinator?
    private let chrome: WorkspaceChromeState?

    private var receiptChip: MacNoticeCapsuleView?
    private var noticeChip: MacNoticeCapsuleView?
    private var alertChip: MacConnectionAlertChip?

    /// Kept because ``teardown()`` must END the following while this stack lives on — the case
    /// ``ObservationFollow/stop()`` exists for.
    private var chipFollow: ObservationFollow?

    init(store: WorkspaceStore, coordinator: OverlayCoordinator?, chrome: WorkspaceChromeState?) {
        self.store = store
        self.coordinator = coordinator
        self.chrome = chrome
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Slate.Metric.space2
        translatesAutoresizingMaskIntoConstraints = false
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// See the header's point 1: everywhere the stack is not a CHIP it is not there at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // MARK: The live read

    /// ONE tracked pass over everything the three chips turn on.
    ///
    /// Reading `store.connectionAlert()` registers observation on each pane's connection status, so the
    /// durable chip appears, re-counts and disappears as panes drop and recover.
    ///
    /// THE COPY RECEIPT is whichever of the two owners has one (user-directed 2026-08-11): pane-scoped
    /// copies publish on the active pane's model and pane-less ones (palette "Copy Path", rail "Copy
    /// Window Title") on the coordinator, but both surface HERE. The coordinator wins a tie because it
    /// is the later, more deliberate act — a pane-less copy is an explicit menu/palette command, while
    /// a pane receipt may be seconds-stale ⌘C.
    private func follow() {
        chipFollow = ObservationFollow.arm(self) { stack in
            (
                receipt: stack.coordinator?.copyReceipt ?? stack.store.activePaneCopyReceipt(),
                notice: stack.coordinator?.notice,
                // The durable indicator shows ONLY with the tabs panel collapsed — an open sidebar is
                // the user's normal per-pane surface, and the chip would be saying it twice.
                alert: stack.chrome?.sidebarCollapsed == true ? stack.store.connectionAlert() : nil,
            )
        } apply: { stack, reading in
            stack.apply(receipt: reading.receipt, notice: reading.notice, alert: reading.alert)
        }
    }

    private func apply(
        receipt: CopyReceipt?, notice: ChipNotice?, alert: WorkspaceConnectionAlert?,
    ) {
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
            MacChipFade.remove(receiptChip, from: self)
            receiptChip = nil
            return
        }
        let chip = receiptChip ?? {
            let made = MacNoticeCapsuleView()
            receiptChip = made
            MacChipFade.insert(made, into: self, at: 0)
            return made
        }()
        chip.present(.receipt(receipt)) { [weak self] in self?.clearCopyReceipt() }
    }

    private func applyNotice(_ notice: ChipNotice?) {
        guard let notice else {
            noticeChip?.stopDwell()
            MacChipFade.remove(noticeChip, from: self)
            noticeChip = nil
            return
        }
        let chip = noticeChip ?? {
            let made = MacNoticeCapsuleView()
            noticeChip = made
            MacChipFade.insert(made, into: self, at: receiptChip == nil ? 0 : 1)
            return made
        }()
        chip.present(.notice(notice)) { [weak self] in self?.coordinator?.clearNotice() }
    }

    private func applyAlert(_ alert: WorkspaceConnectionAlert?) {
        guard let alert else {
            MacChipFade.remove(alertChip, from: self)
            alertChip = nil
            return
        }
        let chip = alertChip ?? {
            let made = MacConnectionAlertChip()
            alertChip = made
            // ALWAYS LAST: the durable member stands at the foot of the column, under whatever
            // transient chip is passing through above it.
            MacChipFade.insert(made, into: self, at: arrangedSubviews.count)
            return made
        }()
        chip.present(alert) { [weak self] in self?.store.jumpToPaneTree(alert.worstPane) }
    }

    /// Expiry clears BOTH owners. Each is idempotent and only one can be non-nil at a time in practice,
    /// so this cannot strand a receipt the other owner still wants shown — while clearing only the
    /// winner would leave the loser's stale receipt to pop straight back the moment the chip faded out.
    private func clearCopyReceipt() {
        coordinator?.clearCopyReceipt()
        store.clearActivePaneCopyReceipt()
    }

    /// Every dwell stopped and every chip dropped. Called when the canvas around it comes down, so no
    /// timer outlives the window holding it.
    func teardown() {
        chipFollow?.stop()
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
/// curve, stated because AppKit has no render pass to infer it from.
///
/// A LEAVING chip is removed in the completion, never before: removing it first would collapse the
/// stack in one frame and animate a view that is no longer in it.
@MainActor
private enum MacChipFade {
    static func insert(_ view: NSView, into stack: NSStackView, at index: Int) {
        view.alphaValue = 0
        stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        stack.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            view.animator().alphaValue = 1
        }
    }

    static func remove(_ view: NSView?, from stack: NSStackView) {
        guard let view, view.superview === stack else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            view.animator().alphaValue = 0
        } completionHandler: {
            // `runAnimationGroup`'s completion is `@Sendable`; AppKit runs it on the main thread
            // without saying so in the type.
            MainActor.assumeIsolated {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
    }
}

// MARK: - The paper capsule (both transient chips)

/// `label · detail` on the floating family's paper capsule — the single view behind BOTH transient
/// chips, so the copy receipt and every notice can never drift apart in type, ink, spacing or surface.
///
/// HIERARCHY IS SIZE AND WEIGHT IN ONE VOICE, never ink alone. The DETAIL is the dominant half in every
/// notice this family carries: the count is what answers "did I get the whole thing?", the chord is
/// what answers "how do I undo that?". The label is the frame around the answer, so it takes the
/// quieter rung.
///
/// ⚠️ PAPER, NOT GLASS, and that is arithmetic rather than taste. The whole on-glass band, from the
/// face to the comment ink, is 3.56 : 1 wide in total, and a chip needs three separable steps inside it
/// (plate, rim, label): every arrangement spends one to buy another. On paper each passes with room —
/// plate 15.32 against the glass, rim 9.57, label 6.99, detail 20.25.
///
/// The SwiftUI half also carries a `.clipShape(.capsule)` against a stray tick where `strokeBorder`'s
/// two arcs meet. There is no counterpart here and none is needed: a `CALayer` border is drawn INSIDE
/// the layer's own bounds along the corner path, so a capsule radius cannot put a whisker outside it.
@MainActor
final class MacNoticeCapsuleView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let separator = NSTextField(labelWithString: "·")
    private let detailField = NSTextField(labelWithString: "")
    private let keycap = MacNoticeKeycap()
    private let row = NSStackView()

    /// The clock, and what is on screen now — on the floor, because neither a `Duration` nor a `Timer`
    /// is a framework question and both shells were running the identity gate from their own copy.
    private let dwell = DecorationChipDwell()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = Slate.Metric.hairline
        // The ladder's own rung for a pill floating over the glass. Nearly invisible against the dark
        // face, and that is fine — it is bought for the case that needs it, where the capsule overlaps
        // bright output and the cream has no contrast of its own.
        layer?.shadowRadius = Slate.Elevation.chip.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.chip.y)
        layer?.shadowOpacity = 1

        for field in [labelField, separator, detailField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
        }
        labelField.font = .systemFont(ofSize: Slate.Typeface.base)
        labelField.textColor = Slate.Native.Overlay.secondary
        separator.font = .systemFont(ofSize: Slate.Typeface.base)
        separator.textColor = Slate.Native.Overlay.tertiary

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [labelField, keycap, separator, detailField] { row.addArrangedSubview(view) }
        addSubview(row)
        NSLayoutConstraint.activate([
            // Generous sides against a tight top/bottom is what reads as a capsule rather than as a
            // rounded box — the proportion IS the shape here, since a capsule has no radius to tune.
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Hit-transparent, per the file header's point 1: this chip has nothing to press, and a rectangle
    /// of dead pointer over the prompt line is what the SwiftUI half's `allowsHitTesting(false)` bought.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
            // ``Slate/Native/Line/overlayRim`` verbatim, NOT a second light-side rim solved for this
            // shape: it is the same paper over the same terminal, and two washes that mean the same
            // thing drifting apart by a few hundredths is the failure the opacity ladder prevents.
            layer?.borderColor = Slate.Native.Line.overlayRim.cgColor
            layer?.shadowColor = Slate.Native.State.overlayShadow.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A true capsule: the corner follows the height rather than naming a radius.
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .circular
    }

    /// Re-targets the chip and restarts its dwell when `identity` changed; a re-apply carrying the same
    /// identity leaves the running clock alone.
    func present(_ copy: DecorationChipCopy, onExpire: @escaping () -> Void) {
        let chord = copy.keycap
        labelField.stringValue = copy.label
        keycap.chord = chord
        keycap.isHidden = chord == nil
        detailField.stringValue = copy.detail
        detailField.isHidden = copy.detail.isEmpty
        // The dot appears ONLY without a cap — a keycap is its own boundary object, so a dot beside one
        // is a second separator doing the first one's job.
        separator.isHidden = chord != nil || copy.detail.isEmpty
        // With a cap the emphasis has already been spent ON the cap, so the trailing verb drops to the
        // label's rung and the sentence has ONE hero. Without one, the detail IS the answer.
        detailField.font = .systemFont(
            ofSize: Slate.Typeface.base, weight: chord == nil ? .semibold : .regular,
        )
        detailField.textColor = chord == nil
            ? Slate.Native.Overlay.primary
            : Slate.Native.Overlay.secondary
        setAccessibilityLabel(copy.accessibility)
        dwell.arm(copy, onExpire: onExpire)
    }

    func stopDwell() { dwell.stop() }
}

// MARK: - The keycap

/// The chord as a pressable object: the system face, semibold, on the overlay plate behind a hairline
/// at the small corner — the keycap voice, sized to a TEXT LINE instead of to a 24pt control row.
///
/// Its ink is the overlay's PRIMARY, above the words on either side of it, because in this sentence the
/// chord IS the answer: the label frames it and the verb after it only says what pressing does.
@MainActor
final class MacNoticeKeycap: NSView {
    var chord: String? {
        didSet { field.stringValue = chord ?? "" }
    }

    private let field = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline

        field.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold)
        field.textColor = Slate.Native.Overlay.primary
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space1),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space1),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.plate.cgColor
            layer?.borderColor = Slate.Native.Overlay.hairline.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The durable connection chip

/// The compact connection-health chip: an amber/red status dot + a count label ("1 reconnecting" /
/// "2 disconnected"), shown at the island's foot while the tabs panel is collapsed and some pane is
/// unhealthy. Clickable — unlike the transient pair — so a click focuses the worst-affected pane.
///
/// ONE SILHOUETTE, TWO MATERIALS. It shares the notice capsule's shape, size and rhythm — same capsule,
/// same padding, same type size — so the column reads as one family; it keeps the GLASS's own palette
/// because it is the DURABLE member (a cream plate glowing over the terminal for as long as a pane
/// stays down is the glare the transient pair is short-lived enough to avoid). Matching the shape is
/// what keeps that material difference reading as a ROLE rather than as two unrelated chips stacked by
/// accident.
///
/// ⚠️ Its label is ``Slate/Native/Terminal/ink``, not `ink2`. The comment ink measures 2.19 : 1 on this
/// plate — the very number that sent the transient chips to paper — and this chip carried it too,
/// unnoticed, while saying that a connection is DOWN. On the glass the primary ink is the only rung
/// that clears the plate (9.16 : 1), and a durable alarm has no excuse to whisper.
@MainActor
final class MacConnectionAlertChip: NSView {
    private let dot = MacConnectionAlertDot()
    private let label = NSTextField(labelWithString: "")
    private var onTap: () -> Void = {}

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = Slate.Metric.hairline

        label.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        label.textColor = Slate.Native.Terminal.ink
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        addSubview(row)
        NSLayoutConstraint.activate(DecorationAlertChipRow.constraints(in: self, row: row))
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Terminal.raised.cgColor
            // ``Slate/Native/Terminal/rim``, never `edge` — `edge` matches the plate's own tone and
            // draws nothing (the 2026-08-10 invisible-border fix, which this chip shares).
            layer?.borderColor = Slate.Native.Terminal.rim.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .circular
    }

    func present(_ alert: WorkspaceConnectionAlert, onTap: @escaping () -> Void) {
        self.onTap = onTap
        label.stringValue = alert.label
        dot.tint(for: alert.worst)
        toolTip = "\(alert.label) — click to focus the affected pane"
        setAccessibilityLabel("\(alert.label). Click to focus the affected pane.")
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onTap()
    }
}

/// The chip's one point of colour — a disc sized off the grid, matched to the capsule's type rather
/// than picked.
@MainActor
private final class MacConnectionAlertDot: NSView {
    private var severity: WorkspaceConnectionAlert.Severity = .reconnecting

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.space2 / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Slate.Metric.space2),
            heightAnchor.constraint(equalToConstant: Slate.Metric.space2),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var wantsUpdateLayer: Bool { true }

    func tint(for severity: WorkspaceConnectionAlert.Severity) {
        self.severity = severity
        needsDisplay = true
    }

    /// Amber while a drop is recovering, red once it is down — the same status roles the toolbar
    /// connection pill (`StatusPresentation`) uses.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink: SlateNativeColor =
                switch severity {
                case .reconnecting: Slate.Native.Status.warn
                case .failed,
                     .unreachable: Slate.Native.Status.err
                }
            layer?.backgroundColor = ink.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
