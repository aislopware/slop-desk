// SimulatorDeviceSections — the device list as headed groups, as
// `slopdesk_devicepanel::sections` answers it.
//
// Extracted from the LIST VIEW, where it read naturally and where a second UI could not reach it
// (docs/56). Nothing in here draws: it is an ordering, a grouping rule and a fact-lifting rule, and
// the same three answers have to hold on a phone as on a Mac or the two panels are different
// products. The twin of ``AndroidDeviceSections``, which lifts the platform version the way this one
// lifts the runtime — and that twinning is why neither of them spells the machine any more. It was
// one fold written twice with different nouns, in two files each drawn by two renderers.
//
// What differs between the two doors is only what each panel knows about a device: this one lends
// `isBooted` and a runtime string, the Android side lends a transport id and a release. The
// EMPTY-value rule is where the difference shows and the crate carries it: `/simulators.json` can
// carry a blank runtime, which is a value a row still has and a heading still cannot lift.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

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
    /// The group of what is up — drawn as cards, and the only group not cut by family.
    package let isRunning: Bool
    /// This section's rows, named by section — the value the list's reflow watches. Section-qualified
    /// because the move a boot makes IS between sections, and a plain list of udids would not see it.
    package let rowIdentities: [String]

    /// Per row, in `devices`' order: whether it still prints a runtime of its own.
    private let runtimeShown: [Bool]

    package var id: String { title }

    package init(
        title: String, runtime: String?, devices: [SimulatorDevice], isRunning: Bool,
        rowIdentities: [String], runtimeShown: [Bool],
    ) {
        self.title = title
        self.runtime = runtime
        self.devices = devices
        self.isRunning = isRunning
        self.rowIdentities = rowIdentities
        self.runtimeShown = runtimeShown
    }

    /// A device prints its own runtime only where the heading has not already said it — the crate's
    /// answer for the row, looked up by the udid that identifies it.
    package func showsRuntime(_ device: SimulatorDevice) -> Bool {
        guard let slot = devices.firstIndex(where: { $0.udid == device.udid }),
              slot < runtimeShown.count
        else { return false }
        return runtimeShown[slot]
    }
}

package enum SimulatorDeviceSections {
    /// The whole list as sections. Running first, then the families in rank order rather than in
    /// encounter order, so the headings do not reshuffle because the host's device set was edited.
    ///
    /// Running is NOT split by family: what is up is one short list, and cutting three booted devices
    /// into three headed groups is ceremony over content.
    package static func sections(for devices: [SimulatorDevice]) -> [SimulatorListSection] {
        guard !devices.isEmpty else { return [] }
        var arena = WsStrings()
        let keys = devices.map { arena.span($0.udid) }
        let runtimes = devices.map { arena.span($0.runtime) }
        let kinds = devices.map { UInt8(clamping: SimulatorDeviceKind.infer(from: $0.name).rank) }
        let booted = devices.map { UInt8($0.isBooted ? 1 : 0) }
        var bytes = arena.bytes

        let answer = bytes.withUnsafeMutableBufferPointer { lent in
            kinds.withUnsafeBufferPointer { families in
                booted.withUnsafeBufferPointer { running in
                    keys.withUnsafeBufferPointer { named in
                        runtimes.withUnsafeBufferPointer { stated in
                            wsAnswerBytes { out, cap in
                                slopdesk_simulator_sections(
                                    families.baseAddress, families.count,
                                    running.baseAddress, running.count,
                                    lent.baseAddress, lent.count,
                                    named.baseAddress, named.count,
                                    stated.baseAddress, stated.count,
                                    out, cap,
                                )
                            }
                        }
                    }
                }
            }
        }

        return DeviceSectionReading(answer).sections.map { section in
            SimulatorListSection(
                title: section.title, runtime: section.shared,
                devices: section.members.compactMap { member in
                    member.index < devices.count ? devices[member.index] : nil
                },
                isRunning: section.isRunning, rowIdentities: section.rowIdentities,
                runtimeShown: section.shows,
            )
        }
    }
}
