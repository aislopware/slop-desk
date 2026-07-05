import Foundation
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// E14 / WI-6 (K6): the kitty desktop-notification protocol (OSC 99) parse in ``HostOutputSniffer``.
///
/// The host turns `ESC ] 99 ; <metadata> ; <payload> ST` into the EXISTING type-25
/// ``WireMessage/notification(title:body:)`` (no new wire). These tests pin the BOUNDED,
/// validate-then-drop subset the plan specifies — title/body, base64 (`e=1`), and the
/// `i=<id>` replace-by-id / `d=0` chunked-continuation assembly — plus the documented ceiling
/// (an unsupported `p`/`e`, a malformed shape, or an oversized payload is DROPPED, never trusted).
///
/// Every test FAILS on the un-fixed code (no `case "99"`): an OSC 99 then falls to the `default`
/// arm of `finishOSC` and emits nothing, so the `.notification` assertions fail
/// (revert-to-confirm-fail).
final class OSC99ParseTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\" // ESC \

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func observeWhole(_ s: String) -> [WireMessage] {
        HostOutputSniffer().observe(bytes(s))
    }

    /// The `.notification` subsequence (the fused sniffer may interleave titles/bells/progress).
    private func notificationsOnly(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter { if case .notification = $0 { return true }
            return false
        }
    }

    // MARK: Plain title-only payload → notification body (the canonical kitty-notification form)

    func testKittyPlainPayloadEmitsNotificationBody() {
        // `ESC]99;;Build finished ESC\` — empty metadata, a single (default-title) payload. We fold a
        // title-only kitty notification into the .notification BODY (empty title → client pane-title
        // fallback), matching the OSC-9 path and the plan's expected `body == "Build finished"`.
        XCTAssertEqual(
            observeWhole("\(ESC)]99;;Build finished\(ST)"),
            [.notification(title: "", body: "Build finished")],
        )
    }

    func testKittyPlainPayloadWithBELTerminator() {
        XCTAssertEqual(
            observeWhole("\(ESC)]99;;Tests passed\(BEL)"),
            [.notification(title: "", body: "Tests passed")],
        )
    }

    func testKittyExplicitTitlePayloadFoldsToBody() {
        // `p=title` is the kitty default; an explicit `p=title` behaves identically (folded to body).
        XCTAssertEqual(
            observeWhole("\(ESC)]99;p=title;Deploy done\(ST)"),
            [.notification(title: "", body: "Deploy done")],
        )
    }

    // MARK: p=body routes the payload to the body field

    func testKittyBodyPayloadRoutesToBody() {
        XCTAssertEqual(
            observeWhole("\(ESC)]99;p=body;the body text\(ST)"),
            [.notification(title: "", body: "the body text")],
        )
    }

    // MARK: base64 (e=1) decoding

    func testKittyBase64PayloadDecodes() {
        // Build the base64 at runtime (no hard-coded literal): `e=1` must decode it back to the text.
        let plain = "café 🚀 built"
        let b64 = Data(plain.utf8).base64EncodedString()
        XCTAssertEqual(
            observeWhole("\(ESC)]99;e=1;\(b64)\(ST)"),
            [.notification(title: "", body: plain)],
        )
    }

    func testKittyInvalidBase64Dropped() {
        // `e=1` with a payload that is NOT valid base64 → dropped (validate-then-drop), no notification.
        XCTAssertEqual(notificationsOnly(observeWhole("\(ESC)]99;e=1;not*base64!\(ST)")), [])
    }

    // MARK: chunked continuation (d=0) + replace-by-id (i=) assembly → title + body

    func testKittyChunkedTitleThenBodyAssembled() {
        // Two OSC-99 sequences sharing `i=1`: the first (d=0, default-title) seeds the title; the
        // second (default d=1, p=body) supplies the body and FINALIZES — one .notification, title+body.
        let stream =
            "\(ESC)]99;i=1:d=0;My Title\(ST)" // d=0 → buffered, emits nothing yet
            + "\(ESC)]99;i=1:p=body;The body\(ST)" // d default 1 → finalize
        let msgs = observeWhole(stream)
        XCTAssertEqual(msgs, [.notification(title: "My Title", body: "The body")])
    }

    func testKittyContinuationChunkEmitsNothingUntilDone() {
        // A lone `d=0` chunk must NOT emit — it is incomplete (the finish chunk never arrived).
        XCTAssertEqual(
            notificationsOnly(observeWhole("\(ESC)]99;i=7:d=0;partial\(ST)")),
            [],
        )
    }

    // MARK: malformed / unsupported shapes are dropped (the bounded ceiling)

    func testKittyMissingPayloadSeparatorDropped() {
        // `ESC]99;text` has only ONE ';' (no metadata/payload separator) → malformed → dropped.
        XCTAssertEqual(notificationsOnly(observeWhole("\(ESC)]99;text\(ST)")), [])
    }

    func testKittyEmptyPayloadDropped() {
        // `ESC]99;;` — empty metadata AND empty payload → nothing to surface → dropped.
        XCTAssertEqual(notificationsOnly(observeWhole("\(ESC)]99;;\(ST)")), [])
    }

    func testKittyCapabilityQueryDropped() {
        // `p=?` is the capability query — an UNSUPPORTED payload type. It is DROPPED, never ANSWERED
        // (no dead capability-query path — the documented honesty ceiling).
        XCTAssertEqual(notificationsOnly(observeWhole("\(ESC)]99;p=?;\(ST)")), [])
    }

    func testKittyUnknownEncodingDropped() {
        // An encoding `e` we do not understand (only 0/1 are defined) → dropped, never trusted.
        XCTAssertEqual(notificationsOnly(observeWhole("\(ESC)]99;e=2;hello\(ST)")), [])
    }

    func testKittyOversizedPayloadDropped() {
        // A payload beyond the per-chunk notifyOscCap (1024) is dropped before any parse.
        let huge = String(repeating: "x", count: 2000)
        XCTAssertEqual(notificationsOnly(observeWhole("\(ESC)]99;;\(huge)\(ST)")), [])
    }

    // MARK: unsupported metadata keys are ignored, not fatal (urgency etc.)

    func testKittyUnsupportedMetadataKeysIgnored() {
        // Urgency `u=2` + an unknown key are ignored (the ceiling); the notification still fires.
        XCTAssertEqual(
            observeWhole("\(ESC)]99;u=2:i=5:z=q;ship it\(ST)"),
            [.notification(title: "", body: "ship it")],
        )
    }

    // MARK: the OSC-99 arm does not disturb the other notification paths

    func testNon99NotificationPathsUntouched() {
        // OSC 9 free-text and OSC 777 notify must still fire byte-identically — the new arm is additive.
        XCTAssertEqual(
            observeWhole("\(ESC)]9;build done\(BEL)"),
            [.notification(title: "", body: "build done")],
        )
        XCTAssertEqual(
            observeWhole("\(ESC)]777;notify;CI;all green\(BEL)"),
            [.notification(title: "CI", body: "all green")],
        )
        // A title OSC is still a title, not swallowed by the 99 path.
        XCTAssertEqual(observeWhole("\(ESC)]2;win\(BEL)"), [.title("win")])
    }

    // MARK: anti-spoof — an OSC 99 embedded in a DCS string body must not fabricate a notification

    func testKittyEmbeddedInStringSequenceSwallowed() {
        // `ESC P` (DCS) … `ESC]99;;spoof` … `ESC \` (ST): a conformant terminal swallows the whole
        // string body — the embedded OSC 99 must NOT fire a phantom notification (R9 #4 parity).
        let dcsSpoof = "\(ESC)P\(ESC)]99;;spoof\(ST)"
        XCTAssertEqual(notificationsOnly(observeWhole(dcsSpoof)), [])
        // A real OSC 99 after the swallowed string still fires (clean resync).
        XCTAssertEqual(
            observeWhole("\(ESC)]99;;real\(ST)"),
            [.notification(title: "", body: "real")],
        )
    }

    // MARK: chunk-boundary invariance — finishOSC is reached identically at every split

    func testKittyChunkInvariance() {
        let raw = bytes("\(ESC)]99;e=1;\(Data("hi there".utf8).base64EncodedString())\(BEL)")
        let whole = HostOutputSniffer().observe(raw)
        XCTAssertEqual(whole, [.notification(title: "", body: "hi there")])
        for size in 1...raw.count {
            let s = HostOutputSniffer()
            var out: [WireMessage] = []
            var i = 0
            while i < raw.count {
                let end = min(i + size, raw.count)
                out.append(contentsOf: s.observe(Array(raw[i..<end])))
                i = end
            }
            XCTAssertEqual(out, whole, "diverged at chunk size \(size)")
        }
    }
}
