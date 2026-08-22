// MacToastStack — the transient notification corner, as a WINDOW of its own.
//
// The second surface off the shared SwiftUI floor (docs/56 stage D), and it is the one that actually
// changes the window's shape. The cheat sheet is SUMMONED — it exists for the second it is up — but
// the toast host was ALWAYS MOUNTED: a full-bleed `NSHostingView` sat over the whole workspace at all
// times so that an arriving card could animate in without a parent re-mount. That mount is what the
// stage-D note is about ("the last SwiftUI mount from the window root"), because an `NSHostingView`
// returns ITSELF from `hitTest(_:)` anywhere inside its bounds — the SwiftUI half had to keep
// `.allowsHitTesting(!coordinator.toasts.isEmpty)` toggling under it just so the terminal beneath
// stayed clickable, and that flag was the only thing standing between the AppKit split and the mouse.
//
// A panel makes the question go away rather than answering it. The window is sized TO THE COLUMN and
// parked in the workspace's bottom-trailing corner, so the region that takes hits is exactly the
// cards — everywhere else is not covered by anything at all, and there is no flag to keep honest.
//
// THREE PROPERTIES THIS PANEL MUST HAVE, none of which the summoned card wanted:
//
//   1. IT NEVER TAKES THE KEYBOARD. A notification arrives while you are typing. `canBecomeKey` is
//      false, and the panel is `.nonactivatingPanel`, so a card appearing mid-command cannot swallow
//      a keystroke — and `acceptsFirstMouse` is what lets its ✕ and its jump still answer the first
//      click without the panel ever becoming key.
//   2. IT IS NOT A DISMISS FLOOR. ``MacOverlayBackdropView`` closes its card on any click that
//      reaches it; here there is nothing to close and no floor to click, so this panel's content view
//      is a plain container.
//   3. IT ORDERS OUT WHEN THE STACK EMPTIES. An empty transparent window over the corner is still a
//      window in the way of nothing — but it is also a window the display server composites for no
//      reason, and ordering it out is what makes "no toasts" cost nothing at all.
//
// WHAT IT DOES NOT OWN is what a card SAYS. The headline, the spine budget, the mark and the dwell
// length are ``ToastPresentation`` in `SlopDeskClientCore`, over `slopdesk_ws_notify_toast_headline`.
// The phone's SwiftUI column asks the same questions and gets the same answers; only the layout and
// the framework differ, which is docs/56's rule at the scale of one surface.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

// MARK: - The panel

/// The window the notification column is drawn in: borderless, transparent, never key, and parked in
/// the workspace window's bottom-trailing corner.
final class MacToastPanel: NSPanel {
    /// ⚠️ NEVER. A card that arrives while the user is typing must not take the keystroke — see the
    /// file header. `canBecomeKey` is false by default for a `.borderless` mask; it is spelled out
    /// because the summoned card next door overrides it to true, and the difference is the point.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The column

/// The panel's content view: the cards, newest LAST, stacked upward from the corner.
///
/// A plain container rather than a floor — nothing here dismisses on a stray click.
@MainActor
final class MacToastColumnView: NSView {
    private let column = NSStackView()
    /// The live cards, keyed by toast id so a re-sync REUSES a card rather than rebuilding it — which
    /// is what lets a hovered card stay hovered and a running dwell keep running while a second toast
    /// arrives beside it.
    private var cards: [String: MacToastCardView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = Slate.Metric.space2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Reconciles the column against the coordinator's list, and answers the size the panel now needs.
    ///
    /// The diff is by ID, not by position: the coordinator replaces a same-id toast in place (a pane
    /// that speaks twice), and rebuilding the card there would restart a dwell the epoch says should
    /// keep running — and drop a hover the pointer never left.
    func sync(
        _ toasts: [Toast],
        onDismiss: @escaping (String) -> Void,
        onJump: @escaping (String) -> Void,
        onResize: @escaping () -> Void,
    ) -> NSSize {
        let live = Set(toasts.map(\.id))
        for (id, card) in cards where !live.contains(id) {
            column.removeArrangedSubview(card)
            card.removeFromSuperview()
            card.stopDwell()
            cards[id] = nil
        }
        for (index, toast) in toasts.enumerated() {
            let expanded = ToastPresentation.isExpanded(index: index, count: toasts.count)
            if let card = cards[toast.id] {
                card.update(toast: toast, expanded: expanded)
            } else {
                let card = MacToastCardView(
                    toast: toast, expanded: expanded,
                    onDismiss: { onDismiss(toast.id) },
                    onJump: toast.paneKey.map { key in { onJump(key) } },
                    onResize: onResize,
                )
                cards[toast.id] = card
                column.addArrangedSubview(card)
            }
        }
        // The stack's order is the coordinator's order — newest LAST, flush to the corner the eye
        // already goes to. `insertArrangedSubview` on an already-arranged view MOVES it, so a card
        // that changed rank (the one below it expired) travels rather than being rebuilt.
        for (index, toast) in toasts.enumerated() {
            guard let card = cards[toast.id] else { continue }
            column.insertArrangedSubview(card, at: index)
        }
        column.layoutSubtreeIfNeeded()
        return column.fittingSize
    }

    /// Every card's dwell timer, stopped. Called when the panel goes away, so a torn-down stack leaves
    /// no timer holding a closure into a window that is gone.
    func stopAll() {
        for card in cards.values { card.stopDwell() }
    }
}

// MARK: - One card

/// One notification: the mark, the headline, the detail line it may be holding back, and the ✕.
///
/// It is a ``MacOverlayCardView`` because a toast is a member of the SAME floating family as the
/// summoned cards — the ground's cream at the family's corner, one hairline, the palette rung of the
/// shadow ladder. The base class swallows a click by default; this one forwards it, because the card
/// IS a door: tapping it jumps to the pane it names.
@MainActor
final class MacToastCardView: MacOverlayCardView {
    private var toast: Toast
    private var expanded: Bool
    private let onDismiss: () -> Void
    private let onJump: (() -> Void)?
    /// Ask the panel to re-fit: a body revealed on hover changes this card's height, which changes
    /// the whole column's — and a panel that did not follow would clip the card it just grew.
    private let onResize: () -> Void

    private let mark = MacToastMarkView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    /// Dwell CONSUMED, in seconds. Advanced by the tick below and FROZEN while hovering — a pointer
    /// resting on a card stops its clock, so a notification can no longer be yanked away mid-read.
    /// Nothing draws it: an earlier round put a depleting hairline along the bottom edge and it was
    /// cut for reading as ornament. The pause is behaviour, not decoration.
    private var spent: Double = 0
    private var dwell: Timer?
    private var hovering = false

    init(
        toast: Toast,
        expanded: Bool,
        onDismiss: @escaping () -> Void,
        onJump: (() -> Void)?,
        onResize: @escaping () -> Void,
    ) {
        self.toast = toast
        self.expanded = expanded
        self.onDismiss = onDismiss
        self.onJump = onJump
        self.onResize = onResize
        super.init(frame: .zero)
        build()
        apply(toast: toast, expanded: expanded)
        restartDwell()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Building

    private func build() {
        // The HEADLINE speaks the event as a sentence-case phrase in the floating family's reading
        // ink — hierarchy by size and weight in ONE voice, like every card title. A subject is usually
        // a command line, whose informative ends are the program and its last argument, so a too-long
        // one loses its MIDDLE rather than its tail.
        headlineLabel.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        headlineLabel.lineBreakMode = .byTruncatingMiddle
        headlineLabel.maximumNumberOfLines = 1
        headlineLabel.isSelectable = false
        headlineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bodyLabel.font = .systemFont(ofSize: Slate.Typeface.base)
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.isSelectable = false
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: ToastPresentation.dismissLabel,
        )?.withSymbolConfiguration(.init(pointSize: Slate.Typeface.small, weight: .semibold))
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let headlineRow = NSStackView(views: [headlineLabel, closeButton])
        headlineRow.orientation = .horizontal
        headlineRow.alignment = .centerY
        headlineRow.spacing = Slate.Metric.space2

        let text = NSStackView(views: [headlineRow, bodyLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Slate.Metric.space1
        headlineRow.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let row = NSStackView(views: [mark, text])
        row.orientation = .horizontal
        // The mark hangs at the TOP of the text block, beside the headline — a disc has no baseline
        // of its own, and centring it against a two-line card would float it beside the detail.
        row.alignment = .top
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space3),
            // One UNIFORM column edge. Cards that hug their own content were tried and rendered as a
            // ragged staircase — see ``Slate/Metric/toastWidth``.
            widthAnchor.constraint(equalToConstant: Slate.Metric.toastWidth),
        ])
        onClick = { [weak self] in self?.onJump?() }
    }

    // MARK: Content

    /// Re-reads a replaced toast. What restarts the dwell is ``ToastPresentation/dwellKey(_:)``, the
    /// same value the phone's `.task(id:)` keys on — keyed on the row's id it would not fire at all
    /// (the id is unchanged), leaving the replacement to inherit the dead card's elapsed timer.
    func update(toast new: Toast, expanded: Bool) {
        let restart = ToastPresentation.dwellKey(new) != ToastPresentation.dwellKey(toast)
        let reflows = expanded != self.expanded
        apply(toast: new, expanded: expanded)
        if restart { restartDwell() }
        if reflows { onResize() }
    }

    private func apply(toast: Toast, expanded: Bool) {
        self.toast = toast
        self.expanded = expanded
        headlineLabel.stringValue = ToastPresentation.headline(for: toast)
        headlineLabel.textColor = Slate.Native.Overlay.primary
        bodyLabel.stringValue = toast.body ?? ""
        bodyLabel.textColor = Slate.Native.Overlay.secondary
        closeButton.contentTintColor = Slate.Native.Overlay.secondary
        mark.show(ToastPresentation.mark(for: toast.flavor))
        bodyLabel.isHidden = !showsBody
        closeButton.isHidden = !showsClose
        toolTip = onJump == nil ? nil : ToastPresentation.jumpHint
        setAccessibilityLabel(headlineLabel.stringValue)
    }

    /// A collapsed card shows only its headline; hovering it reveals the body it was holding back.
    /// The rule is ``ToastPresentation/showsBody(_:expanded:hovering:)``'s — this half only hides.
    private var showsBody: Bool {
        ToastPresentation.showsBody(toast, expanded: expanded, hovering: hovering)
    }

    /// Hover-only, except on a sticky card — ``ToastPresentation/showsClose(_:hovering:)``.
    private var showsClose: Bool { ToastPresentation.showsClose(toast, hovering: hovering) }

    @objc
    private func closeClicked() { onDismiss() }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }

    override func mouseExited(with _: NSEvent) { setHovering(false) }

    /// The reveal reflows the WHOLE column — expanding this card shifts every sibling above it — so
    /// the change runs inside one animation group at the column rung of the motion ladder, and the
    /// panel is re-fitted in the same beat rather than after it.
    private func setHovering(_ inside: Bool) {
        guard hovering != inside else { return }
        hovering = inside
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.stackReflow.duration
            context.timingFunction = Slate.Motion.stackReflow.timingFunction
            // Implicit, so the SIBLING rows move with the two that changed rather than snapping to
            // their new places around an animating pair.
            context.allowsImplicitAnimation = true
            bodyLabel.isHidden = !showsBody
            closeButton.isHidden = !showsClose
            onResize()
        }
    }

    // MARK: The dwell

    /// Starts (or restarts) the countdown. A sticky card — `autoDismiss == nil` — gets no timer at
    /// all, which is also why its ✕ is unconditional.
    private func restartDwell() {
        stopDwell()
        spent = 0
        let total = ToastPresentation.dwellSeconds(toast)
        guard total > 0 else { return }
        // Sampled rather than one `Timer` of `total`, because the sample is what a hover can FREEZE.
        dwell = Timer.scheduledTimer(
            withTimeInterval: ToastPresentation.dwellTick, repeats: true,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.hovering else { return }
                self.spent = Swift.min(total, self.spent + ToastPresentation.dwellTick)
                guard self.spent >= total else { return }
                self.stopDwell()
                self.onDismiss()
            }
        }
    }

    /// Stops the countdown. Idempotent, and called on teardown so no timer outlives its card.
    func stopDwell() {
        dwell?.invalidate()
        dwell = nil
    }
}

// MARK: - The mark

/// The card's one point of colour: the system's enclosed-status idiom — a `*.circle.fill` in
/// hierarchical rendering with the SF Symbols 7 gradient — drawn as its TWO LAYERS, a `circle.fill`
/// disc under the bare glyph, instead of the fused symbol.
///
/// Composed for CENTRING: the fused `info.circle.fill` sets its serif "i" measurably off the disc's
/// centre, which a 20pt mark makes visible; stacked, each glyph centres on its own bounding box. The
/// flat hand-tinted wash disc this replaces was photographed and read as a sticker laid ON the glass
/// — a symbol-drawn disc participates in vibrancy, and the gradient gives it the dimension the fused
/// symbol had (HIG: symbols, not images, on glass).
@MainActor
final class MacToastMarkView: NSView {
    /// The disc — sized off the grid, a shade taller than the headline's cap height.
    private static let discSize = Slate.Metric.space4 + Slate.Metric.space1

    private let disc = NSImageView()
    private let glyph = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.discSize, height: Self.discSize))
        // `.gradient` is the same rendering the phone's `symbolColorRenderingMode(.gradient)` asks
        // for, so the two marks are one mark drawn by two frameworks rather than two lookalikes.
        let gradient = NSImage.SymbolConfiguration(colorRenderingMode: .gradient)
        disc.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.discSize, weight: .regular).applying(gradient))
        // `footnote`/medium puts the glyph at ~0.55 of the disc — the proportion the fused symbol
        // draws its inner layer at — where a bolder, smaller glyph floated lost.
        glyphConfiguration = .init(pointSize: Slate.Typeface.footnote, weight: .medium).applying(gradient)
        for layer in [disc, glyph] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            addSubview(layer)
            NSLayoutConstraint.activate([
                layer.centerXAnchor.constraint(equalTo: centerXAnchor),
                layer.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.discSize),
            heightAnchor.constraint(equalToConstant: Self.discSize),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private var glyphConfiguration = NSImage.SymbolConfiguration()

    /// Draws `mark` — the flavour's bare glyph, in the flavour's rung. The rung → ink map is
    /// ``Slate/Native/toastMarkInk(for:)``'s (docs/56 batch 3) — the RUNG is decided once, in
    /// ``ToastPresentation/mark(for:)``, and the colour lookup is now the one line every renderer
    /// calls rather than a table kept twice.
    func show(_ mark: ToastMark) {
        glyph.image = NSImage(systemSymbolName: mark.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(glyphConfiguration)
        let ink = Slate.Native.toastMarkInk(for: mark.rung)
        glyph.contentTintColor = ink
        disc.contentTintColor = ink.withAlphaComponent(ToastPresentation.discLayerOpacity)
    }
}

// MARK: - The controller

/// The notification corner: owns the panel, keeps it over the workspace's bottom-trailing corner, and
/// orders it out the moment the stack empties.
@MainActor
final class MacToastStackController {
    private let panel: MacToastPanel
    private let column = MacToastColumnView(frame: .zero)
    private weak var host: NSWindow?
    private var frameObservers: [NSObjectProtocol] = []
    private var onDismiss: (String) -> Void = { _ in }
    private var onJump: (String) -> Void = { _ in }
    /// The column's current fitting size — kept so a re-fit prompted by a hover (which changes no
    /// toast at all) can re-ask the column without a list to diff against.
    private var shown = 0

    init(host: NSWindow) {
        self.host = host
        panel = MacToastPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false,
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Each CARD casts its own shadow; a window shadow would trace the column's bounding box.
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = column
        observeHostFrame()
    }

    /// Reconciles the corner against the coordinator's live list. An empty list orders the panel out;
    /// a non-empty one orders it in as a child of the workspace window, which is what makes the corner
    /// follow a move, a minimise and a close for free.
    func sync(_ toasts: [Toast], onDismiss: @escaping (String) -> Void, onJump: @escaping (String) -> Void) {
        self.onDismiss = onDismiss
        self.onJump = onJump
        let size = column.sync(
            toasts, onDismiss: onDismiss, onJump: onJump, onResize: { [weak self] in self?.refit() },
        )
        shown = toasts.count
        guard shown > 0, let host else {
            dismiss()
            return
        }
        place(size)
        if panel.parent == nil {
            host.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// Orders the corner out and stops every dwell. Idempotent.
    func dismiss() {
        column.stopAll()
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Tears the corner down for good — used when the workspace window itself goes away.
    func invalidate() {
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        frameObservers = []
        dismiss()
    }

    /// Re-asks the column for its size without touching the list — what a hover's reveal needs.
    private func refit() {
        column.layoutSubtreeIfNeeded()
        guard shown > 0 else { return }
        place(column.fittingSize)
    }

    /// Parks the panel in the workspace's bottom-trailing corner, inset by the card margin. The stack
    /// grows UPWARD from there, newest card flush to the bottom — the corner the eye already goes to.
    private func place(_ size: NSSize) {
        guard let host else { return }
        let inset = Slate.Metric.space4
        let frame = NSRect(
            x: host.frame.maxX - size.width - inset,
            y: host.frame.minY + inset,
            width: Swift.max(size.width, 1),
            height: Swift.max(size.height, 1),
        )
        panel.setFrame(frame, display: true)
    }

    /// A child window follows a MOVE by itself but not a RESIZE — and this panel is pinned to a
    /// CORNER, so a resize that moves that corner has to move it too.
    private func observeHostFrame() {
        guard let host else { return }
        let center = NotificationCenter.default
        frameObservers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            center.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refit() }
            }
        }
    }
}
