// AndroidDeviceList — the host's Android devices, drawn in Slate.
//
// Structurally the twin of ``SimulatorDeviceList``: a search plate, running devices lifted into their
// own group above, the rest cut by family, both groups in a grid whose column count follows the panel
// width, and every row carrying its verb at rest in the tertiary ink. Every one of those decisions was
// argued out on the simulator panel and holds here for the same reasons — see that file's header.
//
// ⚠️ THE ONE PLACE THE TWO PANELS DIVERGE — and it is the interesting one.
//
// The simulator list draws a running device as a live thumbnail, because for a device that is OFF the
// server knows four things and three are already on screen: the bareness was a want of SUBJECT, and
// the picture was the only subject available. Android inverts BOTH halves of that:
//
//   - A shut-down AVD has an exact `config.ini` — screen size, density, device profile, ABI, API
//     level. There is a fact line to draw, so a row that is not running is not bare.
//   - A running device's picture is EXPENSIVE. Measured 2026-08-04 on this host's emulator:
//     `adb exec-out screencap -p` is 300 KB in ~250 ms, three runs, no variance worth reporting. There
//     is no scale or quality parameter — `screencap` renders at native size and PNG-encodes ON THE
//     DEVICE — so at the simulator card's two-second cadence that is 150 KB/s and a fat slice of a
//     phone's core per listed device. The simulator's equivalent is 13.5 KB in 22 ms.
//
// So the arithmetic that made a live card obviously right over there makes it obviously wrong here,
// and the fact that made it necessary is absent. A running Android device is drawn as a card carrying
// its TRUE PROPORTIONS and its facts, and a picture is taken when somebody asks for one (the context
// menu, or the stage's own capture button). The card is still a card rather than a row, because a
// running device is still the thing you are most likely to want and the shape of the screen is worth
// the width.

#if os(macOS)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// One group of the list: a heading and its devices.
///
/// A SECTION rather than a flat sequence, and for the identity reason `docs/47` records: a device's
/// key is stable across a boot — right for "is this the same device", wrong for "is this the same
/// row", since the row's whole content is a function of the state that just changed. Every section
/// gets its own container, so a device that boots is removed from one grid and inserted into another
/// and cannot carry a stale view across.
struct AndroidListSection: Identifiable {
    let title: String
    /// The platform version every member reports, or `nil` when they do not all agree.
    let version: String?
    let devices: [AndroidDevice]

    var id: String { title }

    /// The group of what is up — drawn as cards, and the only group not cut by family.
    var isRunning: Bool { title == AndroidDeviceList.runningTitle }

    /// A device prints its own version only where the heading has not already said it.
    func showsVersion(_ device: AndroidDevice) -> Bool {
        AndroidDeviceHeader<EmptyView>.version(of: device) != version
    }

    /// This section's rows, named by section — the value the list's reflow watches. Section-qualified
    /// because the move a boot makes IS between sections, and a plain list of keys would not see it.
    var rowIdentities: [String] { devices.map { "\(title)/\($0.key)" } }
}

/// The device family as a SHAPE, so the kind of machine is answered without reading a word. Shared by
/// the rows and the cards so one device reads the same in both. Drawn in the ICON ink for the reason
/// ``SimulatorFamilyMark`` gives: every row carries this, and at full contrast a column of them is a
/// rule down the leading edge competing with the names they exist to help find.
struct AndroidFamilyMark: View {
    let device: AndroidDevice

    var body: some View {
        Image(systemSymbol: AndroidDeviceKind.infer(device).symbol)
            .font(.system(size: Slate.Typeface.body, weight: .medium))
            .foregroundStyle(Slate.Text.icon)
            .frame(width: Slate.Metric.deviceMarkWidth, alignment: .leading)
    }
}

struct AndroidDeviceList: View {
    @Bindable var model: AndroidSidebarModel

    /// Filters as typed. Deliberately NOT persisted: a filter that survived a panel collapse would
    /// hide devices with nothing on screen to explain why.
    @State private var query = ""

    private var matches: [AndroidDevice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.devices }
        return model.devices.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.model ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.serial ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.release ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The whole list as sections. Running first, then the families in the enum's own rank order
    /// rather than in encounter order, so the headings do not reshuffle because the host's device set
    /// was edited.
    static func sections(for devices: [AndroidDevice]) -> [AndroidListSection] {
        var sections: [AndroidListSection] = []
        // Anything with a transport goes in the top group, including a device that is `unauthorized`.
        // That device is the one most in need of being noticed — it is plugged in and refusing — and
        // burying it among the AVDs that are merely switched off is where it would go to hide.
        let attached = devices.filter { $0.serial != nil }
        if !attached.isEmpty {
            sections.append(section(runningTitle, attached))
        }
        let families = Dictionary(grouping: devices.filter { $0.serial == nil }) {
            AndroidDeviceKind.infer($0)
        }
        for (kind, members) in families.sorted(by: { $0.key.rank < $1.key.rank }) {
            sections.append(section(kind.groupTitle, members))
        }
        return sections
    }

    /// One heading and its devices, with the platform version LIFTED into the heading when every
    /// member shares it — the rule ``SimulatorDeviceList/section(_:_:)`` establishes for runtimes. A
    /// device set is usually a handful of AVDs on one system image, so the per-row version was the
    /// same eight characters printed down the whole column.
    static func section(_ title: String, _ members: [AndroidDevice]) -> AndroidListSection {
        AndroidListSection(title: title, version: sharedVersion(of: members), devices: members)
    }

    /// The version every member reports, or `nil` if they disagree. An absent version counts as a
    /// disagreement rather than as a shared value — a heading reading `PHONE ·` would be the panel
    /// lifting the absence of a fact into the place it prints facts.
    static func sharedVersion(of members: [AndroidDevice]) -> String? {
        guard let first = members.first.flatMap(AndroidDeviceHeader<EmptyView>.version(of:)),
              members.allSatisfy({ AndroidDeviceHeader<EmptyView>.version(of: $0) == first })
        else { return nil }
        return first
    }

    static let runningTitle = "Attached"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            if model.devices.isEmpty {
                message("No Android devices or emulators on the host.")
            } else if matches.isEmpty {
                message("No devices match “\(query)”.")
            } else {
                list
            }
        }
        .background(Slate.Surface.field)
    }

    // MARK: Filter

    private var searchBar: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
            SlateSearchField(placeholder: "Search devices", text: $query)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemSymbol: .xmarkCircleFill)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.icon)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .animation(Slate.Anim.smallFade, value: query.isEmpty)
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightControl)
        .slateChromeFieldPlate()
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space2)
    }

    // MARK: List

    private var list: some View {
        let sections = Self.sections(for: matches)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    heading(section)
                    if section.isRunning {
                        shelf(section)
                    } else {
                        grid(section)
                    }
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.bottom, Slate.Metric.space2)
        }
        // THE REFLOW. A boot is not a row changing colour: the device leaves its family, ATTACHED
        // appears above it, and everything under the cut shifts. Keyed on the row IDENTITIES, so a
        // poll that returns the same devices animates nothing and a filter keystroke animates once.
        .animation(Slate.Anim.standard, value: sections.flatMap(\.rowIdentities))
    }

    private var shelfColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: Slate.Metric.deviceCardWidth, maximum: Slate.Metric.deviceCardWidth),
            spacing: Slate.Metric.space2, alignment: .topLeading,
        )]
    }

    private var rowColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: Slate.Metric.deviceRowWidth),
            spacing: Slate.Metric.space1, alignment: .leading,
        )]
    }

    private func shelf(_ section: AndroidListSection) -> some View {
        LazyVGrid(columns: shelfColumns, alignment: .leading, spacing: Slate.Metric.space2) {
            ForEach(section.devices) { device in
                AndroidRunningCard(model: model, device: device) { enter(device) }
                    .contextMenu { menu(for: device) }
            }
        }
        .padding(.horizontal, Slate.Metric.space1)
        .padding(.bottom, Slate.Metric.space2)
    }

    private func grid(_ section: AndroidListSection) -> some View {
        LazyVGrid(columns: rowColumns, alignment: .leading, spacing: 0) {
            ForEach(section.devices) { device in
                row(device, showsVersion: section.showsVersion(device))
            }
        }
    }

    private func heading(_ section: AndroidListSection) -> some View {
        SlateSectionHeader(section.title, caption: section.version) {
            // Emulators only, and counted as such: a physical device is not something this panel may
            // power off, so a control that named every attached device would promise a verb it
            // refuses for half of them.
            let stoppable = section.devices.filter { $0.isRunning && $0.isEmulator }
            if section.isRunning, stoppable.count > 1 {
                SlatePlateButton(
                    symbol: .stopCircle,
                    help: "Shut down all \(stoppable.count) running emulators",
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: Slate.Text.tertiary,
                ) {
                    Task { await model.shutdownAll() }
                }
            }
        }
        .padding(.leading, Slate.Metric.space1)
    }

    private func row(_ device: AndroidDevice, showsVersion: Bool) -> some View {
        SlateListRow(
            active: false,
            onTap: { open(device) },
            leading: { AndroidFamilyMark(device: device) },
            title: {
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            },
            titleTrailing: { hovering in
                HStack(spacing: Slate.Metric.space1) {
                    if let subtitle = subtitle(for: device, showsVersion: showsVersion) {
                        Text(subtitle)
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(Slate.Text.tertiary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    action(for: device, hovering: hovering)
                }
            },
            trailingOverlay: { _ in EmptyView() },
        )
        .contextMenu { menu(for: device) }
    }

    /// The trailing text: the platform version where the heading has not already said it, and the
    /// SCREEN otherwise. The screen is the fact the simulator list could not print — an AVD's
    /// `config.ini` is its definition, not a lookalike's — and it is what tells two similarly-named
    /// AVDs apart when they share a system image.
    private func subtitle(for device: AndroidDevice, showsVersion: Bool) -> String? {
        if showsVersion, let version = AndroidDeviceHeader<EmptyView>.version(of: device) {
            return version
        }
        guard let width = device.width, let height = device.height else { return nil }
        return "\(width) × \(height)"
    }

    /// The one verb that applies, at REST but quiet: a small solid glyph in the tertiary ink, which
    /// steps to the primary one while the pointer is anywhere on the row.
    private func action(for device: AndroidDevice, hovering: Bool) -> some View {
        let isPending = model.pending.contains(device.key)
        return ZStack {
            if isPending {
                // Through `WorkingSpinner` rather than a bare `ProgressView`, which in a hosted
                // column resolves the Aqua appearance and comes out dark grey on a dark theme.
                WorkingSpinner()
                    .frame(width: Slate.Metric.heightControl, height: Slate.Metric.heightControl)
                    .transition(.opacity)
            } else {
                SlatePlateButton(
                    symbol: .playFill,
                    help: "Start \(device.name)",
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: hovering ? Slate.Text.primary : Slate.Text.tertiary,
                ) {
                    Task { await model.boot(device) }
                }
                .transition(.opacity)
            }
        }
        .animation(Slate.Anim.smallFade, value: isPending)
    }

    /// A click on a device that is not running starts it — the same intent a click on a running card
    /// carries, one step earlier. The row's spinner holds until the boot is VISIBLE in the list (see
    /// ``AndroidSidebarModel/boot(_:)``), at which point the row itself moves to the attached shelf.
    private func open(_ device: AndroidDevice) {
        guard !model.pending.contains(device.key) else { return }
        Task { await model.boot(device) }
    }

    /// The selection write rides ONE `withAnimation` transaction, which is what carries the drill —
    /// the panel's transition vocabulary lives on the surface that owns both depths
    /// (``CodeSidebarColumn``), and the views themselves declare no animation for it.
    private func enter(_ device: AndroidDevice) {
        // A booting emulator may be entered — the stage waits for it. See ``AndroidRunningCard``'s
        // tap for why a physical device must actually be running.
        guard device.isRunning || device.isEmulator && device.serial != nil else { return }
        withAnimation(Slate.Anim.standard) { model.select(device.key) }
    }

    @ViewBuilder
    private func menu(for device: AndroidDevice) -> some View {
        if device.isRunning {
            Button("Open Screen") { enter(device) }
            // The capture is 250 ms and 300 KB, which is why it is a menu item rather than a poll —
            // see this file's header. Asked for once, it is worth every millisecond.
            Button("Copy Screenshot") { Task { await model.copyScreenshot(of: device.key) } }
            if device.isEmulator {
                Button("Shut Down") { Task { await model.shutdown(device) } }
            }
        } else if device.avdName != nil {
            Button("Start") { Task { await model.boot(device) } }
        }
        Divider()
        if let serial = device.serial {
            // The serial is what every other tool wants — `adb -s`, an install target, a bug report.
            Button("Copy Serial") { copy(serial) }
        }
        Button("Copy Name") { copy(device.name) }
    }

    private func copy(_ text: String) {
        ClientPasteboard.write(text)
    }

    // MARK: Notices

    // A FAILED POLL DRAWS NOTHING HERE, for the reason `SimulatorDeviceList` records: the last-known
    // devices are still the best information available, the report goes to the window's notification
    // card like every other report this panel makes, and two bespoke alert shapes in one panel was
    // the thing being fixed.

    private func message(_ text: String) -> some View {
        DevicePanelChrome.notice(text)
    }
}
#endif
