// SimulatorDeviceList — the host's devices, drawn in Slate.
//
// This replaced a WKWebView showing the simulator server's own page. The objection was never that
// the page looked wrong: it was that matching it to the theme meant re-scoping its CSS variables AND
// overriding the handful of rules that baked a literal hex, with every server update putting that
// back in play. Drawn natively the question does not arise — the row shell, the section header and
// the search plate are the same ones the navigator uses, so a theme swap repoints this list with
// everything else.
//
// GROUPING is by boot state, not by the server's two arrays. It happens to be the same partition
// today, but the panel's meaning is "what is running" vs "what could run", and a device moving
// between the groups when it boots is the one motion in this list that carries information.
//
// The row's trailing slot swaps under hover: runtime at rest, the boot/shutdown control while the
// pointer is on the row. That is the shell's own idiom (``SlateListRow``'s `trailingOverlay`), and it
// is what lets a fixed-height row carry both the identity of the runtime and an action without
// squeezing them into a sidebar's width side by side.

#if os(macOS)
import SFSafeSymbols
import SwiftUI

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

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let booted = matches.filter(\.isBooted)
                let idle = matches.filter { !$0.isBooted }
                // A heading over nothing is noise, so each group appears only when it has rows —
                // which also means a machine with one booted device shows one heading, not two.
                if !booted.isEmpty {
                    SlateSectionHeader("Running")
                    ForEach(booted) { row($0) }
                }
                if !idle.isEmpty {
                    SlateSectionHeader("Available")
                    ForEach(idle) { row($0) }
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
            // shut-down device has no screen, so its row does nothing until it is booted — streaming
            // nothing would look like a hang rather than a state.
            onTap: { if device.isBooted { model.select(device.udid) } },
            leading: { mark(device) },
            title: {
                Text(device.name)
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            },
            titleTrailing: { hovering in
                if model.pending.contains(device.udid) {
                    // The platform's indicator through `WorkingSpinner`, not `ProgressView`: a bare
                    // `ProgressView` in a hosted column resolves the Aqua appearance and comes out
                    // dark grey on a dark theme (see `StatusDot`'s header).
                    WorkingSpinner()
                } else if !device.runtime.isEmpty {
                    Text(device.runtime)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.tertiary)
                        .lineLimit(1)
                        // Faded rather than removed, so the row's trailing edge does not jump as the
                        // pointer crosses it.
                        .opacity(hovering ? 0 : 1)
                }
            },
            trailingOverlay: { hovering in
                if hovering, !model.pending.contains(device.udid) {
                    action(for: device)
                }
            },
        )
    }

    /// The boot state, as the row's leading mark. One shape, two tones — the accent for a device that
    /// is up, a muted disc for one that is not; the title never recolours.
    private func mark(_ device: SimulatorDevice) -> some View {
        Circle()
            .fill(device.isBooted ? Slate.State.accent : Slate.Text.tertiary.opacity(0.4))
            .frame(width: Slate.Metric.dot, height: Slate.Metric.dot)
    }

    @ViewBuilder
    private func action(for device: SimulatorDevice) -> some View {
        if device.isBooted {
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
