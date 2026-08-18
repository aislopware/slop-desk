// SimulatorDeviceSections — the device list as headed groups.
//
// Extracted from the LIST VIEW, where it read naturally and where a second UI could not reach it
// (docs/56). Nothing in here draws: it is an ordering, a grouping rule and a fact-lifting rule, and
// the same three answers have to hold on a phone as on a Mac or the two panels are different
// products. The twin of ``AndroidDeviceSections``, which lifts the platform version the way this one
// lifts the runtime.

import Foundation

/// One group of the list: a heading and its devices.
///
/// A SECTION rather than a flat sequence of heading-or-device entries, and the identity trap that
/// shape existed to dodge is now structural. A device's udid alone is stable across a boot — right
/// for "is this the same device", wrong for "is this the same row", since the row's whole content is
/// a function of the state that just changed. The earlier fix qualified each row's id by its section;
/// this one gives every section its own container, so a device that boots is removed from one grid
/// and inserted into another and cannot carry a stale view across. Families hold only shut-down
/// devices, so a row can no longer change state without also changing container.
package struct SimulatorListSection: Identifiable {
    package let title: String
    /// The runtime every member reports, or `nil` when they do not all agree.
    package let runtime: String?
    package let devices: [SimulatorDevice]

    package var id: String { title }

    /// The group of what is up — drawn as cards, and the only group not cut by family.
    package var isRunning: Bool { title == SimulatorDeviceSections.runningTitle }

    package init(title: String, runtime: String?, devices: [SimulatorDevice]) {
        self.title = title
        self.runtime = runtime
        self.devices = devices
    }

    /// A device prints its own runtime only where the heading has not already said it.
    package func showsRuntime(_ device: SimulatorDevice) -> Bool { device.runtime != runtime }

    /// This section's rows, named by section — the value the list's reflow watches. Section-qualified
    /// because the move a boot makes IS between sections, and a plain list of udids would not see it.
    package var rowIdentities: [String] { devices.map { "\(title)/\($0.udid)" } }
}

package enum SimulatorDeviceSections {
    package static let runningTitle = "Running"

    /// The whole list as sections. Running first, then the families in the enum's own rank order
    /// rather than in encounter order, so the headings do not reshuffle because the host's device set
    /// was edited.
    package static func sections(for devices: [SimulatorDevice]) -> [SimulatorListSection] {
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
    package static func section(_ title: String, _ members: [SimulatorDevice]) -> SimulatorListSection {
        SimulatorListSection(title: title, runtime: sharedRuntime(of: members), devices: members)
    }

    /// The runtime every member reports, or `nil` if they disagree. An EMPTY runtime string counts as
    /// a disagreement rather than as a shared value — a heading reading `IPHONE ·` would be the panel
    /// lifting the absence of a fact into the place it prints facts.
    package static func sharedRuntime(of members: [SimulatorDevice]) -> String? {
        guard let first = members.first?.runtime, !first.isEmpty,
              members.allSatisfy({ $0.runtime == first }) else { return nil }
        return first
    }
}
