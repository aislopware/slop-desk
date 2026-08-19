// MacAllSettingsIndex — Advanced → ALL SETTINGS, in AppKit.
//
// docs/56 stage D, increment 49. The index is `Platform::Both` and it is the largest bespoke surface by
// far: every client key the catalog knows, searchable, each row either editable in place or showing its
// live value beside a ✎ that jumps to the page that owns it.
//
// Nothing here spells a WORD or a CHOICE. The header, the search placeholder, the two reset titles and
// their confirmations, the "· Default: …" line and the empty-result sentence come from
// `SettingsIndexPresentation`; the option lists come from `SettingsCatalog` through that same file's
// `optionGroup(_:)`, and the one numeric row's range, step and readout come from its `ladder(_:)`. That
// last part is the point of the increment rather than tidiness: the SwiftUI half had thirteen option lists
// typed inline as `Text(…).tag(…)`, and FOUR of them had already drifted from the Rust catalog that has
// held the same lists all along (docs/56 increment 49).
//
// What this file does own is the Mac's storage mapping and the Mac's widgets. `MacSettingsBindings`
// answers "what is behind this key" in four shapes — flag, token, number, text — and the four shapes pick
// the four controls. That mapping cannot be shared for the reason `MacSettingsBindings` states at length:
// `@Default` is a property wrapper and the phone's redraw depends on it being read as one.
//
// A REBUILD IS THE UPDATE, and here it is scoped: typing in the search field rebuilds the ROW COLUMN and
// nothing above it, so the field keeps focus and its insertion point across every keystroke. Rebuilding the
// whole surface would resign first responder on the first character typed.

import AppKit
import SlopDeskClientCore // SettingsIndexPresentation — the index's words and its option table
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

/// The searchable index of every client setting.
@MainActor
final class MacAllSettingsIndex: NSStackView, NSSearchFieldDelegate {
    private let bindings: MacSettingsBindings
    private let onJump: (String) -> Void

    private let search = NSSearchField()
    /// The rows, emptied and refilled on every query change.
    private let rows = NSStackView()

    private var store: PreferencesStore { bindings.store }

    init(bindings: MacSettingsBindings, onJump: @escaping (String) -> Void) {
        self.bindings = bindings
        self.onJump = onJump
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Slate.Metric.space2

        let header = header()
        let resets = resetRow()
        addArrangedSubview(header)
        addArrangedSubview(resets)
        addArrangedSubview(rows)
        for wide in [header, resets, rows] {
            wide.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        refill()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The head of the section

    private func header() -> NSView {
        let title = NSTextField(labelWithString: SettingsIndexPresentation.header)
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.textColor = Slate.Native.Text.tertiary

        search.placeholderString = SettingsIndexPresentation.searchPlaceholder
        search.delegate = self
        // `sendsWholeSearchString` off: this filters an in-memory array, so there is nothing to debounce
        // and a per-keystroke narrowing is what a reader expects of a search field.
        search.sendsWholeSearchString = false
        search.widthAnchor.constraint(equalToConstant: Self.searchWidth).isActive = true

        let stack = NSStackView(views: [title, NSView(), search])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space2
        return stack
    }

    /// Wide enough for a key fragment (`notify-`, `clipboard`), narrow enough to leave the header its line.
    private static let searchWidth: CGFloat = 180

    private func resetRow() -> NSView {
        let all = MacActionButton(title: SettingsIndexPresentation.resetAllTitle) { [weak self] in
            self?.confirmResetAll()
        }
        let advanced = MacActionButton(title: SettingsIndexPresentation.resetAdvancedTitle) { [weak self] in
            self?.confirmResetAdvanced()
        }
        let stack = NSStackView(views: [all, advanced, NSView()])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space2
        return stack
    }

    // MARK: The two resets

    /// Which reset a confirmation is guarding. A VALUE rather than a closure the sheet carries: the
    /// completion handler crosses a concurrency boundary, and a stored closure would have to be made
    /// `Sendable` to ride it — an enum says the same thing without asking anything of the type system.
    private enum Reset {
        case everySetting
        case advancedOnly
    }

    private func confirmResetAll() {
        confirm(
            .everySetting,
            SettingsIndexPresentation.resetAllPrompt,
            SettingsIndexPresentation.resetAllMessage,
            SettingsIndexPresentation.resetAllConfirm,
        )
    }

    private func confirmResetAdvanced() {
        confirm(
            .advancedOnly,
            SettingsIndexPresentation.resetAdvancedPrompt,
            SettingsIndexPresentation.resetAdvancedMessage,
            SettingsIndexPresentation.resetAdvancedConfirm,
        )
    }

    /// The destructive confirmation, as a SHEET when there is a window to hang it on.
    ///
    /// A sheet rather than `runModal()` because this is a settings window and an app-modal alert over one is
    /// a spurious escalation; the `runModal()` fallback is only for a view not yet in a window, which is
    /// unreachable from a button press and cheap to keep honest.
    private func confirm(_ reset: Reset, _ prompt: String, _ message: String, _ verb: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: verb)
        confirmButton.hasDestructiveAction = true
        alert.addButton(withTitle: SettingsIndexPresentation.cancelTitle)
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { perform(reset) }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.perform(reset)
            }
        }
    }

    /// ⚠️ `resetEverySetting(deviceLocal:)`, never `resetAll()`. The confirmation promises EVERY setting and
    /// `resetAll()` cannot reach `device-prefs.json` (`AllSettingsCatalog.deviceLocalKeys`) — the wording and
    /// the call have to be read together, which is why `SettingsIndexPresentation` says so at the wording.
    ///
    /// The refill afterwards is what makes the reset VISIBLE: every control here was built from a value, so
    /// a write nothing rebuilds leaves two hundred stale widgets over restored storage.
    private func perform(_ reset: Reset) {
        switch reset {
        case .everySetting: store.resetEverySetting(deviceLocal: bindings.workspace)
        case .advancedOnly: store.resetAdvancedOnly()
        }
        refill()
    }

    // MARK: The rows

    private func refill() {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let matches = AllSettingsCatalog.filter(search.stringValue)
        guard !matches.isEmpty else {
            let empty = NSTextField(
                wrappingLabelWithString: SettingsIndexPresentation.noMatches(search.stringValue),
            )
            empty.font = .preferredFont(forTextStyle: .caption1)
            empty.textColor = Slate.Native.Text.tertiary
            add(empty)
            return
        }
        for entry in matches { add(row(entry)) }
    }

    private func add(_ view: NSView) {
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    /// One index row: the KEY in monospace with its control beside it, over the description-and-default line.
    ///
    /// The key itself is the row's name here, not its `pageLabel` — the index is the surface a reader
    /// reaches FROM a config file or a doc, so the string they arrived with is the one that has to be
    /// findable. The prose form of the same setting is what the dedicated page shows.
    private func row(_ entry: AllSettingsCatalog.SettingEntry) -> NSView {
        let key = NSTextField(labelWithString: entry.key)
        key.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        key.lineBreakMode = .byTruncatingMiddle

        let top = NSStackView(views: [key, NSView(), control(entry)])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = Slate.Metric.space2
        key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(wrappingLabelWithString: SettingsIndexPresentation.detail(entry))
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = Slate.Native.Text.secondary
        detail.isSelectable = false

        let stack = NSStackView(views: [top, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space1 / 2
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func control(_ entry: AllSettingsCatalog.SettingEntry) -> NSView {
        switch entry.bucket {
        case .hasDedicatedTab: jump(entry)
        case .advancedOnly: inlineControl(entry)
        }
    }

    /// The live value, and a ✎ that repoints the navigator at the page owning the setting.
    ///
    /// The jump reports a SECTION ID rather than a selection: the two halves navigate differently (a `List`
    /// selection there, an `NSTableView` row here) and neither owns the other's selection type, so what
    /// crosses is the id the catalog already carries.
    private func jump(_ entry: AllSettingsCatalog.SettingEntry) -> NSView {
        let value = NSTextField(
            labelWithString: SettingsIndexPresentation.dedicatedValue(
                entry, store: store, device: bindings.workspace,
            ),
        )
        value.font = .preferredFont(forTextStyle: .caption1)
        value.textColor = Slate.Native.Text.secondary
        value.lineBreakMode = .byTruncatingTail

        let button = MacActionButton(title: "") { [weak self] in
            guard let section = entry.targetSection else { return }
            self?.onJump(section)
        }
        button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        button.isBordered = false
        button.contentTintColor = Slate.Native.Text.icon
        // A row whose page this build cannot name is drawn WITHOUT the affordance rather than with a dead
        // one: the value is still true, and a ✎ that goes nowhere is worse than no ✎.
        button.isHidden = entry.targetSection == nil

        let stack = NSStackView(views: [value, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space1
        return stack
    }

    /// The editor for an `.advancedOnly` key: whichever of the four control shapes its STORAGE implies,
    /// over whichever option list or ladder `SettingsIndexPresentation` names for it.
    private func inlineControl(_ entry: AllSettingsCatalog.SettingEntry) -> NSView {
        let key = entry.key
        if SettingsIndexPresentation.isReadOnly(key) {
            guard case let .text(get, _)? = bindings.access(key) else { return defaultText(entry) }
            return summary(SettingsIndexPresentation.readOnlySummary(get()))
        }
        switch bindings.access(key) {
        case let .flag(get, set)?:
            let control = MacActionSwitch(set)
            control.state = get() ? .on : .off
            control.isEnabled = bindings.isEditable(key)
            return control
        case let .token(get, set)?:
            // No group named for a token key means no list to offer, so the row shows what it is instead of
            // a pop-up with nothing in it. Adding the list means adding it to the CATALOG.
            guard let group = SettingsIndexPresentation.optionGroup(key) else { return summary(get()) }
            let options = SettingsCatalog.stringOptions(group)
            let popup = MacActionPopUp(tokens: options.map(\.value), set)
            for option in options { popup.addItem(withTitle: option.menuLabel) }
            // Through `selectedToken` rather than straight off the store: a working-directory key can hold
            // a literal path, which is not one of the two policies the group offers.
            popup.selectToken(SettingsIndexPresentation.selectedToken(key, get()))
            return popup
        case let .number(get, set)?:
            guard let ladder = SettingsIndexPresentation.ladder(key) else { return defaultText(entry) }
            return stepper(ladder, get: get, set: set)
        case let .text(get, set)?:
            let field = MacActionField(set)
            field.stringValue = get()
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
            return field
        case nil:
            return defaultText(entry)
        }
    }

    /// A stepper over a ladder, with the ladder's own readout beside it.
    ///
    /// A stepper rather than the dedicated pages' slider: this row sits in a column of two hundred, where a
    /// slider would take the width every other row uses for its key, and the multiplier's step is coarse
    /// enough that clicking to it is faster than dragging to it.
    private func stepper(
        _ ladder: SettingsCatalog.Ladder, get: () -> Double, set: @escaping (Double) -> Void,
    ) -> NSView {
        let readout = NSTextField(labelWithString: ladder.readout(get()))
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = Slate.Native.Text.secondary

        let control = MacActionStepper { value in
            readout.stringValue = ladder.readout(value)
            set(value)
        }
        control.minValue = ladder.range.lowerBound
        control.maxValue = ladder.range.upperBound
        control.increment = ladder.step
        control.valueWraps = false
        control.doubleValue = get()

        let stack = NSStackView(views: [readout, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Slate.Metric.space1
        return stack
    }

    /// Wide enough for a scheme list (`ssh, ftp, magnet`) without stretching the key column.
    private static let fieldWidth: CGFloat = 180

    /// A live value with no editor — a read-only row, or a token whose list is not in the catalog.
    private func summary(_ words: String) -> NSView {
        let label = NSTextField(labelWithString: words)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = Slate.Native.Text.secondary
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// What a row shows when this renderer has no storage for its key: the default, in the dimmest ink.
    /// It should not happen for an `.advancedOnly` entry, and printing the default is how it stays visible
    /// when it does — an empty cell would read as a rendering bug rather than as a missing binding.
    private func defaultText(_ entry: AllSettingsCatalog.SettingEntry) -> NSView {
        let label = NSTextField(labelWithString: entry.defaultText)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = Slate.Native.Text.tertiary
        return label
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === search else { return }
        refill()
    }
}
