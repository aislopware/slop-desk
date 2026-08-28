// PhoneSimulatorParts — the four things every file in this directory needs, and nothing else.
//
// The ink ROLE resolved to hues, the device family as a shape, a device's context menu as UIKit
// elements, and the keyed task holder that stands in for `.task(id:)`. The Mac's counterpart is
// ``SlopDeskMacUI/MacSimulatorParts`` and it holds the first three; the fourth is here because AppKit
// spells it as `MacDevicePanelLoop` in a file this half may not reach.
//
// ⚠️ NOTHING HERE IS FACTORED AGAINST THE ANDROID HALF, for the reason ``PhoneAndroidParts`` states at
// length: the two panels look alike and share not one byte of protocol, so a `PhoneDeviceInk` covering
// both would be one enum with two disjoint case sets. What genuinely IS shared already lives in
// ``PhoneDevicePanelChrome``.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

/// An ink ROLE resolved to this half's hues.
///
/// The role descends and the hue does not, because `SlopDeskSlate` sits ABOVE `SlopDeskDevicePanels`
/// and a token named from down there would be a cycle rather than a widening (docs/56 §2). The Mac's
/// half spells the same four answers as `NSColor`s in ``SlopDeskMacUI/MacSimulatorInk``.
///
/// An `enum` of statics rather than an `extension SimulatorInk`, which is what the deleted SwiftUI half
/// was: a computed property on a `Sendable` enum is nonisolated by default, so the extension had to
/// carry a `@MainActor` of its own to reach main-actor theme state.
@MainActor
enum PhoneSimulatorInk {
    static func color(_ ink: SimulatorInk) -> UIColor {
        switch ink {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        // `StatusInk`, not `Status`: this rung is spent on TEXT, and the two ladders part exactly
        // there — a dot may be `systemRed` because it is a shape, a word may not.
        case .alarm: Slate.Native.StatusInk.err
        }
    }
}

/// The device family as a SHAPE, so the kind of machine is answered without reading a word. Shared by
/// the rows and the cards so one device reads the same in both.
///
/// Drawn in the ICON ink: every row carries this, and at full contrast a column of them is a rule down
/// the leading edge competing with the names they exist to help find. LEADING inside a fixed width, so
/// a wide glyph and a narrow one still start their titles at the same x.
///
/// WHICH silhouette each family gets is ``SimulatorDeviceKind/symbol``'s — one glyph per family and no
/// finer, because nothing in SF Symbols tells a 17 Pro from a 17 Pro Max and faking that with a point
/// of scale would be noise wearing the costume of information.
@MainActor
func phoneSimulatorFamilyMark(_ device: SimulatorDevice) -> UIView {
    let glyph = UIImageView()
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.contentMode = .left
    glyph.image = UIImage(
        systemName: SimulatorDeviceKind.infer(from: device.name).symbol.rawValue,
        withConfiguration: UIImage.SymbolConfiguration(
            pointSize: Slate.Typeface.body, weight: .medium,
        ),
    )?.withRenderingMode(.alwaysTemplate)
    // A dynamic `UIColor` on `tintColor` is re-resolved by UIKit itself, so there is no `CGColor` here
    // to go stale and no trait registration to keep matched.
    glyph.tintColor = Slate.Native.Text.icon
    glyph.widthAnchor.constraint(equalToConstant: Slate.Metric.deviceMarkWidth).isActive = true
    glyph.isAccessibilityElement = false
    return glyph
}

/// A device's context menu, off the ONE table.
///
/// The VERBS and their order are ``SimulatorPresentation/menu(for:)``'s, so the two halves' menus
/// cannot come apart; what is here is the wiring from a verb to the model call behind it.
///
/// ⚠️ `UIMenu` HAS NO SEPARATOR ELEMENT. The table's ``SimulatorDeviceVerb/separator`` — a verb whose
/// `title` is `nil` — becomes the boundary between two inline sub-menus, which is UIKit's whole
/// vocabulary for a fenced run. There is no divider OBJECT to place: the sections ARE the dividers.
@MainActor
func phoneSimulatorDeviceMenu(
    model: SimulatorSidebarModel, device: SimulatorDevice, onOpen: @escaping () -> Void,
) -> UIMenu {
    var sections: [[UIAction]] = [[]]
    for verb in SimulatorPresentation.menu(for: device) {
        guard let title = verb.title else {
            sections.append([])
            continue
        }
        let row: UIAction = switch verb {
        case .openScreen:
            slateMenuRow(title) { onOpen() }
        // The panel can already put a capture on the pasteboard, and a running device's screen is
        // often worth a picture without being worth opening.
        case .copyScreenshot:
            slateMenuRow(title) { Task { await model.copyScreenshot(of: device.udid) } }
        case .shutdown:
            slateMenuRow(title) { Task { await model.shutdown(device.udid) } }
        case .boot:
            slateMenuRow(title) { Task { await model.boot(device.udid) } }
        // Through the ONE funnel, never a second `UIPasteboard.general` pair.
        case .copyUDID:
            slateMenuRow(title) { ClientPasteboard.write(device.udid) }
        case .copyName:
            slateMenuRow(title) { ClientPasteboard.write(device.name) }
        case .separator:
            // Unreachable — the `guard` above took it. Spelled so the switch stays exhaustive without
            // a `default` that would swallow a verb added later.
            slateMenuRow(title)
        }
        sections[sections.count - 1].append(row)
    }
    return UIMenu(children: sections.filter { !$0.isEmpty }.map { slateMenuSection($0) })
}

/// The pending spinner both list depths draw while a boot or a shutdown is in flight.
///
/// `UIActivityIndicatorView` rather than the deleted `WorkingSpinner`, which was a SwiftUI view built
/// to dodge `ProgressView` resolving the Aqua appearance inside a hosted column — a hosting problem
/// that cannot exist in a tree with no hosting controller in it. Tinted from the token ladder, which is
/// the only part of that view that was ever about this app.
@MainActor
func phoneSimulatorPendingSpinner() -> UIActivityIndicatorView {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = PhoneSimulatorInk.color(.tertiary)
    spinner.hidesWhenStopped = false
    spinner.startAnimating()
    return spinner
}

/// `.task(id:)`, written out.
///
/// The IDENTITY CHECK is the whole thing: re-keying on the value that is already running must be a
/// no-op, or a thumbnail poll would restart on every list repaint and a veil would re-arm its delay on
/// every arriving frame. Cancelling and re-running on a CHANGED key is the other half, and it is what
/// makes the loading veil for a stream that arrived in time never appear at all.
///
/// ⚠️ The key is `AnyHashable` rather than a generic parameter, because a holder is a STORED PROPERTY
/// and its key type varies per call site within one view (the stage keys its veil on a `String` and its
/// screen on a `String?`). A generic would force one holder per key type.
@MainActor
final class PhoneSimulatorLoop {
    private var key: AnyHashable?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    /// Run `body` for `key`, cancelling whatever was running for a different one. Re-keying on the
    /// live key does nothing.
    func keyed(on key: some Hashable, run body: @escaping @MainActor () async -> Void) {
        let wanted = AnyHashable(key)
        guard wanted != self.key || task == nil else { return }
        task?.cancel()
        self.key = wanted
        task = Task { await body() }
    }

    /// Stop, and forget the key — the next `keyed(on:)` starts fresh even for the same value. Called
    /// from `prepareForReuse` and from leaving the window, where "the same device, in a different
    /// cell" must not be mistaken for "still running".
    func cancel() {
        task?.cancel()
        task = nil
        key = nil
    }
}

// MARK: - One beat, spent at the app's own curve

/// Animate `body` on a rung of ``Slate/Motion``.
///
/// ⚠️ `UIView.animate(withDuration:)` is NOT this. Its default is `.curveEaseInOut`, which happens to be
/// ``Slate/Motion/standard``'s four control points and is NOT any other rung's — so a `smallFade` run
/// through the plain call is drawn at the wrong curve while reading, at the call site, as if it were
/// not. The property animator takes the control points, so the rung a caller names is the rung it gets.
///
/// The completion is `@MainActor` because UIKit runs it on the main thread without having said so, and
/// every caller here is a view tearing down the thing that just faded out.
@MainActor
func phoneSimulatorAnimate(
    _ curve: SlateCurve,
    _ body: @escaping @MainActor () -> Void,
    completion: (@MainActor () -> Void)? = nil,
) {
    let animator = UIViewPropertyAnimator(
        duration: curve.duration,
        controlPoint1: CGPoint(x: curve.x1, y: curve.y1),
        controlPoint2: CGPoint(x: curve.x2, y: curve.y2),
    )
    animator.addAnimations { MainActor.assumeIsolated { body() } }
    if let completion {
        animator.addCompletion { _ in MainActor.assumeIsolated { completion() } }
    }
    animator.startAnimation()
}
#endif
