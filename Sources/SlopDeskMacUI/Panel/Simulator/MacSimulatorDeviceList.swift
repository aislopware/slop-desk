// MacSimulatorDeviceList — the host's devices, drawn in Slate, in AppKit (docs/56 stage D,
// increment 52a).
//
// This replaced a `WKWebView` showing the simulator server's own page. The objection was never that the
// page looked wrong: it was that matching it to the theme meant re-scoping its CSS variables AND
// overriding the handful of rules that baked a literal hex, with every server update putting that back
// in play. Drawn natively the question does not arise — the row shell, the section header and the search
// plate are the same ones the rest of the chrome uses, so a theme swap repoints this list with
// everything else.
//
// GROUPING is by DEVICE FAMILY, with running devices lifted into their own group above. That rule, its
// ordering and the runtime-lifting behind the headings are ``SimulatorDeviceSections``' and were already
// shared before this increment — a device set is thirty near-identical strings ("iPhone 17", "iPhone 17
// Pro", "iPhone 17 Pro Max") and the two questions actually asked of the list are "what is running" and
// "where are the iPads", so those are the two cuts.
//
// THE TWO GROUPS ARE DRAWN DIFFERENTLY, because only one of them has anything to show (user-directed
// 2026-08-04, "the list looks bare"). For a device that is OFF the server knows four things and three
// are already on screen; a device that is RUNNING has a screen, which is what ``MacSimulatorRunningCard``
// draws. The bareness was never a want of ornament — it was a want of subject.
//
// AND THE PANEL'S WIDTH IS SPENT ON DEVICES, not on air. Both groups lay out in a grid whose column
// count follows the width (``MacDevicePanelGrid``) — cards at a fixed width, rows at a minimum — so a
// wider panel shows more devices rather than longer rows.
//
// EVERY ROW CARRIES ITS ACTION, at rest, not on hover. An earlier revision hid boot and shutdown behind
// the pointer: discoverable only by accident, and impossible to see the state of. What the pointer
// changes is the action's WEIGHT, not its presence.
//
// A ROW NEVER REPEATS WHAT ITS HEADING ALREADY SAID — but a heading in a GRID does not reach every row
// it names, which is why the family glyph is on every row and every card while the runtime is lifted
// into the heading whenever every member shares it. In three columns the last row of the second grid
// line is most of a panel across and two lines down from that heading, and the eye arriving at it has
// nothing but the name.
//
// ## What a REBUILD costs here, and why it is still a rebuild
//
// The whole row column is rebuilt when the device set or the query changes, and NOT when a row's own
// state ticks: a device stepping through `Booting` observes its own `pending` inside the row
// (``MacSimulatorDeviceRow``), so a poll that returns the same devices rebuilds nothing at all. The
// SwiftUI half draws the same distinction with `.animation(…, value: sections.flatMap(\.rowIdentities))`
// — reflow on the identities, never on the state strings.
//
// The REFLOW itself is what the phone animates and this half cuts. A boot is not a row changing colour:
// the device leaves its family, RUNNING appears above it, and everything under the cut shifts. Animating
// that in AppKit means keeping every row view alive across a rebuild and animating frames between two
// flow layouts, which is a second layout pass over a list that is already re-sorted by the time it runs.
// It is the one thing this renderer gives up, and it is recorded rather than hidden.

import AppKit
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

@MainActor
final class MacSimulatorDeviceList: NSView {
    private let model: SimulatorSidebarModel
    private let onEnter: (String) -> Void

    /// Filters by name and runtime as typed. Deliberately NOT persisted: a filter that survived a panel
    /// collapse would hide devices with nothing on screen to explain why.
    private var query = ""

    private let scroller = NSScrollView()
    private let column = NSStackView()
    private var devices: [SimulatorDevice] = []

    init(model: SimulatorSidebarModel, onEnter: @escaping (String) -> Void) {
        self.model = model
        self.onEnter = onEnter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // THE GROUND, like every other column in this window (ONE ISLAND, law 1) — the list sinks.
        layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        let search = MacDevicePanelSearchPlate(
            placeholder: SimulatorPresentation.searchPlaceholder,
        ) { [weak self] typed in
            self?.query = typed
            self?.refill()
        }

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        let clip = MacSimulatorFlippedClip()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(column)

        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.documentView = clip

        addSubview(search)
        addSubview(scroller)
        NSLayoutConstraint.activate([
            // The search plate SHARES the list's gutter, so it reads exactly as wide as the rows below
            // it — the navigator's own arrangement, verbatim.
            search.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            scroller.topAnchor.constraint(
                equalTo: search.bottomAnchor, constant: Slate.Metric.space2,
            ),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            column.leadingAnchor.constraint(
                equalTo: clip.leadingAnchor, constant: Slate.Metric.space2,
            ),
            column.trailingAnchor.constraint(
                equalTo: clip.trailingAnchor, constant: -Slate.Metric.space2,
            ),
        ])
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }
    }

    // MARK: What the list is looking at

    /// The one observation. The DEVICE SET is read here and a row's own pending flag is read by the row,
    /// which is what keeps a boot from rebuilding the whole column every second while nothing moves.
    private func follow() {
        var set: [SimulatorDevice] = []
        withObservationTracking {
            set = model.devices
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        devices = set
        refill()
    }

    private var matches: [SimulatorDevice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.runtime.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: The column

    private func refill() {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let matches = matches
        guard !devices.isEmpty else {
            add(notice(SimulatorPresentation.noDevices))
            return
        }
        guard !matches.isEmpty else {
            add(notice(SimulatorPresentation.noMatches(query)))
            return
        }
        for section in SimulatorDeviceSections.sections(for: matches) {
            add(heading(section))
            add(section.isRunning ? shelf(section) : grid(section))
        }
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    /// What the list draws in place of rows: centred, secondary, filling the space the rows would have
    /// had.
    ///
    /// A FAILED POLL DRAWS NOTHING HERE (user-directed 2026-08-04). The last-known devices are still the
    /// best information available, the report goes to the window's notification card like every other
    /// report this panel makes, and two bespoke alert shapes in one panel was the thing being fixed.
    /// This is for a list that is genuinely empty, which is a different sentence.
    private func notice(_ words: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: words)
        label.font = .systemFont(ofSize: Slate.Typeface.base)
        label.textColor = Slate.Native.Text.secondary
        label.alignment = .center
        label.isSelectable = false
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: Slate.Metric.space3),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Slate.Metric.space3),
            label.widthAnchor.constraint(
                lessThanOrEqualTo: box.widthAnchor, constant: -Slate.Metric.space3 * 2,
            ),
        ])
        return box
    }

    /// The group's title, with its shared runtime as the heading's own CAPTION. The far edge is where
    /// the group's own CONTROL goes — `Shut Down All` appears only once more than one device is up.
    ///
    /// Nudged onto the ROWS' left rail: the header insets by `space2` and a list row by `space3`, and
    /// four points of disagreement between two things meant to line up reads as "off" without anyone
    /// locating why. The rail lands on the family glyph, which is where a section header belongs.
    private func heading(_ section: SimulatorListSection) -> NSView {
        var accessory: NSView?
        if section.isRunning, section.devices.count > 1 {
            let count = section.devices.count
            accessory = MacDevicePanelGlyphButton(
                symbol: .stopCircle, help: SimulatorPresentation.shutdownAllHelp(count),
                tint: Slate.Native.Text.tertiary,
            ) { [model] in Task { await model.shutdownAll() } }
        }
        let header = MacDevicePanelSectionHeader(
            section.title, caption: section.runtime, accessory: accessory,
        )
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: box.leadingAnchor, constant: Slate.Metric.space1,
            ),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            header.topAnchor.constraint(equalTo: box.topAnchor),
            header.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    /// The running devices, as cards at a FIXED column width. Fixed rather than sharing, so one running
    /// device is one card and not a card stretched across the panel.
    private func shelf(_ section: SimulatorListSection) -> NSView {
        let cards = section.devices.map { device in
            MacSimulatorRunningCard(model: model, device: device) { [onEnter] in onEnter(device.udid) }
        }
        let grid = MacDevicePanelGrid(
            cells: cards, columnWidth: Slate.Metric.deviceCardWidth, isFixed: true,
            spacing: Slate.Metric.space2,
        )
        return inset(grid, leading: Slate.Metric.space1, bottom: Slate.Metric.space2)
    }

    /// The shut-down devices, as rows in columns that SHARE the width. Sharing here because a row's
    /// content is a name, and a name is happy to have more room; a card's content is a picture at a
    /// resolution the server already chose.
    private func grid(_ section: SimulatorListSection) -> NSView {
        let rows = section.devices.map { device in
            MacSimulatorDeviceRow(
                model: model, device: device, showsRuntime: section.showsRuntime(device),
                onEnter: onEnter,
            )
        }
        return MacDevicePanelGrid(
            cells: rows, columnWidth: Slate.Metric.deviceRowWidth, isFixed: false,
            spacing: Slate.Metric.space1,
        )
    }

    private func inset(_ view: NSView, leading: CGFloat, bottom: CGFloat) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -leading),
            view.topAnchor.constraint(equalTo: box.topAnchor),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom),
        ])
        return box
    }
}

/// The scroller's document view. FLIPPED so the column starts at the top and grows down — an unflipped
/// document view pins its content to the bottom of the clip and a short list floats at the wrong end.
@MainActor
final class MacSimulatorFlippedClip: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One shut-down device

/// A row for a device that is not running: its family mark, its name, whatever the heading has not
/// already said, and the one verb that applies.
@MainActor
final class MacSimulatorDeviceRow: MacDevicePanelRowShell {
    private let model: SimulatorSidebarModel
    private let device: SimulatorDevice
    private let onEnter: (String) -> Void
    private let boot: MacDevicePanelGlyphButton
    private let spinner = MacDevicePanelSpinner()

    init(
        model: SimulatorSidebarModel, device: SimulatorDevice, showsRuntime: Bool,
        onEnter: @escaping (String) -> Void,
    ) {
        self.model = model
        self.device = device
        self.onEnter = onEnter
        // SOLID rather than the enclosing `…Circle` pair — a ring at this size reads as a control
        // chrome rather than as a direction, and a dozen of them down the trailing edge read as a rule.
        boot = MacDevicePanelGlyphButton(
            symbol: .playFill, help: SimulatorPresentation.bootHelp(device),
            tint: Slate.Native.Text.tertiary,
        ) { Task { await model.boot(device.udid) } }
        super.init(frame: .zero)

        content.addArrangedSubview(macSimulatorFamilyMark(device))
        let name = macDevicePanelLabel(
            device.name, size: Slate.Typeface.base, color: Slate.Native.Text.primary,
        )
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(name)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        content.addArrangedSubview(spacer)

        // Both in the trailing CLUSTER rather than one of them in a hover overlay: laid out side by
        // side they cannot collide — the first cut of this row put the button over the runtime and drew
        // a play glyph through the word "iOS".
        if let subtitle = SimulatorPresentation.rowSubtitle(device, showsRuntime: showsRuntime) {
            let meta = macDevicePanelLabel(
                subtitle, size: Slate.Typeface.footnote, color: Slate.Native.Text.tertiary,
            )
            meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            content.addArrangedSubview(meta)
        }
        content.addArrangedSubview(spinner)
        content.addArrangedSubview(boot)

        // A shut-down device has no screen, so its row BOOTS it — doing nothing on a click is the
        // behaviour that made an earlier revision feel broken. Same intent a click on a running card
        // carries ("I want to use this device"), one step earlier.
        onTap = { [weak self] in self?.open() }
        followPending()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// At REST but quiet: the verb sits in the tertiary ink and steps to the primary one while the
    /// pointer is anywhere on the row. Drawn at full strength on every row it became a column of a dozen
    /// identical rings down the trailing edge, which is texture, not twelve verbs.
    override func hoverChanged(_ hovering: Bool) {
        boot.tint = hovering ? Slate.Native.Text.primary : Slate.Native.Text.tertiary
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        macSimulatorDeviceMenu(model: model, device: device) { [weak self, udid = device.udid] in
            self?.onEnter(udid)
        }
    }

    private func open() {
        guard !model.pending.contains(device.udid) else { return }
        Task { await model.boot(device.udid) }
    }

    /// The verb and the spinner share the slot and swap — see ``MacSimulatorRunningCard`` for why the
    /// swap is same-size rather than a reflow.
    private func followPending() {
        var pending = false
        withObservationTracking {
            pending = self.model.pending.contains(self.device.udid)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followPending() }
            }
        }
        spinner.isHidden = !pending
        boot.isHidden = pending
    }
}

// MARK: - The context menu both the row and the card carry

/// What a sidebar row has no width for — the UDID, and the destructive verb.
///
/// The VERBS and their order are ``SimulatorPresentation/menu(for:)``'s, so the phone's menu and this
/// one cannot come apart; what is here is the wiring from a verb to the model call behind it, which is
/// the half that is genuinely this renderer's.
@MainActor
func macSimulatorDeviceMenu(
    model: SimulatorSidebarModel, device: SimulatorDevice, onOpen: @escaping () -> Void,
) -> NSMenu {
    let menu = NSMenu()
    for verb in SimulatorPresentation.menu(for: device) {
        guard let title = verb.title else {
            menu.addItem(.separator())
            continue
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.target = MacSimulatorMenuTarget.shared
        item.action = #selector(MacSimulatorMenuTarget.fire(_:))
        item.representedObject = MacSimulatorMenuAction {
            switch verb {
            case .openScreen: onOpen()
            // The panel can already put a capture on the pasteboard, and a running device's screen is
            // often worth a picture without being worth opening.
            case .copyScreenshot: Task { await model.copyScreenshot(of: device.udid) }
            case .shutdown: Task { await model.shutdown(device.udid) }
            case .boot: Task { await model.boot(device.udid) }
            case .copyUDID: ClientPasteboard.write(device.udid)
            case .copyName: ClientPasteboard.write(device.name)
            case .separator: break
            }
        }
        menu.addItem(item)
    }
    return menu
}

/// A menu item's closure, boxed so it can ride `representedObject`.
///
/// `NSMenuItem` dispatches through a target/action pair and carries no closure of its own, so the verb
/// has to travel as an object. Boxed rather than stored on a per-menu target object because the menu is
/// rebuilt on every right-click and a per-menu owner would have to outlive it — this way the item owns
/// its own verb and nothing has to be retained to keep it alive.
@MainActor
private final class MacSimulatorMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// The one shared target. A singleton because the action is entirely in the item's
/// `representedObject`: there is no per-menu state for a target to hold, and giving every menu its own
/// would be an object per right-click that exists only to forward one selector.
@MainActor
private final class MacSimulatorMenuTarget: NSObject {
    static let shared = MacSimulatorMenuTarget()

    @objc
    func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? MacSimulatorMenuAction)?.run()
    }
}
