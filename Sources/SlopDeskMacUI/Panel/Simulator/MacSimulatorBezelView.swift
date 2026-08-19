// MacSimulatorBezelView — the live screen seated in the device's own body, in AppKit (docs/56 stage D,
// increment 52a).
//
// Before there was a bezel the stream was a rectangle on grey. A phone is not a rectangle: it has a
// body, the body has side buttons, and the screen's corners are rounded by the body that clips them.
// All three come from the server (``SimulatorChrome``), so drawing the real thing is a layout away —
// and inventing the proportions locally would be wrong per model and wrong again next year.
//
// LAYOUT. Everything is a fraction of the bezel's own viewport, scaled once by
// ``SimulatorPresentation/fit(_:in:)``. The scale comes from the BLEED rect, not the viewport: side
// buttons protrude past the body, and fitting the viewport alone would clip them off at the panel's
// edge. It is a manual `layout()` rather than constraints because every number is that one scale times
// a server-supplied fraction — expressing thirty of those as multipliers would be the same arithmetic
// spelled in a language that cannot show it.
//
// Z-ORDER is the server's, and it is the whole trick — buttons draw UNDER the body. The body's own
// edge is what makes a protruding button look seated in the case rather than pasted beside it. On
// AppKit that means the body sits LATER in the subview array and must refuse `hitTest` outright, since
// a later sibling is both on top and first to be hit (the SwiftUI half spells the same rule as
// `.allowsHitTesting(false)`).
//
// PRESSES are press-and-hold, not clicks: the artwork swaps on mouse-down and the envelope goes on
// RELEASE, matching the hardware — a volume key that fired on the way down would repeat on every
// accidental brush of the trackpad.
//
// ⚠️ THE TURN IS A CUT HERE, and that is recorded rather than hidden. The SwiftUI half animates its
// `rotationEffect` on `Slate.Anim.smallFade`. The AppKit equivalent is an animated
// `frameCenterRotation` over a view whose subtree contains an `AVSampleBufferDisplayLayer` — which
// disables its own implicit animations precisely because a frame arriving mid-animation cross-fades
// with the previous one and reads as motion blur (see ``SimulatorScreenNSView``). Turning a live video
// layer through 90° would do that for the whole quarter-turn. Getting the animation back means turning
// the BODY and the buttons while the screen cuts, which is a different drawing, not a missing modifier.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

// MARK: - The decode, once per device

/// The Mac's half of ``SimulatorChromeArt``: `NSImage(data:)`, over the fold and the cache that
/// descended in increment 52a.
///
/// The DECODE is here and the two rules around it are not, which is exactly the split
/// ``SimulatorChromeBundle`` asked for when it stopped at bytes: which resources to fetch and what
/// makes a fetch a failure are decisions, and turning bytes into a picture is the platform's.
@MainActor
enum MacSimulatorChrome {
    private static let cache = SimulatorChromeArtCache<NSImage>()

    /// `nil` ⇒ undrawable body, which the stage renders as a bare screen rather than as an error: a
    /// working screen with no body around it is still a working screen.
    static func art(for bundle: SimulatorChromeBundle) -> SimulatorChromeArt<NSImage>? {
        cache.art(for: bundle) { NSImage(data: $0) }
    }
}

// MARK: - The bezel

@MainActor
final class MacSimulatorBezelView: NSView {
    private let art: SimulatorChromeArt<NSImage>
    private let screen: SimulatorScreenNSView
    /// The device as one object — body, buttons and screen — so the whole thing turns together and the
    /// screen view's own coordinate space is left untouched. A rotated `NSView` is hit-tested in its
    /// UNROTATED local space, which is exactly the space the server expects a tap in.
    private let assembly = MacSimulatorBezelAssembly()
    private let body = MacSimulatorBezelBody()
    private var buttons: [MacSimulatorBezelButton] = []

    var orientation: SimulatorOrientation {
        didSet {
            guard orientation != oldValue else { return }
            screen.orientation = orientation
            needsLayout = true
        }
    }

    init(
        art: SimulatorChromeArt<NSImage>,
        frames: SimulatorFrameSink,
        orientation: SimulatorOrientation,
        send: @escaping (SimulatorInputEnvelope) -> Void,
        onContentSize: @escaping (CGSize) -> Void,
    ) {
        self.art = art
        self.orientation = orientation
        screen = SimulatorScreenNSView(frame: .zero)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        screen.send = send
        screen.orientation = orientation
        screen.onContentSize = onContentSize
        screen.wantsLayer = true
        screen.layer?.masksToBounds = true
        frames.attach(screen)

        body.image = art.body

        // BUTTONS FIRST, then the body over them, then the screen. Any other order and a protruding
        // button reads as pasted beside the case instead of seated in it.
        for button in art.chrome.buttons {
            let view = MacSimulatorBezelButton(
                button: button, art: art.buttons[button.id], send: send,
            )
            buttons.append(view)
            assembly.addSubview(view)
        }
        assembly.addSubview(body)
        assembly.addSubview(screen)
        addSubview(assembly)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The mount is going away — a device switch, or the panel closing. The contact is forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone. This is the
    /// `dismantleNSView` the representable used to carry.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        screen.abandonGestures()
    }

    override func layout() {
        super.layout()
        let bleed = art.chrome.bleed
        let scale = SimulatorPresentation.fit(
            bleed.size,
            in: SimulatorPresentation.footprint(bounds.size, turned: orientation.isLandscape),
        )
        guard scale > 0 else { return }

        // Rotation is cleared before the frame is written and re-applied after: `frameCenterRotation`
        // keeps the CENTRE fixed, so setting a size or an origin while it is non-zero moves the view
        // by whatever the old angle implied.
        assembly.frameCenterRotation = 0
        let size = NSSize(width: bleed.width * scale, height: bleed.height * scale)
        assembly.setFrameSize(size)
        assembly.setFrameOrigin(NSPoint(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
        ))
        // NEGATED: ``SimulatorOrientation/viewAngle`` is degrees CLOCKWISE, and AppKit measures a
        // frame rotation counter-clockwise in this (unflipped) container's space.
        assembly.frameCenterRotation = -orientation.viewAngle

        let viewport = art.chrome.screen.viewport
        let origin = bleed.origin
        body.frame = CGRect(
            x: -origin.x * scale, y: -origin.y * scale,
            width: viewport.width * scale, height: viewport.height * scale,
        )

        let rect = art.chrome.screen.rect
        screen.frame = CGRect(
            x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
            width: rect.width * scale, height: rect.height * scale,
        )
        // Clipped rather than merely placed: unclipped video overhangs the rounded corners and reads
        // as a rendering bug, which is exactly the "looks unfinished" the bezel is here to fix.
        screen.layer?.cornerRadius = art.chrome.screen.clipRadius * scale
        screen.layer?.cornerCurve = .continuous

        for (index, button) in art.chrome.buttons.enumerated() where index < buttons.count {
            let box = button.frame(in: viewport)
            buttons[index].frame = CGRect(
                x: (box.minX - origin.x) * scale, y: (box.minY - origin.y) * scale,
                width: box.width * scale, height: box.height * scale,
            )
        }
    }
}

/// The device's own coordinate space: FLIPPED, because every fraction the server sends is measured
/// from the artwork's top-left. Its flippedness is its own and does not depend on its container's,
/// which is what lets the rotation above be reasoned about in one unflipped space.
@MainActor
private final class MacSimulatorBezelAssembly: NSView {
    override var isFlipped: Bool { true }
}

/// The body artwork. It sits OVER the buttons and must never be hit, or every side button on the
/// device becomes unclickable.
@MainActor
private final class MacSimulatorBezelBody: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleAxesIndependently
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// One physical button on the case: rest artwork, pressed artwork, and the envelope on release.
@MainActor
private final class MacSimulatorBezelButton: NSView {
    private let rest: NSImage?
    private let pressed: NSImage?
    private let glyph = NSImageView()
    private let envelope: String
    private let send: (SimulatorInputEnvelope) -> Void

    init(
        button: SimulatorChrome.Button,
        art: (rest: NSImage, pressed: NSImage)?,
        send: @escaping (SimulatorInputEnvelope) -> Void,
    ) {
        rest = art?.rest
        pressed = art?.pressed
        envelope = button.envelopeButton
        self.send = send
        super.init(frame: .zero)
        glyph.imageScaling = .scaleAxesIndependently
        glyph.autoresizingMask = [.width, .height]
        // No artwork for this one: stay CLICKABLE but draw nothing. A coloured placeholder would be a
        // fake button on a photoreal body, and refusing the click would silently drop a verb the
        // server still accepts.
        glyph.image = rest
        addSubview(glyph)
        toolTip = SimulatorPresentation.buttonLabel(for: button.id)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func layout() {
        super.layout()
        glyph.frame = bounds
    }

    override func mouseDown(with _: NSEvent) { glyph.image = pressed ?? rest }

    /// The envelope goes on the UP, and only inside — the hardware's own contract, and the one that
    /// keeps a press dragged off the key from firing it.
    override func mouseUp(with event: NSEvent) {
        glyph.image = rest
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        send(.button(envelope))
    }

    override func accessibilityPerformPress() -> Bool {
        send(.button(envelope))
        return true
    }
}

// MARK: - The bare screen

/// The stream with no body around it — still loading, or a model the server cannot describe.
///
/// Turned the same way the bezel is, for the same reason: the framebuffer never rotates (see
/// ``SimulatorOrientation/viewAngle``), so a landscape device would otherwise read sideways here too.
/// Drawing it at all rather than waiting for the artwork is the point — a working screen with no bezel
/// is a working screen, and refusing to draw until a fetch lands would make a slow server look like a
/// dead stream.
@MainActor
final class MacSimulatorBareScreen: NSView {
    private let screen: SimulatorScreenNSView

    var orientation: SimulatorOrientation {
        didSet {
            guard orientation != oldValue else { return }
            screen.orientation = orientation
            needsLayout = true
        }
    }

    init(
        frames: SimulatorFrameSink,
        orientation: SimulatorOrientation,
        send: @escaping (SimulatorInputEnvelope) -> Void,
        onContentSize: @escaping (CGSize) -> Void,
    ) {
        self.orientation = orientation
        screen = SimulatorScreenNSView(frame: .zero)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        screen.send = send
        screen.orientation = orientation
        screen.onContentSize = onContentSize
        frames.attach(screen)
        addSubview(screen)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        screen.abandonGestures()
    }

    override func layout() {
        super.layout()
        let box = SimulatorPresentation.footprint(bounds.size, turned: orientation.isLandscape)
        screen.frameCenterRotation = 0
        screen.setFrameSize(box)
        screen.setFrameOrigin(NSPoint(
            x: ((bounds.width - box.width) / 2).rounded(),
            y: ((bounds.height - box.height) / 2).rounded(),
        ))
        screen.frameCenterRotation = -orientation.viewAngle
    }
}
