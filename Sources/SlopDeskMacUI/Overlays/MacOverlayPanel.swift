// MacOverlayPanel — a summoned card, as a WINDOW of its own.
//
// docs/56 stage D names this file's existence as the unblock for the whole window root: "the
// overlays become their own windows/views rather than a transparent layer over everything, which is
// what removes the last SwiftUI mount from the window root". The measurement behind that is blunt —
// an `NSHostingView` claims every hit inside its own bounds, so a full-bleed one over `Color.clear`
// returns ITSELF from `hitTest(_:)` and never `nil`. As long as the overlays live inside one, the
// AppKit split beneath them can never take a click without the SwiftUI layer's permission.
//
// So a card is a `.borderless` panel ordered above the workspace window and pinned to its frame.
// That buys back three things the in-window `ZStack` was hand-rolling:
//
//   1. THE DISMISS FLOOR IS THE PANEL. It is opaque to hits by construction — no `SlateClickTarget`
//      button standing in for a rectangle that "takes no hits because it is clear", and no hit
//      barrier on the card to stop the floor being reachable THROUGH the card's own inert body.
//   2. ESC IS THE RESPONDER CHAIN's. `cancelOperation(_:)` is what AppKit sends an unhandled Esc,
//      so the card gets it whether or not anything inside it is focused — which is exactly the case
//      the SwiftUI host had to carry `.onExitCommand` on the backdrop for.
//   3. THE KEYBOARD COMES BACK BY ITSELF. A panel is a window: ordering it out restores the parent
//      window's first responder, which is the thing an in-window card had to fake with an
//      `.onDisappear { store.reclaimKeyboardFocusInActivePane() }`. That call is still made, because
//      the pane's own focus is workspace state rather than responder state, but it is now a
//      confirmation rather than the only thing standing between the user and a deaf terminal.
//
// The card KEEPS THE FAMILY'S LOOK because it reads the family's own tokens (``Slate/Native``): the
// ground's cream at ``Slate/Metric/radiusPanel``, the ``Slate/Native/Line/overlayRim`` hairline, and
// the palette rung of the shadow ladder. Not a second palette — the same constants the SwiftUI half
// derives its `Color`s from, which is the whole reason that layer exists.

import AppKit
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

// MARK: - The panel

/// The window a summoned card is drawn in: borderless, transparent, and pinned over the workspace
/// window it belongs to.
///
/// `canBecomeKey` is overridden because AppKit gives a `.borderless` mask neither key nor main by
/// default, and a card that cannot become key cannot receive Esc, arrow keys or typing. It stays a
/// PANEL rather than a window so it never appears in the Window menu and never becomes main — the
/// workspace window keeps its titlebar's active look while the card is up, exactly as a sheet does.
final class MacOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Never main: the workspace window behind stays the app's main window, so its chrome does not
    /// grey out under a card the user summoned over it.
    override var canBecomeMain: Bool { false }
}

// MARK: - The backdrop (the dismiss floor)

/// The panel's content view: a full-bleed floor that closes the card when the click lands beside it,
/// and answers Esc for the whole panel.
///
/// It draws NOTHING — the backdrop does not dim. These are surfaces you summon over your work and
/// dismiss in a second, and the workspace behind is the context you summoned them about; the ⌃⇥
/// switcher makes the same call and a macOS sheet did not dim either.
final class MacOverlayBackdropView: NSView {
    /// Fired by a click beside the card, by Esc, and by nothing else.
    var onDismiss: () -> Void = {}

    /// Esc with no other handler lands here — see the file header for why this is the panel's job
    /// rather than the card content's.
    override func cancelOperation(_: Any?) {
        onDismiss()
    }

    override var acceptsFirstResponder: Bool { true }

    /// A click that reached the FLOOR is a click beside the card (the card is a subview and gets its
    /// own hits first), which is the dismiss gesture.
    override func mouseDown(with _: NSEvent) {
        onDismiss()
    }

    /// The floor takes the first click even when the panel was not key, so dismissing never costs
    /// two clicks — the same courtesy a sheet's own dismissal has.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - The card surface

/// The paper card itself: the ground's cream at the floating family's own corner, edged by a
/// hairline and dropped on the deepest rung of the shadow ladder.
///
/// The colours are re-resolved in `updateLayer()` rather than assigned once, because a `CALayer`
/// holds a `CGColor` — a flat, already-resolved value — so a dynamic `NSColor` written into one
/// stops following the appearance the moment it is stored.
class MacOverlayCardView: NSView {
    /// What a click on the card's own body does. `nil` — the summoned cards — SWALLOWS it, which is
    /// the correctness fix below. The notification card sets it, because that card IS a door: its
    /// whole body is the jump to the pane it names.
    var onClick: (() -> Void)?

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusPanel
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Slate.Metric.hairline
        layer?.masksToBounds = false
        // The shadow is what LIFTS an opaque cream card off an opaque cream ground; the hairline
        // alone only draws its outline. The palette rung, because this floats above the island,
        // which is itself already above the ground.
        layer?.shadowRadius = Slate.Elevation.palette.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Slate.Elevation.palette.y)
        layer?.shadowOpacity = 1
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func updateLayer() {
        // `effectiveAppearance` has to be the CURRENT one while a dynamic colour resolves, or every
        // rung answers for whatever appearance happened to be drawing last.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
            layer?.borderColor = Slate.Native.Line.overlayRim.cgColor
            layer?.shadowColor = Slate.Native.State.overlayShadow.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The card is SOLID TO CLICKS. A click that lands on its own body — a label, the padding
    /// between two rows, the gap beside a heading — is not a click on the floor, and without this it
    /// would fall through and dismiss the card the user was reaching into. A card that has somewhere
    /// to go answers instead of swallowing.
    override func mouseDown(with _: NSEvent) {
        onClick?()
    }

    /// A card takes the FIRST click even when its panel was not key. The notification corner never
    /// becomes key at all, so without this its jump would silently cost two clicks.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - The card's internal line

/// A rule INSIDE a card — the palette's between its query and its results, the peek card's above and
/// below its reply bar.
///
/// Every one of them is EARNED, which is why there is a shared object for it and no `Divider()`
/// habit: a line is drawn where content SCROLLS PAST an edge and the eye needs to know where the
/// scrolling region begins. Anywhere else the card's own spacing is the separation.
final class MacCardRuleView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Overlay.hairline.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - The controller

/// One summoned card: builds the panel, pins it over its host window, and tears it down.
///
/// It is deliberately NOT an `NSWindowController`. A window controller owns a window's lifetime and
/// its release-on-close behaviour, and this panel's lifetime is a boolean on the overlay
/// coordinator — so the presenter owns it, and every teardown path is `dismiss()`.
@MainActor
final class MacOverlayPanelController {
    private let panel: MacOverlayPanel
    private let backdrop: MacOverlayBackdropView
    private let card: MacOverlayCardView
    private weak var host: NSWindow?
    private var frameObservers: [NSObjectProtocol] = []
    /// The card's own two dimensions, kept so a card whose content is a live list can re-size in
    /// place (see ``resize(to:)``).
    private var cardSize: (width: NSLayoutConstraint, height: NSLayoutConstraint)?

    /// Builds a card of `size` around `content`, over `host`.
    ///
    /// `content` is laid out to fill the card inset by nothing — a card's own padding belongs to the
    /// content, because only the content knows whether its bottom edge is a row of buttons or the
    /// end of a scrolling list.
    init(host: NSWindow, content: NSView, size: NSSize, onDismiss: @escaping () -> Void) {
        self.host = host
        panel = MacOverlayPanel(
            contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false,
        )
        backdrop = MacOverlayBackdropView(frame: NSRect(origin: .zero, size: host.frame.size))
        card = MacOverlayCardView(frame: .zero)

        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The CARD casts the shadow, not the window: a window shadow traces the panel's full-bleed
        // rectangle, which is the whole workspace, so it would ring the window instead of the card.
        panel.hasShadow = false
        panel.level = .normal
        // Follow the workspace onto whatever Space or fullscreen it is on — a card pinned to a
        // window that moved to another Space must go with it, not stay behind on this one.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = backdrop
        backdrop.onDismiss = onDismiss

        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        backdrop.addSubview(card)
        let width = card.widthAnchor.constraint(equalToConstant: size.width)
        let height = card.heightAnchor.constraint(equalToConstant: size.height)
        cardSize = (width, height)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            width,
            height,
            // The card must never run out of a small window; this is the margin it keeps.
            card.leadingAnchor.constraint(
                greaterThanOrEqualTo: backdrop.leadingAnchor, constant: Slate.Metric.space4,
            ),
            card.topAnchor.constraint(
                greaterThanOrEqualTo: backdrop.topAnchor, constant: Slate.Metric.space4,
            ),
        ])
        // The two size constraints yield to the two margins rather than fighting them, so a window
        // narrower than the card shrinks it instead of pushing it off the edge.
        for constraint in card.constraints where constraint.firstAttribute == .width
            || constraint.firstAttribute == .height
        {
            constraint.priority = .defaultHigh
        }
    }

    /// Orders the card in over its host and gives it the keyboard.
    func present() {
        guard let host else { return }
        panel.setFrame(host.frame, display: false)
        // A CHILD window travels with its parent for free: move, minimise, order-out and close all
        // carry the card with them, so there is no state to reconcile when the user drags the
        // workspace window with a card up.
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(backdrop)
        observeHostFrame()
    }

    /// Re-cuts the card to `size`.
    ///
    /// A card whose content is a fixed sheet is measured once at `init`; one whose content is a LIVE
    /// LIST is not, because a query that narrows to two rows should get a two-row card rather than a
    /// full-height one padded out with nothing. Animated, because the height moves on every
    /// keystroke and a card that jumps between two sizes reads as a flicker rather than as a card
    /// following the list — the family's own short curve, so it settles inside the next keystroke.
    func resize(to size: NSSize) {
        guard let cardSize else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.smallFade.duration
            context.timingFunction = Slate.Motion.smallFade.timingFunction
            context.allowsImplicitAnimation = true
            cardSize.width.animator().constant = size.width
            cardSize.height.animator().constant = size.height
            backdrop.layoutSubtreeIfNeeded()
        }
    }

    /// Orders the card out. Idempotent — a second call on an already-dismissed card is a no-op, so
    /// the coordinator's flag and the panel cannot disagree.
    func dismiss() {
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        frameObservers = []
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Keep the panel exactly over the workspace window. A child window follows a MOVE by itself but
    /// not a RESIZE, and the card is centred on the panel — so without this a resize leaves it
    /// centred on the window's old size.
    private func observeHostFrame() {
        guard let host else { return }
        let center = NotificationCenter.default
        frameObservers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            center.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let host = self.host else { return }
                    self.panel.setFrame(host.frame, display: true)
                }
            }
        }
    }
}
