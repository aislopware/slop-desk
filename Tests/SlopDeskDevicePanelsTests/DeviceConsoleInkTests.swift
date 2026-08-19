// DeviceConsoleInkTests — what each device console reads a severity AS.
//
// The scale itself (`DeviceLogSeverity`, and which byte becomes which case) belongs to the parse and
// is pinned in `DeviceLogLineTests`. This is the other half: the two consoles share one enum and do
// NOT share one palette, so the mapping from case to a ROLE is a decision both renderers ask for.
//
// IT MOVED HERE IN docs/56 INCREMENT 52, and the move is the point rather than a tidy-up. It used to
// assert on `Slate.Text.tertiary` — a `Color`, i.e. the SwiftUI half's hue — which is why it lived in
// `SlopDeskClientUITests` and why it could only ever have covered one of the two renderers. Now that
// there are two, an ink test written against either one's colour type would pin half the product and
// pass while the other half drifted. The ordering below is the decision; the hue each framework
// resolves it to is a one-line `switch` on each side and is not a thing to test twice.

import SlopDeskDevicePanels
import XCTest

final class DeviceConsoleInkTests: XCTestCase {
    /// Both consoles switch over the whole scale, and each keeps the reading it had when the two
    /// grammars owned two enums. This pins the pair that would otherwise drift silently: `plain`
    /// recedes on Android because it holds `logcat`'s debug, and does not on the simulator because
    /// there `Df` is the ordinary default and `Db` has its own bucket.
    @MainActor
    func testTheSharedScaleKeepsEachConsolesOwnInk() {
        XCTAssertEqual(AndroidPresentation.logInk(.plain), .tertiary)
        XCTAssertEqual(AndroidPresentation.logInk(.info), .secondary)
        XCTAssertEqual(SimulatorPresentation.Console.ink(for: .plain), .secondary)
        XCTAssertEqual(SimulatorPresentation.Console.ink(for: .debug), .tertiary)
        for loud in [DeviceLogSeverity.fatal, .error] {
            XCTAssertEqual(AndroidPresentation.logInk(loud), .err)
            XCTAssertEqual(SimulatorPresentation.Console.ink(for: loud), .alarm)
        }
    }

    /// Only a FAULT is inked in colour. Info used to be green; a busy device emits it hundreds of
    /// times a second, which spent the console's alarm colour on the ordinary case (user-directed
    /// 2026-08-04). Asserting the role rather than the hue is what makes this hold for both halves:
    /// neither renderer can quietly resolve `.secondary` to the alarm colour, because it never asks.
    @MainActor
    func testOnlyAFaultIsInkedInColourAndEveryHealthyLevelIsAGrey() {
        XCTAssertEqual(SimulatorPresentation.Console.ink(for: .error), .alarm)
        XCTAssertEqual(SimulatorPresentation.Console.ink(for: .fatal), .alarm)
        for healthy in [DeviceLogSeverity.info, .plain, .debug] {
            XCTAssertNotEqual(
                SimulatorPresentation.Console.ink(for: healthy), .alarm,
                "\(healthy) is not a problem and must not borrow the problem colour",
            )
            XCTAssertNotEqual(
                AndroidPresentation.logInk(healthy), .err,
                "\(healthy) is not a problem and must not borrow the problem colour",
            )
        }
    }

    /// Debug still recedes and info does not — the two greys are a LUMINANCE ordering, which is the
    /// channel that survived the colour removal. Collapsing them would lose that.
    @MainActor
    func testADebugLineSitsFurtherBackThanAnOrdinaryOne() {
        XCTAssertEqual(SimulatorPresentation.Console.ink(for: .debug), .tertiary)
        XCTAssertEqual(SimulatorPresentation.Console.ink(for: .info), .secondary)
        XCTAssertNotEqual(
            SimulatorPresentation.Console.ink(for: .debug),
            SimulatorPresentation.Console.ink(for: .info),
        )
    }
}
