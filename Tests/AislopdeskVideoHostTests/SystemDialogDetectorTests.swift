#if os(macOS)
import CoreGraphics
import XCTest
@testable import AislopdeskVideoHost

/// `SystemDialogDetector` — the pure classifier that decides which on-screen windows are system
/// prompts to surface in their own pane (the user's case: a SecurityAgent login/password dialog).
/// Values mirror the HW probe (2026-06-12): SecurityAgent prompt at layer 1000, 260×312, onScreen.
final class SystemDialogDetectorTests: XCTestCase {
    private typealias Snap = SystemDialogDetector.WindowSnapshot

    private func snap(
        _ id: UInt32,
        owner: String,
        bundle: String,
        onScreen: Bool = true,
        w: CGFloat = 260,
        h: CGFloat = 312,
        title: String = "",
    ) -> Snap {
        Snap(
            windowID: id,
            ownerName: owner,
            bundleID: bundle,
            isOnScreen: onScreen,
            title: title,
            frame: CGRect(x: 830, y: 201, width: w, height: h),
        )
    }

    // The HW-probed SecurityAgent password prompt → surfaced + flagged secure.
    func testSecurityAgentPromptIsSecureDialog() {
        let d = SystemDialogDetector.classify(snap(1966, owner: "SecurityAgent", bundle: "com.apple.SecurityAgent"))
        XCTAssertEqual(d?.windowID, 1966)
        XCTAssertEqual(d?.owner, "SecurityAgent")
        XCTAssertEqual(d?.width, 260)
        XCTAssertEqual(d?.height, 312)
        XCTAssertEqual(d?.isSecure, true)
    }

    // Touch ID / LocalAuthentication agent — also secure.
    func testCoreauthdIsSecureDialog() {
        XCTAssertEqual(
            SystemDialogDetector.classify(snap(7, owner: "coreauthd", bundle: "com.apple.coreauthd"))?.isSecure,
            true,
        )
    }

    // Matched by OWNER NAME even when the bundle id is unexpected/blank (resilient across builds).
    func testOwnerNameMatchWithoutBundle() {
        XCTAssertNotNil(SystemDialogDetector.classify(snap(8, owner: "SecurityAgent", bundle: "")))
    }

    // A normal app window (Chrome) is NOT a system dialog.
    func testRegularAppWindowIgnored() {
        XCTAssertNil(SystemDialogDetector.classify(snap(
            1783,
            owner: "Google Chrome",
            bundle: "com.google.Chrome",
            w: 700,
            h: 500,
        )))
    }

    // The SecurityAgent OFFSCREEN helper (onScreen=false, 500×500) must not surface.
    func testOffscreenHelperIgnored() {
        XCTAssertNil(SystemDialogDetector.classify(snap(
            1967,
            owner: "SecurityAgent",
            bundle: "com.apple.SecurityAgent",
            onScreen: false,
            w: 500,
            h: 500,
        )))
    }

    // A sub-minSize same-owner sliver (an indicator) is rejected.
    func testTinyWindowIgnored() {
        XCTAssertNil(SystemDialogDetector.classify(snap(
            9,
            owner: "SecurityAgent",
            bundle: "com.apple.SecurityAgent",
            w: 20,
            h: 20,
        )))
    }

    // detect() filters a mixed snapshot down to just the system prompts, order preserved.
    func testDetectFiltersMixedSnapshot() {
        let windows = [
            snap(1, owner: "Google Chrome", bundle: "com.google.Chrome", w: 700, h: 500),
            snap(1966, owner: "SecurityAgent", bundle: "com.apple.SecurityAgent"),
            snap(1967, owner: "SecurityAgent", bundle: "com.apple.SecurityAgent", onScreen: false, w: 500, h: 500),
            snap(3, owner: "Finder", bundle: "com.apple.finder", w: 900, h: 600),
        ]
        let dialogs = SystemDialogDetector.detect(windows)
        XCTAssertEqual(dialogs.map(\.windowID), [1966], "only the visible SecurityAgent prompt surfaces")
    }
}
#endif
