// DeviceSectionReading — the ONE walk over a sectioned device list, as
// `slopdesk_ffi::device_sections` frames it.
//
// Both panels ask their own door and both read this layout, so the cursor walk is written once here
// rather than twice in the two faces — the argument ``DevicePanelBlob``'s own header makes about
// the four mixed deliveries that preceded it.
//
// The layout, and the reason each field is in it, is stated at the door. What matters on this side
// is that a member names a row by INDEX into the array the panel already holds: nothing about a
// device makes the trip back except the words the panel did not have — the heading, the fact the
// group lifted, and the row identity.
//
// Short-delivery discipline is ``DevicePanelBlob``'s: a run read past the end answers the empty
// string, a byte answers `0` and a count answers none, so a layout disagreement loses fields rather
// than shifting every later one into its neighbour's slot.

import Foundation

/// One sectioned reading.
package struct DeviceSectionReading {
    /// One row's place in a section.
    package struct Member {
        /// Which row of the array the panel lent this is.
        package let index: Int
        /// Whether the row still prints its own value — false exactly when the heading said it.
        package let showsValue: Bool
        /// `heading/key`, the value a list's reflow watches.
        package let rowIdentity: String
    }

    /// One rendered group.
    package struct Section {
        package let title: String
        package let isRunning: Bool
        /// The fact every member agreed on, or `nil` when they did not.
        package let shared: String?
        package let members: [Member]

        package var rowIdentities: [String] { members.map(\.rowIdentity) }
        package var shows: [Bool] { members.map(\.showsValue) }
    }

    package let sections: [Section]

    package init(_ bytes: [UInt8]) {
        var blob = DevicePanelBlob(bytes)
        let count = blob.count16()
        sections = (0..<count).map { _ in
            let isRunning = blob.byte() == 1
            let title = blob.text()
            let present = blob.byte() == 1
            let shared = blob.text()
            let members = (0..<blob.count16()).map { _ in
                Member(index: blob.count16(), showsValue: blob.byte() == 1, rowIdentity: blob.text())
            }
            return Section(
                title: title, isRunning: isRunning, shared: present ? shared : nil,
                members: members,
            )
        }
    }
}
