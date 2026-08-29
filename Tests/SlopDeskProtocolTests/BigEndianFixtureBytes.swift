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

    /// A count, or a length prefix — the only width the bodies this target still spells by hand hold.
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

// The READER half was a second copy of `VideoWireFixtureBytes`' `BigEndianReader`, one test target
// over, and nothing in this target ever built one — every decode here goes through the Rust codec.
// The append half stays: a test that hand-builds the bytes it expects is the point.
//
// The `Int32` overload went the same way in `docs/63` §G.4. Its only callers spelled a `gitStatus`
// body's ahead/behind/stash, in the round-trip suite that retired with `MetadataCodec`'s host-side
// encoders — and this file carries only the widths its remaining callers actually write.
//
// `Int64`, `UInt32` and `UInt64` went one stage later, when `WorkspaceChannelCodec` lost its
// host-facing half. Their only callers spelled a subscribe body's `knownStateNum` and an intent's
// hostile `argLen`, both in fault tests that `rust/slopdesk-wire`'s `workspace` suite already pins;
// `Int64` was `UInt64`'s only caller, so the two left together. What is left of the wire this target
// still spells by hand is the presence ROSTER, whose every field is a `u16`, a `u8` or sixteen raw
// UUID bytes — so one overload is now the whole file.
