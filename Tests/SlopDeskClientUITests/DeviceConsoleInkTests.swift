// DeviceConsoleInkTests — what each device console PAINTS a severity.
//
// The scale itself (`DeviceLogSeverity`, and which byte becomes which case) belongs to the parse and
// is pinned in `SlopDeskDevicePanelsTests/DeviceLogLineTests`. This is the other half: the two
// consoles share one enum and do NOT share one palette, so the mapping from case to ink is a view
// decision and lives beside the views.

#if os(macOS)
import SlopDeskDevicePanels
import SlopDeskSlate
import XCTest
@testable import SlopDeskClientUI

final class DeviceConsoleInkTests: XCTestCase {
    /// Both console views switch over the whole scale, and each keeps the ink it had when the two
    /// grammars owned two enums. This pins the pair that would otherwise drift silently: `plain`
    /// recedes on Android because it holds `logcat`'s debug, and does not on the simulator because
    /// there `Df` is the ordinary default and `Db` has its own bucket.
    @MainActor
    func testTheSharedScaleKeepsEachConsolesOwnInk() {
        XCTAssertEqual(AndroidConsoleView.tint(for: .plain), Slate.Text.tertiary)
        XCTAssertEqual(AndroidConsoleView.tint(for: .info), Slate.Text.secondary)
        XCTAssertEqual(SimulatorConsoleView.tint(for: .plain), Slate.Text.secondary)
        XCTAssertEqual(SimulatorConsoleView.tint(for: .debug), Slate.Text.tertiary)
        for loud in [DeviceLogSeverity.fatal, .error] {
            XCTAssertEqual(AndroidConsoleView.tint(for: loud), Slate.StatusInk.err)
            XCTAssertEqual(SimulatorConsoleView.tint(for: loud), Slate.StatusInk.err)
        }
    }

    /// The console and this test read the SAME `tint(for:)`, so the rendered ink cannot drift from
    /// the pin. Info used to be green; a busy device emits it hundreds of times a second, which spent
    /// the console's alarm colour on the ordinary case (user-directed 2026-08-04).
    @MainActor
    func testOnlyAFaultIsInkedInColourAndEveryHealthyLevelIsAGrey() {
        XCTAssertEqual(SimulatorConsoleView.tint(for: .error), Slate.StatusInk.err)
        XCTAssertEqual(SimulatorConsoleView.tint(for: .fatal), Slate.StatusInk.err)
        for healthy in [DeviceLogSeverity.info, .plain, .debug] {
            XCTAssertNotEqual(
                SimulatorConsoleView.tint(for: healthy), Slate.StatusInk.err,
                "\(healthy) is not a problem and must not borrow the problem colour",
            )
        }
    }

    /// Debug still recedes and info does not — the two greys are a LUMINANCE ordering, which is the
    /// channel that survived the colour removal. Collapsing them would lose that.
    @MainActor
    func testADebugLineSitsFurtherBackThanAnOrdinaryOne() {
        XCTAssertEqual(SimulatorConsoleView.tint(for: .debug), Slate.Text.tertiary)
        XCTAssertEqual(SimulatorConsoleView.tint(for: .info), Slate.Text.secondary)
        XCTAssertNotEqual(SimulatorConsoleView.tint(for: .debug), SimulatorConsoleView.tint(for: .info))
    }
}
#endif
