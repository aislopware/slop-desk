// SimulatorChromeTests — the device body decode, the family glyph, and the orientation cycle.
//
// All three are pure and all three are the kind of thing that is wrong silently: a bezel whose screen
// rect is off puts the video through the case, a family inferred backwards puts an iPad glyph on a
// phone, and a rotation cycle with a dead end makes a button that stops working after three presses.

#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

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

    func testEveryFamilyDrawsItsOwnShape() {
        // `SimulatorFamilyMark` is on every row and every card so the machine can be told apart
        // without reading the name. Two families sharing a symbol would silently undo that — the
        // reader would see one shape and believe it means one thing.
        let symbols = SimulatorDeviceKind.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
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

    // What the BEZEL does with `viewAngle` — that a quarter-turned device is fitted against swapped
    // bounds, because a rotation transform does not change layout — is a rendering-framework
    // compensation and is pinned beside the view, in `SlopDeskClientUITests/SimulatorBezelFitTests`.

    func testOnlyTheTwoLandscapeValuesReportThemselvesAsLandscape() {
        XCTAssertTrue(SimulatorOrientation.landscapeLeft.isLandscape)
        XCTAssertTrue(SimulatorOrientation.landscapeRight.isLandscape)
        XCTAssertFalse(SimulatorOrientation.portrait.isLandscape)
        XCTAssertFalse(SimulatorOrientation.portraitUpsideDown.isLandscape)
    }

    /// The status bar's PRESET and the verb that clears it are `slopdesk_devicepanel::sim_control`'s
    /// and are pinned there — the eight pairs the server takes, and the measured 400 that makes a
    /// clear a `DELETE` rather than an empty body. What crosses here is the plan the panel acts on.
    func testClearingTheStatusBarIsADeleteRatherThanAFlagInTheBody() {
        XCTAssertEqual(SimulatorControlPlan(.statusBar, hasPayload: false)?.method, "DELETE")
        XCTAssertEqual(SimulatorControlPlan(.statusBar, hasPayload: true)?.method, "POST")
        XCTAssertEqual(
            SimulatorControlPlan(.statusBar, hasPayload: true)?.contentType, "application/json",
        )
        XCTAssertNil(SimulatorControlPlan(.statusBar, hasPayload: false)?.contentType)
    }

    /// Every operation this build declares has a plan, and the two budgets are not each other's: an
    /// install is minutes and a control call is seconds.
    func testEveryOperationHasAPlanAndOnlyAnUploadGetsTheLongBudget() {
        for operation in SimulatorControlOperation.allCases {
            XCTAssertNotNil(SimulatorControlPlan(operation), "\(operation)")
        }
        XCTAssertEqual(SimulatorControlPlan(.files, hasPayload: true)?.timeout, 300)
        XCTAssertEqual(SimulatorControlPlan(.devices)?.timeout, 8)
        // A poll answered from a copy of its own previous answer is not a poll — and the bezel
        // artwork is per MODEL and never changes, so it is the one read that may be cached.
        XCTAssertTrue(SimulatorControlPlan(.devices)?.ignoresCache == true)
        XCTAssertFalse(SimulatorControlPlan(.resource)?.ignoresCache == true)
    }
}
#endif
