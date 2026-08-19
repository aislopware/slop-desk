// MacSimulatorParts — the pieces of the Simulators panel that name a SIMULATOR, in AppKit
// (docs/56 stage D, increments 52a and 53).
//
// What is left here after increment 53 is the whole of what could not merge, and the test is
// mechanical: **every declaration below names a simulator type in its signature.** The ink resolver
// takes a ``SimulatorInk``, the family mark a ``SimulatorDevice``, the fact line and the fact view a
// ``SimulatorFact``. The eleven shells that took `String`, `NSView`, `SFSymbol` or nothing at all went
// to `MacDevicePanelParts.swift`, because a shell with no device type in its signature is chrome
// rather than a device abstraction — see that file's header for the line and why it holds.
//
// The rule those eleven did NOT bend: nothing that names a simulator may be factored against the
// Android half. The two panels share not one byte of protocol, and a common device vocabulary would be
// an abstraction over a coincidence.
//
// WHAT IS NOT HERE. The words are ``SimulatorPresentation``'s, one target down and shared with the
// phone.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - The ink roles, resolved

/// One role from ``SimulatorInk`` as a colour.
///
/// The half that resolves, and the reason ``SimulatorInk`` exists at all: `SlopDeskSlate` DEPENDS on
/// `SlopDeskDevicePanels`, so a token cannot descend without becoming a cycle. Four lines here, four
/// lines on the phone, and the DECISION about which run is loud is neither's.
@MainActor
enum MacSimulatorInk {
    static func color(_ ink: SimulatorInk) -> NSColor {
        switch ink {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        case .alarm: Slate.Native.StatusInk.err
        }
    }
}

// MARK: - The device-family mark

/// The device family as a SHAPE, so the kind of machine is answered without reading a word.
///
/// One glyph per family and no finer — see ``SimulatorDeviceKind/symbol`` for which silhouette each
/// family gets and why the pad is turned on its side. Drawn in the ICON ink rather than the primary
/// one: every row carries this, so at full contrast a column of them is a rule down the leading edge
/// competing with the names they exist to help find.
///
/// LEADING, not centred: inside a family group every row carries the SAME silhouette, so what centring
/// would buy is nothing, while what it costs is the heading — a 13pt phone centred in a 24pt column
/// starts five points right of the `IPHONE` above it.
@MainActor
func macSimulatorFamilyMark(_ device: SimulatorDevice) -> NSView {
    let kind = SimulatorDeviceKind.infer(from: device.name)
    let glyph = NSImageView(
        image: NSImage(systemSymbolName: kind.symbol.rawValue, accessibilityDescription: nil)
            ?? NSImage(),
    )
    glyph.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Slate.Typeface.body, weight: .medium,
    )
    glyph.contentTintColor = Slate.Native.Text.icon
    glyph.imageAlignment = .alignLeft
    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.widthAnchor.constraint(equalToConstant: Slate.Metric.deviceMarkWidth).isActive = true
    return glyph
}

// MARK: - The fact line

/// The header's measured facts, middle-dot separated, each with its own tooltip and its own Copy.
///
/// The four rules the line keeps are `SlateFactLine`'s and are not restated: figures speak the
/// instrument voice, every fact is copyable on its own, the separator belongs to the LINE rather than
/// to a fact (so a fact appearing or leaving cannot strand a dangling `·`), and the label is drawn
/// rather than only hovered.
@MainActor
final class MacSimulatorFactLine: NSStackView {
    init(_ facts: [SimulatorFact], size: CGFloat = Slate.Typeface.footnote) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false

        for (index, fact) in facts.enumerated() {
            if index > 0 {
                addArrangedSubview(macDevicePanelLabel(
                    "·", size: size, color: Slate.Native.Text.tertiary,
                ))
            }
            addArrangedSubview(MacSimulatorFactView(fact, size: size))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addArrangedSubview(spacer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

/// One fact: its grey label and its value, as ONE hit target — the tooltip, the Copy menu and the
/// truncation all belong to the pair, not to the word in front of it.
@MainActor
private final class MacSimulatorFactView: NSStackView {
    private let copies: String
    private let title: String

    init(_ fact: SimulatorFact, size: CGFloat) {
        copies = fact.copies
        title = SimulatorPresentation.copyTitle(fact)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false

        if fact.showsLabel {
            let name = macDevicePanelLabel(
                fact.label, size: size, color: Slate.Native.Text.tertiary,
            )
            // The LABEL is what yields first when the band narrows: a truncated grey word is still a
            // hint, and a truncated figure is a wrong number.
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addArrangedSubview(name)
        }
        addArrangedSubview(macDevicePanelLabel(
            fact.text, size: size, color: MacSimulatorInk.color(fact.ink), mono: fact.isMeasured,
        ))
        toolTip = fact.label
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The context menu is built per click rather than stored: it is one item, and an `NSMenu` held by
    /// every fact of every header is a retained object per figure on screen.
    override func menu(for _: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: #selector(copyValue), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Through the ONE funnel, never a second `NSPasteboard.general` pair — the clear-then-write is
    /// load-bearing on AppKit and ``ClientPasteboard/write(_:)`` already owns it.
    @objc
    private func copyValue() { ClientPasteboard.write(copies) }
}
