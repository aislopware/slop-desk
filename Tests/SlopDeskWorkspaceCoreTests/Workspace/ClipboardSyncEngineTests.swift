#if os(macOS)
import AppKit
import SlopDeskPasteboard
import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``ClipboardSyncEngine`` tick logic against a NAMED pasteboard + fake push/pull seams (no live
/// socket): push-on-local-change with pending retry, baseline-first pull, and the loop-safety
/// contract (our own applies never bounce back, pulled clips never re-apply).
@MainActor
final class ClipboardSyncEngineTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var pushed: [MetadataCodec.ClipboardClip] = []
    private var pushResult = true
    private var pullRequests: [Int64] = []
    private var pullResult: (changeCount: Int64, clip: MetadataCodec.ClipboardClip?)?

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func setUp() async throws {
        pasteboard = NSPasteboard(
            name: NSPasteboard.Name("slopdesk.tests.syncengine.\(UUID().uuidString)"),
        )
        pasteboard.clearContents()
        pushed = []
        pushResult = true
        pullRequests = []
        pullResult = nil
    }

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    private func makeEngine() -> ClipboardSyncEngine {
        ClipboardSyncEngine(
            pasteboard: SystemPasteboard(pasteboard),
            push: { [weak self] clip in
                guard let self else { return false }
                pushed.append(clip)
                return pushResult
            },
            pull: { [weak self] lastSeen in
                guard let self else { return nil }
                pullRequests.append(lastSeen)
                return pullResult
            },
        )
    }

    private func copyLocally(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Push (local copy → host)

    func testLocalCopyIsPushed() async {
        let engine = makeEngine()
        copyLocally("hello host")
        await engine.tick()
        XCTAssertEqual(pushed.map(\.bytes), [Data("hello host".utf8)])
        XCTAssertEqual(pushed.first?.kind, .text)
    }

    func testLaunchTimeClipIsNotPushed() async {
        copyLocally("already there at launch")
        let engine = makeEngine()
        await engine.tick()
        XCTAssertEqual(pushed, [], "the engine seeds at the current count — no retro-push")
    }

    func testUnchangedBoardPushesNothing() async {
        let engine = makeEngine()
        copyLocally("once")
        await engine.tick()
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pushed.count, 1, "one change → exactly one push")
    }

    func testFailedPushStaysPendingAndRetries() async {
        let engine = makeEngine()
        pushResult = false
        copyLocally("flaky")
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pushed.count, 2, "a rejected push retries every tick")
        pushResult = true
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pushed.count, 3, "accepted → pending cleared, no further pushes")
    }

    func testNoPullWhileAPushIsPending() async {
        let engine = makeEngine()
        pushResult = false
        copyLocally("stuck")
        await engine.tick()
        XCTAssertEqual(pullRequests, [], "a stale host answer must not race the newer local clip")
        pushResult = true
        await engine.tick()
        XCTAssertEqual(pullRequests.count, 1, "pull resumes once the push lands")
    }

    func testConcealedClipIsNeverPushed() async {
        let engine = makeEngine()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("1", forType: PasteboardClip.concealedType)
        await engine.tick()
        XCTAssertEqual(pushed, [], "password-manager clips stay local")
    }

    func testFileCopyIsNeverPushed() async {
        let engine = makeEngine()
        pasteboard.clearContents()
        pasteboard.setString("file:///Users/x/doc.pdf", forType: .fileURL)
        pasteboard.setString("doc.pdf", forType: .string)
        await engine.tick()
        XCTAssertEqual(pushed, [], "a local file path is meaningless on the host")
    }

    // MARK: Pull (host copy → local)

    func testFirstPullIsABaselineProbe() async {
        let engine = makeEngine()
        pullResult = (changeCount: 40, clip: nil)
        await engine.tick()
        XCTAssertEqual(pullRequests, [MetadataCodec.clipboardBaselineProbe])
        await engine.tick()
        XCTAssertEqual(pullRequests.last, 40, "subsequent pulls carry the learned count")
    }

    func testPulledHostClipIsAppliedLocally() async {
        let engine = makeEngine()
        pullResult = (changeCount: 41, clip: MetadataCodec.ClipboardClip(
            kind: .text, bytes: Data("from host".utf8),
        ))
        await engine.tick()
        XCTAssertEqual(pasteboard.string(forType: .string), "from host")
    }

    func testAppliedHostClipIsNotPushedBack() async {
        let engine = makeEngine()
        pullResult = (changeCount: 41, clip: MetadataCodec.ClipboardClip(
            kind: .text, bytes: Data("from host".utf8),
        ))
        await engine.tick()
        pullResult = (changeCount: 41, clip: nil)
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pushed, [], "our own apply advanced the local count — it must NOT bounce back")
    }

    func testPulledImageClipLandsAsPNGAndTIFF() async throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        )
        let png = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
        let engine = makeEngine()
        pullResult = (changeCount: 50, clip: MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: png))
        await engine.tick()
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testPullFailureResetsTheBaseline() async {
        let engine = makeEngine()
        pullResult = (changeCount: 40, clip: nil)
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pullRequests.last, 40)
        pullResult = nil // disconnect
        await engine.tick()
        pullResult = (changeCount: 90, clip: nil)
        await engine.tick()
        XCTAssertEqual(
            pullRequests.last, MetadataCodec.clipboardBaselineProbe,
            "a reconnect must re-baseline, never apply state from across the gap",
        )
    }

    func testUnknownFutureKindIsDroppedNotApplied() async {
        copyLocally("local truth")
        let engine = makeEngine()
        pullResult = (changeCount: 60, clip: MetadataCodec.ClipboardClip(kindByte: 99, bytes: Data([1])))
        await engine.tick()
        XCTAssertEqual(pasteboard.string(forType: .string), "local truth", "unknown kind → drop, never guess")
    }
}
#endif
