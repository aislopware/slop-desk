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
// EVERY ROW CARRIES ITS ACTION, at rest, not on hover. The previous revision hid boot and shutdown
// behind the pointer: discoverable only by accident, and impossible to see the state of. What the
// pointer changes is the action's WEIGHT, not its presence — at rest it is a small tertiary glyph, and
// the hovered row's verb steps up to the primary ink. Drawn at full strength on every row it became a
// column of a dozen identical rings down the trailing edge, which is texture, not twelve verbs
// (user-directed 2026-08-04).
//
// A ROW NEVER REPEATS WHAT ITS HEADING ALREADY SAID. One rule, applied twice: the runtime is lifted
// into the heading when every member shares it, and the family glyph is drawn only under RUNNING —
// the one group whose members are NOT all the same kind. Under `IPHONE` a column of iPhone glyphs is
// the same fact stated eleven times, in the dimmest ink on the surface, along the edge the eye uses
// to find the names.
//
// The CONTEXT MENU carries what a sidebar row has no width for — the UDID, and the destructive verb.

#if os(macOS)
import AppKit
import SFSafeSymbols
import SwiftUI

/// One line of the list: a section heading, or a device under one.
///
/// The identity carries the SECTION as well as the device, and that is the whole point of the type.
/// A device's udid alone is stable across a boot — which is correct for "is this the same device"
/// and wrong for "is this the same row": the row's entire content (glyph tint, trailing verb,
/// subtitle) is a function of the state that just changed, and reusing the built view keeps every
/// one of them at its old value. Qualifying by section makes a device that changes group a REMOVE
/// and an INSERT, so it is rebuilt from the device it now is.
enum SimulatorListEntry: Identifiable {
    /// A group's title, plus the runtime its members SHARE — `nil` when they do not all agree.
    case heading(String, runtime: String?)
    /// A device under one heading. `showsRuntime` and `showsFamily` are false when the heading above
    /// it already says the same thing.
    case device(SimulatorDevice, section: String, showsRuntime: Bool, showsFamily: Bool)

    var id: String {
        switch self {
        case let .heading(title, _): "heading/\(title)"
        case let .device(device, section, _, _): "\(section)/\(device.udid)"
        }
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

    /// The whole list as ONE flat sequence — headings and rows together, each carrying an identity
    /// that names its section. Running first, then the families in the enum's own rank order rather
    /// than in encounter order, so the headings do not reshuffle because the host's device set was
    /// edited.
    static func entries(for devices: [SimulatorDevice]) -> [SimulatorListEntry] {
        var entries: [SimulatorListEntry] = []
        let booted = devices.filter(\.isBooted)
        // Running comes first and is NOT split by family: what is up is one short list, and cutting
        // three booted devices into three headed groups is ceremony over content.
        if !booted.isEmpty {
            entries += group(Self.runningTitle, booted)
        }
        let families = Dictionary(grouping: devices.filter { !$0.isBooted }) {
            SimulatorDeviceKind.infer(from: $0.name)
        }
        for (kind, members) in families.sorted(by: { $0.key.rank < $1.key.rank }) {
            entries += group(kind.groupTitle, members)
        }
        return entries
    }

    /// One heading and its rows, with the runtime LIFTED into the heading when every member shares
    /// it. A device set is a dozen devices on one installed runtime, so the per-row runtime was the
    /// same eight characters printed down the whole column — weight with no information in it, and
    /// the single loudest reason the list read as a spreadsheet. Said once at the top it is still
    /// answered at a glance; a row whose runtime differs from its neighbours keeps its own and is now
    /// the ONLY row carrying one, which is exactly the row worth noticing.
    static func group(_ title: String, _ members: [SimulatorDevice]) -> [SimulatorListEntry] {
        let shared = sharedRuntime(of: members)
        // RUNNING is the one group not cut by family, so it is the one group where the leading glyph
        // says something its heading did not.
        let mixedFamilies = title == runningTitle
        return [.heading(title, runtime: shared)]
            + members.map {
                .device(
                    $0, section: title, showsRuntime: $0.runtime != shared,
                    showsFamily: mixedFamilies,
                )
            }
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
        .background(Slate.Surface.ground)
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
        .background(Slate.State.hover, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space2)
    }

    // MARK: List

    /// ONE `ForEach`, over the flattened entries. Not a heading-plus-nested-`ForEach` per group: two
    /// sibling `ForEach`es inside one lazy stack whose elements share an id let the stack reuse the
    /// row it already built for that id. Measured 2026-08-04 — a device that booted moved up into
    /// Running still drawing the grey glyph and the Boot button from its family group, while the one
    /// that shut down moved down still drawing the accent glyph and Shut Down. Position followed the
    /// state; the content did not.
    private var list: some View {
        let entries = Self.entries(for: matches)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    switch entry {
                    case let .heading(title, runtime):
                        heading(title, runtime: runtime)
                    case let .device(device, _, showsRuntime, showsFamily):
                        row(device, showsRuntime: showsRuntime, showsFamily: showsFamily)
                    }
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.bottom, Slate.Metric.space2)
        }
        // THE REFLOW. A boot is not a row changing colour: the device leaves its family, RUNNING
        // appears above it, and everything under the cut shifts by a row — the one structural change
        // this list ever makes, and it used to happen between two frames with nothing to connect the
        // row you clicked to the row that arrived at the top. Keyed on the entry IDENTITIES, so a poll
        // that returns the same devices animates nothing and a filter keystroke animates once.
        //
        // On the ids and not on `matches`: a device whose `state` string ticks through `Booting` is
        // the SAME row saying something new, and re-running a 30-row reflow for it would animate the
        // list every second while nothing moved.
        .animation(Slate.Anim.standard, value: entries.map(\.id))
    }

    /// The group's title, with its shared runtime as the heading's own CAPTION rather than as a
    /// trailing accessory. One caps label and one figure, not a label and a sentence: the heading is
    /// taxonomy, so the runtime joins it as taxonomy rather than arriving in the prose face the rows
    /// below use — and beside the word it qualifies rather than at the panel's far edge, which at
    /// this surface's width is most of a screen away from it.
    private func heading(_ title: String, runtime: String?) -> some View {
        // Nudged onto the ROWS' left rail. The shared header insets by `space2` and a list row by
        // `space3`; with the family glyph gone the row's title starts the run of text this heading
        // names, and four points of disagreement between two things meant to line up is the kind of
        // thing that reads as "off" without anyone locating why.
        SlateSectionHeader(title, caption: runtime)
            .padding(.leading, Slate.Metric.space1)
    }

    private func row(
        _ device: SimulatorDevice, showsRuntime: Bool, showsFamily: Bool,
    ) -> some View {
        SlateListRow(
            active: model.selection == device.udid,
            // Opening the screen is the row's gesture; boot and shutdown are the explicit control. A
            // shut-down device has no screen, so its row boots it instead — doing nothing on a click
            // is the behaviour that made the previous revision feel broken.
            onTap: { open(device) },
            leading: { mark(device, showsFamily: showsFamily) },
            title: {
                // A booted device carries its name one weight up. The heading it sorts under already
                // says it is running; this is what keeps that legible once the eye is down among the
                // rows and the heading has scrolled out of the corner of it.
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base, weight: device.isBooted ? .medium : .regular))
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

    /// The device family as the row's leading glyph — drawn ONLY where the heading has not already
    /// said it (see the file header). Under RUNNING the shape says iPhone or iPad; everywhere else
    /// the slot collapses and the names take the section header's own left rail.
    ///
    /// The glyph never says running-or-not in a HUE — that is the pattern this repo reversed on
    /// 07-30, and this list has three stronger channels for it already: the heading the row sorts
    /// under, the weight of its name, and the stop-versus-play verb at the end of it.
    @ViewBuilder
    private func mark(_ device: SimulatorDevice, showsFamily: Bool) -> some View {
        if showsFamily {
            Image(systemSymbol: SimulatorDeviceKind.infer(from: device.name).symbol)
                .font(.system(size: Slate.Typeface.body, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
                .frame(width: Slate.Metric.iconSize)
        }
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
                    symbol: device.isBooted ? .stopFill : .playFill,
                    help: device.isBooted ? "Shut down \(device.name)" : "Boot \(device.name)",
                    size: Slate.Typeface.footnote,
                    plate: Slate.Metric.heightControl,
                    tint: hovering ? Slate.Text.primary : Slate.Text.tertiary,
                ) {
                    Task {
                        if device.isBooted { await model.shutdown(device.udid) }
                        else { await model.boot(device.udid) }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Slate.Anim.smallFade, value: isPending)
    }

    /// A click on a booted device opens its screen; on a shut-down one it boots it. Two verbs on one
    /// gesture because they are the same intent — "I want to use this device" — and the row already
    /// carries the explicit control for anyone who means the other one.
    ///
    /// The selection write rides ONE `withAnimation` transaction, which is what carries the drill —
    /// the panel's transition vocabulary lives on the surface that owns both depths
    /// (``CodeSidebarColumn``), and the views themselves declare no animation for it. Same shape as
    /// the tab strip's `selectSurface`: the caller opens the beat, the transitions ride it.
    private func open(_ device: SimulatorDevice) {
        if device.isBooted {
            enter(device.udid)
        } else if !model.pending.contains(device.udid) {
            Task { await model.boot(device.udid) }
        }
    }

    private func enter(_ udid: String) {
        withAnimation(Slate.Anim.standard) { model.select(udid) }
    }

    @ViewBuilder
    private func menu(for device: SimulatorDevice) -> some View {
        if device.isBooted {
            Button("Open Screen") { enter(device.udid) }
            Button("Shut Down") { Task { await model.shutdown(device.udid) } }
        } else {
            Button("Boot") { Task { await model.boot(device.udid) } }
        }
        Divider()
        // The UDID is what every other tool wants — `xcrun simctl`, a test invocation, a bug report —
        // and it is far too long to put in a sidebar row.
        Button("Copy UDID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(device.udid, forType: .string)
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(device.name, forType: .string)
        }
    }

    // MARK: Notices

    // A FAILED POLL DRAWS NOTHING HERE (user-directed 2026-08-04). It used to rule a warning row in
    // above the rows, on the reasoning that the last-known devices are still the best information
    // available and blanking them would make a flaky link look like a device set that vanished. That
    // reasoning stands, and is exactly why the list is left alone: the report goes to the window's
    // notification card like every other report this panel makes, and the rows keep saying what they
    // last knew. Two bespoke alert shapes in one panel was the thing being fixed.

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.base))
            .foregroundStyle(Slate.Text.secondary)
            .multilineTextAlignment(.center)
            .padding(Slate.Metric.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
