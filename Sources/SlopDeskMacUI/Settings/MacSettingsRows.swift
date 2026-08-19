// MacSettingsRows — one described row, as an AppKit view.
//
// Every row here takes a `SettingsLayout.Row` and a `MacSettingAccess` and returns an `NSView`.
// NOTHING in this file spells a label, a subtitle, an option name or a range: the first two are the
// row's, the third is `SettingsCatalog.options(...)`, and the fourth is the ladder's or the stepper's.
// That is the property `check-supervisor` ratchets on the SwiftUI side, and it holds here by the same
// construction — a view that cannot reach a string cannot drift from it.
//
// A row's SHAPE is `Control`, which names a widget KIND and never a widget. So the Mac answers
// `.cards` with a segmented control rather than the phone's tile grid: a card grid is how a
// touch target shows art per option, and a settings window with a mouse has a control for exactly
// this that carries the system's own focus ring and keyboard traversal. Same schema, different
// drawing — which is the whole point of splitting the two halves (docs/56 §3).

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - The label stack every row leads with

/// The bold label over its gray subtitle — the shape a settings row's words are set in.
@MainActor
func macRowLabel(_ title: String, _ subtitle: String, glyph: String? = nil) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Slate.Metric.space1 / 2

    let name = NSTextField(labelWithString: title)
    name.font = .preferredFont(forTextStyle: .body)
    stack.addArrangedSubview(name)

    if !subtitle.isEmpty {
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = Slate.Native.Text.secondary
        detail.isSelectable = false
        stack.addArrangedSubview(detail)
    }

    guard let glyph, let image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil) else {
        return stack
    }
    // The group's icon rail: a row whose meaning no icon improves still lands ON the rail, so a
    // twenty-switch page stays scannable.
    let icon = NSImageView(image: image)
    icon.contentTintColor = Slate.Native.Text.icon
    icon.translatesAutoresizingMaskIntoConstraints = false
    let row = NSStackView(views: [icon, stack])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = Slate.Metric.space2
    NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: Slate.Metric.iconSize)])
    return row
}

// MARK: - The row builder

/// Builds one row of a group, or `nil` for a row this half draws nothing for.
///
/// A `nil` is not a failure to handle a case — it is the honest answer for a row whose control kind
/// this build has no widget for. Drawing an empty box would look like a bug rather than an absence.
@MainActor
struct MacSettingsRowBuilder {
    let bindings: MacSettingsBindings
    /// The Agents card's install-hooks model. Handed to the hooks surface DIRECTLY rather than through an
    /// environment: the environment injection existed for the hosted SwiftUI subtree, and the device-local
    /// preference owner that rode beside it is already on ``bindings`` (`MacSettingsBindings.workspace`),
    /// which is the one place the Mac resolves device-local storage.
    let agentHooks: AgentHooksController?
    /// Called with the key a control just wrote. Some writes change which OTHER rows belong on the
    /// page — the window-size mode, the link-scheme mode, the line-height mode — and those conditions
    /// are on a setting's value rather than on the platform, so they are the renderer's and the page
    /// rebuilds rather than the table listing two variants of itself. The page decides which keys
    /// those are; a builder that rebuilt on every write would throw away the search query someone had
    /// typed into a hosted surface two groups below.
    let onValueChanged: (String) -> Void
    /// Where the All-Settings index's ✎ sends the navigator, by section id.
    let onJump: (String) -> Void

    func view(for row: SettingsLayout.Row) -> NSView? {
        switch row.control {
        case let .toggle(glyph):
            guard case let .flag(get, set)? = bindings.access(row.key) else { return nil }
            return toggle(row, glyph: glyph, get: get, set: set)
        case let .menu(group, glyph):
            guard case let .token(get, set)? = bindings.access(row.key) else { return nil }
            return menu(row, group: group, glyph: glyph, get: get, set: set)
        case let .cards(group):
            guard case let .token(get, set)? = bindings.access(row.key) else { return nil }
            return segments(row, group: group, get: get, set: set)
        case let .slider(ladder):
            guard case let .number(get, set)? = bindings.access(row.key) else { return nil }
            return slider(row, ladder: ladder, get: get, set: set)
        case let .stepper(range):
            guard case let .number(get, set)? = bindings.access(row.key) else { return nil }
            return stepper(row, range: range, get: get, set: set)
        case let .text(glyph):
            guard case let .text(get, set)? = bindings.access(row.key) else { return nil }
            return field(row, glyph: glyph, get: get, set: set)
        case .note:
            return note(row.subtitle)
        case let .bespoke(id):
            return bespoke(id)
        }
    }

    /// A bespoke group, drawn in AppKit — every one of them.
    ///
    /// UNTIL INCREMENT 49 SEVEN OF THESE WERE `NSHostingView`s over the phone's SwiftUI, on the argument
    /// that a surface which is not a control kind has nothing for the two halves to differ about. What that
    /// argument missed is that a hosted surface is not shared drawing, it is a SwiftUI RUNTIME inside an
    /// `NSStackView`: it sizes itself by its own measurement pass, it cannot be reached by the window's
    /// responder chain the way the rows around it can, and — the one that decided it — an `ImageRenderer`
    /// snapshot of the page photographs it as a hole. Meanwhile the words those surfaces carried WERE
    /// shared, but by being typed once in a view rather than once below both halves, so the option lists
    /// inside them had already drifted from the Rust catalog in four places.
    ///
    /// So the split is now the one docs/56 stage D states everywhere else: every DECISION descends to
    /// `SlopDeskClientCore` (`SettingsBespokePresentation`, `SettingsIndexPresentation`,
    /// `SettingsConfigFile`), and each half draws it in its own framework. `SettingsBespokeSurface` stays
    /// where it is — it is the PHONE's renderer, not a shared one.
    ///
    /// Two ids need no phone half at all: the layout table gates `os-integration` and `cli-install` to
    /// `Platform::Mac` and their content is LaunchServices and `/usr/local/bin`. They are the SAME views
    /// the first-launch checklist shows, which is what stopped them being two copies of four rows of prose.
    /// `raw-overrides` and `config-file` joined them here for the same reason — a config path under
    /// `~/.config` has no iOS reading.
    ///
    /// An id with no arm draws NOTHING, which is the honest answer for a surface this build does not have
    /// and the same contract a key with no binding holds on the described side.
    private func bespoke(_ id: String) -> NSView {
        switch id {
        case "os-integration": MacOSIntegrationRows()
        case "cli-install": MacCLIInstallCard()
        case "notification-permission": MacNotificationPermissionRow()
        case "editor-empty": MacEditorEmptyCard()
        case "claude-hooks": MacHooksSettingsRows(agentHooks: agentHooks)
        // The Font-Family scope tabs over two different bodies — the primary family with its three
        // derived faces, or the ordered fallback list — and the "Aa" specimen list. Size, line height,
        // ligatures and style are described rows above it.
        case "font-family": MacFontFamilySurface(store: bindings.store)
        case "cursor-preview": MacCursorPreviewSurface(store: bindings.store)
        // The chord editor is `Platform::Both`, so BOTH halves draw it — but the Mac's recorder is an
        // `NSEvent` monitor scoped to this window, and a monitor is not a view to host. Both read the
        // same registry and the same ``KeybindingCapture``; only the drawing differs.
        case "keybindings": MacKeybindingsEditor(store: bindings.store)
        case "raw-overrides": MacRawOverridesBox(store: bindings.store)
        case "config-file": MacConfigFileRows(store: bindings.store)
        case "all-settings": MacAllSettingsIndex(bindings: bindings, onJump: onJump)
        default: NSView()
        }
    }

    /// Prose belonging to the GROUP rather than to a setting — a footnote explaining why a choice the
    /// reader might expect is not offered.
    func note(_ words: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: words)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = Slate.Native.Text.secondary
        label.isSelectable = false
        return label
    }

    // MARK: The kinds

    private func toggle(
        _ row: SettingsLayout.Row, glyph: String,
        get: () -> Bool, set: @escaping (Bool) -> Void,
    ) -> NSView {
        let control = MacActionSwitch { value in
            set(value)
            onValueChanged(row.key)
        }
        control.state = get() ? .on : .off
        control.isEnabled = bindings.isEditable(row.key)
        return trailing(macRowLabel(row.label, row.subtitle, glyph: glyph), control)
    }

    private func menu(
        _ row: SettingsLayout.Row, group: SettingsCatalog.Group, glyph: String?,
        get: () -> String, set: @escaping (String) -> Void,
    ) -> NSView {
        let options = SettingsCatalog.stringOptions(group)
        let popup = MacActionPopUp(tokens: options.map(\.value)) { token in
            set(token)
            onValueChanged(row.key)
        }
        // The MENU label, not the plain one: a menu item has no second line to hang a caption on, so
        // the caveat is folded in after an en dash rather than dropped.
        for option in options { popup.addItem(withTitle: option.menuLabel) }
        popup.selectToken(get())
        return trailing(macRowLabel(row.label, row.subtitle, glyph: glyph), popup)
    }

    /// The card row's Mac form. A segmented control is what a mouse-driven window has for "pick one of
    /// a handful"; the ART each card carries is a touch affordance the phone keeps.
    private func segments(
        _ row: SettingsLayout.Row, group: SettingsCatalog.Group,
        get: () -> String, set: @escaping (String) -> Void,
    ) -> NSView {
        let options = SettingsCatalog.stringOptions(group)
        let control = MacActionSegments(tokens: options.map(\.value)) { token in
            set(token)
            onValueChanged(row.key)
        }
        control.segmentCount = options.count
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        for (index, option) in options.enumerated() {
            control.setLabel(option.label, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectToken(get())
        return stacked(macRowLabel(row.label, row.subtitle), control)
    }

    private func slider(
        _ row: SettingsLayout.Row, ladder: SettingsCatalog.Ladder,
        get: () -> Double, set: @escaping (Double) -> Void,
    ) -> NSView {
        let readout = NSTextField(labelWithString: ladder.readout(get()))
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = Slate.Native.Text.secondary

        let control = MacActionSlider { value in
            readout.stringValue = ladder.readout(value)
            set(value)
            onValueChanged(row.key)
        }
        control.minValue = ladder.range.lowerBound
        control.maxValue = ladder.range.upperBound
        control.doubleValue = get()
        // The stops are what the ladder exists FOR — a handful of magnitudes anyone actually wants —
        // so the slider ticks at them rather than sliding continuously past them.
        control.numberOfTickMarks = ladder.presets.count
        control.allowsTickMarkValuesOnly = false

        let line = NSStackView(views: [control, readout])
        line.orientation = .horizontal
        line.spacing = Slate.Metric.space2
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stacked(macRowLabel(row.label, row.subtitle), line)
    }

    private func stepper(
        _ row: SettingsLayout.Row, range: SettingsCatalog.Stepper,
        get: () -> Double, set: @escaping (Double) -> Void,
    ) -> NSView {
        let readout = NSTextField(labelWithString: range.readout(get()))
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let control = MacActionStepper { value in
            readout.stringValue = range.readout(value)
            set(value)
            onValueChanged(row.key)
        }
        control.minValue = range.doubleRange.lowerBound
        control.maxValue = range.doubleRange.upperBound
        control.increment = Double(range.step)
        control.valueWraps = false
        control.doubleValue = get()

        let line = NSStackView(views: [readout, control])
        line.orientation = .horizontal
        line.spacing = Slate.Metric.space1
        return trailing(macRowLabel(row.label, row.subtitle), line)
    }

    private func field(
        _ row: SettingsLayout.Row, glyph: String?,
        get: () -> String, set: @escaping (String) -> Void,
    ) -> NSView {
        let control = MacActionField { text in
            set(text)
            onValueChanged(row.key)
        }
        control.stringValue = get()
        control.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return stacked(macRowLabel(row.label, row.subtitle, glyph: glyph), control)
    }

    // MARK: Two row shapes

    /// Label on the left, control on the right — the settings row's default.
    private func trailing(_ label: NSView, _ control: NSView) -> NSView {
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space3
        stack.distribution = .fill
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    /// Control UNDER its label — for the widths a trailing control cannot take: a segmented row of
    /// four, a slider that needs the whole width to be worth sliding, a free-text field.
    private func stacked(_ label: NSView, _ control: NSView) -> NSView {
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space2
        return stack
    }
}
