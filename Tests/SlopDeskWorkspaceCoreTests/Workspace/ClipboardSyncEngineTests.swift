#if os(macOS)
import AppKit
import SlopDeskProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``ClipboardSyncEngine`` tick logic against a NAMED board + fake push/pull seams (no live socket):
/// push-on-local-change with pending retry, baseline-first pull, and the loop-safety contract (our
/// own applies never bounce back, pulled clips never re-apply).
///
/// ⚠️ WHAT IS NOT HERE ANY MORE, AND WHY. The four rules about what may leave a machine — image
/// before text, the concealed refusal, the file-copy refusal, the content cap — are
/// `rust/slopdesk-clipboard`'s, asserted against its own fake board and again through the HOST's
/// end. A Swift suite restating them would be the third copy of a rule Swift no longer implements,
/// which is the very drift this port closed. What is still Swift's, and so still here, is the tick:
/// the ORDER the engine does things in, and that ``ClipboardSyncEngine/noteAttendedLocalRead(_:)``
/// consults the board's declared types BEFORE it builds a clip.
///
/// `NSPasteboard` appears below only to SEED and to READ BACK raw flavours — states the door's write
/// surface deliberately cannot produce (a board declaring two types at once) and a flavour it
/// deliberately does not answer for (the TIFF twin). Every assertion about behaviour goes through
/// ``ClientPasteboard``.
@MainActor
final class ClipboardSyncEngineTests: XCTestCase {
    /// The seeding/read-back handle on the same board ``board`` names.
    private var pasteboard: NSPasteboard!
    private var board: ClientPasteboard!
    private var pushed: [MetadataCodec.ClipboardClip] = []
    private var pushResult = true
    private var pullRequests: [Int64] = []
    private var pullResult: (changeCount: Int64, clip: MetadataCodec.ClipboardClip?)?

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func setUp() async throws {
        let name = "slopdesk.tests.syncengine.\(UUID().uuidString)"
        board = ClientPasteboard(name: name)
        pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
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
        board = nil
    }

    /// The concealed marker, asked for rather than typed: a literal here would keep passing against
    /// a UTI `rust/slopdesk-clipboard` had stopped recognising.
    private static let concealedType = NSPasteboard.PasteboardType(
        ClientPasteboard.concealedTypeIdentifier,
    )

    /// `attendedReadsFrom` is the seam the app shells pass their store through — the tests that drive
    /// the whole store → engine → host chain give it one, the rest leave it `nil` exactly as a headless
    /// engine has.
    private func makeEngine(attendedReadsFrom store: WorkspaceStore? = nil) -> ClipboardSyncEngine {
        ClipboardSyncEngine(
            board: board,
            attendedReadsFrom: store,
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
        board.write(text)
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

    /// The tick's snapshot takes the fold's refusals — pinned here at the SEAM only (one board the
    /// fold refuses, reaching the engine), not rule by rule; see the type docs.
    func testTheTickPushesNothingTheFoldRefuses() async {
        let engine = makeEngine()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("1", forType: Self.concealedType)
        await engine.tick()
        XCTAssertEqual(pushed, [], "password-manager clips stay local")
    }

    // MARK: The ATTENDED door (the only client→host path a phone has)

    /// A clip the TICK will never snapshot still reaches the host once the user's own gesture reads it.
    ///
    /// The board state here is the platform-free stand-in for the phone's whole predicament: a clip the
    /// tick has already decided not to push (`testLaunchTimeClipIsNotPushed` pins that it never will).
    /// On iOS EVERY clip is in that position, because `captureLocalChange()` may not read content off a
    /// timer. Before ``ClipboardSyncEngine/noteAttendedLocalRead(_:)`` existed there was no second door,
    /// so a copy on the phone reached the host's pasteboard by no path at all — the paste paths the type
    /// docs pointed at all TYPE the text into a pane and none of them ever called `setClipboard`.
    func testAnAttendedReadPushesAClipTheTickWillNeverSee() async {
        copyLocally("copied before the engine watched")
        let engine = makeEngine()
        await engine.tick()
        XCTAssertEqual(pushed, [], "the tick has passed on this clip and never revisits it")
        engine.noteAttendedLocalRead("copied before the engine watched")
        await engine.tick()
        XCTAssertEqual(
            pushed.map(\.bytes), [Data("copied before the engine watched".utf8)],
            "the user's own read is the door the timer cannot open",
        )
        XCTAssertEqual(pushed.first?.kind, .text)
    }

    /// The attended door inherits the retry machinery rather than growing its own.
    func testAnAttendedReadRetriesUntilTheHostTakesIt() async {
        let engine = makeEngine()
        pushResult = false
        engine.noteAttendedLocalRead("flaky attended")
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pushed.count, 2, "a rejected attended push retries every tick, like any other")
        pushResult = true
        await engine.tick()
        await engine.tick()
        XCTAssertEqual(pushed.count, 3, "accepted → pending cleared")
    }

    /// A CONCEALED clip stays on the device even when the user pastes it somewhere on purpose. The
    /// paste is one machine's; the board is both machines'.
    ///
    /// This is the ORDER assertion the Swift side still owes: the attended door is handed text that
    /// is already in hand, so nothing forces it to consult the board at all — and if it did not, a
    /// password would ship. It takes the refusal from ``ClientPasteboard/isSyncable``, which reads
    /// the DECLARED types and so costs no second content read.
    func testAnAttendedReadConsultsTheBoardBeforeBuildingAClip() async {
        let engine = makeEngine()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("1", forType: Self.concealedType)
        XCTAssertFalse(board.isSyncable, "the board itself refuses — that is what the door must ask")
        engine.noteAttendedLocalRead("hunter2")
        await engine.tick()
        XCTAssertEqual(pushed, [], "a password the user pasted into a pane must not land on the host board")
    }

    /// Empty text and over-cap text are dropped, and the ECHO guard holds on this door too: a clip we
    /// just applied FROM the host is not shipped back to it.
    func testTheAttendedDoorDropsEmptyOverCapAndOurOwnApply() async {
        let engine = makeEngine()
        engine.noteAttendedLocalRead("")
        await engine.tick()
        XCTAssertEqual(pushed, [], "empty is not a clip")

        engine.noteAttendedLocalRead(
            String(repeating: "x", count: MetadataCodec.maxClipboardContentBytes + 1),
        )
        await engine.tick()
        XCTAssertEqual(pushed, [], "over-cap is dropped, never truncated")

        pullResult = (changeCount: 41, clip: MetadataCodec.ClipboardClip(
            kind: .text, bytes: Data("from host".utf8),
        ))
        await engine.tick()
        engine.noteAttendedLocalRead("from host")
        await engine.tick()
        XCTAssertEqual(pushed, [], "pasting what the host just sent must not bounce it back")
    }

    /// The whole chain, wired the way the app shells wire it: the store's attended read is the engine's
    /// push. `attendedReadsFrom:` is the ONE place the seam is installed, so neither shell can wire it
    /// its own way.
    func testTheStoresAttendedReadReachesTheHost() async {
        let store = WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
        let engine = makeEngine(attendedReadsFrom: store)
        store.clipboardTextProvider = { "typed on the phone" }
        XCTAssertEqual(store.currentLocalClipboard(), "typed on the phone")
        await engine.tick()
        XCTAssertEqual(
            pushed.map(\.bytes), [Data("typed on the phone".utf8)],
            "every caller of currentLocalClipboard() is a paste the user asked for — and now a sync",
        )
    }

    /// Turning clipboard HISTORY off says "do not retain my clips", not "do not let my two machines
    /// share a clipboard". The ring stays empty; the host still gets the clip.
    func testTheHistoryToggleDoesNotGateTheSync() async {
        let store = WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
        let engine = makeEngine(attendedReadsFrom: store)
        stateSetting("general.record-clipboard-history", false)
        store.clipboardTextProvider = { "not retained, still shared" }
        _ = store.currentLocalClipboard()
        XCTAssertTrue(store.clipboardRing.isEmpty, "recording is off — nothing is retained")
        await engine.tick()
        XCTAssertEqual(pushed.map(\.bytes), [Data("not retained, still shared".utf8)])
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
        XCTAssertEqual(board.plainText, "from host")
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
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "the AppKit half declares the twin so every app can paste")
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
        XCTAssertEqual(board.plainText, "local truth", "unknown kind → drop, never guess")
    }
}
#endif
