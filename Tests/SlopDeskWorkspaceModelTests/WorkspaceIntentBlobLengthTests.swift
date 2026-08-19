import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// The `u16` in front of an intent's sub-payload must be the number of bytes that follow it.
///
/// SWIFT had this bug and RUST was right: `slopdesk_wire::document::intent::put_blob` clamps the
/// declared length and cuts the payload to it, and its doc comment names Swift as the offender —
/// `spawnDetachedPane` and `setPaneVideoTarget` both wrote a WRAPPED length (`count >> 8`, `count`)
/// and then appended every byte anyway. Past 64 KiB that is not an oversized blob, it is a MIS-SPLIT
/// frame: the length says one thing and the payload is another, so the decoder reads the blob's tail
/// as the next field, and a host validating the arguments validates the wrong bytes.
///
/// Nothing pinned in `golden/golden_vectors.json` moves, and these tests are also the proof of that:
/// the small-payload case asserts the frame is byte-for-byte a length plus its blob, which is what
/// every real payload has always been — ``WorkspaceIntentArgs/maxBlobBytes`` (16 KiB) refuses anything
/// near the boundary on the way back in. Only the pathological frame changes, from "decodes as
/// something else" to "decodes truncated and is rejected".
final class WorkspaceIntentBlobLengthTests: XCTestCase {
    /// Two strings just under the codec's own per-string cap, so the encoded `videoTarget` is past
    /// what a `u16` can address. Unreachable from the UI — that is the point of the case: the encoder
    /// must not be the thing that decides a frame is well-formed.
    private func oversizedVideo() -> VideoEndpoint {
        VideoEndpoint(
            windowID: 7,
            title: String(repeating: "t", count: 60000),
            appName: String(repeating: "a", count: 60000),
            displayID: 1,
        )
    }

    private func smallVideo() -> VideoEndpoint {
        VideoEndpoint(windowID: 0, title: "Studio Display", appName: "", displayID: 1)
    }

    /// The big-endian `u16` at `offset`.
    private func declaredLength(_ data: Data, at offset: Int) -> Int {
        let bytes = [UInt8](data)
        guard offset + 1 < bytes.count else { return -1 }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    func testAnOversizedVideoTargetStillDeclaresTheBytesItWrites() {
        let video = oversizedVideo()
        let blob = WorkspaceStateCodec.encodeVideoTarget(video)
        XCTAssertGreaterThan(
            blob.count,
            65535,
            "the fixture only tests anything if the blob really is past what the length can address",
        )

        // `setPaneVideoTarget`: [16B pane][u16 len][videoTarget]
        let repoint = WorkspaceIntentArgs.encode(pane: PaneID(), video: video)
        XCTAssertEqual(
            repoint.count - 18,
            declaredLength(repoint, at: 16),
            "the length prefix must name exactly the bytes that follow it, or the frame mis-splits",
        )
        XCTAssertEqual(declaredLength(repoint, at: 16), 65535, "clamped, the way `put_blob` clamps")

        // `spawnDetachedPane`: [16B pane][u8 kind][u16 len][videoTarget]
        let mint = WorkspaceIntentArgs.encode(detachedPane: PaneID(), kind: .desktop, video: video)
        XCTAssertEqual(
            mint.count - 19,
            declaredLength(mint, at: 17),
            "the mint speaks the same grammar as the re-point, including this",
        )
    }

    /// The frame every real client actually sends, unchanged: length, then that many bytes, then
    /// nothing. This is the assertion that says the fix cannot have moved a pinned vector.
    func testARealVideoTargetIsUnchangedByTheClamp() {
        let video = smallVideo()
        let blob = WorkspaceStateCodec.encodeVideoTarget(video)
        XCTAssertLessThan(blob.count, Int(WorkspaceIntentArgs.maxBlobBytes), "a real target is far inside the cap")

        let repoint = WorkspaceIntentArgs.encode(pane: PaneID(), video: video)
        XCTAssertEqual(declaredLength(repoint, at: 16), blob.count)
        XCTAssertEqual(repoint.suffix(blob.count), blob, "every byte of the blob is still written")

        let mint = WorkspaceIntentArgs.encode(detachedPane: PaneID(), kind: .desktop, video: video)
        XCTAssertEqual(declaredLength(mint, at: 17), blob.count)
        XCTAssertEqual(mint.suffix(blob.count), blob)
    }

    /// No target at all stays a zero length and nothing after it — the UNBIND, which has to stay
    /// distinguishable from "the bytes did not decode".
    func testNoVideoTargetIsAZeroLengthAndNoPayload() {
        let repoint = WorkspaceIntentArgs.encode(pane: PaneID(), video: nil)
        XCTAssertEqual(repoint.count, 18)
        XCTAssertEqual(declaredLength(repoint, at: 16), 0)

        let mint = WorkspaceIntentArgs.encode(detachedPane: PaneID(), kind: .terminal, video: nil)
        XCTAssertEqual(mint.count, 19)
        XCTAssertEqual(declaredLength(mint, at: 17), 0)
    }
}
