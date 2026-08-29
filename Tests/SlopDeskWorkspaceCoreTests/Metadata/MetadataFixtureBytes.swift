import Foundation

// Hand-spelled HOST-side metadata reply bodies, for the CLIENT tests that need one as input.
//
// `MetadataClient` owns only the client's diagonal of the metadata wire: it writes requests and
// reads responses. Its tests still need response bodies, and the half of the Swift codec that built
// them is gone — every response ENCODER is Rust's now. What replaces it here is a second SPELLER of
// those bodies, never a second implementation: flat literal bytes with the layout written over each
// helper, no clamp, no validation, no shared writer that could grow into one.
// `Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift` is the same fixture for the same reason,
// one test target over.
//
// Every layout below is pinned against the matching `encode_*` in
// `rust/slopdesk-wire/src/metadata/codec.rs`. A body that agreed with an encoder by construction
// would assert nothing — spelling it out is the point, not a shortfall.
//
// ALL multi-byte integers are big-endian ("network byte order"), and the bytes are assembled one at
// a time so the spelling stays explicit rather than alignment- or endian-dependent.

/// Host-shaped metadata payloads, spelled byte by byte. Shared by every suite in this target.
enum MetadataFixtureBytes {
    /// A `processes` reply body: `[UInt16 count]` then
    /// `[UInt32 pid][UInt32 uptimeSec][UInt16 nameLen][name UTF-8]` per entry.
    ///
    /// The count is written verbatim from `entries`; clamping it here would re-derive the encoder's
    /// own rule instead of spelling a body to test the decoder against.
    static func processList(_ entries: [(pid: UInt32, uptimeSec: UInt32, name: String)]) -> Data {
        var bytes = Data(be16(UInt16(entries.count)))
        for entry in entries {
            bytes.append(contentsOf: be32(entry.pid))
            bytes.append(contentsOf: be32(entry.uptimeSec))
            bytes.append(contentsOf: lengthPrefixed(entry.name))
        }
        return bytes
    }

    /// A `ports` reply body: `[UInt16 count]` then
    /// `[UInt16 port][UInt8 proto][UInt16 nameLen][procName UTF-8]` per entry.
    ///
    /// `proto` is the RAW transport byte (0 = tcp, 1 = udp), carried forward-tolerantly. An empty
    /// list — the "No listening ports" state — is the two count bytes and nothing else.
    static func portList(_ entries: [(port: UInt16, proto: UInt8, procName: String)]) -> Data {
        var bytes = Data(be16(UInt16(entries.count)))
        for entry in entries {
            bytes.append(contentsOf: be16(entry.port))
            bytes.append(entry.proto)
            bytes.append(contentsOf: lengthPrefixed(entry.procName))
        }
        return bytes
    }

    /// A `listDirectory` reply body: `[UInt16 count]` then `[UInt8 isDir][UInt16 nameLen][name UTF-8]`
    /// per entry. Leaf names only — the client joins them with the request path.
    static func dirListing(_ entries: [(isDir: Bool, name: String)]) -> Data {
        var bytes = Data(be16(UInt16(entries.count)))
        for entry in entries {
            bytes.append(entry.isDir ? 1 : 0)
            bytes.append(contentsOf: lengthPrefixed(entry.name))
        }
        return bytes
    }

    /// The WHOLE `gitStatus` reply body for a cwd that is not inside a repository: the single
    /// `hasRepo = 0` byte. Branch, remote, repo root, ahead/behind/stash and the file list never
    /// reach the wire in this case, which is why the no-repo payload is one byte rather than a run
    /// of empty fields.
    static let gitStatusNoRepo = Data([0x00])

    /// A `hostVitals` (verb 17) reply body — 7 bytes:
    /// `[UInt8 cpu%][UInt8 memory%][UInt8 pressure][UInt32 diskFreeMiB]`.
    ///
    /// `pressure` is the raw memory-pressure byte (0 = normal, 1 = warn, 2 = critical). Percents are
    /// written verbatim: the clamp to `0...100` belongs to the codec on both sides, and a fixture
    /// that pre-clamped could not hand the decoder a wild byte to clamp.
    static func hostVitals(cpu: UInt8, memory: UInt8, pressure: UInt8, diskFreeMiB: UInt32) -> Data {
        Data([cpu, memory, pressure] + be32(diskFreeMiB))
    }

    /// An `openInCodeServer` (verb 19) reply body: the single disposition byte
    /// (0 = workbench, 1 = hostDefault).
    static func codeOpenDisposition(_ byte: UInt8) -> Data {
        Data([byte])
    }

    /// A big-endian `UInt16`, most significant byte first.
    private static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// A big-endian `UInt32`, most significant byte first.
    private static func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    /// A string field: `[UInt16 BE byte count][UTF-8 bytes]`. The length is the string's own UTF-8
    /// byte count, written verbatim — the encoder's over-long clamp is not repeated here.
    private static func lengthPrefixed(_ value: String) -> [UInt8] {
        let utf8 = Array(value.utf8)
        return be16(UInt16(utf8.count)) + utf8
    }
}
