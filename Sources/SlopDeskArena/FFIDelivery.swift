// FFIDelivery — the ONE way Swift asks a door for bytes, and the ONE way it lends a door text.
//
// docs/55 §4: a delivery door writes into the caller's buffer only if the answer FITS, and returns
// the length it needed either way. So every call is ask-with-a-guess, and grow-once when the guess
// was short. Written out at each face that is the same four lines five times, which is the shape
// every cross-language off-by-one in this project has come in through.
//
// It lives beside ``ArenaText`` and for its reason: this was hostd's alone until the supervisor
// protocol folded into `slopdesk-ffi`, at which point the second target needed the identical four
// lines. Neither half is a boundary — a closure and a `(ptr, len)` pair are arithmetic — so this
// module still depends on nothing but Foundation, not even `CSlopDeskFFI`.
//
// The decode here REPAIRS invalid UTF-8 rather than answering nil, which is why it carries the
// `optional_data_string_conversion` waiver the rest of the tree spells the same way. The bytes come
// from Rust, where every one of these answers is already a `&str` — so a replacement character can
// only mean the door and this file disagree about the layout, and a mangled word is a better report
// of that than a whole answer silently collapsing to nil.
//
// It used to hold a third pair: `ffiPushRun`/`ffiRuns`, the `[UInt32 big-endian length][UTF-8]`
// framing of `crate::push_text`, which carried a curated environment out as KEY, VALUE pairs and a
// spawn's argv out as one run per argument. Neither face is Swift any more, and no Swift asks for
// either read or write — so the framing has ONE implementation again, `crate::push_text`'s, and the
// Swift half went with the callers rather than waiting for one that is not coming back.

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

/// The same convention for a door that answers `#[repr(C)]` RECORDS rather than bytes.
///
/// Its own buffer rather than ``ffiAnswerBytes``' — a record array has to be aligned for its
/// element, and reinterpreting a byte buffer would be an unaligned load on every field.
///
/// Asks first with `(nil, 0)`, because a record count is cheap to answer and a wrong first guess
/// costs a whole delivery rather than a few bytes. A door that answers a count it then declines to
/// fill delivers nothing, the same way an over-long byte answer does: a short array is a wrong
/// answer, and the empty one is at least an honest report of the disagreement.
public func ffiAnswerRecords<Record>(
    _: Record.Type,
    _ door: (UnsafeMutablePointer<Record>?, Int) -> Int,
) -> [Record] {
    let needed = door(nil, 0)
    guard needed > 0 else { return [] }
    return [Record](unsafeUninitializedCapacity: needed) { buffer, initialised in
        let written = door(buffer.baseAddress, needed)
        initialised = written == needed ? needed : 0
    }
}

/// The same, decoded as UTF-8 — what every door whose answer is one path or one word wants.
public func ffiAnswerText(
    capacity: Int = 4096,
    _ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int,
) -> String {
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
