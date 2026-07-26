import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// The workspace codec reads bytes a NETWORK PEER sent. Every malformation must be a clean throw —
/// never a trap, never an over-allocation, never unbounded recursion.
///
/// `WorkspaceTreeOps` and friends were written for trusted `@MainActor` callers with local input;
/// this codec is the boundary where that stops being true, so the validate-then-drop discipline is
/// pinned here rather than assumed.
final class WorkspaceStateCodecHostileTests: XCTestCase {
    private func key(_ kind: UInt8, _ objectID: UUID, _ field: UInt8) -> WorkspaceKey {
        WorkspaceKey(kind: kind, objectID: objectID, field: field)
    }

    private func sampleState() -> HostWorkspaceState {
        let pane = UUID(), tab = UUID()
        return HostWorkspaceState([
            WorkspaceEntry(key: key(3, pane, 3), value: Data("main.go - NVIM".utf8)),
            WorkspaceEntry(key: key(3, pane, 8), value: Data("vi .".utf8)),
            WorkspaceEntry(key: key(2, tab, 0), value: Data("slopdesk".utf8)),
        ])
    }

    // MARK: - Truncation

    /// Truncation at EVERY byte offset. A frame cut anywhere must throw, and specifically must not
    /// decode to a plausible-but-wrong state.
    func testTruncationAtEveryOffsetThrows() {
        let full = WorkspaceStateCodec.encodeSnapshot(sampleState())
        for cut in 0..<full.count {
            XCTAssertThrowsError(
                try WorkspaceStateCodec.decodeSnapshot(full.prefix(cut)),
                "a snapshot truncated to \(cut)/\(full.count) bytes must throw",
            )
        }
        XCTAssertNoThrow(try WorkspaceStateCodec.decodeSnapshot(full), "the untruncated frame decodes")
    }

    /// Trailing garbage is a malformation too — a decoder that ignores it would accept two different
    /// byte strings for one state and break the golden pin.
    func testTrailingBytesThrow() {
        var full = WorkspaceStateCodec.encodeSnapshot(sampleState())
        full.append(0xFF)
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeSnapshot(full))
    }

    // MARK: - Hostile counts

    /// `entryCount = UInt32.max` on an otherwise-empty buffer. The count is bounded against the bytes
    /// actually remaining BEFORE any `reserveCapacity`, so this costs nothing.
    func testAbsurdEntryCountThrowsWithoutAllocating() {
        let payload = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeSnapshot(payload)) { error in
            XCTAssertEqual(error as? WorkspaceCodecError, .malformedBody)
        }
    }

    /// An entry whose declared value length is `UInt32.max` with no bytes behind it.
    func testAbsurdValueLengthThrows() {
        var bytes: [UInt8] = [0, 0, 0, 1] // entryCount = 1
        bytes.append(3) // kind
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: 16)) // objectID
        bytes.append(1) // field
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // valueLen
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeSnapshot(Data(bytes))) { error in
            XCTAssertEqual(error as? WorkspaceCodecError, .malformedBody)
        }
    }

    /// The delete list gets the same treatment as the set list.
    func testAbsurdDeleteCountThrows() {
        let payload = Data([0, 0, 0, 0] + [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeDiff(payload))
    }

    // MARK: - layoutStructure recursion

    private func nested(depth: Int) -> WorkspaceLayoutNode {
        var node = WorkspaceLayoutNode.leaf(PaneID(raw: UUID()))
        for _ in 0..<depth {
            node = .split(id: SplitNodeID(raw: UUID()), axis: .horizontal, children: [node])
        }
        return node
    }

    /// The cap boundary, exactly. `SplitNode.maxDepth` is 12: 11 and 12 decode, 13 throws.
    ///
    /// Each node is built ONCE and compared against its own round-trip — `nested(depth:)` mints fresh
    /// UUIDs per call, so comparing two separate constructions would never hold.
    func testLayoutDepthCapBoundary() throws {
        for depth in [1, 11, SplitNode.maxDepth] {
            let node = nested(depth: depth)
            XCTAssertEqual(
                try WorkspaceStateCodec.decodeLayout(WorkspaceStateCodec.encodeLayout(node)), node,
                "depth \(depth) is within the cap and round-trips exactly",
            )
        }
        let tooDeep = WorkspaceStateCodec.encodeLayout(nested(depth: SplitNode.maxDepth + 1))
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeLayout(tooDeep)) { error in
            XCTAssertEqual(error as? WorkspaceCodecError, .depthExceeded)
        }
    }

    /// A hand-built bomb: 200 nested split tags with no payload. Must throw on the DEPTH cap, having
    /// never recursed far enough to threaten the stack.
    func testDeeplyNestedGarbageThrowsOnDepthNotStack() {
        var bytes: [UInt8] = []
        for _ in 0..<200 {
            bytes.append(1)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
            bytes.append(0) // axis
            bytes.append(1) // one child
        }
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeLayout(Data(bytes))) { error in
            XCTAssertEqual(error as? WorkspaceCodecError, .depthExceeded)
        }
    }

    /// `childCount` is a `u8`, so fan-out is bounded at 255 by the FORMAT. A declared 255 children
    /// with no bytes behind them must throw rather than reserve.
    func testMaxChildCountWithNoPayloadThrows() {
        var bytes: [UInt8] = [1]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        bytes.append(0) // axis
        bytes.append(255) // childCount
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeLayout(Data(bytes)))
    }

    /// An unknown node tag is a malformation, not a skip — unlike an unknown ENTRY, a node has no
    /// length prefix, so the decoder cannot know how far to jump.
    func testUnknownLayoutTagThrows() {
        XCTAssertThrowsError(try WorkspaceStateCodec.decodeLayout(Data([9])))
    }

    /// A non-zero axis byte resolves to `.vertical` rather than trapping — the `byte != 0` discipline.
    func testUnexpectedAxisByteDoesNotTrap() throws {
        var bytes: [UInt8] = [1]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        bytes.append(0x7F) // neither 0 nor 1
        bytes.append(0)
        guard case let .split(_, axis, _) = try WorkspaceStateCodec.decodeLayout(Data(bytes)) else {
            XCTFail("expected a split node")
            return
        }
        XCTAssertEqual(axis, .vertical)
    }

    // MARK: - Values

    /// Weights ride as a raw `bitPattern`, so they survive BIT-EXACTLY — including the values a
    /// decimal round-trip would smear.
    func testWeightBitPatternIsExact() throws {
        for value in [0.1, 1.0 / 3.0, Double.pi, 5e-324, Double.greatestFiniteMagnitude] {
            let decoded = try WorkspaceStateCodec.decodeWeight(WorkspaceStateCodec.encodeWeight(.flex(value)))
            guard case let .flex(out) = decoded else {
                XCTFail("kind must round-trip")
                return
            }
            XCTAssertEqual(out.bitPattern, value.bitPattern, "\(value) must survive bit-exactly")
        }
        let fixed = try WorkspaceStateCodec.decodeWeight(WorkspaceStateCodec.encodeWeight(.fixed(240)))
        XCTAssertEqual(fixed, .fixed(240))
    }

    func testTruncatedWeightThrows() {
        let full = WorkspaceStateCodec.encodeWeight(.flex(0.5))
        for cut in 0..<full.count {
            XCTAssertThrowsError(try WorkspaceStateCodec.decodeWeight(full.prefix(cut)))
        }
    }

    /// Invalid UTF-8 decodes to `nil` — never a lossy string with replacement characters, which would
    /// silently render mojibake as if it were a real title.
    func testInvalidUTF8DecodesToNilNotLossy() {
        XCTAssertNil(WorkspaceStateCodec.decodeString(Data([0xFF, 0xFE])))
        XCTAssertEqual(WorkspaceStateCodec.decodeString(Data("ok".utf8)), "ok")
    }

    /// String clamping lands on a SCALAR boundary, so a truncated value stays valid UTF-8.
    func testStringClampKeepsValidUTF8() {
        let emoji = String(repeating: "🚀", count: 40) // 4 bytes each
        let clamped = WorkspaceStateCodec.encodeString(emoji, maxBytes: 10)
        XCTAssertLessThanOrEqual(clamped.count, 10)
        XCTAssertNotNil(String(data: clamped, encoding: .utf8), "the clamp must not split a scalar")
    }

    /// A zero-length value is a VALUE, not an absence — the title-retirement signal must survive the
    /// wire as a present-and-empty entry.
    func testZeroLengthValueRoundTrips() throws {
        let pane = UUID()
        let state = HostWorkspaceState([WorkspaceEntry(key: key(3, pane, 3), value: Data())])
        let decoded = try WorkspaceStateCodec.decodeSnapshot(WorkspaceStateCodec.encodeSnapshot(state))
        XCTAssertEqual(decoded[key(3, pane, 3)], Data(), "present-and-empty, not missing")
        XCTAssertNotNil(decoded[key(3, pane, 3)])
    }

    /// Forward tolerance: an entry with a kind/field this build has never heard of is KEPT verbatim,
    /// so an older client's state stays byte-equal to the host's and its ack means what it says.
    /// (docs/45 §5.3 proposed SKIPPING these; keeping is strictly stronger — a skip would have the
    /// client ack a state it does not hold.)
    func testUnknownKindAndFieldAreKeptVerbatim() throws {
        let objectID = UUID()
        let state = HostWorkspaceState([
            WorkspaceEntry(key: key(200, objectID, 250), value: Data("from the future".utf8)),
        ])
        let decoded = try WorkspaceStateCodec.decodeSnapshot(WorkspaceStateCodec.encodeSnapshot(state))
        XCTAssertEqual(decoded, state, "an unknown entry round-trips rather than vanishing")
    }

    // MARK: - Diff framing

    func testDiffRoundTripsIncludingDeletes() throws {
        let pane = UUID()
        let from = HostWorkspaceState([
            WorkspaceEntry(key: key(3, pane, 1), value: Data("a".utf8)),
            WorkspaceEntry(key: key(3, pane, 2), value: Data("b".utf8)),
        ])
        let to = HostWorkspaceState([WorkspaceEntry(key: key(3, pane, 1), value: Data("z".utf8))])
        let diff = to.diff(from: from)

        let decoded = try WorkspaceStateCodec.decodeDiff(WorkspaceStateCodec.encodeDiff(diff))
        XCTAssertEqual(decoded, diff)
        XCTAssertEqual(from.applying(decoded), to, "the DECODED diff still carries the base to the target")
    }

    func testDiffTruncationAtEveryOffsetThrows() {
        let pane = UUID()
        let from = HostWorkspaceState([WorkspaceEntry(key: key(3, pane, 1), value: Data("a".utf8))])
        let to = HostWorkspaceState([WorkspaceEntry(key: key(3, pane, 2), value: Data("b".utf8))])
        let full = WorkspaceStateCodec.encodeDiff(to.diff(from: from))
        for cut in 0..<full.count {
            XCTAssertThrowsError(try WorkspaceStateCodec.decodeDiff(full.prefix(cut)), "cut at \(cut)")
        }
    }
}
