// DevicePanelSymbolTests — the compile-time check the SF Symbol crossing gave up, relocated.
//
// Both panels' glyphs used to be `SFSafeSymbols` literals: `.chevronBackward`, `.rotateRight`,
// `.listBulletRectangle`. The compiler checked every one of them, because a mistyped case is not a
// case. They are `slopdesk_devicepanel`'s now, and they cross as NAMES — which is what keeps a verb
// table WHOLE (a plate's glyph, its tooltip, its latched pair and the action it fires are one row in
// one language) at the cost of that check, since a `&'static str` in Rust is only a string.
//
// So the check moves here, where it can still fail before anyone sees a blank plate. A name that no
// longer resolves is exactly what the literal made impossible: the symbol was renamed or withdrawn
// at this deployment target, and the panel draws an empty square where a control used to be.
//
// ## Why `NSImage(systemSymbolName:)` and not `SFSymbol(rawValue:)`
//
// `SFSymbol` is `RawRepresentable` with a public `init(rawValue:)`, so reconstituting one NEVER
// fails — every string is an `SFSymbol`, including `"nonsuch.glyph"`. Asking the system to actually
// draw it is the only question worth asking, and it is the same question both renderers ask at
// mount: `Image(systemSymbol:)` on the phone and `NSImage(systemSymbolName:)` on the Mac both
// resolve through the same catalogue.
//
// macOS-only, and that is not a gap: the two frameworks read ONE catalogue that ships with the OS,
// and a name absent from the Mac's is absent from the phone's. What the gate avoids is a UIKit
// import in a target that deliberately has neither.

#if os(macOS)
import AppKit
import SFSafeSymbols
import XCTest
@testable import SlopDeskDevicePanels

final class DevicePanelSymbolTests: XCTestCase {
    /// Every glyph the Android panel's toolbar crosses — three navigation plates, four action
    /// plates, the console plate, and each of their latched twins.
    @MainActor
    func testEveryAndroidStagePlateResolves() {
        let trays = AndroidPresentation.navigationTray
            + AndroidPresentation.actionTray
            + [AndroidPresentation.consoleVerb]
        XCTAssertEqual(trays.count, 8, "the crate publishes eight plates across its three trays")
        for verb in trays {
            assertResolves(verb.symbol, "\(verb.action) at rest")
            assertResolves(verb.latchedSymbol, "\(verb.action) latched")
        }
    }

    /// The console drawer's three, which cross as loose words rather than as plates.
    @MainActor
    func testEveryAndroidConsoleGlyphResolves() {
        assertResolves(AndroidPresentation.consoleFollowSymbol, "logcat follow")
        assertResolves(AndroidPresentation.consoleClearSymbol, "logcat clear")
        assertResolves(AndroidPresentation.consoleHideSymbol, "logcat hide")
    }

    /// Every plate the Simulators surface crosses, latching pairs included.
    func testEverySimulatorPlateResolves() {
        let plates = SimulatorVocabulary.plates
        XCTAssertEqual(plates.count, 14, "five toolbar plates, three latching pairs, three console")
        for plate in plates {
            assertResolves(plate.symbol, plate.help)
        }
    }

    /// A crossed name is never EMPTY. A short delivery pads with `""` rather than shifting, so an
    /// empty glyph is the shape a layout disagreement takes — and `NSImage` answers `nil` for it,
    /// which the assertions above would catch. This says so at the table instead of at one plate.
    func testNoCrossedGlyphIsEmpty() {
        for plate in SimulatorVocabulary.plates {
            XCTAssertFalse(plate.symbol.rawValue.isEmpty, "plate “\(plate.help)” crossed unnamed")
        }
    }

    private func assertResolves(_ symbol: SFSymbol, _ what: String, line: UInt = #line) {
        XCTAssertNotNil(
            NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil),
            "“\(symbol.rawValue)” (\(what)) does not resolve at this deployment target",
            line: line,
        )
    }
}
#endif
