// SimulatorChromeTests — the device body decode, the family glyph, and the orientation cycle.
//
// All three are pure and all three are the kind of thing that is wrong silently: a bezel whose screen
// rect is off puts the video through the case, a family inferred backwards puts an iPad glyph on a
// phone, and a rotation cycle with a dead end makes a button that stops working after three presses.

#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class SimulatorChromeTests: XCTestCase {
    /// A trimmed copy of what the server answers for an iPhone 17 Pro, measured 2026-08-04.
    private func definition(
        buttons: String? = nil, screen: String? = nil,
    ) -> Data {
        let screenObject = screen ?? """
        {
          "bezelImage": { "bare": "/simulators/U/bezel.png?buttons=false",
                          "rest": "/simulators/U/bezel.png" },
          "clipRadius": 62,
          "rect": { "x": 18, "y": 18, "width": 400, "height": 872 },
          "viewport": { "width": 436, "height": 908 }
        }
        """
        return Data("""
        { "identity": { "model": "iPhone 17 Pro" },
          "screen": \(screenObject),
          "buttons": [\(buttons ?? Self.oneButton)] }
        """.utf8)
    }

    private static let oneButton = """
    { "id": "power",
      "box": { "leftPct": 97.0, "topPct": 28.8, "widthPct": 3.6, "heightPct": 11.1 },
      "images": { "rest": "/simulators/U/chrome-button/power.png",
                  "pressed": "/simulators/U/chrome-button/power-down.png" },
      "envelope": { "button": "power", "type": "button" } }
    """

    func testTheScreenGeometryDecodesInViewportUnits() {
        let chrome = SimulatorChrome.decode(definition())
        XCTAssertEqual(chrome?.model, "iPhone 17 Pro")
        XCTAssertEqual(chrome?.screen.viewport, CGSize(width: 436, height: 908))
        XCTAssertEqual(chrome?.screen.rect, CGRect(x: 18, y: 18, width: 400, height: 872))
        XCTAssertEqual(chrome?.screen.clipRadius, 62)
        // The panel draws the BARE body and its own buttons, so this is the reference it must keep.
        XCTAssertEqual(chrome?.screen.barePath, "/simulators/U/bezel.png?buttons=false")
    }

    func testAButtonBoxIsAFractionOfTheViewportAndMayLieOutsideIt() {
        let chrome = SimulatorChrome.decode(definition())
        let button = try? XCTUnwrap(chrome?.buttons.first)
        XCTAssertEqual(button?.id, "power")
        let frame = button?.frame(in: CGSize(width: 436, height: 908))
        XCTAssertEqual(frame?.minX ?? 0, 436 * 0.970, accuracy: 0.01)
        XCTAssertEqual(frame?.height ?? 0, 908 * 0.111, accuracy: 0.01)
        // Past the viewport's right edge on purpose: a side button protrudes from the body.
        XCTAssertGreaterThan((frame?.maxX ?? 0), 436)
    }

    func testTheBleedCoversWhatProtrudesPastTheBody() {
        // Laying out to the viewport alone would clip the side buttons off at the panel's edge, which
        // is the bug this rect exists to prevent.
        let chrome = try? XCTUnwrap(SimulatorChrome.decode(definition()))
        let bleed = try? XCTUnwrap(chrome?.bleed)
        XCTAssertEqual(bleed?.minX, 0)
        XCTAssertGreaterThan(bleed?.width ?? 0, 436)
    }

    func testALeftRailButtonExtendsTheBleedToNegativeXRatherThanBeingClipped() {
        let left = """
        { "id": "action",
          "box": { "leftPct": -1.15, "topPct": 17.6, "widthPct": 3.67, "heightPct": 3.74 },
          "images": { "rest": "/a.png", "pressed": "/b.png" },
          "envelope": { "button": "action", "type": "button" } }
        """
        let chrome = SimulatorChrome.decode(definition(buttons: left))
        XCTAssertLessThan(chrome?.bleed.minX ?? 0, 0)
    }

    func testTheEnvelopeNameIsTakenFromTheServerRatherThanAssumedToEqualTheId() {
        // They match for every button seen so far. Reading the id instead would be a silent mismatch
        // the first time the server names one differently.
        let renamed = """
        { "id": "side", "box": { "leftPct": 0, "topPct": 0, "widthPct": 1, "heightPct": 1 },
          "images": { "rest": "/a.png", "pressed": "/b.png" },
          "envelope": { "button": "side-button", "type": "button" } }
        """
        XCTAssertEqual(
            SimulatorChrome.decode(definition(buttons: renamed))?.buttons.first?.envelopeButton,
            "side-button",
        )
    }

    func testADegenerateScreenFailsTheWholeDecodeBecauseThereIsNothingToDraw() {
        let zero = """
        { "bezelImage": { "bare": "/a.png", "rest": "/b.png" }, "clipRadius": 4,
          "rect": { "x": 0, "y": 0, "width": 0, "height": 872 },
          "viewport": { "width": 436, "height": 908 } }
        """
        XCTAssertNil(SimulatorChrome.decode(definition(screen: zero)))
        XCTAssertNil(SimulatorChrome.decode(Data("{}".utf8)))
        XCTAssertNil(SimulatorChrome.decode(Data("[]".utf8)))
    }

    func testOneUnusableButtonIsDroppedAloneRatherThanFailingTheBody() {
        // The body is what matters; a model whose button art the server cannot produce still gets a
        // correct screen in the right place.
        let mixed = """
        { "id": "bad", "box": { "leftPct": 0, "topPct": 0, "widthPct": 0, "heightPct": 0 },
          "images": { "rest": "/a.png", "pressed": "/b.png" } },
        \(Self.oneButton)
        """
        let chrome = SimulatorChrome.decode(definition(buttons: mixed))
        XCTAssertEqual(chrome?.buttons.map(\.id), ["power"])
    }

    // MARK: Family

    func testTheFamilyComesFromTheProductNameAndFallsBackToThePhone() {
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "iPhone 17 Pro Max"), .phone)
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "iPad Pro 13-inch (M5)"), .pad)
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "Apple Watch Series 11 (46mm)"), .watch)
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "Apple TV 4K (3rd generation)"), .tv)
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "Apple Vision Pro"), .vision)
        // Unrecognised draws a plausible silhouette rather than a question mark — the name is right
        // there beside it.
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "Some Future Thing"), .phone)
    }

    func testAWatchIsNotMistakenForATVByTheSubstringInItsName() {
        // "Apple Watch" contains no "tv", but the check order is what guarantees it stays that way.
        XCTAssertEqual(SimulatorDeviceKind.infer(from: "Apple Watch Ultra 3"), .watch)
    }

    func testEveryFamilyRanksDistinctlySoTheHeadingsCannotReshuffle() {
        let ranks = SimulatorDeviceKind.allCases.map(\.rank)
        XCTAssertEqual(Set(ranks).count, ranks.count)
    }

    // MARK: Orientation

    func testAQuarterTurnCyclesForeverInBothDirections() {
        // A rotate button that reaches a dead end after three presses is the bug this pins.
        var value = SimulatorOrientation.portrait
        for _ in 0..<4 { value = value.turned(.right) }
        XCTAssertEqual(value, .portrait)
        for _ in 0..<4 { value = value.turned(.left) }
        XCTAssertEqual(value, .portrait)
    }

    func testTurningRightThenLeftReturnsToWhereItStarted() {
        for start in SimulatorOrientation.allCases {
            XCTAssertEqual(start.turned(.right).turned(.left), start)
        }
    }

    func testTheWireValuesAreTheServersOwnKebabCase() {
        XCTAssertEqual(SimulatorOrientation.portrait.wireValue, "portrait")
        XCTAssertEqual(SimulatorOrientation.landscapeLeft.wireValue, "landscape-left")
        XCTAssertEqual(SimulatorOrientation.landscapeRight.wireValue, "landscape-right")
        XCTAssertEqual(SimulatorOrientation.portraitUpsideDown.wireValue, "portrait-upside-down")
        XCTAssertEqual(Set(SimulatorOrientation.allCases.map(\.wireValue)).count, 4)
    }

    func testEachQuarterTurnHasTheAngleThatPutsTheDeviceUpright() {
        // Measured on a live device 2026-08-04: the framebuffer stays PORTRAIT whatever the device is
        // doing — a rotated Safari still streams 1206×2622 with its interface drawn sideways inside
        // it. So these angles are what the panel turns to undo that, and their signs are the two
        // directions read off those captures.
        XCTAssertEqual(SimulatorOrientation.portrait.viewAngle, 0)
        XCTAssertEqual(SimulatorOrientation.landscapeLeft.viewAngle, 90)
        XCTAssertEqual(SimulatorOrientation.landscapeRight.viewAngle, -90)
        XCTAssertEqual(SimulatorOrientation.portraitUpsideDown.viewAngle, 180)
    }

    func testATurnedDeviceIsFittedAgainstSwappedBoundsSoItDoesNotOverflowTheSidebar() {
        // `rotationEffect` does not change layout, so fitting a quarter-turned phone against the
        // panel's real bounds sizes it to a width it will never occupy.
        let bounds = CGSize(width: 300, height: 900)
        XCTAssertEqual(SimulatorBezelView.footprint(bounds, turned: false), bounds)
        XCTAssertEqual(
            SimulatorBezelView.footprint(bounds, turned: true), CGSize(width: 900, height: 300),
        )
    }

    func testOnlyTheTwoLandscapeValuesReportThemselvesAsLandscape() {
        XCTAssertTrue(SimulatorOrientation.landscapeLeft.isLandscape)
        XCTAssertTrue(SimulatorOrientation.landscapeRight.isLandscape)
        XCTAssertFalse(SimulatorOrientation.portrait.isLandscape)
        XCTAssertFalse(SimulatorOrientation.portraitUpsideDown.isLandscape)
    }

    func testTheDemoStatusBarIsApplesOwnMarketingClock() {
        XCTAssertEqual(SimulatorStatusBar.demo["time"], "9:41")
        XCTAssertEqual(SimulatorStatusBar.demo["batteryLevel"], "100")
        // The server rejects the WHOLE body on one bad field, so a plausible synonym costs the entire
        // preset. Measured against a live server 2026-08-04: "unplugged" is a 400, "discharging" is
        // the accepted spelling.
        XCTAssertEqual(SimulatorStatusBar.demo["batteryState"], "discharging")
    }

    func testClearingTheStatusBarIsADeleteRatherThanAFlagInTheBody() {
        // Measured 2026-08-04: an empty or flag-only POST answers 400 "set at least one status-bar
        // field", so a clear spelled as an override does not no-op — it fails outright.
        XCTAssertEqual(SimulatorControlClient.statusBarMethod(for: [:]), "DELETE")
        XCTAssertEqual(SimulatorControlClient.statusBarMethod(for: SimulatorStatusBar.demo), "POST")
    }
}
#endif
