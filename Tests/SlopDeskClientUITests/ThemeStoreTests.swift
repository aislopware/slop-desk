// ThemeStore tests — the runtime theme holder that defeats the STATIC `Slate.theme` across the
// AppKit `NSSplitViewController` boundary. Pure logic only: `apply(_:)` mapping, the default Monokai Pro
// Classic invariant, and the IDENTITY-keyed cross-boundary change notification (so a same-lightness variant
// switch still repaints). NO SCStream/VT/Metal/VideoWindowView is touched.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ThemeStoreTests: XCTestCase {
    /// The default theme is Monokai Pro Classic (dark) — the product default.
    func testDefaultIsMonokaiProClassic() {
        let store = ThemeStore()
        XCTAssertFalse(store.active.isLight, "the default theme is the dark Monokai Pro Classic")
        XCTAssertEqual(store.active.id, "monokai-classic")
    }

    func testApplyMapsThemeChoiceToTheTheme() {
        let store = ThemeStore()
        store.apply(.monokaiProClassic)
        XCTAssertEqual(store.active.id, "monokai-classic")
        XCTAssertFalse(store.active.isLight, "Monokai Pro Classic is dark")
        store.apply(.monokaiProClassicLight)
        XCTAssertEqual(store.active.id, "monokai-classic-light")
        XCTAssertTrue(store.active.isLight, "Monokai Pro Light is light")
        store.apply(.monokaiProSpectrum)
        XCTAssertEqual(store.active.id, "monokai-spectrum")
        // The legacy palettes still resolve.
        store.apply(.dark)
        XCTAssertFalse(store.active.isLight, ".dark maps to the dark theme")
        store.apply(.paper)
        XCTAssertTrue(store.active.isLight, ".paper maps to the light theme")
        // nil (appearance reset/unset) now FOLLOWS the OS — the picker presents an unset slot as "System": dark
        // OS → the dark default, light OS → the light default. The probe is stubbed for determinism.
        store.osIsDark = { true }
        store.active = .paper
        store.apply(nil)
        XCTAssertEqual(store.active.id, "monokai-classic", "nil in dark mode → the dark default")
        store.osIsDark = { false }
        store.apply(nil)
        XCTAssertEqual(store.active.id, "monokai-classic-light", "nil in light mode → the light default")
    }

    /// Each theme carries the libghostty terminal bg/fg matching its chrome window colour (flat design): a
    /// dark variant's terminal background must equal its chrome window hex. Guards the chrome↔terminal sync.
    func testTerminalBackgroundMatchesChromeWindow() {
        // Monokai Classic chrome window is #2D2A2E ⇒ the terminal background hex is the same, no `#`.
        XCTAssertEqual(SlateTheme.monokaiProClassic.terminalBackgroundHex, "2D2A2E")
        XCTAssertEqual(SlateTheme.monokaiProClassic.terminalForegroundHex, "FCFCFA")
        XCTAssertEqual(SlateTheme.monokaiProSpectrum.terminalBackgroundHex, "222222")
        XCTAssertEqual(SlateTheme.monokaiProClassicLight.terminalBackgroundHex, "FAF4F2")
    }

    /// A theme change posts the cross-`NSHostingController` repaint notification keyed on theme IDENTITY —
    /// so even a SAME-lightness variant switch (Classic → Spectrum, both dark) posts; an idempotent re-apply
    /// of the SAME theme does NOT.
    func testApplyPostsChangeNotificationOnIdentityChange() {
        let store = ThemeStore.shared
        store.active = .monokaiProClassic

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: nil, queue: nil,
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.apply(.monokaiProClassic) // no change → no post
        XCTAssertEqual(posts, 0)
        store.apply(.monokaiProSpectrum) // SAME lightness, different variant → one post
        XCTAssertEqual(posts, 1)
        store.apply(.monokaiProSpectrum) // idempotent → no post
        XCTAssertEqual(posts, 1)
        store.apply(.monokaiProClassicLight) // dark → light → one more post
        XCTAssertEqual(posts, 2)
    }

    // MARK: - dual-slot follow-OS + cross-module id round-trip

    /// With "Use separated theme for dark mode" ON, the OS appearance SELECTS the slot (light → primary
    /// `theme`, dark → `themeDark`) and an OS flip re-resolves LIVE. The `osIsDark` probe is stubbed (no NSApp).
    func testDualSlotFollowsOSAppearanceLive() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(
            theme: .paper, themeDark: .dark, useSeparateDarkTheme: true,
        ))
        XCTAssertEqual(store.active.id, "paper", "OS light → the primary/light slot")
        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "dark", "OS dark → the dark slot, live")
        dark = false
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "paper", "flip back to light, live")
    }

    /// An OS flip posts the cross-boundary repaint EXACTLY when the resolved theme actually changes (a
    /// follow-OS user), and a re-resolve with no OS change posts nothing.
    func testReresolvePostsOnOSFlipForSeparateDark() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(
            theme: .paper, themeDark: .dark, useSeparateDarkTheme: true,
        ))
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: store, queue: nil,
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(posts, 1, "an OS flip to dark posts the cross-boundary repaint")
        store.reresolveForOSAppearance() // OS still dark → idempotent
        XCTAssertEqual(posts, 1, "re-resolving with no OS change posts nothing")
    }

    /// A NON-follow-OS user (separate-dark OFF, a concrete theme) does not change — nor post — on an OS flip.
    /// Revert-to-confirm: a resolver that ignored `useSeparateDarkTheme` and always followed the OS would fail.
    func testNonFollowOSThemeDoesNotChangeOnOSFlip() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(theme: .monokaiProClassic))
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: store, queue: nil,
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(posts, 0, "a fixed (non-follow-OS) theme doesn't change on an OS flip")
        XCTAssertEqual(store.active.id, "monokai-classic")
    }

    /// The legacy `.system` single choice follows the OS through `apply(appearance:)` + the live re-resolve.
    func testSystemChoiceFollowsOSThroughApplyAppearance() {
        let store = ThemeStore()
        store.osIsDark = { true }
        store.apply(appearance: AppearancePreferences(theme: .system))
        XCTAssertEqual(store.active.id, "monokai-classic", "OS dark → Monokai Pro Classic")
        store.osIsDark = { false }
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "monokai-classic-light", "OS light → Monokai Pro Classic Light, live")
    }

    /// CROSS-MODULE PIN: every concrete ``ThemeChoice``'s `builtinID` (in the leaf) round-trips to a built-in
    /// ``SlateTheme`` whose `id` matches (in ClientUI). Catches a drift between the leaf's id strings
    /// (``ThemeResolution`` / ``ThemeChoice/builtinID``) and the SwiftUI `SlateTheme.id` halves.
    func testBuiltinIDRoundTripsToSlateThemeID() {
        for choice in ThemeChoice.allCases where choice != .system {
            guard let id = choice.builtinID else {
                XCTFail("\(choice) must expose a builtinID")
                continue
            }
            let theme = ThemeStore.builtin(id: id)
            XCTAssertNotNil(theme, "\(choice) id \(id) must resolve to a built-in SlateTheme")
            XCTAssertEqual(theme?.id, id, "round-trip: ThemeChoice.builtinID ⇄ SlateTheme.id")
        }
        // The leaf's default ids match the shipped Classic / Classic-Light themes.
        XCTAssertEqual(ThemeStore.builtin(id: ThemeResolution.defaultDarkID)?.id, SlateTheme.monokaiProClassic.id)
        XCTAssertEqual(
            ThemeStore.builtin(id: ThemeResolution.defaultLightID)?.id, SlateTheme.monokaiProClassicLight.id,
        )
    }
}
#endif
