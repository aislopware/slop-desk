import AppKit
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// ``HostClipboardPerformer`` — the host half of clipboard sync (verbs 15/16) against a NAMED
/// pasteboard (the `ClientPasteboard` test idiom: the machine-global `.general` board is shared
/// state a parallel test run or the user's own ⌘C would clobber; the pasteboard server needs no
/// window-server session, so this stays hang-safe).
final class HostClipboardPerformerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var state: HostClipboardPerformer.SyncState!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(
            name: NSPasteboard.Name("slopdesk.tests.hostclipboard.\(UUID().uuidString)"),
        )
        pasteboard.clearContents()
        state = HostClipboardPerformer.SyncState()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        state = nil
        super.tearDown()
    }

    /// A tiny valid PNG (1×1 opaque pixel), generated at runtime — no binary fixture in the repo.
    private static let onePixelPNG: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        )
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not synthesize the 1x1 PNG fixture")
        }
        return png
    }()

    private func respond(verb: MetadataVerb, payload: Data) -> WireMessage? {
        HostClipboardPerformer.response(
            requestID: 1, verb: verb.rawValue, payload: payload,
            pasteboard: pasteboard, state: state,
        )
    }

    private func decodeStatus(_ message: WireMessage?) -> (status: UInt8, payload: Data)? {
        guard case let .metadataResponse(_, status, payload) = message else { return nil }
        return (status, payload)
    }

    // MARK: Routing

    func testNonClipboardVerbsFallThroughToTheBuilder() {
        for verb in MetadataVerb.allCases where verb != .setClipboard && verb != .readClipboard {
            XCTAssertNil(respond(verb: verb, payload: Data()), "\(verb) must return nil")
        }
    }

    // MARK: setClipboard (verb 15)

    func testSetTextWritesThePasteboard() {
        let clip = MetadataCodec.ClipboardClip(kind: .text, bytes: Data("từ client".utf8))
        let reply = decodeStatus(respond(verb: .setClipboard, payload: MetadataCodec.encodeClipboardSet(clip)))
        XCTAssertEqual(reply?.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(reply?.payload, Data(), "side-effect-only verb replies empty")
        XCTAssertEqual(pasteboard.string(forType: .string), "từ client")
    }

    func testSetImageWritesPNGAndTIFFFlavors() {
        let clip = MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: Self.onePixelPNG)
        let reply = decodeStatus(respond(verb: .setClipboard, payload: MetadataCodec.encodeClipboardSet(clip)))
        XCTAssertEqual(reply?.status, MetadataStatus.ok.rawValue)
        XCTAssertEqual(pasteboard.data(forType: .png), Self.onePixelPNG, "PNG flavor is byte-exact")
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "TIFF twin for apps that only read public.tiff")
    }

    func testSetGarbagePNGDoesNotDestroyTheCurrentClip() {
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let clip = MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: Data([1, 2, 3]))
        let reply = decodeStatus(respond(verb: .setClipboard, payload: MetadataCodec.encodeClipboardSet(clip)))
        XCTAssertEqual(reply?.status, MetadataStatus.error.rawValue)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me", "validate BEFORE clearing")
    }

    func testSetHostilePayloadsAnswerError() {
        // Empty payload, unknown kind, empty text — all .error, never a trap, always a reply.
        for payload in [Data(), Data([200, 1]), Data([MetadataCodec.ClipboardKind.text.rawValue])] {
            let reply = decodeStatus(respond(verb: .setClipboard, payload: payload))
            XCTAssertEqual(reply?.status, MetadataStatus.error.rawValue)
        }
    }

    func testSetNonUTF8TextAnswersError() {
        let payload = Data([MetadataCodec.ClipboardKind.text.rawValue, 0xFF, 0xFE])
        XCTAssertEqual(
            decodeStatus(respond(verb: .setClipboard, payload: payload))?.status,
            MetadataStatus.error.rawValue,
        )
    }

    // MARK: readClipboard (verb 16)

    private func pull(lastSeen: Int64) -> (changeCount: Int64, clip: MetadataCodec.ClipboardClip?)? {
        let reply = decodeStatus(respond(
            verb: .readClipboard,
            payload: MetadataCodec.encodeClipboardReadRequest(lastSeenChangeCount: lastSeen),
        ))
        guard reply?.status == MetadataStatus.ok.rawValue, let payload = reply?.payload else { return nil }
        return try? MetadataCodec.decodeClipboardReadResponse(payload)
    }

    func testBaselineProbeAnswersCountOnly() {
        pasteboard.clearContents()
        pasteboard.setString("pre-connection clip", forType: .string)
        let result = pull(lastSeen: MetadataCodec.clipboardBaselineProbe)
        XCTAssertEqual(result?.changeCount, Int64(pasteboard.changeCount))
        XCTAssertNil(result?.clip, "a baseline probe must never ship (stale) content")
    }

    func testChangedTextClipIsShipped() {
        let baseline = pull(lastSeen: MetadataCodec.clipboardBaselineProbe)
        pasteboard.clearContents()
        pasteboard.setString("host copy", forType: .string)
        let result = pull(lastSeen: baseline?.changeCount ?? 0)
        XCTAssertEqual(result?.clip?.kind, .text)
        XCTAssertEqual(result?.clip.map(\.bytes), Data("host copy".utf8))
    }

    func testUnchangedCountAnswersNoClip() {
        pasteboard.clearContents()
        pasteboard.setString("stable", forType: .string)
        let first = pull(lastSeen: MetadataCodec.clipboardBaselineProbe)
        let second = pull(lastSeen: first?.changeCount ?? 0)
        XCTAssertNil(second?.clip, "same changeCount → count-only answer, no content re-ship")
    }

    func testClientPushIsNeverEchoedBack() {
        let baseline = pull(lastSeen: MetadataCodec.clipboardBaselineProbe)
        let clip = MetadataCodec.ClipboardClip(kind: .text, bytes: Data("pushed from client".utf8))
        _ = respond(verb: .setClipboard, payload: MetadataCodec.encodeClipboardSet(clip))
        // The client pulls with its PRE-push last-seen count (it has not polled since): the count
        // advanced, but the content is its own push — the host must answer "unchanged".
        let result = pull(lastSeen: baseline?.changeCount ?? 0)
        XCTAssertEqual(result?.changeCount, Int64(pasteboard.changeCount))
        XCTAssertNil(result?.clip, "the echo guard must suppress the client's own clip")
    }

    func testHostCopyAfterClientPushIsShipped() {
        let clip = MetadataCodec.ClipboardClip(kind: .text, bytes: Data("pushed".utf8))
        _ = respond(verb: .setClipboard, payload: MetadataCodec.encodeClipboardSet(clip))
        let afterPush = pull(lastSeen: MetadataCodec.clipboardBaselineProbe)
        pasteboard.clearContents()
        pasteboard.setString("native host copy", forType: .string)
        let result = pull(lastSeen: afterPush?.changeCount ?? 0)
        XCTAssertEqual(result?.clip.map(\.bytes), Data("native host copy".utf8))
    }

    func testImageClipPrefersPNGOverText() {
        pasteboard.clearContents()
        pasteboard.setData(Self.onePixelPNG, forType: .png)
        pasteboard.setString("caption", forType: .string)
        let clip = HostClipboardPerformer.currentClip(pasteboard)
        XCTAssertEqual(clip?.kind, .imagePNG)
        XCTAssertEqual(clip?.bytes, Self.onePixelPNG)
    }

    func testTIFFOnlyClipIsTranscodedToPNG() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: Self.onePixelPNG)?.tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        let clip = HostClipboardPerformer.currentClip(pasteboard)
        XCTAssertEqual(clip?.kind, .imagePNG)
        XCTAssertNotNil(clip.flatMap { NSBitmapImageRep(data: $0.bytes) }, "transcoded bytes decode as an image")
    }

    func testFileCopyClipIsNotShipped() {
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/x", forType: .fileURL)
        pasteboard.setString("x", forType: .string)
        XCTAssertNil(HostClipboardPerformer.currentClip(pasteboard), "a host file path is meaningless remotely")
    }

    func testReadRequestTruncatedAnswersError() {
        XCTAssertEqual(
            decodeStatus(respond(verb: .readClipboard, payload: Data([0, 1])))?.status,
            MetadataStatus.error.rawValue,
        )
    }
}
