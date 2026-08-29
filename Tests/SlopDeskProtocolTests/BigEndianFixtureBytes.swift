import Foundation

// Tiny big-endian read/write helpers, for TESTS that spell the wire out by hand.
//
// ALL multi-byte integers are big-endian ("network byte order") on the wire, and byte-by-byte
// assembly is what makes the spelling explicit rather than alignment- or endian-dependent.
//
// These lived in `Sources/SlopDeskProtocol` while the Swift codecs read and wrote bytes. Every one
// of those codecs is Rust now, so the last callers are the tests — and a test that hand-builds the
// bytes it expects is the point, not a shortfall: a round trip through one codebase's own encoder
// and decoder passes just as happily when both have drifted from the wire. `VideoWireFixtureBytes`
// is the same helper for the same reason, one test target over.
//
// They must not go back to `Sources/`: `slopdesk-invariants` fails on a declaration of either there,
// because a "just this one field" helper is how a second implementation of a wire grows back.

extension Data {
    // MARK: Append (encode)

    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: Int64) {
        appendBE(UInt64(bitPattern: value))
    }

    mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

// The READER half was a second copy of `VideoWireFixtureBytes`' `BigEndianReader`, one test target
// over, and nothing in this target ever built one — every decode here goes through the Rust codec.
// The append half stays: a test that hand-builds the bytes it expects is the point.
//
// The `Int32` overload went the same way in `docs/63` §G.4. Its only callers spelled a `gitStatus`
// body's ahead/behind/stash, in the round-trip suite that retired with `MetadataCodec`'s host-side
// encoders — and this file carries only the widths its remaining callers actually write.
