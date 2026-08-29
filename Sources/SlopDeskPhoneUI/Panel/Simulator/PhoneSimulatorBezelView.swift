// PhoneSimulatorBezelView — the live screen seated in the device's own body, in UIKit.
//
// Before there was a bezel the stream was a rectangle on grey. A phone is not a rectangle: it has a
// body, the body has side buttons, and the screen's corners are rounded by the body that clips them.
// All three come from the server (``SimulatorChrome``), so drawing the real thing is a layout away —
// and inventing the proportions locally would be wrong per model and wrong again next year.
//
// LAYOUT. Everything is a fraction of the bezel's own viewport, scaled once by
// ``SimulatorPresentation/fit(_:in:)``. The scale comes from the BLEED rect, not the viewport: side
// buttons protrude past the body, and fitting the viewport alone would clip them off at the panel's
// edge. It is a manual `layoutSubviews` rather than constraints because every number is that one scale
// times a server-supplied fraction — expressing thirty of those as multipliers would be the same
// arithmetic spelled in a language that cannot show it.
//
// Z-ORDER is the server's, and it is the whole trick — buttons draw UNDER the body. The body's own
// edge is what makes a protruding button look seated in the case rather than pasted beside it. On UIKit
// that means the body is added LATER (a later sibling is both on top and first to be hit) and must
// refuse touches outright, which is what `isUserInteractionEnabled = false` says here and
// `.allowsHitTesting(false)` said in the deleted half.
//
// PRESSES are press-and-hold, not taps: the artwork swaps on touch-DOWN and the envelope goes on
// RELEASE, matching the hardware — a volume key that fired on the way down would repeat on every
// accidental brush.
//
// ⚠️ THE TURN IS NOT NEGATED HERE, and the Mac's is. ``SimulatorOrientation/viewAngle`` is degrees
// CLOCKWISE; `CGAffineTransform(rotationAngle:)` is clockwise-positive in UIKit's own top-left-origin
// space, so the number goes in as it comes out. AppKit measures `frameCenterRotation`
// counter-clockwise in an unflipped container, which is why `MacSimulatorBezelView` negates. Neither
// is a fix for the other's bug: they are two coordinate conventions and the shared value is stated in
// one of them.
//
// ⚠️ AND A `transform` MAKES `frame` MEANINGLESS. The assembly's size and position are written as
// `bounds` and `center` with the transform CLEARED, then the transform goes back on — the same
// obligation the AppKit half spells as "rotation is cleared before the frame is written". Writing
// `frame` on a rotated view sets the bounding box of the rotation, which is not the thing being sized.
//
// ⚠️ THE TURN IS A CUT, exactly as it is on the Mac, and for exactly the same reason: the subtree
// contains an `AVSampleBufferDisplayLayer` which disables its own implicit animations precisely
// because a frame arriving mid-animation cross-fades with the previous one and reads as motion blur.
// Turning a live video layer through 90° would do that for the whole quarter-turn. Getting the
// animation back means turning the BODY and the buttons while the screen cuts, which is a different
// drawing, not a missing modifier.

#if os(iOS)
import SlopDeskClientCore // `DeviceBezelGeometry` — where a piece of the artwork lands
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

// MARK: - The decode, once per device

/// The phone's half of ``SimulatorChromeArt``: `UIImage(data:)`, over the fold and the cache that
/// descended in increment 52a.
///
/// The DECODE is here and the two rules around it are not, which is exactly the split
/// ``SimulatorChromeBundle`` asked for when it stopped at bytes: which resources to fetch and what
/// makes a fetch a failure are decisions, and turning bytes into a picture is the platform's. The
/// deleted SwiftUI half spelled this over `Image.decoded`, which went with it.
@MainActor
enum PhoneSimulatorChrome {
    private static let cache = SimulatorChromeArtCache<UIImage>()

    /// `nil` ⇒ undrawable body, which the stage renders as a bare screen rather than as an error: a
    /// working screen with no body around it is still a working screen.
    static func art(for bundle: SimulatorChromeBundle) -> SimulatorChromeArt<UIImage>? {
        cache.art(for: bundle) { UIImage(data: $0) }
    }
}

// MARK: - The bezel

@MainActor
final class PhoneSimulatorBezelView: UIView {
    private let art: SimulatorChromeArt<UIImage>
    private let screen: PhoneSimulatorScreenView
    /// The device as one object — body, buttons and screen — so the whole thing turns together and the
    /// screen view's own coordinate space is left untouched. A transformed `UIView` is hit-tested in
    /// its UNTRANSFORMED bounds space, which is exactly the space the server expects a tap in.
    private let assembly = UIView()
    private let body = UIImageView()
    private var buttons: [PhoneSimulatorBezelButton] = []

    var orientation: SimulatorOrientation {
        didSet {
            guard orientation != oldValue else { return }
            screen.orientation = orientation
            setNeedsLayout()
        }
    }

    init(
        art: SimulatorChromeArt<UIImage>,
        frames: SimulatorFrameSink,
        orientation: SimulatorOrientation,
        send: @escaping (SimulatorInputEnvelope) -> Void,
        onContentSize: @escaping (CGSize) -> Void,
    ) {
        self.art = art
        self.orientation = orientation
        screen = PhoneSimulatorScreenView(frame: .zero)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        screen.send = send
        screen.orientation = orientation
        screen.onContentSize = onContentSize
        screen.clipsToBounds = true
        screen.layer.cornerCurve = .continuous
        frames.attach(screen)

        body.image = art.body
        // `scaleToFill`, matching the AppKit half's `scaleAxesIndependently`: the frame written below
        // is already the artwork's own aspect times one scale, so preserving it again would only
        // introduce a rounding gap between the body and the screen seated in it.
        body.contentMode = .scaleToFill
        // The body sits OVER the buttons and must never be hit, or every side button on the device
        // becomes unpressable.
        body.isUserInteractionEnabled = false

        // BUTTONS FIRST, then the body over them, then the screen. Any other order and a protruding
        // button reads as pasted beside the case instead of seated in it.
        for button in art.chrome.buttons {
            let view = PhoneSimulatorBezelButton(
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
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The mount is going away — a device switch, or the panel closing. The contact is forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone. This is the
    /// `dismantleUIView` the representable used to carry.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        screen.abandonGestures()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bleed = art.chrome.bleed
        let scale = SimulatorPresentation.fit(
            bleed.size,
            in: SimulatorPresentation.footprint(bounds.size, turned: orientation.isLandscape),
        )
        guard scale > 0 else { return }

        // See the header: `frame` is undefined under a transform, so the size and the position are
        // written as `bounds` and `center` with the transform cleared, and the turn goes back on last.
        assembly.transform = .identity
        let size = CGSize(width: bleed.width * scale, height: bleed.height * scale)
        assembly.bounds = CGRect(origin: .zero, size: size)
        assembly.center = CGPoint(x: bounds.midX.rounded(), y: bounds.midY.rounded())
        // NOT negated — see the header. Degrees in, radians out.
        assembly.transform = CGAffineTransform(rotationAngle: orientation.viewAngle * .pi / 180)

        // Every piece is seated the same way — ``DeviceBezelGeometry/seat(_:in:scale:)`` — because the
        // three of them differ only in which rectangle the artwork declares.
        let viewport = art.chrome.screen.viewport
        body.frame = DeviceBezelGeometry.seat(
            CGRect(origin: .zero, size: viewport), in: bleed, scale: scale,
        )
        screen.frame = DeviceBezelGeometry.seat(art.chrome.screen.rect, in: bleed, scale: scale)
        // Clipped rather than merely placed: unclipped video overhangs the rounded corners and reads
        // as a rendering bug, which is exactly the "looks unfinished" the bezel is here to fix.
        screen.layer.cornerRadius = art.chrome.screen.clipRadius * scale

        for (index, button) in art.chrome.buttons.enumerated() where index < buttons.count {
            buttons[index].frame = DeviceBezelGeometry.seat(
                button.frame(in: viewport), in: bleed, scale: scale,
            )
        }
    }
}

/// One physical button on the case: rest artwork, pressed artwork, and the envelope on release.
@MainActor
private final class PhoneSimulatorBezelButton: UIControl {
    private let rest: UIImage?
    private let pressed: UIImage?
    private let glyph = UIImageView()
    private let envelope: String
    private let send: (SimulatorInputEnvelope) -> Void

    init(
        button: SimulatorChrome.Button,
        art: (rest: UIImage, pressed: UIImage)?,
        send: @escaping (SimulatorInputEnvelope) -> Void,
    ) {
        rest = art?.rest
        pressed = art?.pressed
        envelope = button.envelopeButton
        self.send = send
        super.init(frame: .zero)
        glyph.contentMode = .scaleToFill
        glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glyph.isUserInteractionEnabled = false
        // No artwork for this one: stay PRESSABLE but draw nothing. A coloured placeholder would be a
        // fake button on a photoreal body, and refusing the press would silently drop a verb the
        // server still accepts.
        glyph.image = rest
        addSubview(glyph)

        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        addTarget(self, action: #selector(up), for: [.touchUpOutside, .touchCancel])

        isAccessibilityElement = true
        accessibilityTraits = .button
        // Both halves of the help string — see ``UIView/slateHelp(_:)``. A symbol-only control on a
        // photoreal body has no other human-readable name.
        slateHelp(SimulatorPresentation.buttonLabel(for: button.id))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
    }

    @objc
    private func down() { glyph.image = pressed ?? rest }

    @objc
    private func up() { glyph.image = rest }

    /// The envelope goes on the UP, and only inside — the hardware's own contract, and the one that
    /// keeps a press dragged off the key from firing it. `.touchUpInside` IS that condition.
    @objc
    private func fire() {
        glyph.image = rest
        send(.button(envelope))
    }

    override func accessibilityActivate() -> Bool {
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
final class PhoneSimulatorBareScreen: UIView {
    private let screen: PhoneSimulatorScreenView

    var orientation: SimulatorOrientation {
        didSet {
            guard orientation != oldValue else { return }
            screen.orientation = orientation
            setNeedsLayout()
        }
    }

    init(
        frames: SimulatorFrameSink,
        orientation: SimulatorOrientation,
        send: @escaping (SimulatorInputEnvelope) -> Void,
        onContentSize: @escaping (CGSize) -> Void,
    ) {
        self.orientation = orientation
        screen = PhoneSimulatorScreenView(frame: .zero)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        screen.send = send
        screen.orientation = orientation
        screen.onContentSize = onContentSize
        frames.attach(screen)
        addSubview(screen)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        screen.abandonGestures()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = SimulatorPresentation.footprint(bounds.size, turned: orientation.isLandscape)
        // Cleared, written, re-applied — the same obligation the bezel's own layout carries.
        screen.transform = .identity
        screen.bounds = CGRect(origin: .zero, size: box)
        screen.center = CGPoint(x: bounds.midX.rounded(), y: bounds.midY.rounded())
        screen.transform = CGAffineTransform(rotationAngle: orientation.viewAngle * .pi / 180)
    }
}
#endif
