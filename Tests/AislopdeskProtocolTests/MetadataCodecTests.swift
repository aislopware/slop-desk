import Foundation
import XCTest
@testable import AislopdeskProtocol

/// E4 / WI-2 — the per-verb `MetadataCodec` payload codecs that ride INSIDE the opaque
/// `metadataResponse` payload (`ProcessList` / `PortList` / `DirListing` / `GitStatus` /
/// `AgentSessionList`). These prove:
///
/// - **byte-exact layout** (hand-computed expected bytes, independent of the golden corpus, so a
///   refactor that shifts a field is caught here too — not a tautology against the codec's own output);
/// - **encode↔decode round-trips** for representative, empty, Unicode, and forward-tolerant values;
/// - **validate-then-drop (ES-E4-5):** a declared count/length larger than the body throws
///   ``AislopdeskError/truncated`` with NO allocation (count-before-alloc); a non-UTF-8 string field
///   throws ``AislopdeskError/malformedBody(_:)``; a fuzz-ish table of truncated/garbage buffers each
///   throws and NEVER traps;
/// - **clamp on a >64 KiB field:** the `UInt16` length field is clamped (not `truncatingIfNeeded`), so
///   the round-trip survives (revert-to-confirm-fail: a wrapping length would desync the decoder).
final class MetadataCodecTests: XCTestCase {
    // MARK: - ProcessList

    func testProcessListRoundTrip() throws {
        let cases: [[MetadataCodec.ProcessInfo]] = [
            [],
            [.init(pid: 0, uptimeSec: 0, name: "")],
            [
                .init(pid: 0x0102_0304, uptimeSec: 42, name: "-zsh"),
                .init(pid: UInt32.max, uptimeSec: UInt32.max, name: "claude · 文字 🚀"),
            ],
        ]
        for items in cases {
            let decoded = try MetadataCodec.decodeProcessList(MetadataCodec.encodeProcessList(items))
            XCTAssertEqual(decoded, items)
        }
    }

    func testProcessListExactBytes() {
        // count=1; entry pid=0x01020304, uptime=0x00000010, name="zsh".
        let bytes = [UInt8](MetadataCodec.encodeProcessList([
            .init(pid: 0x0102_0304, uptimeSec: 0x10, name: "zsh"),
        ]))
        XCTAssertEqual(bytes, [
            0x00, 0x01, // count = 1
            0x01, 0x02, 0x03, 0x04, // pid
            0x00, 0x00, 0x00, 0x10, // uptimeSec
            0x00, 0x03, // nameLen = 3
            0x7A, 0x73, 0x68, // "zsh"
        ])
    }

    func testProcessListCountBeforeAllocDrops() {
        // count claims 1000 entries but the body is empty → reject BEFORE allocating, never over-read.
        XCTAssertThrowsError(try MetadataCodec.decodeProcessList(Data([0x03, 0xE8]))) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    func testProcessListTruncatedMidEntryDrops() {
        // count=1 but only 3 of the 10 fixed entry bytes present → truncated.
        XCTAssertThrowsError(
            try MetadataCodec.decodeProcessList(Data([0x00, 0x01, 0x01, 0x02, 0x03])),
        ) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    func testProcessListBadUTF8Drops() {
        // count=1, pid/uptime present, nameLen=1, name byte = 0xFF (invalid UTF-8 start) → malformedBody.
        let body = Data([
            0x00, 0x01, // count
            0x00, 0x00, 0x00, 0x01, // pid
            0x00, 0x00, 0x00, 0x00, // uptime
            0x00, 0x01, // nameLen = 1
            0xFF, // not valid UTF-8
        ])
        XCTAssertThrowsError(try MetadataCodec.decodeProcessList(body)) { error in
            guard case .malformedBody = (error as? AislopdeskError) else {
                return XCTFail("expected malformedBody, got \(error)")
            }
        }
    }

    // MARK: - PortList

    func testPortListRoundTrip() throws {
        let cases: [[MetadataCodec.PortInfo]] = [
            [], // "No listening ports"
            [
                .init(port: 8080, proto: 0, procName: "node"),
                .init(port: 53, proto: 1, procName: "mDNSResponder"),
                .init(port: 65535, proto: 200, procName: ""), // unknown future proto byte tolerated
            ],
        ]
        for items in cases {
            let decoded = try MetadataCodec.decodePortList(MetadataCodec.encodePortList(items))
            XCTAssertEqual(decoded, items)
        }
    }

    func testPortListEmptyExactBytes() {
        XCTAssertEqual([UInt8](MetadataCodec.encodePortList([])), [0x00, 0x00]) // count = 0
    }

    func testPortProtocolMapping() {
        XCTAssertEqual(MetadataCodec.PortInfo(port: 1, proto: 0, procName: "").portProtocol, .tcp)
        XCTAssertEqual(MetadataCodec.PortInfo(port: 1, proto: 1, procName: "").portProtocol, .udp)
        // Unknown future proto byte maps to nil (forward-tolerant) — never a trap.
        XCTAssertNil(MetadataCodec.PortInfo(port: 1, proto: 9, procName: "").portProtocol)
    }

    func testPortListCountBeforeAllocDrops() {
        XCTAssertThrowsError(try MetadataCodec.decodePortList(Data([0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    // MARK: - DirListing

    func testDirListingRoundTrip() throws {
        let cases: [[MetadataCodec.DirEntry]] = [
            [],
            [
                .init(isDir: true, name: "Sources"),
                .init(isDir: false, name: "README.md"),
                .init(isDir: true, name: "café 📁"),
            ],
        ]
        for items in cases {
            let decoded = try MetadataCodec.decodeDirListing(MetadataCodec.encodeDirListing(items))
            XCTAssertEqual(decoded, items)
        }
    }

    func testDirListingIsDirReadAsByteNotEqualZero() throws {
        // isDir discriminator read as `byte != 0`: a hostile 0x02 decodes to isDir=true (never assumed {0,1}).
        let body = Data([
            0x00, 0x01, // count = 1
            0x02, // isDir = 0x02 (truthy)
            0x00, 0x01, // nameLen = 1
            0x61, // "a"
        ])
        let decoded = try MetadataCodec.decodeDirListing(body)
        XCTAssertEqual(decoded, [.init(isDir: true, name: "a")])
    }

    func testDirListingCountBeforeAllocDrops() {
        XCTAssertThrowsError(try MetadataCodec.decodeDirListing(Data([0x10, 0x00]))) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    // MARK: - GitStatus

    func testGitStatusNoRepoRoundTrip() throws {
        let decoded = try MetadataCodec.decodeGitStatus(MetadataCodec.encodeGitStatus(.noRepo))
        XCTAssertEqual(decoded, .noRepo)
    }

    func testGitStatusNoRepoExactBytes() {
        // hasRepo=false → a single 0x00 byte, no trailing fields.
        XCTAssertEqual([UInt8](MetadataCodec.encodeGitStatus(.noRepo)), [0x00])
    }

    func testGitStatusRepoRoundTrip() throws {
        let status = MetadataCodec.GitStatusPayload(
            hasRepo: true,
            branch: "main",
            remoteURL: "git@github.com:aislopware/aislopdesk.git",
            ahead: 3,
            behind: -2, // negative survives (Int32 BE)
            files: [
                .init(statusCode: 0x12, path: "Sources/main.swift"),
                .init(statusCode: 0xFF, path: "docs/café.md"),
            ],
        )
        let decoded = try MetadataCodec.decodeGitStatus(MetadataCodec.encodeGitStatus(status))
        XCTAssertEqual(decoded, status)
    }

    func testGitStatusHasRepoReadAsByteNotEqualZero() throws {
        // hasRepo byte = 0x07 (truthy) → treated as a repo; the rest of the layout is read.
        let body = Data([
            0x07, // hasRepo (truthy)
            0x00, 0x01, 0x61, // branch "a"
            0x00, 0x00, // remote ""
            0x00, 0x00, 0x00, 0x00, // ahead = 0
            0x00, 0x00, 0x00, 0x00, // behind = 0
            0x00, 0x00, // 0 files
        ])
        let decoded = try MetadataCodec.decodeGitStatus(body)
        XCTAssertTrue(decoded.hasRepo)
        XCTAssertEqual(decoded.branch, "a")
    }

    func testGitStatusFileCountBeforeAllocDrops() {
        // hasRepo, empty branch/remote, ahead/behind, fileCount=5000 but no file bytes → truncated.
        let body = Data([
            0x01, // hasRepo
            0x00, 0x00, // branch ""
            0x00, 0x00, // remote ""
            0x00, 0x00, 0x00, 0x00, // ahead
            0x00, 0x00, 0x00, 0x00, // behind
            0x13, 0x88, // fileCount = 5000
        ])
        XCTAssertThrowsError(try MetadataCodec.decodeGitStatus(body)) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    func testGitStatusTruncatedHeaderDrops() {
        // hasRepo=true but the branch length prefix is missing → truncated (validate-then-drop).
        XCTAssertThrowsError(try MetadataCodec.decodeGitStatus(Data([0x01]))) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    // MARK: - AgentSessionList

    func testAgentSessionListRoundTrip() throws {
        let cases: [[MetadataCodec.AgentSessionInfo]] = [
            [],
            [
                .init(
                    agentKindByte: 0,
                    id: "9f3c-claude",
                    title: "Fix the wire codec",
                    cwd: "/Users/me/project",
                    mtimeMS: 1_749_700_000_123,
                ),
                .init(
                    agentKindByte: 1,
                    id: "codex-42",
                    title: "",
                    cwd: "/tmp/café 🚀",
                    mtimeMS: Int64.max,
                ),
                .init(agentKindByte: 200, id: "x", title: "y", cwd: "z", mtimeMS: -1), // unknown kind tolerated
            ],
        ]
        for items in cases {
            let decoded = try MetadataCodec.decodeAgentSessionList(MetadataCodec.encodeAgentSessionList(items))
            XCTAssertEqual(decoded, items)
        }
    }

    func testAgentKindMapping() {
        XCTAssertEqual(MetadataCodec.AgentSessionInfo(
            agentKindByte: 0, id: "", title: "", cwd: "", mtimeMS: 0,
        ).agentKind, .claude)
        XCTAssertEqual(MetadataCodec.AgentSessionInfo(
            agentKindByte: 2, id: "", title: "", cwd: "", mtimeMS: 0,
        ).agentKind, .opencode)
        XCTAssertNil(MetadataCodec.AgentSessionInfo(
            agentKindByte: 9, id: "", title: "", cwd: "", mtimeMS: 0,
        ).agentKind)
    }

    func testAgentSessionListCountBeforeAllocDrops() {
        XCTAssertThrowsError(try MetadataCodec.decodeAgentSessionList(Data([0x20, 0x00]))) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    // MARK: - Clamp on a >64 KiB field (revert-to-confirm-fail for the UInt16-length clamp)

    func testProcessNameOver64KiBClampsAndRoundTrips() throws {
        // A 70000-byte name exceeds the UInt16 length field. The clamp writes 0xFFFF (65535) and only
        // 65535 bytes — NOT `truncatingIfNeeded` (which would write 70000 & 0xFFFF = 0x1170 = 4464 and
        // desync the decoder). Proof: the length field is exactly 0xFFFF and the round-trip yields a
        // 65535-byte name.
        let huge = String(repeating: "a", count: 70000)
        let encoded = MetadataCodec.encodeProcessList([.init(pid: 1, uptimeSec: 2, name: huge)])
        // Bytes [10..11] are the nameLen field (count 2 + pid 4 + uptime 4).
        XCTAssertEqual([UInt8](encoded)[10], 0xFF)
        XCTAssertEqual([UInt8](encoded)[11], 0xFF)
        let decoded = try MetadataCodec.decodeProcessList(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name.utf8.count, Int(UInt16.max))
        XCTAssertEqual(decoded.first?.pid, 1)
        XCTAssertEqual(decoded.first?.uptimeSec, 2)
    }

    // MARK: - Fuzz-ish: every garbage/truncated buffer drops, never traps

    func testGarbageBuffersNeverTrap() {
        let buffers: [Data] = [
            Data(),
            Data([0x00]), // half a count
            Data([0xFF]),
            Data([0xFF, 0xFF]), // max count, empty body
            Data(repeating: 0xFF, count: 7),
            Data([0x00, 0x01, 0x00]), // count=1 then a single stray byte
        ]
        // Each decoder must THROW (drop) on each buffer — never crash. The git decoder treats a lone
        // 0x00 as "no repo" (valid) and 0xFF as hasRepo (then truncates), so it is asserted separately.
        for buffer in buffers {
            XCTAssertThrowsError(try MetadataCodec.decodeProcessList(buffer))
            XCTAssertThrowsError(try MetadataCodec.decodePortList(buffer))
            XCTAssertThrowsError(try MetadataCodec.decodeDirListing(buffer))
            XCTAssertThrowsError(try MetadataCodec.decodeAgentSessionList(buffer))
        }
        // GitStatus: an empty buffer truncates; a lone 0x00 is the valid "no repo" payload.
        XCTAssertThrowsError(try MetadataCodec.decodeGitStatus(Data()))
        XCTAssertEqual(try MetadataCodec.decodeGitStatus(Data([0x00])), .noRepo)
    }
}
