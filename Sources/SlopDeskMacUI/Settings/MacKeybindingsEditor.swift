// MacKeybindingsEditor — the chord editor in Settings ▸ Key Bindings, in AppKit.
//
// Every binding the registry knows, grouped by category, with the chord that actually fires beside it
// and a chip that records a replacement. The phone renders the SAME list from the SAME registry
// (``KeybindingsEditorView``) — the Rust settings table calls this group `Platform::Both` and says why:
// a phone with a hardware keyboard runs the same bindings, and the list is worth reading with none.
//
// WHAT IT DOES NOT OWN is any of the thinking. The captured keystroke → record / cancel / UNBIND rule is
// ``KeybindingCapture``, which asks `slopdesk_video::key_naming` — the same table the dispatcher builds
// chords from, so a chord recorded here is the chord that fires. The search filter, the reset gate and
// the two override mutations that PRESERVE the config.toml literal-byte bindings are
// ``KeybindingsEditorModel``. What is here is rows, a plate, and one `NSEvent` monitor.
//
// THE MONITOR IS SCOPED TO THIS WINDOW, and that is a fix rather than a detail: a `.keyDown` local
// monitor fires for events delivered to ANY window in the process, so an unscoped one meant that
// clicking "Press a key…" and then clicking away swallowed every keystroke app-wide and recorded the
// first as a bogus chord. It captures only events destined for its own key window, and stands down when
// that window resigns key.
//
// A REBUILD IS THE UPDATE, the same as every other page in this target: `PreferencesStore` is
// `@Observable`, AppKit has no invalidation to hang on that, and every mutation here goes through a
// control in this file — so the control rebuilds. The list is a hundred rows of static text; rebuilding
// it costs less than the machinery to diff it would.

import AppKit
import SlopDeskClientCore // SettingsChordCapture — the recorder's claim on Esc
import SlopDeskClientUI // Slate — the ONE token ladder, in its native (NSColor/NSFont) view
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore

@MainActor
final class MacKeybindingsEditor: NSView, NSSearchFieldDelegate {
    private let store: PreferencesStore

    /// The binding id currently recording, or `nil`. ONE at a time, so the monitor has a single
    /// unambiguous target.
    private var recordingID: String? {
        didSet {
            guard recordingID != oldValue else { return }
            // Tell the window's Esc rule to stand down while a chord is being recorded — there Esc
            // means "cancel the capture", not "close Settings" (``SettingsEscapePolicy``).
            SettingsChordCapture.shared.isCapturing = recordingID != nil
            if recordingID == nil { stopMonitor() } else { startMonitor() }
            rebuild()
        }
    }

    /// The live search query. Filters by action name, keywords OR chord — see
    /// ``KeybindingsEditorModel/matches(_:effectiveChord:query:)``.
    private var searchQuery = ""

    private let resetSlot = NSStackView()
    private let search = NSSearchField()
    private let bannerSlot = NSStackView()
    private let list = NSStackView()

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(store: PreferencesStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        resetSlot.orientation = .horizontal
        resetSlot.alignment = .centerY
        bannerSlot.orientation = .vertical
        bannerSlot.alignment = .leading
        bannerSlot.spacing = Slate.Metric.space1
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Slate.Metric.space3

        search.placeholderString = "Search key bindings"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let column = NSStackView(views: [header(), search, bannerSlot, list])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Slate.Metric.space3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in [search, bannerSlot, list] {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// LEAVING THE WINDOW STANDS THE RECORDER DOWN. The monitor and the resign observer are
    /// process-wide registrations, and the settings page rebuilds its sections whenever a value gates
    /// another row — so a page discarded mid-capture would otherwise leave a monitor behind swallowing
    /// keystrokes on behalf of a view that is gone, and leave Esc permanently disowned.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        recordingID = nil
    }

    // MARK: - Drawing

    private func rebuild() {
        drawResetSlot()
        drawBanner()
        drawList()
    }

    /// The header's one live part: "Reset to Default" appears only once SOMETHING is customized, and
    /// clears every customization at once — there is no per-row revert.
    private func drawResetSlot() {
        empty(resetSlot)
        guard KeybindingsEditorModel.hasCustomizations(store.keybindings) else { return }
        let button = MacActionButton(title: "Reset to Default") { [weak self] in self?.confirmReset() }
        button.isBordered = false
        button.contentTintColor = Slate.Native.accent
        button.toolTip = "Reset every customized shortcut to its default"
        resetSlot.addArrangedSubview(button)
    }

    /// Chords bound to more than one action, named plainly. A conflict is not an error the editor can
    /// resolve — both bindings are the user's — so it is reported rather than blocked.
    private func drawBanner() {
        empty(bannerSlot)
        let conflicts = store.keybindingConflicts()
        guard !conflicts.isEmpty else { return }

        let heading = NSTextField(labelWithString: "Shortcut conflicts")
        heading.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold)
        heading.textColor = Slate.Native.StatusInk.warn
        let mark = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                ?? NSImage(),
        )
        mark.contentTintColor = Slate.Native.StatusInk.warn
        let title = NSStackView(views: [mark, heading])
        title.orientation = .horizontal
        title.alignment = .centerY
        title.spacing = Slate.Metric.space1
        bannerSlot.addArrangedSubview(title)

        for line in conflictLines(conflicts) {
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = Slate.Native.Text.secondary
            label.isSelectable = false
            bannerSlot.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: bannerSlot.widthAnchor).isActive = true
        }
    }

    private func conflictLines(_ conflicts: [String: [String]]) -> [String] {
        conflicts.map { chord, ids in
            let titles = ids.compactMap { id in binding(forID: id)?.title }.sorted()
            return "\(chord): \(titles.joined(separator: ", "))"
        }.sorted()
    }

    private func drawList() {
        empty(list)
        let conflicting = Set(store.keybindingConflicts().values.flatMap(\.self))
        for category in WorkspaceAction.Category.allCases {
            let rows = bindings(in: category)
            guard !rows.isEmpty else { continue }
            list.addArrangedSubview(sectionHeader(category.rawValue))
            for entry in rows {
                let row = rowView(entry, isConflicting: conflicting.contains(entry.id))
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        if list.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: "No shortcut matches “\(searchQuery)”.")
            empty.font = .preferredFont(forTextStyle: .body)
            empty.textColor = Slate.Native.Text.tertiary
            list.addArrangedSubview(empty)
        }
    }

    private func sectionHeader(_ words: String) -> NSView {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: words.uppercased(),
            attributes: [
                .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .medium),
                .foregroundColor: Slate.Native.Text.tertiary,
                // Wide enough to read as engraving, applied ONLY to an all-caps label.
                .kern: Slate.Typeface.instrumentTracking,
            ],
        ))
        label.isSelectable = false
        return label
    }

    /// One binding: its glyph, its name, a conflict mark when it shares a chord, and the chip.
    private func rowView(_ binding: WorkspaceBinding, isConflicting: Bool) -> NSView {
        let glyph = NSImageView(
            image: NSImage(systemSymbolName: binding.symbol, accessibilityDescription: nil) ?? NSImage(),
        )
        glyph.contentTintColor = Slate.Native.Text.secondary
        glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let title = NSTextField(labelWithString: binding.title)
        title.font = .preferredFont(forTextStyle: .body)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [glyph, title]
        if isConflicting {
            let mark = NSImageView(
                image: NSImage(
                    systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil,
                ) ?? NSImage(),
            )
            mark.contentTintColor = Slate.Native.StatusInk.warn
            mark.toolTip = "This shortcut conflicts with another command"
            views.append(mark)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        views.append(chip(for: binding))

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        return row
    }

    /// The trailing chip: the effective chord, or "Press a key…" while this row is the recorder.
    /// Clicking it arms; clicking it again stands down.
    private func chip(for binding: WorkspaceBinding) -> NSView {
        let recording = recordingID == binding.id
        return MacChordChip(
            label: recording ? "Press a key…" : effectiveGlyph(for: binding),
            recording: recording,
        ) { [weak self] in
            guard let self else { return }
            recordingID = recordingID == binding.id ? nil : binding.id
        }
    }

    // MARK: - Reading the registry

    /// The bindings in `category` that survive the search, minus the synthetic ⌘1…⌘9 representative —
    /// it has no single chord to rebind, and the real per-digit chords are an implementation detail.
    private func bindings(in category: WorkspaceAction.Category) -> [WorkspaceBinding] {
        WorkspaceBindingRegistry.allBindings.filter {
            $0.category == category
                && $0.id != WorkspaceBindingRegistry.selectPaneRepresentative.id
                && KeybindingsEditorModel.matches(
                    $0, effectiveChord: effectiveChord(for: $0), query: searchQuery,
                )
        }
    }

    private func binding(forID id: String) -> WorkspaceBinding? {
        WorkspaceBindingRegistry.allBindings.first { $0.id == id }
    }

    private func effectiveChord(for binding: WorkspaceBinding) -> KeyChord? {
        WorkspaceBindingRegistry.resolvedChord(for: binding.action, overrides: store.keybindings)
    }

    /// What the chip shows: the override if it maps, else the registry default, else nothing bound.
    private func effectiveGlyph(for binding: WorkspaceBinding) -> String {
        if let override = store.keybindings.chord(for: binding.id), let mapped = override.asRegistryChord {
            return WorkspaceBindingRegistry.glyph(mapped)
        }
        if let chord = binding.chord { return WorkspaceBindingRegistry.glyph(chord) }
        return "—"
    }

    // MARK: - Writing (all through `store.keybindings`, the single persistence channel)

    /// Setting `store.keybindings` republishes to `WorkspaceBindingRegistry.activeOverrides`, which is
    /// what `resolvedChordTable` reads — so this editor adds NO persistence channel of its own.
    private func setOverride(_ chord: KeybindingPreferences.KeyChord, for id: String) {
        // MUTATE the existing model rather than rebuilding it: `KeybindingPreferences(overrides:)`
        // defaults `textBindings` / `unbinds` to empty, so a rebuild silently wipes the user's
        // config.toml literal-byte bindings on every edit.
        store.keybindings = KeybindingsEditorModel.settingOverride(chord, for: id, in: store.keybindings)
        recordingID = nil
    }

    private func clearOverride(_ id: String) {
        guard store.keybindings.chord(for: id) != nil else { return }
        store.keybindings = KeybindingsEditorModel.clearingOverride(for: id, in: store.keybindings)
    }

    private func confirmReset() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset all key bindings?"
        alert.informativeText = "This clears every customized shortcut and restores the defaults."
        alert.addButton(withTitle: "Cancel")
        let reset = alert.addButton(withTitle: "Reset to Default")
        reset.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertSecondButtonReturn, let self else { return }
                self.recordingID = nil
                self.store.keybindings = KeybindingPreferences()
                self.rebuild()
            }
        }
    }

    // MARK: - Capture

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ONLY events aimed at this recorder's own key window. A key delivered anywhere else
            // passes through UNCHANGED — never swallowed, never mis-recorded.
            guard let window, window.isKeyWindow, event.window === window else {
                return event
            }
            capture(event)
            return nil // swallow while recording, and only for our own window
        }
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main,
        ) { [weak self] _ in
            // Stand down on click-away / app switch, so a later keystroke elsewhere can never be
            // captured as the new chord.
            MainActor.assumeIsolated { self?.recordingID = nil }
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Esc cancels (no write), Backspace / Forward-Delete CLEAR the binding, a usable chord is
    /// recorded, and an unmappable key is ignored — the row stays armed. The rule is
    /// ``KeybindingCapture``'s; this only extracts the event's parts and applies the answer.
    private func capture(_ event: NSEvent) {
        guard let id = recordingID else { return }
        let mods = event.modifierFlags
        switch KeybindingCapture.outcome(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            command: mods.contains(.command),
            shift: mods.contains(.shift),
            option: mods.contains(.option),
            control: mods.contains(.control),
        ) {
        case .cancel:
            recordingID = nil
        case .clear:
            clearOverride(id)
            recordingID = nil
        case .ignore:
            break // no usable chord yet — keep recording
        case let .bind(chord):
            setOverride(chord, for: id)
        }
    }

    // MARK: - Chrome

    private func header() -> NSView {
        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .systemFont(ofSize: Slate.Typeface.base, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString:
            "Click a shortcut to record a replacement; Backspace clears it, Esc cancels.",
        )
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = Slate.Native.Text.secondary
        subtitle.isSelectable = false

        let words = NSStackView(views: [title, subtitle])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Slate.Metric.space1 / 2
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [words, resetSlot])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Slate.Metric.space2
        return row
    }

    func controlTextDidChange(_ note: Notification) {
        guard note.object as? NSSearchField === search else { return }
        searchQuery = search.stringValue
        drawList()
    }

    private func empty(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

// MARK: - The chord chip

/// The plate a chord is shown on and recorded into: an inset well at rest, the accent's wash while it
/// is the recorder. A button rather than a label with a click handler, because it IS a button — it
/// takes focus, it takes Space, and VoiceOver announces it as one.
private final class MacChordChip: NSButton {
    private let handler: () -> Void
    private let recording: Bool

    init(label: String, recording: Bool, _ handler: @escaping () -> Void) {
        self.handler = handler
        self.recording = recording
        super.init(frame: .zero)
        title = label
        font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        isBordered = false
        contentTintColor = recording ? Slate.Native.accent : Slate.Native.Text.secondary
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        target = self
        action = #selector(fire)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Re-resolved rather than assigned once: a `CALayer` holds a flat `CGColor`, so a dynamic
        // `NSColor` written into one stops following the appearance the moment it is stored.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = recording
                ? Slate.Native.State.selected.cgColor
                : Slate.Native.Overlay.well.cgColor
            layer?.borderColor = recording
                ? Slate.Native.accent.cgColor
                : Slate.Native.Overlay.hairline.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc
    private func fire() { handler() }
}
