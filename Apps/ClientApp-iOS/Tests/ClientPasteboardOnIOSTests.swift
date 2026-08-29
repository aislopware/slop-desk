import SlopDeskProtocol
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SlopDeskWorkspaceCore

/// The `UIPasteboard` half of `rust/slopdesk-apple-pasteboard`, which NOTHING else can assert.
///
/// The `AppKit` half runs under `cargo test` on the macOS host; the `UIKit` half cannot, because
/// there is no iOS host to run a cargo test on and a simulator is not one. So its only assertions
/// are here, driving the same `slopdesk_clipboard_*` doors the Mac drives and reaching
/// `UIPasteboard` underneath them. Without this file the phone's board is a framework wrapper
/// nothing ever ran.
///
/// Every board here is NAMED. `UIPasteboard.general` is the user's own clipboard even inside a test
/// process — there is no per-process general board on iOS the way `NSPasteboard(name:)` gives one —
/// so a suite that touched it would clobber whatever the person running it had copied.
///
/// The one thing not asserted here is the "Allow Paste?" alert itself: a modal permission prompt is
/// not observable from a host-less logic bundle. What IS asserted is the fact the tick loops branch
/// on — that this platform reports an unattended content read as NOT permitted — since a wrong
/// answer there is what would put that alert on screen once a second.
final class ClientPasteboardOnIOSTests: XCTestCase {
    private var board: ClientPasteboard!

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func setUp() async throws {
        board = ClientPasteboard(name: "slopdesk.tests.ios.\(UUID().uuidString)")
        board.clear()
    }

    /// The platform fact the monitor and the sync engine both branch on. macOS answers `true` and
    /// `swift test` pins that; only this triple can pin the other arm.
    func testThisPlatformRefusesAnUnattendedContentRead() {
        XCTAssertFalse(
            ClientPasteboard.unattendedContentReadIsPermitted,
            "iOS raises a modal Allow Paste? alert — the tick loops must never read content off a timer",
        )
    }

    /// Write → the count moves → read it back → clear. The whole surface `UIPasteboard` backs, in
    /// the order a copy-then-paste actually happens.
    func testTextRoundTripsThroughTheBoard() {
        let before = board.changeCount
        XCTAssertTrue(board.write("typed on the phone"))
        XCTAssertNotEqual(board.changeCount, before, "a write advances the counter the poll reads")
        XCTAssertTrue(board.hasPlainText, "the probe sees it without the content crossing")
        XCTAssertEqual(board.plainText, "typed on the phone")
        board.clear()
        XCTAssertFalse(board.hasPlainText, "cleared is empty, not stale")
        XCTAssertNil(board.plainText)
    }

    /// An empty write is a refusal, and a refusal leaves the board ALONE. The validate-then-clear
    /// contract, on the half where `setItems` replaces outright rather than accumulating.
    func testAnEmptyWriteRefusesWithoutTouchingTheBoard() {
        board.write("keep me")
        XCTAssertFalse(board.write(""), "empty is not a clip")
        XCTAssertEqual(board.plainText, "keep me", "a refused write never destroys what was there")
    }

    /// The `UIKit` `Flavour` spellings against the framework's own UTIs — this crate's `uikit.rs`
    /// reads them from `objc2-uniform-type-identifiers`' `extern` statics, and a wrong static would
    /// make every refusal below silently pass through.
    ///
    /// The marker is asked for rather than typed, for the reason `one-pasteboard-clip` bans the
    /// literal in Swift: a copy here would keep passing against a UTI the fold had stopped
    /// recognising.
    func testAConcealedBoardIsNotSyncable() {
        board.write("hunter2")
        XCTAssertTrue(board.isSyncable, "ordinary text may leave the device")

        UIPasteboard(name: UIPasteboard.Name(board.name), create: true)?
            .setItems([[ClientPasteboard.concealedTypeIdentifier: Data([1])]])
        XCTAssertFalse(board.isSyncable, "a password manager's clip stays on the device")
    }

    /// A file copy is a path, and a path means nothing on the other machine.
    func testAFileCopyIsNotSyncable() {
        UIPasteboard(name: UIPasteboard.Name(board.name), create: true)?
            .setItems([[UTType.fileURL.identifier: Data("file:///var/x".utf8)]])
        XCTAssertFalse(board.isSyncable)
    }

    /// A wire clip applied to the phone's board — the direction clipboard sync is WHOLE on iOS,
    /// because writing asks no permission. Also the loop-shaped pass that stands in for the
    /// `AppKit` half's leak test: `docs/57` §3 wants every wrapper exercised repeatedly, and there
    /// is no `cargo test` on this triple to run one in.
    func testApplyingWireClipsRepeatedlyLeavesTheBoardCoherent() {
        for index in 0..<200 {
            let clip = MetadataCodec.ClipboardClip(kind: .text, bytes: Data("clip \(index)".utf8))
            XCTAssertTrue(board.apply(clip))
            board.clear()
        }
        XCTAssertNil(board.plainText, "200 write/clear rounds end where they started")
    }

    /// An unknown future kind byte is refused, board untouched — the forward-tolerance the wire
    /// promises, taken at the last possible moment.
    func testAnUnknownKindIsRefusedWithoutTouchingTheBoard() {
        board.write("local truth")
        XCTAssertFalse(board.apply(MetadataCodec.ClipboardClip(kindByte: 99, bytes: Data([1]))))
        XCTAssertEqual(board.plainText, "local truth")
    }
}
