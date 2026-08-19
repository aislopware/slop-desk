// AndroidDeviceList — the host's Android devices, drawn in Slate ON THE PHONE.
//
// iOS-ONLY SINCE docs/56 INCREMENT 52b; the Mac draws the same two depths in AppKit
// (``SlopDeskMacUI/MacAndroidDeviceList``). What both halves read out of ``AndroidPresentation``
// rather than spelling twice: the filter, the two empty sentences, the row's subtitle, the predicate
// that decides whether a tap opens a mirror at all, and the context menu's whole table.
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

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

/// An ink ROLE resolved to this half's hues.
///
/// The role descends and the hue does not, because `SlopDeskSlate` sits ABOVE `SlopDeskDevicePanels`
/// and a token named from down there would be a cycle rather than a widening (docs/56 §2). The Mac's
/// half spells the same five answers against `Slate.Native.Text`; this is the SwiftUI one, and it is
/// here rather than in the design floor because the enum it switches over belongs to this panel.
extension AndroidInk {
    /// `@MainActor` because the ladder is: `Slate.Text` is main-actor state, and a computed property
    /// on a `Sendable` enum is nonisolated by default, so this reads as "a background thread asking
    /// for the theme's current hue" without it. The Mac's half inherits the isolation from the views
    /// that call it; this one is reached from `Text(…).foregroundStyle(…)` in a nonisolated position.
    @MainActor
    var color: Color {
        switch self {
        case .primary: Slate.Text.primary
        case .secondary: Slate.Text.secondary
        case .tertiary: Slate.Text.tertiary
        case .icon: Slate.Text.icon
        // `StatusInk`, not `Status`: this rung is spent on TEXT, and the two ladders part exactly
        // there — a dot may be `systemRed` because it is a shape, a word may not.
        case .err: Slate.StatusInk.err
        }
    }
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
            .foregroundStyle(AndroidInk.icon.color)
            .frame(width: Slate.Metric.deviceMarkWidth, alignment: .leading)
    }
}

struct AndroidDeviceList: View {
    @Bindable var model: AndroidSidebarModel

    /// Filters as typed. Deliberately NOT persisted: a filter that survived a panel collapse would
    /// hide devices with nothing on screen to explain why.
    @State private var query = ""

    private var matches: [AndroidDevice] {
        AndroidPresentation.matches(model.devices, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            if model.devices.isEmpty {
                message(AndroidPresentation.noDevices)
            } else if matches.isEmpty {
                message(AndroidPresentation.noMatches(query))
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
                .foregroundStyle(AndroidInk.icon.color)
            SlateSearchField(placeholder: AndroidPresentation.searchPlaceholder, text: $query)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemSymbol: .xmarkCircleFill)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(AndroidInk.icon.color)
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
        let sections = AndroidDeviceSections.sections(for: matches)
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
            // WHICH devices a stop-all may act on is ``AndroidPresentation/stoppable(in:)`` — a
            // physical device is not something this panel may power off, so a control that named
            // every attached device would promise a verb it refuses for half of them.
            let stoppable = AndroidPresentation.stoppable(in: section.devices)
            if section.isRunning, stoppable.count > 1 {
                SlatePlateButton(
                    symbol: .stopCircle,
                    help: AndroidPresentation.shutDownAllHelp(count: stoppable.count),
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: AndroidInk.tertiary.color,
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
            onTap: { AndroidPresentation.open(device, on: model) },
            leading: { AndroidFamilyMark(device: device) },
            title: {
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(AndroidInk.primary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            },
            titleTrailing: { hovering in
                HStack(spacing: Slate.Metric.space1) {
                    if let subtitle = AndroidPresentation.subtitle(
                        for: device, showsVersion: showsVersion,
                    ) {
                        Text(subtitle)
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(AndroidInk.tertiary.color)
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
                    help: AndroidPresentation.startHelp(device),
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: hovering ? AndroidInk.primary.color : AndroidInk.tertiary.color,
                ) {
                    Task { await model.boot(device) }
                }
                .transition(.opacity)
            }
        }
        .animation(Slate.Anim.smallFade, value: isPending)
    }

    /// The selection write rides ONE `withAnimation` transaction, which is what carries the drill —
    /// the panel's transition vocabulary lives on the surface that owns both depths
    /// (``CodePanelSurfaces``), and the views themselves declare no animation for it. The GUARD is
    /// ``AndroidPresentation/canEnter(_:)``, which is why this is not the second hand-spelled copy of
    /// it that it used to be.
    private func enter(_ device: AndroidDevice) {
        guard AndroidPresentation.canEnter(device) else { return }
        withAnimation(Slate.Anim.standard) { model.select(device.key) }
    }

    /// The menu is a TABLE from below and this is only its drawing — which verbs a device offers, in
    /// what order, and where the separator falls are decisions, and a decision drawn twice drifts
    /// silently (``AndroidPresentation/menu(for:)``).
    private func menu(for device: AndroidDevice) -> some View {
        ForEach(Array(AndroidPresentation.menu(for: device).enumerated()), id: \.offset) { entry in
            switch entry.element {
            case .separator:
                Divider()
            case let .verb(verb):
                Button(verb.title) {
                    AndroidPresentation.run(verb, device: device, on: model, enter: enter)
                }
            }
        }
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
