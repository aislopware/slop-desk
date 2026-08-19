import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - VideoCapPolicyTests

/// Pins the ``VideoCapPolicy`` / ``VideoDeviceClass`` CROSSING (docs/22 §7): the tiers and the
/// resolution matrix are `slopdesk_workspace::responsive`'s, so what is asserted here is that each
/// case carries the byte the header names and each answering byte comes back as the right case — a
/// swapped map would hand a phone the Mac's ceiling with every rule test still green.
///
/// The store keeps the plain `liveVideoCap: Int` shape — the final test wires a cap-1 store and proves
/// the store's activation gate honours whatever Int the policy chose.
@MainActor
final class VideoCapPolicyTests: XCTestCase {
    // MARK: - The case-index crossing, both directions

    /// Each case carries its own byte to the ceiling door: a swap here is invisible to the crate.
    func testEachDeviceClassCrossesToItsOwnTier() {
        XCTAssertEqual(VideoCapPolicy.cap(for: .phone), 1, "phone tier")
        XCTAssertEqual(VideoCapPolicy.cap(for: .pad), 2, "pad tier")
        XCTAssertEqual(VideoCapPolicy.cap(for: .mac), 3, "mac tier")
    }

    /// And each answering byte comes back as the case it names, across the whole signal matrix — the
    /// three distinct answers prove the reverse map is not collapsing onto one case.
    func testEachAnsweringByteComesBackAsItsOwnCase() {
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: true, horizontalSizeClassCompact: true, userInterfaceIdiomPad: true),
            .mac, "isMac dominates — idiom/size-class are irrelevant",
        )
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: false, horizontalSizeClassCompact: false, userInterfaceIdiomPad: true),
            .pad, "regular pad → pad",
        )
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: false, horizontalSizeClassCompact: true, userInterfaceIdiomPad: true),
            .phone, "compact pad (slide-over) falls to the phone tier",
        )
    }

    /// The composed `cap(isMac:horizontalSizeClassCompact:userInterfaceIdiomPad:)` equals
    /// `cap(for: deviceClass(...))` across the whole signal matrix — the round trip through the byte
    /// and back loses nothing.
    func testComposedConvenienceMatchesResolveThenMap() {
        for isMac in [true, false] {
            for compact in [true, false] {
                for pad in [true, false] {
                    let composed = VideoCapPolicy.cap(
                        isMac: isMac, horizontalSizeClassCompact: compact, userInterfaceIdiomPad: pad,
                    )
                    let resolved = VideoCapPolicy.cap(for: VideoCapPolicy.deviceClass(
                        isMac: isMac, horizontalSizeClassCompact: compact, userInterfaceIdiomPad: pad,
                    ))
                    XCTAssertEqual(
                        composed,
                        resolved,
                        "composed == resolve-then-map (isMac=\(isMac) compact=\(compact) pad=\(pad))",
                    )
                }
            }
        }
    }

    // MARK: - the store honours the policy-chosen Int (cap-1 gates the 2nd desktop pane)

    /// The store keeps the plain `liveVideoCap: Int` shape; building it with the PHONE tier
    /// (``VideoCapPolicy/phoneCap`` = 1) makes the second `.desktop` pane gate — proving the
    /// policy-chosen Int flows straight into the activation ceiling.
    func testStoreBuiltWithPhoneCapGatesTheSecondRemoteGUIPane() {
        let phoneCap = VideoCapPolicy.cap(for: .phone)
        XCTAssertEqual(phoneCap, 1, "the phone tier admits exactly one live video pane")

        // Two `.desktop` panes, one per display. A desktop pane is ALWAYS its own OS window — it is
        // never a leaf in a tab (docs/DECISIONS.md 2026-07-22/23) — so the ingress that opens one is
        // what the cap is about, and one display id each keeps the second from revealing the first.
        let store = WorkspaceStore(
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: phoneCap,
        )
        store.attachLoopbackWorkspaceDocument()
        let ids = (0..<2).map { store.openDesktopWindow(displayID: UInt32($0)) }
        XCTAssertEqual(Set(ids).count, 2, "two distinct desktop windows")

        XCTAssertTrue(store.activateVideo(ids[0]), "the single phone-cap slot admits the first pane")
        XCTAssertFalse(store.activateVideo(ids[1]), "the second desktop pane is gated at the phone cap of 1")
    }
}
