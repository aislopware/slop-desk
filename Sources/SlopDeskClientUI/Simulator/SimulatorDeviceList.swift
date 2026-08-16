// SimulatorDeviceList — the host's devices, drawn in Slate.
//
// This replaced a WKWebView showing the simulator server's own page. The objection was never that
// the page looked wrong: it was that matching it to the theme meant re-scoping its CSS variables AND
// overriding the handful of rules that baked a literal hex, with every server update putting that
// back in play. Drawn natively the question does not arise — the row shell, the section header and
// the search plate are the same ones the navigator uses, so a theme swap repoints this list with
// everything else.
//
// GROUPING is by DEVICE FAMILY, with running devices lifted into their own group above. A device set
// is thirty near-identical strings ("iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max"), and the two
// questions actually asked of this list are "what is running" and "where are the iPads" — so those
// are the two cuts. Sorting inside a family is the server's own order, which is stable across polls;
// a list that reorders itself under the cursor is the opposite of what someone clicking Boot wants.
//
// THE TWO GROUPS ARE DRAWN DIFFERENTLY, because only one of them has anything to show (user-directed
// 2026-08-04, "the list looks bare"). For a device that is OFF the server knows four things — name,
// runtime, state, udid — and three are already on screen. There is no fifth: measured 2026-08-04,
// `definition.json` is CHROME data and falls back to a near model, so a size column or a per-row
// silhouette built on it would be wrong for four of this host's eleven devices. A device that is
// RUNNING has a screen, and that is what ``SimulatorRunningCard`` draws. The bareness was never a
// want of ornament — it was a want of subject.
//
// AND THE PANEL'S WIDTH IS SPENT ON DEVICES, not on air. A right panel is ~700pt and a device name is
// ~180 of it: one row per line put a play triangle five hundred points from the name it belonged to
// and turned the trailing edge into a column of identical glyphs. Both groups lay out in a grid whose
// column count follows the width — cards at a fixed width, rows at a minimum — so a wider panel shows
// more devices rather than longer rows.
//
// EVERY ROW CARRIES ITS ACTION, at rest, not on hover. The previous revision hid boot and shutdown
// behind the pointer: discoverable only by accident, and impossible to see the state of. What the
// pointer changes is the action's WEIGHT, not its presence — at rest it is a small tertiary glyph, and
// the hovered row's verb steps up to the primary ink. Drawn at full strength on every row it became a
// column of a dozen identical rings down the trailing edge, which is texture, not twelve verbs
// (user-directed 2026-08-04).
//
// A ROW NEVER REPEATS WHAT ITS HEADING ALREADY SAID — but a heading in a GRID does not reach every
// row it names. The runtime is still lifted into the heading when every member shares it, and that
// rule is unchanged. The family glyph is a different case now: in a single column, `IPAD` sat
// directly above every row under it and a glyph on each was the same word restated eleven times. In
// three columns the last row of the second grid line is most of a panel across and two lines down
// from that heading, and the eye arriving at it has nothing but the name. So the glyph is back, on
// every row and on every card — one shape per family, drawn in the icon ink so a column of them
// sorts the list without competing with the names (user-directed 2026-08-04).
//
// The CONTEXT MENU carries what a sidebar row has no width for — the UDID, and the destructive verb.

#if os(macOS)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

/// One group of the list: a heading and its devices.
///
/// A SECTION rather than a flat sequence of heading-or-device entries, and the identity trap that
/// shape existed to dodge is now structural. A device's udid alone is stable across a boot — right
/// for "is this the same device", wrong for "is this the same row", since the row's whole content is
/// a function of the state that just changed. The earlier fix qualified each row's id by its section;
/// this one gives every section its own container, so a device that boots is removed from one grid
/// and inserted into another and cannot carry a stale view across. Families hold only shut-down
/// devices, so a row can no longer change state without also changing container.
struct SimulatorListSection: Identifiable {
    let title: String
    /// The runtime every member reports, or `nil` when they do not all agree.
    let runtime: String?
    let devices: [SimulatorDevice]

    var id: String { title }

    /// The group of what is up — drawn as cards, and the only group not cut by family.
    var isRunning: Bool { title == SimulatorDeviceList.runningTitle }

    /// A device prints its own runtime only where the heading has not already said it.
    func showsRuntime(_ device: SimulatorDevice) -> Bool { device.runtime != runtime }

    /// This section's rows, named by section — the value the list's reflow watches. Section-qualified
    /// because the move a boot makes IS between sections, and a plain list of udids would not see it.
    var rowIdentities: [String] { devices.map { "\(title)/\($0.udid)" } }
}

/// The device family as a SHAPE, so the kind of machine is answered without reading a word
/// (user-directed 2026-08-04). Shared by the rows and the cards so one device reads the same in both.
///
/// One glyph per family and no finer: SF Symbols has a phone, a pad, a watch, a television and a
/// visor, and nothing that tells a 17 Pro from a 17 Pro Max. Faking that difference by scaling the
/// symbol a point or two would be noise wearing the costume of information — the size *is* the thing
/// the name says, and the name is right beside it. Which silhouette each family gets, and why the pad
/// is turned on its side, is in ``SimulatorDeviceKind/symbol``.
///
/// Drawn in the ICON ink rather than the primary one. Every row carries this, so at full contrast a
/// column of them is a rule down the leading edge competing with the names they exist to help find;
/// in the dimmest ink they stop being legible at 13pt, which defeats the point of having them.
struct SimulatorFamilyMark: View {
    let device: SimulatorDevice

    var body: some View {
        Image(systemSymbol: SimulatorDeviceKind.infer(from: device.name).symbol)
            .font(.system(size: Slate.Typeface.body, weight: .medium))
            .foregroundStyle(Slate.Text.icon)
            // Leading, not centred: inside a family group every row carries the SAME silhouette, so
            // what centring would buy is nothing, while what it costs is the heading — a 13pt phone
            // centred in a 24pt column starts five points right of the `IPHONE` above it.
            .frame(width: Slate.Metric.deviceMarkWidth, alignment: .leading)
    }
}

struct SimulatorDeviceList: View {
    @Bindable var model: SimulatorSidebarModel

    /// Filters by name and runtime as typed. Deliberately NOT persisted: a filter that survived a
    /// panel collapse would hide devices with nothing on screen to explain why.
    @State private var query = ""

    private var matches: [SimulatorDevice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.devices }
        return model.devices.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.runtime.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The whole list as sections. Running first, then the families in the enum's own rank order
    /// rather than in encounter order, so the headings do not reshuffle because the host's device set
    /// was edited.
    static func sections(for devices: [SimulatorDevice]) -> [SimulatorListSection] {
        var sections: [SimulatorListSection] = []
        let booted = devices.filter(\.isBooted)
        // Running comes first and is NOT split by family: what is up is one short list, and cutting
        // three booted devices into three headed groups is ceremony over content.
        if !booted.isEmpty {
            sections.append(section(runningTitle, booted))
        }
        let families = Dictionary(grouping: devices.filter { !$0.isBooted }) {
            SimulatorDeviceKind.infer(from: $0.name)
        }
        for (kind, members) in families.sorted(by: { $0.key.rank < $1.key.rank }) {
            sections.append(section(kind.groupTitle, members))
        }
        return sections
    }

    /// One heading and its devices, with the runtime LIFTED into the heading when every member shares
    /// it. A device set is a dozen devices on one installed runtime, so the per-row runtime was the
    /// same eight characters printed down the whole column — weight with no information in it, and
    /// the single loudest reason the list read as a spreadsheet. Said once at the top it is still
    /// answered at a glance; a row whose runtime differs from its neighbours keeps its own and is now
    /// the ONLY row carrying one, which is exactly the row worth noticing.
    static func section(_ title: String, _ members: [SimulatorDevice]) -> SimulatorListSection {
        SimulatorListSection(title: title, runtime: sharedRuntime(of: members), devices: members)
    }

    /// The runtime every member reports, or `nil` if they disagree. An EMPTY runtime string counts as
    /// a disagreement rather than as a shared value — a heading reading `IPHONE ·` would be the panel
    /// lifting the absence of a fact into the place it prints facts.
    static func sharedRuntime(of members: [SimulatorDevice]) -> String? {
        guard let first = members.first?.runtime, !first.isEmpty,
              members.allSatisfy({ $0.runtime == first }) else { return nil }
        return first
    }

    static let runningTitle = "Running"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            if model.devices.isEmpty {
                message("No simulator devices on the host.")
            } else if matches.isEmpty {
                message("No devices match “\(query)”.")
            } else {
                list
            }
        }
        // THE GROUND, like every other column in this window (ONE ISLAND, law 1) — the list sinks.
        .background(Slate.Surface.field)
    }

    // MARK: Filter

    /// The navigator's search plate, verbatim — an AppKit-backed field on the hover tint, sharing the
    /// list's gutter so it reads exactly as wide as the rows below it. `SlateSearchField` rather than
    /// `TextField` for the reason its header gives: at footnote size a SwiftUI field bumps its text a
    /// point on focus.
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
                // It appears on the FIRST keystroke and vanishes on the last, which at a field's
                // trailing edge is a glyph blinking beside the caret. The fade is what keeps it from
                // reading as part of the typing.
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
        // THE REFLOW. A boot is not a row changing colour: the device leaves its family, RUNNING
        // appears above it, and everything under the cut shifts — the one structural change this list
        // ever makes, and it used to happen between two frames with nothing to connect the row you
        // clicked to the card that arrived at the top. Keyed on the row IDENTITIES, so a poll that
        // returns the same devices animates nothing and a filter keystroke animates once.
        //
        // On the identities and not on `matches`: a device whose `state` string ticks through
        // `Booting` is the SAME row saying something new, and re-running the reflow for it would
        // animate the list every second while nothing moved.
        .animation(Slate.Anim.standard, value: sections.flatMap(\.rowIdentities))
    }

    /// The running devices, as cards at a FIXED column width. Fixed rather than adaptive so one
    /// running device is one card and not a card stretched across the panel.
    private var shelfColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: Slate.Metric.deviceCardWidth, maximum: Slate.Metric.deviceCardWidth),
            spacing: Slate.Metric.space2, alignment: .topLeading,
        )]
    }

    /// The shut-down devices, as rows in columns that SHARE the width. Adaptive here because a row's
    /// content is a name, and a name is happy to have more room; a card's content is a picture at a
    /// resolution the server already chose.
    private var rowColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: Slate.Metric.deviceRowWidth),
            spacing: Slate.Metric.space1, alignment: .leading,
        )]
    }

    private func shelf(_ section: SimulatorListSection) -> some View {
        LazyVGrid(columns: shelfColumns, alignment: .leading, spacing: Slate.Metric.space2) {
            ForEach(section.devices) { device in
                SimulatorRunningCard(model: model, device: device) { enter(device.udid) }
                    .contextMenu { menu(for: device) }
            }
        }
        .padding(.horizontal, Slate.Metric.space1)
        .padding(.bottom, Slate.Metric.space2)
    }

    private func grid(_ section: SimulatorListSection) -> some View {
        LazyVGrid(columns: rowColumns, alignment: .leading, spacing: 0) {
            ForEach(section.devices) { device in
                row(device, showsRuntime: section.showsRuntime(device))
            }
        }
    }

    /// The group's title, with its shared runtime as the heading's own CAPTION rather than as a
    /// trailing accessory. One caps label and one figure, not a label and a sentence: the heading is
    /// taxonomy, so the runtime joins it as taxonomy rather than arriving in the prose face the rows
    /// below use — and beside the word it qualifies rather than at the panel's far edge, which at
    /// this surface's width is most of a screen away from it.
    ///
    /// The far edge is where the group's own CONTROL goes, which is the distinction the header shell
    /// draws: `Shut Down All` is offered only once more than one device is up, because with one
    /// running it is the same click as that card's own stop button under a longer name.
    private func heading(_ section: SimulatorListSection) -> some View {
        // Nudged onto the ROWS' left rail. The shared header insets by `space2` and a list row by
        // `space3`, and four points of disagreement between two things meant to line up is the kind
        // of thing that reads as "off" without anyone locating why. The rail lands on the family
        // glyph, which is where a section header belongs: the glyph column is the row's left edge,
        // and a heading indented past it would hang in the middle of its own group.
        SlateSectionHeader(section.title, caption: section.runtime) {
            if section.isRunning, section.devices.count > 1 {
                SlatePlateButton(
                    symbol: .stopCircle,
                    help: "Shut down all \(section.devices.count) running devices",
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

    private func row(_ device: SimulatorDevice, showsRuntime: Bool) -> some View {
        SlateListRow(
            active: false,
            // A shut-down device has no screen, so its row boots it — doing nothing on a click is the
            // behaviour that made the previous revision feel broken.
            onTap: { open(device) },
            leading: { SimulatorFamilyMark(device: device) },
            title: {
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            },
            // Both in the trailing CLUSTER, not one of them in the shell's hover overlay: that
            // overlay is for an affordance the meta fades out to make room for, and this action
            // never fades. Laid out side by side they cannot collide — the first cut of this row put
            // the button over the runtime and drew a play glyph through the word "iOS".
            titleTrailing: { hovering in
                HStack(spacing: Slate.Metric.space1) {
                    if let subtitle = subtitle(for: device, showsRuntime: showsRuntime) {
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

    /// The trailing text: the live state while the device is CHANGING, the runtime when it is not and
    /// the heading has not already said it, and nothing at all otherwise. A device spends seconds in
    /// `Booting`, and showing its runtime through that is the panel claiming nothing is happening
    /// while something is — so a transition always outranks the suppression above it.
    private func subtitle(for device: SimulatorDevice, showsRuntime: Bool) -> String? {
        let settled = device.state.isEmpty
            || device.isBooted
            || device.state.caseInsensitiveCompare("Shutdown") == .orderedSame
        if !settled { return device.state }
        return showsRuntime && !device.runtime.isEmpty ? device.runtime : nil
    }

    /// The one verb that applies, at REST but quiet: a small solid glyph in the tertiary ink, which
    /// steps to the primary one while the pointer is anywhere on the row. Solid rather than the
    /// enclosing `…Circle` pair — a ring at this size reads as a control chrome rather than as a
    /// direction, and a dozen of them down the trailing edge read as a rule.
    private func action(for device: SimulatorDevice, hovering: Bool) -> some View {
        let isPending = model.pending.contains(device.udid)
        // The two occupy the SAME slot and cross-fade rather than replace each other. Both are
        // `heightControl` square, so the row does not move; what would move without this is the eye,
        // because a glyph becoming a spinner in one frame reads as a redraw rather than as the click
        // being accepted — and accepting the click is the whole of what the spinner is there to say.
        return ZStack {
            if isPending {
                // The platform's indicator through `WorkingSpinner`, not `ProgressView`: a bare
                // `ProgressView` in a hosted column resolves the Aqua appearance and comes out dark
                // grey on a dark theme (see `StatusDot`'s header).
                WorkingSpinner()
                    .frame(width: Slate.Metric.heightControl, height: Slate.Metric.heightControl)
                    .transition(.opacity)
            } else {
                SlatePlateButton(
                    symbol: .playFill,
                    help: "Boot \(device.name)",
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: hovering ? Slate.Text.primary : Slate.Text.tertiary,
                ) {
                    Task { await model.boot(device.udid) }
                }
                .transition(.opacity)
            }
        }
        .animation(Slate.Anim.smallFade, value: isPending)
    }

    /// A click on a shut-down device boots it — the same intent a click on a running card carries
    /// ("I want to use this device"), one step earlier.
    private func open(_ device: SimulatorDevice) {
        guard !model.pending.contains(device.udid) else { return }
        Task { await model.boot(device.udid) }
    }

    /// The selection write rides ONE `withAnimation` transaction, which is what carries the drill —
    /// the panel's transition vocabulary lives on the surface that owns both depths
    /// (``CodeSidebarColumn``), and the views themselves declare no animation for it. Same shape as
    /// the tab strip's `selectSurface`: the caller opens the beat, the transitions ride it.
    private func enter(_ udid: String) {
        withAnimation(Slate.Anim.standard) { model.select(udid) }
    }

    @ViewBuilder
    private func menu(for device: SimulatorDevice) -> some View {
        if device.isBooted {
            Button("Open Screen") { enter(device.udid) }
            // The panel can already put a capture on the pasteboard, and a running device's screen is
            // often worth a picture without being worth opening — a card is a hundred points tall, so
            // the reader can see there is something to grab from here.
            Button("Copy Screenshot") { Task { await model.copyScreenshot(of: device.udid) } }
            Button("Shut Down") { Task { await model.shutdown(device.udid) } }
        } else {
            Button("Boot") { Task { await model.boot(device.udid) } }
        }
        Divider()
        // The UDID is what every other tool wants — `xcrun simctl`, a test invocation, a bug report —
        // and it is far too long to put in a sidebar row.
        Button("Copy UDID") { ClientPasteboard.write(device.udid) }
        Button("Copy Name") { ClientPasteboard.write(device.name) }
    }

    // MARK: Notices

    // A FAILED POLL DRAWS NOTHING HERE (user-directed 2026-08-04). It used to rule a warning row in
    // above the rows, on the reasoning that the last-known devices are still the best information
    // available and blanking them would make a flaky link look like a device set that vanished. That
    // reasoning stands, and is exactly why the list is left alone: the report goes to the window's
    // notification card like every other report this panel makes, and the rows keep saying what they
    // last knew. Two bespoke alert shapes in one panel was the thing being fixed.

    private func message(_ text: String) -> some View {
        DevicePanelChrome.notice(text)
    }
}
#endif
