// DeviceRowFilter — the ONE search-box predicate behind both panels' lists and both consoles.
//
// ## What was here instead
//
// Four byte-identical copies of the same three lines, in four targets:
//
//   Sources/SlopDeskDevicePanels/Android/AndroidPresentation.swift   ×2 (the list, the console)
//   Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorDeviceList.swift
//   Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorConsoleView.swift
//   Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift
//   Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorConsoleView.swift
//
// Six spellings of `localizedCaseInsensitiveContains` over "does any field of this row contain what
// was typed". Only one of them was ever reached by a test, which is `docs/55` §8's drift class in
// its purest form: the copy a test holds is not the copy the SwiftUI half runs, and nothing can
// notice them parting.
//
// ## Why it also got fast
//
// `localizedCaseInsensitiveContains` is grapheme-aware, locale-aware search over text that is
// ASCII in every row a device has ever emitted. Measured in a scratch `swiftc -O` harness (not in
// the tree) against the shipped `macos-arm64` slice, at `logCapacity` = 600 console rows, two runs
// agreeing:
//
//   needle hits   873.8 µs / 876.9 µs   →   111.6 µs / 110.4 µs
//   needle misses 1661.8 µs / 1624.6 µs →   131.2 µs / 128.5 µs
//
// A miss is the state every keystroke passes through — the first character typed matches nothing
// until it does — and the console redraws on every arriving line, so this ran at whatever rate a
// booting device logs at. The figures INCLUDE building the record blob below, which is the whole
// cost of the new shape: one buffer, one crossing, positions back.
//
// ## The rule is not new, and is deliberately not re-written here
//
// `slopdesk_workspace::binding_search::matches` already answers exactly this question — "which rows
// of a lent record list does this query keep, folding case" — for the keybindings editor and, at
// one remove, for Settings. It is not specific to a keybinding: the blob it reads is `count` rows
// of `field_count` fields, and a console row lends two where a binding lends four. So this file
// adds MARSHALLING and no rule, and the door it calls is the one that crate already exports. The
// ABI name still says `ws_binding` because its first caller was the keybindings editor; renaming it
// to something the device panels can read without a second glance means touching
// `Sources/SlopDeskWorkspaceCore/Workspace/Domain/KeybindingsEditorModel.swift` in the same change.
//
// ## The fold is NOT `localizedCaseInsensitiveContains`, and that is the point
//
// The door folds case by Unicode simple lowercasing, over an ASCII byte scan whenever both sides
// are ASCII. `localizedCaseInsensitiveContains` normalizes first and folds by compatibility. They
// were probed against each other on the shipped slice; of seventeen cases, eleven AGREE — including
// every ASCII one, the Turkish dotted İ, a Greek final sigma, an emoji and CJK — and four differ,
// all in the same direction:
//
//   haystack "Café" (NFC)      needle "Café" (NFD)   platform: match   door: no match
//   haystack "STRASSE"         needle "straße"       platform: match   door: no match
//   haystack "ﬁle not found"   needle "file"         platform: match   door: no match
//
// Taking that trade is not a shrug about Unicode. It is what makes this search box agree with every
// OTHER search box in the app — the palette, Settings, the keybindings editor all already fold this
// way through the same rule — where before it was the one field with different semantics from the
// rest, and nobody had written down that it was. ``DeviceRowFilterTests`` pins the boundary rather
// than leaving it as prose.
//
// One correction to what the old comment claimed: `localizedCaseInsensitiveContains` is NOT
// diacritic-insensitive. `AndroidPresentation.matches` said it was ("Case- and diacritic-insensitive
// through `localizedCaseInsensitiveContains`, which is the platform's own answer") and it never was
// — typing `cafe` did not find `Café` before this change and does not after it. The option that
// would have done it is `.diacriticInsensitive`, which that call does not pass.

import CSlopDeskFFI
import Foundation

/// Which rows of a list a search box keeps.
///
/// The caller says what a row's searchable fields ARE — which is the only part of this that differs
/// between a device list and a console — and gets back the rows that survive, in order.
package enum DeviceRowFilter {
    /// The rows whose fields contain `query`, case-folded.
    ///
    /// A blank query keeps everything and never crosses: a search box nobody has typed into is not
    /// a filter, and the panels sit in that state almost all of the time.
    package static func surviving<Row>(
        _ rows: [Row], query: String, fields: (Row, inout DeviceRowFields) -> Void,
    ) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !rows.isEmpty else { return rows }
        var lent = DeviceRowFields(rowCount: rows.count)
        for row in rows {
            lent.openRow()
            fields(row, &lent)
        }
        return keep(rows, matching: trimmed, in: lent.bytes)
    }

    /// The door, asked once for the whole list.
    ///
    /// The answer can never be wider than the list that was offered, so the buffer is sized up
    /// front and the retry §4 allows for is unreachable — CHECKED rather than assumed, because
    /// reading a buffer the door refused to fill is the one failure that convention prevents.
    private static func keep<Row>(_ rows: [Row], matching query: String, in records: [UInt8]) -> [Row] {
        var query = query
        return query.withUTF8 { needle -> [Row] in
            records.withUnsafeBufferPointer { lent -> [Row] in
                var out = [Int](repeating: 0, count: rows.count)
                let found = out.withUnsafeMutableBufferPointer { slots in
                    slopdesk_ws_binding_row_matches(
                        needle.baseAddress, needle.count,
                        lent.baseAddress, lent.count,
                        slots.baseAddress, slots.count,
                    )
                }
                guard found > 0, found <= out.count else { return [] }
                // Clamped rather than trusted, for the reason `DeviceLogLine.slice` gives: the
                // positions cross a C ABI, and one past the end would be a trap here rather than a
                // wrong list.
                return out.prefix(found).compactMap { $0 >= 0 && $0 < rows.count ? rows[$0] : nil }
            }
        }
    }
}

/// One row's searchable spellings, being written into the blob the door reads.
///
/// `[u32 count]`, then `count` records, each `[u8 field_count]` then that many `[u32 len][len
/// bytes]` fields, little-endian — `slopdesk_workspace::binding_search`'s format, because it is
/// that function's argument. Little-endian because the only caller is an Apple silicon process
/// handing bytes to itself.
package struct DeviceRowFields {
    var bytes: [UInt8] = []
    private var rowStart = 0

    init(rowCount: Int) {
        // 160 bytes a row is a logcat line with its tag and change to spare; a short row wastes a
        // little and a long one grows once. The point is that a 600-row console allocates ONCE.
        bytes.reserveCapacity(rowCount * 160)
        append(length: rowCount)
    }

    /// Opens a record with a field count of zero, which ``add(_:)`` then counts up.
    mutating func openRow() {
        bytes.append(0)
        rowStart = bytes.count - 1
    }

    /// Lends one spelling. An empty field is written rather than skipped and matches nothing — only
    /// a blank QUERY keeps everything — so an absent model or serial costs four bytes and no rule.
    package mutating func add(_ text: String) {
        var text = text
        text.withUTF8 { utf8 in
            append(length: utf8.count)
            bytes.append(contentsOf: utf8)
        }
        bytes[rowStart] &+= 1
    }

    private mutating func append(length: Int) {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: length).littleEndian) {
            bytes.append(contentsOf: $0)
        }
    }
}
