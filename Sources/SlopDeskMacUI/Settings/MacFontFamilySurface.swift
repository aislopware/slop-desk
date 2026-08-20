// MacFontFamilySurface — the Appearance → Font Family group, in AppKit.
//
// docs/56 stage D, increment 49. The group stays bespoke for the reason the layout table records: it is a
// pair of SCOPE TABS over two different bodies, and a control whose choice picks which OTHER controls exist
// is not a row any table describes. It is `Platform::Both`, so there are two renderers, and every word —
// the scope labels, the two scope notes, the four placeholders, the host-boundary note, the fallback
// editor's strings — plus the fallback list's parse/join rules and the installed-family enumeration come
// from `SettingsFontSurface` / `SettingsFontFallbackList` / `InstalledFontFamilies` in `SlopDeskClientCore`.
//
// A REBUILD IS THE UPDATE. Two things here decide which controls exist — the scope tab and the auto-match
// toggle — and neither is a value the layout table can gate on, so this rebuilds its own body the way
// `MacSettingsPage` rebuilds a section.
//
// ## Two AppKit registers, deliberately chosen
//
// **The specimen list is an `NSMenu`, not a popover.** The SwiftUI half builds a popover with its own
// search field because a SwiftUI `Menu` flattens a custom font and the "Aa" would render in the system face
// — the whole point of a specimen. AppKit does not have that problem: `NSMenuItem.attributedTitle` honours
// the font it is given, so each item shows its family in ITS OWN face. What the menu replaces is the
// popover's search field, with the type-select every `NSMenu` already has.
//
// **There is no draft debouncer.** The SwiftUI half hand-builds one (`DraftCommitDebouncer`) because a
// `TextField` binding writes per keystroke, and every write to `store.terminal` persists and rebuilds the
// libghostty config. AppKit's editing model IS that debouncer: `MacActionField` commits on Return and on
// end-of-editing and never in between, which is the same three edges — submit, blur, teardown — spelled by
// the framework instead of by a timer.

import AppKit
import SlopDeskClientCore // SettingsFontSurface / SettingsFontFallbackList / InstalledFontFamilies
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

/// The Font Family group: the scope tabs, the body the active scope opens, and the host-boundary note.
@MainActor
final class MacFontFamilySurface: NSStackView {
    private let store: PreferencesStore
    /// Which scope is showing. Defaults to Global — the primary, always-rendered family.
    private var scope: SettingsFontScope = .global

    private let note = macSettingsNote(SettingsFontScope.global.note, .secondary, style: .subheadline)
    /// The scope's own controls, emptied and refilled on every switch.
    private let body = NSStackView()

    init(store: PreferencesStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = Slate.Metric.space3

        addArrangedSubview(scopeTabs())
        addArrangedSubview(note)
        addArrangedSubview(body)
        let host = macSettingsNote(SettingsFontSurface.hostNote, .secondary, style: .subheadline)
        addArrangedSubview(host)
        for wide in [note, body, host] {
            wide.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The tabs

    /// "Settings for" over the two scopes.
    ///
    /// A segmented control, not the phone's capsule pills: two mutually exclusive choices that differ by
    /// their WORDS is exactly what `NSSegmentedControl` is, and it brings the focus ring and ←/→ traversal
    /// a hand-drawn pill row would have to reimplement.
    private func scopeTabs() -> NSView {
        let heading = NSTextField(labelWithString: SettingsFontSurface.scopeHeading)
        heading.font = .preferredFont(forTextStyle: .subheadline)
        heading.textColor = Slate.Native.Text.secondary

        let tabs = SettingsFontScope.allCases
        let control = MacActionSegments(tokens: tabs.map(\.rawValue)) { [weak self] token in
            guard let picked = SettingsFontScope(rawValue: token) else { return }
            self?.scope = picked
            self?.rebuild()
        }
        control.segmentCount = tabs.count
        control.trackingMode = .selectOne
        for (index, tab) in tabs.enumerated() {
            control.setLabel(tab.label, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectToken(scope.rawValue)

        let stack = NSStackView(views: [heading, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space1
        return stack
    }

    // MARK: The body

    private func rebuild() {
        note.stringValue = scope.note
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch scope {
        case .global: fillGlobal()
        case .fallback: fillFallback()
        }
    }

    /// Global scope: the auto-match toggle, the primary family, then the three derived faces.
    ///
    /// The face fields are SHOWN and disabled while auto-match owns them, never hidden: a reader who turns
    /// auto-match off needs to have already seen that there are three faces under it.
    private func fillGlobal() {
        let locked = store.terminal.autoMatchWeightStyle
        let toggle = MacActionSwitch { [weak self] value in
            self?.store.terminal.autoMatchWeightStyle = value
            self?.rebuild()
        }
        toggle.state = locked ? .on : .off
        add(
            row(
                macRowLabel(SettingsLayout.label(for: AllSettingsCatalog.RenderKey.fontAutoMatchWeightStyle), ""),
                toggle,
            ),
        )

        add(
            familyRow(
                AllSettingsCatalog.RenderKey.fontFamily,
                placeholder: SettingsFontSurface.primaryPlaceholder,
                get: { [store] in store.terminal.fontFamily },
                set: { [store] in store.terminal.fontFamily = $0 },
            ),
        )
        let placeholder = SettingsFontSurface.derivedPlaceholder(locked: locked)
        add(
            familyRow(
                AllSettingsCatalog.RenderKey.fontFamilyBold, placeholder: placeholder, locked: locked,
                get: { [store] in store.terminal.fontFamilyBold },
                set: { [store] in store.terminal.fontFamilyBold = $0 },
            ),
        )
        add(
            familyRow(
                AllSettingsCatalog.RenderKey.fontFamilyItalic, placeholder: placeholder, locked: locked,
                get: { [store] in store.terminal.fontFamilyItalic },
                set: { [store] in store.terminal.fontFamilyItalic = $0 },
            ),
        )
        add(
            familyRow(
                AllSettingsCatalog.RenderKey.fontFamilyBoldItalic, placeholder: placeholder, locked: locked,
                get: { [store] in store.terminal.fontFamilyBoldItalic },
                set: { [store] in store.terminal.fontFamilyBoldItalic = $0 },
            ),
        )
    }

    /// Fallback scope: each family already in the chain as a removable specimen row, then the add line.
    private func fillFallback() {
        let families = SettingsFontFallbackList.entries(store.terminal.fontFamilyFallback)
        if families.isEmpty {
            add(macSettingsNote(SettingsFontSurface.fallbackEmpty, .tertiary, style: .subheadline))
        }
        for (index, family) in families.enumerated() {
            add(fallbackRow(family, at: index))
        }

        // The add field writes NOTHING on its own: it is a staging buffer, and the button beside it is what
        // commits. So it reads its own text back rather than riding a store binding — the shape the SwiftUI
        // half spells as `draftCommit: false` on the same control.
        let field = MacFontFamilyField(
            placeholder: SettingsFontSurface.fallbackAddPlaceholder, value: "", onCommit: { _ in },
        )
        let button = MacActionButton(title: SettingsFontSurface.fallbackAddTitle) { [weak self, weak field] in
            guard let self, let field else { return }
            guard let updated = SettingsFontFallbackList.adding(
                field.value, to: store.terminal.fontFamilyFallback,
            ) else { return }
            store.terminal.fontFamilyFallback = updated
            rebuild()
        }
        let line = NSStackView(views: [field, button])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = Slate.Metric.space2
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(line)
    }

    private func fallbackRow(_ family: String, at index: Int) -> NSView {
        let remove = MacActionButton(title: "") { [weak self] in
            guard let self,
                  let updated = SettingsFontFallbackList.removing(
                      at: index, from: store.terminal.fontFamilyFallback,
                  )
            else { return }
            store.terminal.fontFamilyFallback = updated
            rebuild()
        }
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
        remove.isBordered = false
        remove.contentTintColor = Slate.Native.Text.tertiary
        remove.toolTip = SettingsFontSurface.fallbackRemoveHint

        let name = NSTextField(labelWithString: family)
        let row = NSStackView(views: [specimen(family), name, NSView(), remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        return row
    }

    /// One family field, labelled by the setting it edits.
    private func familyRow(
        _ key: String,
        placeholder: String,
        locked: Bool = false,
        get: () -> String,
        set: @escaping (String) -> Void,
    ) -> NSView {
        let field = MacFontFamilyField(placeholder: placeholder, value: get(), onCommit: set)
        field.isEnabled = !locked
        // Dimmed as well as disabled, the pair the SwiftUI half spells `.disabled` + `.opacity(0.5)`:
        // AppKit greys a disabled TEXT FIELD's text but not its bezel, so the field alone still reads live.
        field.alphaValue = locked ? Slate.Opacity.withheld : 1
        return row(macRowLabel(SettingsLayout.label(for: key), ""), field)
    }

    /// The "Aa" specimen, set in the family it names — the one mark that tells a font row from a text row.
    /// A family this device does not have falls back to the system face rather than vanishing, because the
    /// list is the HOST's to satisfy (``SettingsFontSurface/hostNote``) and a missing local face is normal.
    private func specimen(_ family: String) -> NSTextField {
        let label = NSTextField(labelWithString: "Aa")
        label.font = NSFont(name: family, size: NSFont.preferredFont(forTextStyle: .body).pointSize)
            ?? .preferredFont(forTextStyle: .body)
        label.alignment = .left
        label.widthAnchor.constraint(equalToConstant: Self.specimenWidth).isActive = true
        return label
    }

    /// Wide enough for two glyphs of the widest monospaced face anyone installs, so the names beside them
    /// still form a column.
    private static let specimenWidth: CGFloat = 28

    private func add(_ view: NSView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func row(_ label: NSView, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space3
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }
}

// MARK: - The family field

/// A free-text family field with a specimen menu beside it.
///
/// FREE TEXT, not a closed picker, and that is a fact about the product rather than a control preference:
/// the terminal renders on the HOST, so any family the host has can be typed even when this device has
/// never heard of it. The menu is a convenience over ``InstalledFontFamilies``, never an enforced set.
@MainActor
final class MacFontFamilyField: NSStackView {
    private let field: MacActionField
    private let onCommit: (String) -> Void

    /// What the field currently holds — read by the Fallback scope's Add button, which commits on its own
    /// press rather than on the field's.
    var value: String { field.stringValue }

    /// Whether the field accepts an edit. `NSView` has no `isEnabled` to override — a stack view is a
    /// container, not a control — so this forwards to the one child that has one.
    var isEnabled: Bool {
        get { field.isEnabled }
        set { field.isEnabled = newValue }
    }

    init(placeholder: String, value: String, onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
        field = MacActionField(onCommit)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = placeholder
        field.stringValue = value
        field.font = .preferredFont(forTextStyle: .body)
        addArrangedSubview(field)

        let chevron = MacActionButton(title: "") { [weak self] in self?.showSpecimens() }
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.isBordered = false
        chevron.contentTintColor = Slate.Native.Text.tertiary
        addArrangedSubview(chevron)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([field.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth)])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Wide enough that a two-word family name is readable without the row stretching to the page.
    private static let minWidth: CGFloat = 150

    /// Pop the specimen menu under the field.
    ///
    /// Each item's title is ATTRIBUTED and set in its own family, which is what makes this a specimen list
    /// rather than a list of names — the property the SwiftUI half needs a custom popover for. A tick marks
    /// the family in force; typing narrows the menu through `NSMenu`'s own type-select.
    private func showSpecimens() {
        let menu = NSMenu()
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        for family in InstalledFontFamilies.all {
            let item = NSMenuItem(title: family, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = family
            item.attributedTitle = NSAttributedString(
                string: family,
                attributes: [.font: NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)],
            )
            item.state = family == field.stringValue ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: SettingsFontSurface.specimenEmpty, action: nil, keyEquivalent: "")
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }

    /// A pick is one discrete, intentional commit — it writes straight through, unlike a keystroke.
    @objc
    private func pick(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        field.stringValue = family
        onCommit(family)
    }
}
