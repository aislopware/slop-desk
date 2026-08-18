// MacSettingsPage — one settings section, built from the table.
//
// The whole body is `SettingsLayout.groups(section, for: .mac)`: a group becomes a titled box, a row
// becomes a control, and the group's apply-timing becomes the chip under it. This file names no
// section, no group, no row and no option — ask it what the Appearance page contains and it cannot
// tell you, which is the property that makes the two halves incapable of drifting.
//
// A REBUILD IS THE UPDATE. Three rows on this page are conditioned on another setting's VALUE — the
// window steppers on the size mode, the custom link schemes on the detection mode, the line-height
// multiplier on the line-height mode — and those conditions are dynamic rather than layout, so the
// table lists every row and the page decides. AppKit has no invalidation to hang that on, so a write
// rebuilds the section's stack. It is a form of a few dozen views rebuilt on a click, not a frame
// loop; the alternative is a dependency graph hand-maintained per row, which is what the SwiftUI half
// gets from the framework and this half would have to get wrong by hand.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate — the ONE token ladder, in its native (NSColor/NSFont) view
import SlopDeskWorkspaceCore

/// The right column: the selected section, scrolled.
@MainActor
final class MacSettingsPageController: NSViewController {
    private let store: PreferencesStore
    private let agentHooks: AgentHooksController?
    private let workspace: WorkspaceStore?

    private let scroll = NSScrollView()
    private let column = NSStackView()
    /// Which section is shown, so a rebuild after a write lands on the same page.
    private var section: String = ""
    /// Where the All-Settings index's ✎ sends the navigator — set by the window that owns both columns.
    var onJump: (String) -> Void = { _ in }

    init(store: PreferencesStore, agentHooks: AgentHooksController?, workspace: WorkspaceStore?) {
        self.store = store
        self.agentHooks = agentHooks
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Slate.Metric.space4
        column.translatesAutoresizingMaskIntoConstraints = false
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space4, right: Slate.Metric.space4,
        )

        let clip = NSView()
        clip.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: clip.bottomAnchor),
        ])

        scroll.documentView = clip
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        view = scroll
        // The document tracks the clip view's WIDTH so a wrapping subtitle knows how wide it may be;
        // its height is its content's, which is what makes the page scroll rather than squash.
        clip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            clip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    /// Show a section by its routed id.
    func show(_ section: String) {
        self.section = section
        rebuild()
        scroll.contentView.scroll(to: .zero)
    }

    // MARK: Building

    private func rebuild() {
        for view in column.arrangedSubviews { column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let bindings = MacSettingsBindings(store: store, workspace: workspace)
        let builder = MacSettingsRowBuilder(
            bindings: bindings,
            agentHooks: agentHooks,
            workspace: workspace,
            onValueChanged: { [weak self] key in
                guard Self.gatesAnotherRow(key) else { return }
                // Rebuilding on the next turn of the run loop rather than inside the control's own
                // action keeps AppKit from tearing down the view that is mid-send.
                DispatchQueue.main.async { self?.rebuild() }
            },
            onJump: { [weak self] section in self?.onJump(section) },
        )
        for group in SettingsLayout.groups(section, for: .mac) {
            column.addArrangedSubview(box(group, builder, bindings))
        }
    }

    /// One group: its header, the rows this half draws, and the chip saying when an edit lands.
    private func box(
        _ group: SettingsLayout.Group,
        _ builder: MacSettingsRowBuilder,
        _ bindings: MacSettingsBindings,
    ) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Slate.Metric.space3
        rows.translatesAutoresizingMaskIntoConstraints = false

        for row in group.rows {
            guard visible(row, bindings) else { continue }
            if let view = builder.view(for: row) {
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            for extra in dependents(of: row, builder, bindings) {
                rows.addArrangedSubview(extra)
                extra.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }

        // The chip belongs where an EDIT does. A group of nothing but bespoke surfaces has no edit for
        // a timing to describe — the surface inside says when its own changes land, if it has any.
        if group.editsASetting {
            rows.addArrangedSubview(timingChip(group.timing))
        }

        guard !group.drawsItsOwnHeader else { return rows }
        let header = NSTextField(labelWithString: group.title)
        header.font = .preferredFont(forTextStyle: .headline)

        let stack = NSStackView(views: [header, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space2
        rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A chip saying when an edit in this group takes effect — the deferred/live distinction as a data
    /// attribute rather than as prose, which is what the words and the symbol crossing as a value buys.
    private func timingChip(_ timing: SettingsCatalog.ApplyTiming) -> NSView {
        let icon = NSImageView(
            image: NSImage(systemSymbolName: timing.symbol, accessibilityDescription: nil) ?? NSImage(),
        )
        let label = NSTextField(labelWithString: timing.label)
        label.font = .preferredFont(forTextStyle: .caption1)
        let tint: NSColor = timing == .live ? Slate.Native.Status.ok : Slate.Native.Status.warn
        label.textColor = tint
        icon.contentTintColor = tint

        let chip = NSStackView(views: [NSView(), icon, label])
        chip.orientation = .horizontal
        chip.spacing = Slate.Metric.space1
        chip.alignment = .centerY
        return chip
    }

    // MARK: What the VALUE of another setting decides

    /// The three settings whose VALUE decides whether some other row is drawn — read off the two
    /// functions below, which are the only places such a condition may live. A write to anything else
    /// changes a control's value and nothing about the page, so it does not cost a rebuild.
    private static func gatesAnotherRow(_ key: String) -> Bool {
        key == SettingsKey.windowSizeKey
            || key == SettingsKey.autoDetectLinkSchemesKey
            || key == AllSettingsCatalog.RenderKey.fontLineHeight
    }

    /// Whether a row belongs on the page right now. Every condition here is on another setting's
    /// value, never on the platform — a platform gate is the table's, and this is what is left.
    private func visible(_ row: SettingsLayout.Row, _ bindings: MacSettingsBindings) -> Bool {
        switch row.key {
        case SettingsKey.windowColsKey,
             SettingsKey.windowRowsKey:
            token(SettingsKey.windowSizeKey, bindings) == WindowSizeMode.grid.rawValue
        case SettingsKey.windowWidthPxKey,
             SettingsKey.windowHeightPxKey:
            token(SettingsKey.windowSizeKey, bindings) == WindowSizeMode.frame.rawValue
        case SettingsKey.customLinkSchemes:
            token(SettingsKey.autoDetectLinkSchemesKey, bindings) == AutoDetectLinkSchemes.custom.rawValue
        default:
            true
        }
    }

    /// The controls a row's own VALUE opens — today only the line-height multiplier, which is what
    /// picking `custom` reveals and therefore is not a row of its own.
    private func dependents(
        of row: SettingsLayout.Row,
        _ builder: MacSettingsRowBuilder,
        _ bindings: MacSettingsBindings,
    ) -> [NSView] {
        guard row.key == AllSettingsCatalog.RenderKey.fontLineHeight,
              token(row.key, bindings) == "custom",
              case let .number(get, set) = bindings.lineHeightMultiplier()
        else { return [] }

        let readout = NSTextField(labelWithString: String(format: "%.2f×", get()))
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = Slate.Native.Text.secondary
        let slider = MacActionSlider { value in
            readout.stringValue = String(format: "%.2f×", value)
            set(value)
        }
        slider.minValue = 0.8
        slider.maxValue = 2.0
        slider.doubleValue = get()

        let line = NSStackView(views: [NSTextField(labelWithString: "Multiplier"), slider, readout])
        line.orientation = .horizontal
        line.spacing = Slate.Metric.space2
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return [
            line,
            builder.note("Changing line height re-measures the cell and reflows the terminal (a resize)."),
        ]
    }

    private func token(_ key: String, _ bindings: MacSettingsBindings) -> String {
        guard case let .token(get, _)? = bindings.access(key) else { return "" }
        return get()
    }
}
