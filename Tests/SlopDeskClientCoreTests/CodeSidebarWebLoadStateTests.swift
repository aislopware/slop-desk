#if os(macOS)
import XCTest
@testable import SlopDeskClientCore

/// ``CodeSidebarWebLoadState`` — the first-paint veil's state machine (a plain class; no WKWebView
/// is ever constructed here, per hang-safety).
@MainActor
final class CodeSidebarWebLoadStateTests: XCTestCase {
    func testBornVeiled() {
        // A fresh webview shows WebKit's white canvas until the page paints — the veil must be up
        // BEFORE the first delegate callback ever fires.
        XCTAssertTrue(CodeSidebarWebLoadState().veiled)
    }

    func testSettleLiftsTheVeil() {
        let state = CodeSidebarWebLoadState()
        state.navigationStarted()
        state.navigationSettled()
        XCTAssertFalse(state.veiled)
    }

    func testReloadReVeils() {
        // The header's reload button restarts the main-frame navigation — the white canvas comes
        // back, so the veil must too.
        let state = CodeSidebarWebLoadState()
        state.navigationStarted()
        state.navigationSettled()
        state.navigationStarted()
        XCTAssertTrue(state.veiled)
    }
}
#endif
