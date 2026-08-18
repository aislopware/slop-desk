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
