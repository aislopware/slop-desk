import Foundation

// The two byte-level utilities every codec in this module shares — one for lending a buffer to a
// door, one for taking a buffer back from it. They lived inside `WireMessageCodec.swift` while that
// file was the biggest of the three; `docs/63` G.4 deleted its byte pair, and a shared helper whose
// largest remaining user is a different file is a helper in the wrong place.

extension Data {
    /// Hands this buffer to `body` as the `(pointer, length)` pair every door in `slopdesk_ffi.h`
    /// takes. The pointer is valid for the duration of `body` and no longer.
    ///
    /// An EMPTY buffer short-circuits to `(nil, 0)` rather than borrowing: the messages this wire
    /// sends most — an `ack`, an `.output`, an `.input` — carry no text at all, so their arena is
    /// empty every time, and `withUnsafeBytes` on it is a borrow bought for nothing.
    @inline(__always)
    func spanning<R>(_ body: (UnsafeRawPointer?, Int) throws -> R) rethrows -> R {
        try isEmpty ? body(nil, 0) : withUnsafeBytes { try body($0.baseAddress, $0.count) }
    }
}

/// Where this module's byte buffers come from.
enum WireBuffer {
    /// A buffer of exactly `count` bytes, written by `fill` and handed back as `Data`.
    ///
    /// WHICH allocation is a measured choice, because the two `Data` shapes cross over:
    ///
    ///   - `Data(count:)` zeroes what it hands back, but a buffer of 14 bytes or fewer — a git
    ///     status with no repo, a presence update — lives INSIDE the `Data` value and never reaches
    ///     the allocator at all (~5 ns against ~113 ns for a `malloc`).
    ///   - `Data(bytesNoCopy:deallocator:)` skips the zeroing but carries a heavier representation,
    ///     about 20 ns of it, which only pays for itself once the pass it skips is longer than that.
    ///
    /// Measured, the crossing is at ``zeroingCheaperThanTheAllocator``: below it the two are within
    /// noise and the small-buffer win is large; at 32 KiB — a directory listing of a large tree, a
    /// process table — the zeroing costs as much as the encode that follows it (1.18 µs against
    /// 632 ns).
    @inline(__always)
    static func filled(_ count: Int, _ fill: (UnsafeMutableRawPointer?) -> Void) -> Data {
        guard count > 0 else { return Data() }
        guard count >= zeroingCheaperThanTheAllocator else {
            var buffer = Data(count: count)
            buffer.withUnsafeMutableBytes { fill($0.baseAddress) }
            return buffer
        }
        guard let out = malloc(count) else { preconditionFailure("out of memory for a wire buffer") }
        fill(out)
        return Data(bytesNoCopy: out, count: count, deallocator: .free)
    }

    /// The size at and above which writing into UNINITIALISED memory beats letting `Data` zero the
    /// buffer first — see ``filled(_:_:)`` for the two costs that cross here.
    private static let zeroingCheaperThanTheAllocator = 4096
}
