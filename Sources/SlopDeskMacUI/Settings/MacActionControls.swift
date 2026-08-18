// MacActionControls — AppKit controls that carry their own handler.
//
// Target/action wants a target OBJECT and a selector, which for a page built at runtime means either
// a controller full of `@objc` methods that then has to work out which row fired, or a control that
// holds its own closure. The second is what a schema-driven page wants: the row builder already knows
// what a control writes when it is built, and nothing downstream has to re-derive it.
//
// Each subclass adds exactly one thing — the closure and the `self`-targeted action that calls it —
// and the TOKEN-selecting pair add a second: a token is what the option catalog carries, so a control
// over a group is asked to select and report tokens rather than indices. An index would break
// silently the first time an option was inserted, which is the same reason the boundary crosses
// tokens in the first place.

import AppKit
import SlopDeskClientUI // Slate — the ONE token ladder, in its native (NSColor/NSFont) view

/// A checkbox that reports its new state.
final class MacActionSwitch: NSSwitch {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    @objc
    private func fire() { handler(state == .on) }
}

/// A push button that runs its own closure.
final class MacActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    @objc
    private func fire() { handler() }
}

/// A vertical radio group whose buttons stand for TOKENS.
///
/// A settings page answers "pick one of a few" with a pop-up, because a page of twenty rows cannot
/// spend four lines on each. A first-launch STEP is the opposite shape — one question, a whole card to
/// ask it in — so the choices are laid out where a reader can see both at once without a click. Same
/// option catalog, same tokens; the widget is what the surface decides.
final class MacActionRadios: NSStackView {
    private let tokens: [String]
    private let handler: (String) -> Void
    private var buttons: [NSButton] = []

    init(tokens: [String], titles: [String], _ handler: @escaping (String) -> Void) {
        self.tokens = tokens
        self.handler = handler
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false
        for title in titles {
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(fire))
            buttons.append(button)
            addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Show the button standing for `token`. A token no button stands for selects NOTHING rather than
    /// falling to the first, which would show the reader a value they do not have.
    func selectToken(_ token: String) {
        guard let index = tokens.firstIndex(of: token) else { return }
        for (position, button) in buttons.enumerated() { button.state = position == index ? .on : .off }
    }

    @objc
    private func fire(_ sender: NSButton) {
        guard let index = buttons.firstIndex(of: sender), tokens.indices.contains(index) else { return }
        handler(tokens[index])
    }
}

/// A pop-up whose items stand for TOKENS, reported by token rather than by index.
final class MacActionPopUp: NSPopUpButton {
    private let tokens: [String]
    private let handler: (String) -> Void

    init(tokens: [String], _ handler: @escaping (String) -> Void) {
        self.tokens = tokens
        self.handler = handler
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Show the item standing for `token`. A token no item stands for selects NOTHING rather than
    /// falling to the first item, which would silently show the reader a value they do not have.
    func selectToken(_ token: String) {
        guard let index = tokens.firstIndex(of: token) else { return }
        selectItem(at: index)
    }

    @objc
    private func fire() {
        guard tokens.indices.contains(indexOfSelectedItem) else { return }
        handler(tokens[indexOfSelectedItem])
    }
}

/// A segmented control whose segments stand for TOKENS — the Mac's answer to a row of cards.
final class MacActionSegments: NSSegmentedControl {
    private let tokens: [String]
    private let handler: (String) -> Void

    init(tokens: [String], _ handler: @escaping (String) -> Void) {
        self.tokens = tokens
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func selectToken(_ token: String) {
        guard let index = tokens.firstIndex(of: token) else { return }
        selectedSegment = index
    }

    @objc
    private func fire() {
        guard tokens.indices.contains(selectedSegment) else { return }
        handler(tokens[selectedSegment])
    }
}

/// A slider that reports its value as it moves — continuously, so the readout beside it tracks the
/// thumb rather than jumping when the drag ends.
final class MacActionSlider: NSSlider {
    private let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isContinuous = true
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    @objc
    private func fire() { handler(doubleValue) }
}

/// A plus/minus stepper that reports its value.
final class MacActionStepper: NSStepper {
    private let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    @objc
    private func fire() { handler(doubleValue) }
}

/// A text field that commits on Return and on losing focus, never per keystroke.
///
/// Per-keystroke would be wrong for every field a settings page has: each write persists and
/// re-publishes, so typing three characters into the custom-schemes field would rebuild the terminal
/// config three times. The same reasoning the font combobox spells as a draft-commit debouncer, in
/// the form AppKit already gives — `NSTextField` sends its action on Return, and its delegate reports
/// the end of editing.
final class MacActionField: NSTextField, NSTextFieldDelegate {
    private let handler: (String) -> Void

    init(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isEditable = true
        isBordered = true
        bezelStyle = .roundedBezel
        delegate = self
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    @objc
    private func fire() { handler(stringValue) }

    func controlTextDidEndEditing(_: Notification) { handler(stringValue) }
}
