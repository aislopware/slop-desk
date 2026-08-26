// AndroidDeviceSections — the device list as headed groups, as
// `slopdesk_devicepanel::sections` answers it.
//
// This used to be three `static func`s on the LIST VIEW, which is where it read naturally and where
// it could not be reached from a second UI (docs/56). Nothing about it is a view: it is an ordering,
// a grouping rule and a fact-lifting rule, and the same three answers have to hold on a phone as on
// a Mac or the two panels are different products.
//
// They now have to hold on the SIMULATOR panel too, which is the second half of the same argument.
// ``SimulatorDeviceSections`` was this file with different nouns — a runtime where this one lifts a
// version — and two spellings of one machine, each drawn by two renderers, is four places for the
// same rule to drift. One crossing decides it for both.
//
// ## What crosses
//
// The devices do NOT. The door is lent four positional arrays — each device's family, whether `adb`
// has a transport for it, its API level and, in one blob, its key and release string — and answers
// INDICES into the array the panel still holds, plus the three things the panel does not have: the
// heading, the version the group lifted, and the row identity.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

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
    /// The group of what is up — drawn as cards, and the only group not cut by family.
    package let isRunning: Bool
    /// This section's rows, named by section — the value the list's reflow watches. Section-qualified
    /// because the move a boot makes IS between sections, and a plain list of keys would not see it.
    package let rowIdentities: [String]

    /// Per row, in `devices`' order: whether it still prints a version of its own.
    private let versionShown: [Bool]

    package var id: String { title }

    package init(
        title: String, version: String?, devices: [AndroidDevice], isRunning: Bool,
        rowIdentities: [String], versionShown: [Bool],
    ) {
        self.title = title
        self.version = version
        self.devices = devices
        self.isRunning = isRunning
        self.rowIdentities = rowIdentities
        self.versionShown = versionShown
    }

    /// A device prints its own version only where the heading has not already said it — the crate's
    /// answer for the row, looked up by the key that identifies it.
    package func showsVersion(_ device: AndroidDevice) -> Bool {
        guard let slot = devices.firstIndex(where: { $0.key == device.key }),
              slot < versionShown.count
        else { return false }
        return versionShown[slot]
    }
}

package enum AndroidDeviceSections {
    /// The whole list as sections. Running first, then the families in rank order rather than in
    /// encounter order, so the headings do not reshuffle because the host's device set was edited.
    ///
    /// Anything with a transport goes in the top group, including a device that is `unauthorized`.
    /// That device is the one most in need of being noticed — it is plugged in and refusing — and
    /// burying it among the AVDs that are merely switched off is where it would go to hide.
    package static func sections(for devices: [AndroidDevice]) -> [AndroidListSection] {
        guard !devices.isEmpty else { return [] }
        var arena = WsStrings()
        let keys = devices.map { arena.span($0.key) }
        let releases = devices.map { arena.span($0.release) }
        let kinds = devices.map { UInt8(clamping: AndroidDeviceKind.infer($0).rank) }
        let attached = devices.map { UInt8($0.serial == nil ? 0 : 1) }
        let apiLevels = devices.map { Int64($0.apiLevel ?? 0) }
        var bytes = arena.bytes

        let answer = bytes.withUnsafeMutableBufferPointer { lent in
            kinds.withUnsafeBufferPointer { families in
                attached.withUnsafeBufferPointer { transports in
                    apiLevels.withUnsafeBufferPointer { levels in
                        keys.withUnsafeBufferPointer { named in
                            releases.withUnsafeBufferPointer { stated in
                                wsAnswerBytes { out, cap in
                                    slopdesk_android_sections(
                                        families.baseAddress, families.count,
                                        transports.baseAddress, transports.count,
                                        levels.baseAddress, levels.count,
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
        }

        return DeviceSectionReading(answer).sections.map { section in
            AndroidListSection(
                title: section.title, version: section.shared,
                devices: section.members.compactMap { member in
                    member.index < devices.count ? devices[member.index] : nil
                },
                isRunning: section.isRunning, rowIdentities: section.rowIdentities,
                versionShown: section.shows,
            )
        }
    }
}

package extension AndroidDevice {
    /// `Android 16` where the device says so, `API 36` where only the level is known — which is the
    /// case for an AVD that has never booted, since the marketing string is a property the system
    /// image sets at first boot.
    ///
    /// The SAME door the grouping lifts from, which is the point of it being a door at all: a header
    /// printing a version the grouping never compared is how the two would drift apart.
    var versionLabel: String? {
        devicePanelLend(release ?? "") { bytes, len in
            wsAnswer { out, cap in
                slopdesk_android_version_label(
                    bytes, len, release != nil,
                    Int64(apiLevel ?? 0), apiLevel != nil, out, cap,
                )
            }
        }
    }
}
