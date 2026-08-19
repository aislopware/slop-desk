// MacAndroidParts — the pieces of the Android panel that name an ANDROID DEVICE, in AppKit
// (docs/56 stage D, increments 52b and 53).
//
// Increment 52b's header listed the shells here that touch no device type and called them "the honest
// candidates for one `MacDevicePanelParts.swift` once both halves have landed and their shapes have
// stopped moving". Increment 53 is that merge, and what is left in this file is the residue the test
// predicted: **every declaration below names an Android type in its signature.** The ink resolver takes
// an ``AndroidInk``, the family mark an ``AndroidDevice``, the fact line and the fact view an
// ``AndroidFact``.
//
// The rule the merge did NOT bend, and it is 52b's: nothing that names a device may be factored against
// the Simulator half. The two panels share not one byte of protocol — `scrcpy` over `adb` against
// `baguette`'s websocket, Annex-B against AVC, packed control messages against JSON envelopes — and a
// common device vocabulary would be an abstraction over a coincidence. A shell taking `String`,
// `NSView` or `SFSymbol` is chrome and merged; a function taking an `AndroidDevice` is protocol and
// stayed.
//
// WHAT IS NOT HERE. The words and the folds are ``AndroidPresentation``'s, one target down and shared
// with the phone.

import AppKit
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - The ink roles, resolved

/// One role from ``AndroidInk`` as a colour.
///
/// The half that resolves, and the reason ``AndroidInk`` exists at all: `SlopDeskSlate` DEPENDS on
/// `SlopDeskClientCore`, which sits beside `SlopDeskDevicePanels` and above nothing that could name a
/// token back — so a hue cannot descend without becoming a cycle. Five lines here, five lines on the
/// phone, and the DECISION about which run is loud is neither's.
@MainActor
enum MacAndroidInk {
    static func color(_ ink: AndroidInk) -> NSColor {
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

// MARK: - The device-family mark

/// The device family as a SHAPE, so the kind of machine is answered without reading a word.
///
/// One glyph per family and no finer — see ``AndroidDeviceKind/symbol`` for which silhouette each
/// family gets. Drawn in the ICON ink rather than the primary one: every row carries this, so at full
/// contrast a column of them is a rule down the leading edge competing with the names they exist to
/// help find.
///
/// LEADING, not centred: inside a family group every row carries the SAME silhouette, so what centring
/// would buy is nothing, while what it costs is the heading — a 13pt phone centred in a 24pt column
/// starts five points right of the caps label above it.
@MainActor
func macAndroidFamilyMark(_ device: AndroidDevice) -> NSView {
    let glyph = NSImageView(
        image: NSImage(
            systemSymbolName: AndroidDeviceKind.infer(device).symbol.rawValue,
            accessibilityDescription: nil,
        ) ?? NSImage(),
    )
    glyph.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Slate.Typeface.body, weight: .medium,
    )
    glyph.contentTintColor = MacAndroidInk.color(.icon)
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
final class MacAndroidFactLine: NSStackView {
    init(_ facts: [AndroidFact], size: CGFloat = Slate.Typeface.footnote) {
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
            addArrangedSubview(MacAndroidFactView(fact, size: size))
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
private final class MacAndroidFactView: NSStackView {
    private let copies: String
    private let title: String

    init(_ fact: AndroidFact, size: CGFloat) {
        copies = fact.copies
        title = AndroidPresentation.copyTitle(fact)
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
            fact.text, size: size, color: MacAndroidInk.color(fact.ink), mono: fact.isMeasured,
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
