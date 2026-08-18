// AndroidDeviceSections — the device list as headed groups.
//
// This used to be three `static func`s on the LIST VIEW, which is where it read naturally and where
// it could not be reached from a second UI (docs/56). Nothing about it is a view: it is an ordering,
// a grouping rule and a fact-lifting rule, and the same three answers have to hold on a phone as on
// a Mac or the two panels are different products.

import Foundation

/// One group of the list: a heading and its devices.
///
/// A SECTION rather than a flat sequence, and for the identity reason `docs/48` records: a device's
/// key is stable across a boot — right for "is this the same device", wrong for "is this the same
/// row", since the row's whole content is a function of the state that just changed. Every section
/// gets its own container, so a device that boots is removed from one grid and inserted into another
/// and cannot carry a stale view across.
package struct AndroidListSection: Identifiable {
    package let title: String
    /// The platform version every member reports, or `nil` when they do not all agree.
    package let version: String?
    package let devices: [AndroidDevice]

    package var id: String { title }

    /// The group of what is up — drawn as cards, and the only group not cut by family.
    package var isRunning: Bool { title == AndroidDeviceSections.runningTitle }

    package init(title: String, version: String?, devices: [AndroidDevice]) {
        self.title = title
        self.version = version
        self.devices = devices
    }

    /// A device prints its own version only where the heading has not already said it.
    package func showsVersion(_ device: AndroidDevice) -> Bool {
        device.versionLabel != version
    }

    /// This section's rows, named by section — the value the list's reflow watches. Section-qualified
    /// because the move a boot makes IS between sections, and a plain list of keys would not see it.
    package var rowIdentities: [String] { devices.map { "\(title)/\($0.key)" } }
}

package enum AndroidDeviceSections {
    package static let runningTitle = "Attached"

    /// The whole list as sections. Running first, then the families in the enum's own rank order
    /// rather than in encounter order, so the headings do not reshuffle because the host's device set
    /// was edited.
    package static func sections(for devices: [AndroidDevice]) -> [AndroidListSection] {
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
    /// member shares it — the rule ``SimulatorDeviceSections/section(_:_:)`` establishes for
    /// runtimes. A device set is usually a handful of AVDs on one system image, so the per-row
    /// version was the same eight characters printed down the whole column.
    package static func section(_ title: String, _ members: [AndroidDevice]) -> AndroidListSection {
        AndroidListSection(title: title, version: sharedVersion(of: members), devices: members)
    }

    /// The version every member reports, or `nil` if they disagree. An absent version counts as a
    /// disagreement rather than as a shared value — a heading reading `PHONE ·` would be the panel
    /// lifting the absence of a fact into the place it prints facts.
    package static func sharedVersion(of members: [AndroidDevice]) -> String? {
        guard let first = members.first?.versionLabel,
              members.allSatisfy({ $0.versionLabel == first })
        else { return nil }
        return first
    }
}

package extension AndroidDevice {
    /// `Android 16` where the device says so, `API 36` where only the level is known — which is the
    /// case for an AVD that has never booted, since the marketing string is a property the system
    /// image sets at first boot.
    ///
    /// Lives on the device rather than on the header view that prints it, because the LIST reads it
    /// too — to decide whether a heading can speak for every row under it.
    var versionLabel: String? {
        if let release, !release.isEmpty { return "Android " + release }
        if let apiLevel { return "API \(apiLevel)" }
        return nil
    }
}
