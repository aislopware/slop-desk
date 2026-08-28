// PhoneAndroidParts — the three things every file in this directory needs, and nothing else.
//
// The ink ROLE resolved to hues, the device family as a shape, and a device's context menu as UIKit
// elements. The Mac's counterpart is ``SlopDeskMacUI/MacAndroidParts`` and it holds the same first two;
// the third is here because a `UIMenu` and an `NSMenu` are built differently enough that the two shells
// each assemble their own, off the ONE table (``AndroidPresentation/menu(for:)``).
//
// ⚠️ NOTHING HERE IS FACTORED AGAINST THE SIMULATOR HALF, and that is a judgement rather than an
// oversight. The two panels look alike and share not one byte of protocol — `scrcpy` over `adb`
// against `baguette`'s websocket, Annex-B against AVC, packed control messages against JSON envelopes.
// A `PhoneDeviceInk` covering both would be one enum with two disjoint sets of cases and a family mark
// that had to ask which device type it was looking at; the resemblance is a coincidence, not an
// abstraction waiting to be found. What genuinely IS shared — the empty stage, the notice, the clear
// key, the veil's actuator — already lives in ``PhoneDevicePanelChrome``.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

/// An ink ROLE resolved to this half's hues.
///
/// The role descends and the hue does not, because `SlopDeskSlate` sits ABOVE `SlopDeskDevicePanels`
/// and a token named from down there would be a cycle rather than a widening (docs/56 §2). The Mac's
/// half spells the same five answers as `NSColor`s in ``SlopDeskMacUI/MacAndroidInk``.
///
/// An `enum` of statics rather than an `extension AndroidInk`, which is what the deleted SwiftUI half
/// was: a computed property on a `Sendable` enum is nonisolated by default, so the extension had to
/// carry a `@MainActor` of its own to reach main-actor theme state. A namespace that is already
/// `@MainActor` needs no such note on every member.
@MainActor
enum PhoneAndroidInk {
    static func color(_ ink: AndroidInk) -> UIColor {
        switch ink {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        case .icon: Slate.Native.Text.icon
        // `StatusInk`, not `Status`: this rung is spent on TEXT, and the two ladders part exactly
        // there — a dot may be `systemRed` because it is a shape, a word may not.
        case .err: Slate.Native.StatusInk.err
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
/// ⚠️ WHICH glyph is ``AndroidDeviceKind/infer(_:)``'s, and `docs/48`'s first list trap is the reason:
/// `ro.build.characteristics` is `emulator,nosdcard` on most emulators, and `nosdcard` contains `car`,
/// so a substring search draws an automotive head unit for every phone AVD. The crate matches TOKENS.
@MainActor
func phoneAndroidFamilyMark(_ device: AndroidDevice) -> UIView {
    let glyph = UIImageView()
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.contentMode = .left
    glyph.tintColor = PhoneAndroidInk.color(.icon)
    glyph.image = UIImage(
        systemName: AndroidDeviceKind.infer(device).symbol.rawValue,
        withConfiguration: UIImage.SymbolConfiguration(
            pointSize: Slate.Typeface.body, weight: .medium,
        ),
    )?.withRenderingMode(.alwaysTemplate)
    glyph.isAccessibilityElement = false
    NSLayoutConstraint.activate([
        glyph.widthAnchor.constraint(equalToConstant: Slate.Metric.deviceMarkWidth),
    ])
    return glyph
}

/// A device's context menu, as UIKit elements.
///
/// The menu is a TABLE from below and this is only its drawing — which verbs a device offers, in what
/// order, and where the separator falls are decisions, and a decision drawn twice drifts silently
/// (``AndroidPresentation/menu(for:)``).
///
/// ⚠️ `.separator` becomes a SECTION BOUNDARY, not an element. UIKit has no divider object: an inline
/// sub-menu IS the divider, so the flat run the crate answers is cut at every separator and each piece
/// becomes a ``slateMenuSection``. A trailing or leading separator therefore costs nothing, where a
/// divider element would have drawn a stray line.
@MainActor
func phoneAndroidDeviceMenu(
    for device: AndroidDevice, run: @escaping (AndroidDeviceVerb) -> Void,
) -> [UIMenuElement] {
    var sections: [[UIAction]] = [[]]
    for entry in AndroidPresentation.menu(for: device) {
        switch entry {
        case .separator:
            sections.append([])
        case let .verb(verb):
            sections[sections.count - 1].append(slateMenuRow(verb.title) { run(verb) })
        }
    }
    return sections.filter { !$0.isEmpty }.map { slateMenuSection($0) }
}

/// The pending spinner both list depths draw while a boot or a shutdown is in flight.
///
/// `UIActivityIndicatorView` rather than the deleted `WorkingSpinner`, which was a SwiftUI view built
/// to dodge `ProgressView` resolving the Aqua appearance inside a hosted column — a hosting problem
/// that cannot exist in a tree with no hosting controller in it. Tinted from the token ladder, which is
/// the only part of that view that was ever about this app.
@MainActor
func phoneAndroidPendingSpinner() -> UIActivityIndicatorView {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = PhoneAndroidInk.color(.tertiary)
    spinner.hidesWhenStopped = false
    spinner.startAnimating()
    return spinner
}
#endif
