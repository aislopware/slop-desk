import XCTest
@testable import AislopdeskClientUI

// MARK: - VideoCapPolicyTests

/// Pins the pure per-device live-video ceiling policy (``VideoCapPolicy`` / ``VideoDeviceClass``,
/// docs/22 §7, ITEM #5): the number the app injects into ``WorkspaceStore/liveVideoCap`` differs by
/// device class because the `.remoteGUI` video stack (2 UDP sockets + `VTDecompressionSession` +
/// `CVDisplayLink`) scales with the host's decode/compositing headroom — a phone can hold the fewest
/// concurrent windows, a Mac the most.
///
/// These are pure, synchronously-runnable assertions (no SwiftUI, no platform calls): the policy is a
/// value-typed function so the per-tier numbers and the resolution matrix are pinned in one place. The
/// store keeps the plain `liveVideoCap: Int` shape — the final test wires a cap-1 store and proves the
/// store's activation gate honours whatever Int the policy chose.
@MainActor
final class VideoCapPolicyTests: XCTestCase {
    // MARK: - Tier values: distinct + ordered (phone ≤ pad ≤ mac)

    /// The three tiers are the documented constants and are strictly ordered phone < pad < mac, so a
    /// higher-headroom device class always admits at least as many concurrent video panes.
    func testTierValuesAreDistinctAndOrdered() {
        XCTAssertEqual(VideoCapPolicy.phoneCap, 1, "phone tier")
        XCTAssertEqual(VideoCapPolicy.padCap, 2, "pad tier")
        XCTAssertEqual(VideoCapPolicy.macCap, 3, "mac tier")

        // Distinct.
        XCTAssertEqual(
            Set([VideoCapPolicy.phoneCap, VideoCapPolicy.padCap, VideoCapPolicy.macCap]).count,
            3,
            "the three tiers are distinct",
        )
        // Ordered (the monotone-headroom contract).
        XCTAssertLessThanOrEqual(VideoCapPolicy.phoneCap, VideoCapPolicy.padCap, "phone ≤ pad")
        XCTAssertLessThanOrEqual(VideoCapPolicy.padCap, VideoCapPolicy.macCap, "pad ≤ mac")
        XCTAssertLessThan(VideoCapPolicy.phoneCap, VideoCapPolicy.macCap, "phone < mac (strictly)")
    }

    /// `cap(for:)` maps each device class to its documented tier value.
    func testCapForDeviceClassMapsEachTier() {
        XCTAssertEqual(VideoCapPolicy.cap(for: .phone), VideoCapPolicy.phoneCap)
        XCTAssertEqual(VideoCapPolicy.cap(for: .pad), VideoCapPolicy.padCap)
        XCTAssertEqual(VideoCapPolicy.cap(for: .mac), VideoCapPolicy.macCap)
    }

    // MARK: - deviceClass resolution matrix

    /// macOS is always the mac tier regardless of the (irrelevant) idiom / size-class inputs.
    func testDeviceClassMacAlwaysMacRegardlessOfOtherSignals() {
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: true, horizontalSizeClassCompact: false, userInterfaceIdiomPad: false),
            .mac,
        )
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: true, horizontalSizeClassCompact: true, userInterfaceIdiomPad: true),
            .mac, "isMac dominates — idiom/size-class are irrelevant",
        )
    }

    /// A pad idiom resolves `.pad` ONLY when it is NOT compact; a compact pad (slide-over / a
    /// phone-narrow split) falls to the conservative phone tier.
    func testDeviceClassPadResolvesPadOnlyWhenRegular() {
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: false, horizontalSizeClassCompact: false, userInterfaceIdiomPad: true),
            .pad, "regular pad → pad",
        )
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: false, horizontalSizeClassCompact: true, userInterfaceIdiomPad: true),
            .phone, "compact pad (slide-over) falls to the phone tier",
        )
    }

    /// A non-pad idiom (iPhone) is always the phone tier, compact or not.
    func testDeviceClassPhoneIdiomAlwaysPhone() {
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: false, horizontalSizeClassCompact: true, userInterfaceIdiomPad: false),
            .phone, "compact phone → phone",
        )
        XCTAssertEqual(
            VideoCapPolicy.deviceClass(isMac: false, horizontalSizeClassCompact: false, userInterfaceIdiomPad: false),
            .phone, "a (hypothetical) regular phone is still the phone tier",
        )
    }

    // MARK: - composed convenience

    /// The composed `cap(isMac:horizontalSizeClassCompact:userInterfaceIdiomPad:)` equals
    /// `cap(for: deviceClass(...))` across the whole signal matrix — one call resolves the tier AND
    /// maps it to the ceiling.
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
        // Spot-check the load-bearing tiers through the composed call.
        XCTAssertEqual(
            VideoCapPolicy.cap(isMac: true, horizontalSizeClassCompact: false, userInterfaceIdiomPad: false),
            3,
        )
        XCTAssertEqual(
            VideoCapPolicy.cap(isMac: false, horizontalSizeClassCompact: false, userInterfaceIdiomPad: true),
            2,
        )
        XCTAssertEqual(
            VideoCapPolicy.cap(isMac: false, horizontalSizeClassCompact: true, userInterfaceIdiomPad: true),
            1,
        )
        XCTAssertEqual(
            VideoCapPolicy.cap(isMac: false, horizontalSizeClassCompact: true, userInterfaceIdiomPad: false),
            1,
        )
    }

    // MARK: - the store honours the policy-chosen Int (cap-1 gates the 2nd remoteGUI pane)

    /// The store keeps the plain `liveVideoCap: Int` shape; building it with the PHONE tier
    /// (``VideoCapPolicy/phoneCap`` = 1) makes the second `.remoteGUI` pane gate — proving the
    /// policy-chosen Int flows straight into the activation ceiling.
    func testStoreBuiltWithPhoneCapGatesTheSecondRemoteGUIPane() {
        let phoneCap = VideoCapPolicy.cap(for: .phone)
        XCTAssertEqual(phoneCap, 1, "the phone tier admits exactly one live video pane")

        // A single-remoteGUI-pane canvas grown to two remoteGUI leaves (no stray default terminal pane).
        let rootID = PaneID()
        let spec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let store = WorkspaceStore(
            restoring: Workspace.make(panes: [(rootID, spec)], focused: rootID),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: phoneCap,
        )
        store.addPane(kind: .remoteGUI)
        let ids = store.workspace.canvas.allIDs()
        XCTAssertEqual(ids.count, 2, "two remoteGUI leaves")

        XCTAssertTrue(store.activateVideo(ids[0]), "the single phone-cap slot admits the first pane")
        XCTAssertFalse(store.activateVideo(ids[1]), "the second remoteGUI pane is gated at the phone cap of 1")
    }
}
