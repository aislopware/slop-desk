// DeviceRowFilterTests — the one search-box predicate both panels' lists and both consoles share.
//
// What these hold is the part that could not be held before: there were SIX spellings of this
// filter across four targets, and a test could only ever reach one of them. The rule now has one
// home, so the cases below cover both panels and both drawings at once.
//
// The FOLD is pinned deliberately and not only asserted in prose. The predicate moved from
// `localizedCaseInsensitiveContains` — normalizing, compatibility-folding, locale-aware — to
// `slopdesk_workspace::binding_search`'s Unicode simple lowercase over an ASCII byte scan, which is
// what every other search field in the app already used. Eleven probed cases agree and four differ;
// both halves are pinned here, so a future change to either side is a red test rather than a silent
// change to what a filter box finds.

import XCTest
@testable import SlopDeskDevicePanels

// `SimulatorPresentation.Console` is `@MainActor` — it is the drawer's own presentation type and
// every caller is a view — so the suite is too rather than each case awaiting into it.
@MainActor
final class DeviceRowFilterTests: XCTestCase {
    private func log(_ name: String, _ message: String) -> DeviceLogLine {
        DeviceLogLine(time: "13:50:19.565", name: name, message: message)
    }

    private func rows() -> [DeviceLogLine] {
        [
            log("ActivityManager", "Displayed com.example.app/.MainActivity"),
            log("SurfaceFlinger", "Latch skipped for layer 0x7f"),
            log("Poster", "waiting on binder transaction 7"),
            log("", "--------- beginning of crash"),
        ]
    }

    // MARK: - The predicate

    /// A search box nobody has typed into is not a filter, and both panels sit in that state almost
    /// all of the time — so the blank query never crosses and never copies.
    func testABlankQueryKeepsEveryRowInOrder() {
        let all = rows()
        XCTAssertEqual(AndroidPresentation.visible(all, filter: ""), all)
        XCTAssertEqual(AndroidPresentation.visible(all, filter: "   "), all)
        XCTAssertEqual(SimulatorPresentation.Console.visible(all, filter: "\t "), all)
    }

    func testTheQueryIsTrimmedBeforeItIsMatched() {
        XCTAssertEqual(
            AndroidPresentation.visible(rows(), filter: "  binder  ").map(\.name), ["Poster"],
        )
    }

    /// Both fields, in the order the rows arrived — the answer is positions in the lent list, so a
    /// filtered console cannot re-order itself.
    func testEitherFieldMatchesAndSurvivorsKeepTheirOrder() {
        // The tag alone, then the message alone — the two halves of "over the whole row".
        XCTAssertEqual(AndroidPresentation.visible(rows(), filter: "flinger").map(\.name), ["SurfaceFlinger"])
        XCTAssertEqual(AndroidPresentation.visible(rows(), filter: "binder").map(\.name), ["Poster"])

        let byMessage = AndroidPresentation.visible(rows(), filter: "e")
        XCTAssertEqual(
            byMessage.map(\.name), ["ActivityManager", "SurfaceFlinger", "Poster", ""],
        )
    }

    func testCaseIsFoldedInBothDirections() {
        XCTAssertEqual(AndroidPresentation.visible(rows(), filter: "POSTER").count, 1)
        XCTAssertEqual(AndroidPresentation.visible(rows(), filter: "poster").count, 1)
        XCTAssertEqual(AndroidPresentation.visible(rows(), filter: "PoStEr").count, 1)
    }

    func testNothingMatchingIsAnEmptyListRatherThanTheWholeOne() {
        XCTAssertTrue(AndroidPresentation.visible(rows(), filter: "zzzz").isEmpty)
    }

    /// An unparsed banner lends an EMPTY name field. It must be written rather than skipped, or the
    /// row's two fields would be one and every later row would be read out of the wrong record.
    func testARowWithAnEmptyFieldStillMatchesOnTheOtherOne() {
        let kept = AndroidPresentation.visible(rows(), filter: "beginning of crash")
        XCTAssertEqual(kept.map(\.message), ["--------- beginning of crash"])
    }

    func testAnEmptyListAnswersEmptyForAnyQuery() {
        XCTAssertTrue(AndroidPresentation.visible([], filter: "anything").isEmpty)
        XCTAssertTrue(SimulatorPresentation.matches([], query: "anything").isEmpty)
    }

    // MARK: - The fold's boundary

    /// The eleven-of-seventeen that the platform call and this one agree on. ASCII is every row a
    /// device has actually emitted, and the four non-ASCII cases here are the ones that survive the
    /// change unchanged.
    func testTheFoldStillAgreesWithThePlatformWhereverBothApply() {
        let cases: [(String, String)] = [
            ("ActivityManager: started", "activitymanager"),
            ("uid 10501 pid=7", "pid="),
            ("İstanbul", "i̇stanbul"),
            ("ΟΔΟΣ", "οδος"),
            ("boot 🚀 done", "🚀"),
            ("日本語ログ", "本語"),
            ("CAFÉ", "café"),
        ]
        for (haystack, needle) in cases {
            XCTAssertEqual(
                AndroidPresentation.visible([log("", haystack)], filter: needle).count,
                haystack.localizedCaseInsensitiveContains(needle) ? 1 : 0,
                "\(haystack) / \(needle)",
            )
        }
    }

    /// And the four that differ, pinned in the direction they differ in. Every one needs a human to
    /// type a canonically-equivalent-but-not-identical spelling of what a device wrote; taking the
    /// trade is what makes this box agree with the palette, Settings and the keybindings editor,
    /// which all fold this way already.
    func testTheFoldDoesNotNormaliseAndThatIsPinnedRatherThanPresumed() {
        let composed = "Caf\u{00E9} Poster"
        let decomposed = "Cafe\u{0301}"
        XCTAssertTrue(composed.localizedCaseInsensitiveContains(decomposed))
        XCTAssertTrue(AndroidPresentation.visible([log("", composed)], filter: decomposed).isEmpty)

        XCTAssertTrue("STRASSE".localizedCaseInsensitiveContains("straße"))
        XCTAssertTrue(AndroidPresentation.visible([log("", "STRASSE")], filter: "straße").isEmpty)

        XCTAssertTrue("\u{FB01}le not found".localizedCaseInsensitiveContains("file"))
        XCTAssertTrue(
            AndroidPresentation.visible([log("", "\u{FB01}le not found")], filter: "file").isEmpty,
        )
    }

    /// The claim the old comment made and the call never honoured: `localizedCaseInsensitiveContains`
    /// passes `.caseInsensitive` and nothing else, so typing `cafe` never found `Café` — before this
    /// change or after it. Pinned so the sentence cannot come back.
    func testNeitherFoldWasEverDiacriticInsensitive() {
        XCTAssertFalse("Café Poster".localizedCaseInsensitiveContains("cafe"))
        XCTAssertTrue(AndroidPresentation.visible([log("", "Café Poster")], filter: "cafe").isEmpty)
    }

    // MARK: - The device lists

    private func android(
        _ name: String, serial: String?, model: String?, release: String?,
    ) -> AndroidDevice {
        AndroidDevice(
            key: name, name: name, serial: serial, avdName: nil, state: "device",
            isEmulator: serial?.hasPrefix("emulator") ?? false, manufacturer: nil, model: model,
            release: release, apiLevel: nil, abi: nil, width: nil, height: nil, density: nil,
            formFactor: nil,
        )
    }

    func testTheAndroidListSearchesAllFourFieldsAndToleratesTheAbsentOnes() {
        let devices = [
            android("Pixel 8 API 34", serial: "emulator-5554", model: nil, release: "14"),
            android("Galaxy S23", serial: "R5CT10ABCDE", model: "SM-S911B", release: nil),
        ]
        XCTAssertEqual(AndroidPresentation.matches(devices, query: "sm-s911").map(\.name), ["Galaxy S23"])
        XCTAssertEqual(AndroidPresentation.matches(devices, query: "5554").map(\.name), ["Pixel 8 API 34"])
        XCTAssertEqual(AndroidPresentation.matches(devices, query: "14").map(\.name), ["Pixel 8 API 34"])
        XCTAssertEqual(AndroidPresentation.matches(devices, query: "").count, 2)
    }

    func testTheSimulatorListSearchesNameAndRuntime() {
        let devices = [
            SimulatorDevice(
                udid: "A", name: "iPhone 16 Pro", runtime: "iOS 26.0", state: "Booted", isBooted: true,
            ),
            SimulatorDevice(
                udid: "B", name: "iPad Pro 13-inch", runtime: "iOS 18.4", state: "Shutdown",
                isBooted: false,
            ),
        ]
        XCTAssertEqual(SimulatorPresentation.matches(devices, query: "ipad").map(\.udid), ["B"])
        XCTAssertEqual(SimulatorPresentation.matches(devices, query: "26.0").map(\.udid), ["A"])
        XCTAssertEqual(SimulatorPresentation.matches(devices, query: "ios").count, 2)
        XCTAssertEqual(SimulatorPresentation.matches(devices, query: "  ").count, 2)
    }
}
