// FFIDelivery — the ONE way Swift asks a door for bytes, and the ONE framing it reads and writes
// length-prefixed runs in.
//
// docs/55 §4: a delivery door writes into the caller's buffer only if the answer FITS, and returns
// the length it needed either way. So every call is ask-with-a-guess, and grow-once when the guess
// was short. Written out at each face that is the same four lines five times, which is the shape
// every cross-language off-by-one in this project has come in through.
//
// The run framing is `crate::push_text`'s: `[UInt32 big-endian length][UTF-8 bytes]`, used in both
// directions — a curated environment crosses out as KEY, VALUE pairs in it and comes back in it, and
// a spawn's argv crosses out as one run per argument.
//
// It lives beside ``ArenaText`` and for its reason: this was hostd's alone until the supervisor
// protocol folded into `slopdesk-ffi`, at which point the second target needed the identical four
// lines. Neither half is a boundary — a closure and a length prefix are arithmetic — so this module
// still depends on nothing but Foundation, not even `CSlopDeskFFI`.
//
// A run that would read past the end of the blob ends the walk rather than shifting into whatever
// follows: a short delivery means the door and this file disagree about the layout, and continuing
// would dress every later run in its neighbour's text.
//
// Both decodes here REPAIR invalid UTF-8 rather than answering nil, which is why each carries the
// `optional_data_string_conversion` waiver the rest of the tree spells the same way. The bytes come
// from Rust, where every one of these answers is already a `&str` — so a replacement character can
// only mean the framing above is wrong, and a mangled environment variable is a better report of
// that than a whole spawn env silently collapsing to nil.

import Foundation

/// Runs a docs/55 §4 delivery door and returns exactly the bytes it wrote.
///
/// `capacity` is the first guess. Over it, the door reports its size and the call happens again —
/// which is the retry the convention exists to make correct. An answer of `0`, or one that somehow
/// still does not fit the grown buffer, is the empty delivery.
public func ffiAnswerBytes(
    capacity: Int = 4096,
    _ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int,
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

/// The same, decoded as UTF-8 — what every door whose answer is one path or one word wants.
public func ffiAnswerText(
    capacity: Int = 4096,
    _ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int,
) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: ffiAnswerBytes(capacity: capacity, door), as: UTF8.self)
}

/// Lends one string's UTF-8 to a door for the length of the call, and nothing longer.
///
/// The other half of §4: a door that TAKES text takes `(ptr, len)`, and the pointer is only valid
/// inside the closure. Written here because a face that lends three strings nests three of these,
/// and every one of them spelled by hand is a chance to let a temporary array die early.
public func ffiLend<T>(_ text: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
    Array(text.utf8).withUnsafeBufferPointer(body)
}

/// Appends one `[UInt32 big-endian length][UTF-8]` run.
public func ffiPushRun(_ blob: inout [UInt8], _ text: String) {
    let bytes = Array(text.utf8)
    let length = UInt32(bytes.count)
    blob.append(UInt8(truncatingIfNeeded: length >> 24))
    blob.append(UInt8(truncatingIfNeeded: length >> 16))
    blob.append(UInt8(truncatingIfNeeded: length >> 8))
    blob.append(UInt8(truncatingIfNeeded: length))
    blob.append(contentsOf: bytes)
}

/// Reads up to `count` runs out of `blob`, stopping early on a truncated or overrunning prefix.
public func ffiRuns(_ blob: [UInt8], count: Int) -> [String] {
    var runs: [String] = []
    runs.reserveCapacity(count)
    var cursor = blob.startIndex
    for _ in 0..<count {
        guard cursor + 4 <= blob.endIndex else { break }
        let length = Int(
            UInt32(blob[cursor]) << 24 | UInt32(blob[cursor + 1]) << 16
                | UInt32(blob[cursor + 2]) << 8 | UInt32(blob[cursor + 3]),
        )
        cursor += 4
        guard cursor + length <= blob.endIndex else { break }
        // swiftlint:disable:next optional_data_string_conversion
        runs.append(String(decoding: blob[cursor..<(cursor + length)], as: UTF8.self))
        cursor += length
    }
    return runs
}
