// DevicePanelDelivery — the ONE cursor that walks a device panel's group deliveries, and the ONE
// way this target lends a string to a door.
//
// ## Why a second reader, when `wsRuns` exists
//
// `wsRuns(_:count:)` reads the homogeneous case: `count` `[UInt32 big-endian length][UTF-8 bytes]`
// runs and nothing else. Four of the doors below that one cannot read, because their blobs are
// MIXED — a count, then per row some bytes and some strings:
//
//   slopdesk_android_stage_verbs   [u16 count] then [u8 tray][u8 action] + 4 strings per plate
//   slopdesk_simulator_plates      [u16 count] then 2 strings per plate
//   slopdesk_android_facts         [u16 count] then [u8 ink][u8 measured][u8 label] + 3 strings
//   slopdesk_simulator_facts       the same framing
//
// Written out at each of those four sites, that is four cursor walks — which is the exact bug
// `wsRuns`' own header records having found in four faces of the settings catalogue. So the walk is
// one type, and the four readers are four `while` loops over it.
//
// ## The short-delivery discipline is `wsRuns`'
//
// A run read past the end of the blob answers the EMPTY string and leaves the cursor at the end,
// rather than shifting into whatever follows. A short delivery means the door and this file
// disagree about the layout, and the alternative is a silent off-by-one where every field after the
// gap wears its neighbour's words. Same for a byte: past the end reads `0`, which is every one of
// these enums' first case and none of their error cases — a plate that draws on the navigation
// tray, an ink that is `primary`, both of which are visibly ordinary rather than quietly wrong.
//
// The producers are all `slopdesk-ffi`, so these bytes are a Rust `&'static str` or a `format!` and
// cannot be invalid UTF-8. A failable decode would add a branch meaning "this run has no text",
// which is a wrong answer rather than a cautious one.

import Foundation
import SlopDeskWorkspaceModel

/// A cursor over one delivery: bytes, counts and length-prefixed runs, in the order a door wrote
/// them.
package struct DevicePanelBlob {
    private let bytes: [UInt8]
    private var cursor: Int

    package init(_ bytes: [UInt8]) {
        self.bytes = bytes
        cursor = bytes.startIndex
    }

    /// Runs the door with docs/55 §4's retry and opens a cursor over what it delivered.
    ///
    /// `capacity` is the caller's guess at what fits in one call. Over it the door reports its size
    /// and the read happens again, which is the retry that convention exists to make correct.
    package init(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) {
        self.init(wsAnswerBytes(door))
    }

    /// Whether the door answered NOTHING.
    ///
    /// Most blobs here are fixed tables where `0` can only mean the caller measured its buffer
    /// wrong. Two are not: `slopdesk_android_device_list` and `slopdesk_sim_log_message` both refuse
    /// with `0` and both have a real answer that is nearly empty — a host with no device attached
    /// still answers, and an empty rail is a different picture from the last one the panel saw. So
    /// the refusal is the ABSENCE of bytes and the empty answer is its own count, and this is the
    /// one question that separates them.
    package var isRefusal: Bool { bytes.isEmpty }

    /// One byte, or `0` past the end.
    package mutating func byte() -> UInt8 {
        guard cursor < bytes.endIndex else { return 0 }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    /// A `[UInt16 big-endian]` row count, or `0` past the end.
    package mutating func count16() -> Int {
        Int(byte()) << 8 | Int(byte())
    }

    /// A `[UInt32 big-endian]` row count, or `0` past the end.
    ///
    /// Wider than ``count16()`` for the one delivery whose row count is not a table's: a `logcat`
    /// chunk is 64 KiB of a device's own output, so a chunk that is all newlines has more rows than
    /// two bytes can name, and a truncated count would drop the console's tail without saying so.
    package mutating func count32() -> Int {
        var count = 0
        for _ in 0..<4 { count = count << 8 | Int(byte()) }
        return count
    }

    /// One `[u8 present][Int64 big-endian]` figure, or `nil` when the door said there is none.
    ///
    /// An `Option` crosses as a value plus a FLAG, never as a sentinel (`docs/55` §4) — and the
    /// eight bytes are written either way, so the walk is fixed-width and the flag is the only
    /// thing that decides. A density of zero and an absent one are different facts about an AVD,
    /// and a sentinel would spell the first as the second.
    ///
    /// Past the end reads absent, which is ``DevicePanelBlob``'s short-delivery discipline: a
    /// layout disagreement loses the field rather than shifting every later one along.
    package mutating func optionalCount() -> Int? {
        let present = byte() != 0
        var bits: UInt64 = 0
        for _ in 0..<8 { bits = bits << 8 | UInt64(byte()) }
        guard present else { return nil }
        return Int(Int64(bitPattern: bits))
    }

    /// One `[UInt32 big-endian length][UTF-8 bytes]` run, or the empty string past the end.
    package mutating func text() -> String {
        var length = 0
        for _ in 0..<4 { length = length << 8 | Int(byte()) }
        // A length of ZERO is a real field, not the end. Several of these tables carry a run that is
        // empty BY CONSTRUCTION — the streaming stage's caption, a menu separator's title — and
        // treating one as a short delivery would blank every field after it.
        guard length > 0 else { return "" }
        guard bytes.distance(from: cursor, to: bytes.endIndex) >= length else {
            cursor = bytes.endIndex
            return ""
        }
        defer { cursor += length }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self)
    }

    /// The next `count` runs, PADDED with empties if the delivery came up short — the discipline at
    /// the head of this file, and the reason a positional table can be read without a checksum.
    package mutating func texts(_ count: Int) -> [String] {
        var runs: [String] = []
        runs.reserveCapacity(count)
        for _ in 0..<count { runs.append(text()) }
        return runs
    }
}

/// Lends one string to a door as the `(bytes, len)` pair the crate reads.
///
/// The closure scope IS the safety contract — the pointer is live for exactly the call inside it —
/// so nothing else goes in it. An empty string lends a non-null pointer to zero bytes, which every
/// door already reads as the same non-answer a missing key makes.
package func devicePanelLend<T>(
    _ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> T,
) -> T {
    var bytes = Array(text.utf8)
    return bytes.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress, buffer.count)
    }
}

/// The same lend for bytes that arrived as bytes — a reply line off a socket, a chunk of console
/// output — rather than as a word this side typed.
///
/// An empty `Data` lends ZERO BYTES, and whether its base address is null is not contractual —
/// `withUnsafeBytes` may hand back either. Every door already reads both spellings as the same
/// non-answer an absent argument makes, so neither side has to know which one it got.
package func devicePanelLend<T>(
    _ data: Data, _ body: (UnsafePointer<UInt8>?, Int) -> T,
) -> T {
    data.withUnsafeBytes { bytes in
        body(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
}

/// The KIND bytes a menu door delivers, with §4's retry.
///
/// A menu is short and its length is the answer, so this is the `[Int]`-shaped sibling of
/// ``DevicePanelBlob``: the door reports how many rows it has, and a second ask fills them.
package func devicePanelKinds(
    capacity: Int, _ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int,
) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: capacity)
    var needed = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
    if needed > out.count {
        out = [UInt8](repeating: 0, count: needed)
        needed = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
    }
    guard needed > 0, needed <= out.count else { return [] }
    return Array(out[0..<needed])
}
