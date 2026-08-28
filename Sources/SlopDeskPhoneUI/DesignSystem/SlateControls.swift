// SlateControls — the reusable chrome controls on the token layer (REBUILD-V2, L6/L9).
//
// The hover-plate button idiom, rung for rung:
//   idle  → transparent plate, icon tint
//   hover → plate fills with `Slate.Native.State.hover`, ~120ms `smallFade`
//   press → one rung further, `Slate.Native.State.selected`
// No springs — every transition rides a timing curve from `Slate.Motion`.

#if os(iOS)
import QuartzCore
import SFSafeSymbols
import SlopDeskSlate
import UIKit

/// A small icon button with a rounded hover plate: transparent when idle, filled under the pointer,
/// one rung further under the finger.
///
/// ⚠️ A `UIButton`, NOT a bare `UIControl`, and that is the whole reason ONE class covers both the verb
/// plate and the menu plate. A menu here is not a presented view controller: it is a button carrying a
/// `menu` with `showsMenuAsPrimaryAction = true`, and both of those are properties on `UIButton` and
/// nowhere else. Making the verb button the menu button's own base is what keeps the plate idiom — the
/// fill ladder, the fade, the acknowledgement — spelled ONCE for the two controls that draw it, instead
/// of a second copy living in whatever class happened to need a menu.
///
/// ⚠️ THE GLYPH IS OUR OWN `UIImageView`, never `setImage(_:for:)`. `UIButton`'s image machinery dims
/// its content on highlight, which would fight the plate fill that IS this control's press feedback —
/// two answers to one press, one of them the framework's default rather than this app's. `UIButton`
/// here is only the host for `isHighlighted` and `menu`; the anatomy is ``SlatePlateIconButton``'s.
///
/// The relationship to that control, stated because it is a real overlap: this button's ladder is
/// exactly ``SlatePlateIconButton``'s at `active == false, onTray == false`. What it has instead of the
/// latch is a caller-supplied ``tint`` — a device list's trailing verb draws in its row's tertiary ink,
/// the GUI control bar tints a latched mode with the accent — and what it lacks is
/// `active`/`morphOn`/`onTray`. Folding the two into one control means giving the SlateKit one a tint
/// property, a change to that file rather than this one.
@MainActor
final class SlatePlateVerbButton: UIButton {
    /// The glyph's ink. The caller's, not the control's: a device list's trailing verb draws in its
    /// row's tertiary ink, and the GUI control bar tints a latched mode with the accent.
    var tint: UIColor {
        didSet {
            guard tint != oldValue else { return }
            refreshGlyph()
        }
    }

    /// The tooltip AND the accessible name — see ``UIKit/UIView/slateHelp(_:)``. Symbol-only controls
    /// have no other human-readable name, so a help string that stopped at the tooltip would strand
    /// VoiceOver on a row of unlabelled buttons.
    var help: String? {
        didSet {
            guard help != oldValue else { return }
            slateHelp(help)
        }
    }

    private let symbol: SFSymbol
    private let glyphSize: CGFloat
    private let action: () -> Void
    private let glyph = UIImageView()
    /// The pointer is over the plate. iPadOS with a trackpad has hover exactly as the Mac does; a
    /// touch-only device never sets it, and the plate then reads press-only.
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            refreshFill()
        }
    }

    init(
        symbol: SFSymbol, help: String? = nil, size: CGFloat = Slate.Metric.iconSize,
        plate: CGFloat = Slate.Metric.plate, tint: UIColor = Slate.Native.Text.icon,
        action: @escaping () -> Void = {},
    ) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        glyphSize = size
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: plate, height: plate))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        backgroundColor = .clear

        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: plate),
            heightAnchor.constraint(equalToConstant: plate),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        // ⚠️ A `CGColor` on a layer is RESOLVED, not dynamic: it was fixed at the appearance current
        // when it was assigned. The registration names the ONE trait this control depends on rather
        // than waking on every trait change, and it is the modern spelling — `traitCollectionDidChange`
        // is deprecated at this deployment target.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: Self, _: UITraitCollection) in
            button.refreshGlyph()
            button.refreshFill(animated: false)
        }
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        slateHelp(help)
        refreshGlyph()
        refreshFill(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The press rung, and THE MENU PLATE TAKES IT TOO.
    ///
    /// That is worth stating because it is the one behaviour this control gained rather than carried
    /// over. A menu plate used to draw hover and nothing else: a press never reached the label of the
    /// declarative `Menu` it was built from, which was an artifact of that framework and not a decision
    /// about how a menu plate should read. `isHighlighted` reaches a `UIButton` whether it opens a menu
    /// or runs a verb, so both get the same press rung — a plate is a plate wherever it is mounted.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            refreshFill()
        }
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began,
             .changed: hovering = true
        default: hovering = false
        }
    }

    @objc
    private func fire() {
        // A verb answers the press — its real effect (a device booting, a window resizing) is seconds
        // away, and a key that waits for the reply reads as one that missed the tap.
        //
        // A MENU plate does not: what answers there is the menu appearing. `showsMenuAsPrimaryAction`
        // already means `.touchUpInside` never fires on one, so this guard is belt-and-braces — but it
        // is the guard that states the rule, rather than leaving it as a fact about UIKit's dispatch
        // that a later `sendActions(for:)` could quietly break.
        if menu == nil {
            glyph.addSymbolEffect(.bounce.down, options: .speed(Slate.Anim.ackSpeed))
        }
        action()
    }

    /// MEDIUM, always — this button never latches, so it never steps up to semibold. At 13pt an SF
    /// Symbol in the regular weight goes wispy against a light theme's paper, which is why the rest
    /// weight is one rung above regular on both plate idioms.
    private func refreshGlyph() {
        glyph.image = UIImage(
            systemName: symbol.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium),
        )?.withTintColor(tint.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
    }

    /// Idle transparent, hover faint, press one rung past hover — the three rungs a non-latching plate
    /// has, against ``SlatePlateIconButton``'s five.
    ///
    /// Both directions through the same 120ms fade (``Slate/Motion/smallFade``), so a tap shorter than
    /// that still shows: the release fades from wherever the press had reached. `CATransaction` rather
    /// than `UIView.animate` because the property is the LAYER's — a background colour set on the view
    /// would fight the corner radius the plate is drawn with.
    private func refreshFill(animated: Bool = true) {
        let fill: UIColor =
            if isHighlighted {
                Slate.Native.State.selected
            } else if hovering {
                Slate.Native.State.hover
            } else {
                .clear
            }
        let resolved = fill.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = resolved
        CATransaction.commit()
    }
}

/// The MENU twin of ``SlatePlateVerbButton``: the SAME plate around an icon that drops a menu.
///
/// COMPOSED, NOT SUBCLASSED, which is the ruling the Mac's `macPlateMenuButton` already carries: a menu
/// is a different ACTION on the same button, not a different button, so it belongs in the button's
/// configuration rather than in a third class that would be a third place for the plate's rules to
/// drift. `SlatePlateVerbButton` stays `final`.
///
/// ⚠️ THE MENU IS BUILT AT OPEN, and that is a behaviour this RESTORES rather than one it invents. A
/// declarative `Menu`'s content was evaluated with the enclosing view body, not when the menu opened —
/// `GuiPastePlateMenu.canPasteCurrent`'s header records what that cost: every render of the GUI footer
/// was reading the clipboard, so iOS put an unprompted "Allow Paste?" alert on screen, and the phone had
/// to ask a weaker question (a probe) than the Mac's menu does. `UIDeferredMenuElement` in its
/// `.uncached` form runs its provider EVERY time the menu is displayed, which is exactly the moment
/// `macPlateMenuButton`'s `itemsAtOpen` names. Live state — the host's displays as they stand now, the
/// clipboard ring as it stands now — is therefore read once per open, by both shells.
///
/// The menu vocabulary maps whole: a divider between rows is a nested `UIMenu(options: .displayInline)`
/// section, a check-marked row is a ``slateMenuRow`` with `checked: true`, a greyed row is one with
/// `enabled: false`, and a submenu is a nested `UIMenu` with a title.
@MainActor
func slatePlateMenuButton(
    symbol: SFSymbol, help: String? = nil, tint: UIColor = Slate.Native.Text.icon,
    itemsAtOpen: @escaping () -> [UIMenuElement],
) -> SlatePlateVerbButton {
    let button = SlatePlateVerbButton(symbol: symbol, help: help, tint: tint)
    button.menu = UIMenu(title: "", children: [
        UIDeferredMenuElement.uncached { complete in complete(itemsAtOpen()) },
    ])
    // Primary action, so ONE tap opens the menu. Without it a `UIButton` with a `menu` needs a
    // long press, and the plate would answer a tap by doing nothing at all.
    button.showsMenuAsPrimaryAction = true
    return button
}

/// A menu row, spelled once so no two menus can disagree about what "disabled" or "checked" looks
/// like — the UIKit twin of the Mac's `macMenuItem`.
@MainActor
func slateMenuRow(
    _ title: String, enabled: Bool = true, checked: Bool = false, action: (() -> Void)? = nil,
) -> UIAction {
    UIAction(
        title: title,
        attributes: enabled ? [] : .disabled,
        state: checked ? .on : .off,
    ) { _ in action?() }
}

/// A run of rows fenced off from its neighbours, which UIKit spells as an inline sub-menu rather than
/// as a separator element. There is no divider OBJECT to place: the sections are the dividers.
@MainActor
func slateMenuSection(_ rows: [UIMenuElement]) -> UIMenu {
    UIMenu(title: "", options: .displayInline, children: rows)
}

extension UIView {
    /// Carry a help string, which lands in TWO places.
    ///
    /// ⚠️ The accessible name is the load-bearing half. `UIToolTipInteraction` is a pointer affordance
    /// and nothing more, so stopping there would leave every symbol-only plate in the app unnamed to
    /// VoiceOver — these controls have no title, so the help string is the only human-readable thing
    /// they carry. A declarative `.help(_:)` folded the two together for free; UIKit makes you say
    /// both, which is why saying both lives here and not at sixteen call sites.
    ///
    /// `nil` clears both, and the interaction is REUSED rather than stacked: a control whose help text
    /// changes with its state (the console's follow plate says "Follow" or "Stop following") would
    /// otherwise grow one interaction per flip.
    func slateHelp(_ text: String?) {
        accessibilityLabel = text
        if let existing = interactions.compactMap({ $0 as? UIToolTipInteraction }).first {
            existing.defaultToolTip = text
        } else if let text {
            addInteraction(UIToolTipInteraction(defaultToolTip: text))
        }
    }
}
#endif
