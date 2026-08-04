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
// behind the pointer: discoverable only by accident, and impossible to see the state of. The glyph is
// the family, the tint is the state, and the trailing control is always the one verb that applies.
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
    case heading(String)
    case device(SimulatorDevice, section: String)

    var id: String {
        switch self {
        case let .heading(title): "heading/\(title)"
        case let .device(device, section): "\(section)/\(device.udid)"
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
            entries.append(.heading(Self.runningTitle))
            entries += booted.map { .device($0, section: Self.runningTitle) }
        }
        let families = Dictionary(grouping: devices.filter { !$0.isBooted }) {
            SimulatorDeviceKind.infer(from: $0.name)
        }
        for (kind, members) in families.sorted(by: { $0.key.rank < $1.key.rank }) {
            entries.append(.heading(kind.groupTitle))
            entries += members.map { .device($0, section: kind.groupTitle) }
        }
        return entries
    }

    static let runningTitle = "Running"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            if let failure = model.failure {
                banner(failure)
            }
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
            }
        }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.entries(for: matches)) { entry in
                    switch entry {
                    case let .heading(title): SlateSectionHeader(title)
                    case let .device(device, _): row(device)
                    }
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.bottom, Slate.Metric.space2)
        }
    }

    private func row(_ device: SimulatorDevice) -> some View {
        SlateListRow(
            active: model.selection == device.udid,
            // Opening the screen is the row's gesture; boot and shutdown are the explicit control. A
            // shut-down device has no screen, so its row boots it instead — doing nothing on a click
            // is the behaviour that made the previous revision feel broken.
            onTap: { open(device) },
            leading: { mark(device) },
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
            titleTrailing: { _ in
                HStack(spacing: Slate.Metric.space1) {
                    Text(subtitle(for: device))
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    action(for: device)
                }
            },
            trailingOverlay: { _ in EmptyView() },
        )
        .contextMenu { menu(for: device) }
    }

    /// The trailing text: the runtime normally, the live state while it is changing. A device spends
    /// seconds in `Booting`, and showing its runtime through that is the panel claiming nothing is
    /// happening while something is.
    private func subtitle(for device: SimulatorDevice) -> String {
        let settled = device.state.isEmpty
            || device.isBooted
            || device.state.caseInsensitiveCompare("Shutdown") == .orderedSame
        return settled ? device.runtime : device.state
    }

    /// The device family as the row's leading glyph, tinted by boot state. Two channels, one mark:
    /// the SHAPE says iPhone or iPad, the TINT says running or not — which is what makes a set of
    /// thirty near-identical names scannable at all.
    private func mark(_ device: SimulatorDevice) -> some View {
        Image(systemSymbol: SimulatorDeviceKind.infer(from: device.name).symbol)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(device.isBooted ? Slate.State.accent : Slate.Text.tertiary)
            .frame(width: Slate.Metric.iconSize)
    }

    @ViewBuilder
    private func action(for device: SimulatorDevice) -> some View {
        if model.pending.contains(device.udid) {
            // The platform's indicator through `WorkingSpinner`, not `ProgressView`: a bare
            // `ProgressView` in a hosted column resolves the Aqua appearance and comes out dark grey
            // on a dark theme (see `StatusDot`'s header).
            WorkingSpinner()
                .frame(width: Slate.Metric.heightControl, height: Slate.Metric.heightControl)
        } else if device.isBooted {
            PlateIconButton(symbol: .stopCircle, plate: Slate.Metric.heightControl) {
                Task { await model.shutdown(device.udid) }
            }
            .help("Shut down \(device.name)")
        } else {
            PlateIconButton(symbol: .playCircle, plate: Slate.Metric.heightControl) {
                Task { await model.boot(device.udid) }
            }
            .help("Boot \(device.name)")
        }
    }

    /// A click on a booted device opens its screen; on a shut-down one it boots it. Two verbs on one
    /// gesture because they are the same intent — "I want to use this device" — and the row already
    /// carries the explicit control for anyone who means the other one.
    private func open(_ device: SimulatorDevice) {
        if device.isBooted {
            model.select(device.udid)
        } else if !model.pending.contains(device.udid) {
            Task { await model.boot(device.udid) }
        }
    }

    @ViewBuilder
    private func menu(for device: SimulatorDevice) -> some View {
        if device.isBooted {
            Button("Open Screen") { model.select(device.udid) }
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

    /// A failure sits ABOVE the list rather than replacing it: the last-known devices are still the
    /// best information available, and blanking them on one failed poll would make a flaky link look
    /// like a device set that vanished.
    private func banner(_ text: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .exclamationmarkTriangle)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Status.warn)
            Text(text)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.bottom, Slate.Metric.space2)
    }

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
