// ThemeStore tests — the runtime theme holder that defeats the STATIC `Slate.theme` across the
// AppKit `NSSplitViewController` boundary. Pure logic only: `apply(_:)` mapping, the default Foundry
// Ember invariant, and the IDENTITY-keyed cross-boundary change notification (so a same-lightness variant
// switch still repaints). NO SCStream/VT/Metal/VideoWindowView is touched.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ThemeStoreTests: XCTestCase {
    /// The default theme is Foundry Ember (dark) — the product default.
    func testDefaultIsFoundryEmber() {
        let store = ThemeStore()
        XCTAssertFalse(store.active.isLight, "the default theme is the dark Foundry Ember")
        XCTAssertEqual(store.active.id, "foundry-ember")
    }

    func testApplyMapsThemeChoiceToTheTheme() {
        let store = ThemeStore()
        store.apply(.foundryEmber)
        XCTAssertEqual(store.active.id, "foundry-ember")
        XCTAssertFalse(store.active.isLight, "Foundry Ember is dark")
        store.apply(.foundryEmberLight)
        XCTAssertEqual(store.active.id, "foundry-ember-light")
        XCTAssertTrue(store.active.isLight, "Foundry Ember Light is light")
        store.apply(.foundryGraphite)
        XCTAssertEqual(store.active.id, "foundry-graphite")
        store.apply(.foundryEmber)
        XCTAssertFalse(store.active.isLight, "Foundry Ember maps to the dark theme")
        store.apply(.foundryEmberLight)
        XCTAssertTrue(store.active.isLight, "Foundry Ember Light maps to the light theme")
        // nil (appearance reset/unset) now FOLLOWS the OS — the picker presents an unset slot as "System": dark
        // OS → the dark default, light OS → the light default. The probe is stubbed for determinism.
        store.osIsDark = { true }
        store.active = .foundryEmberLight
        store.apply(nil)
        XCTAssertEqual(store.active.id, "foundry-ember", "nil in dark mode → the dark default")
        store.osIsDark = { false }
        store.apply(nil)
        XCTAssertEqual(store.active.id, "foundry-ember-light", "nil in light mode → the light default")
    }

    /// Each theme carries the libghostty terminal bg/fg matching its chrome window colour (flat design): a
    /// dark variant's terminal background must equal its chrome window hex. Guards the chrome↔terminal sync.
    func testTerminalBackgroundMatchesChromeWindow() {
        // Foundry Ember chrome face is #27221E ⇒ the terminal background hex is the same, no `#`.
        XCTAssertEqual(SlateTheme.foundryEmber.terminalBackgroundHex, "27221E")
        XCTAssertEqual(SlateTheme.foundryEmber.terminalForegroundHex, "E6DED6")
        XCTAssertEqual(SlateTheme.foundryGraphite.terminalBackgroundHex, "222325")
        XCTAssertEqual(SlateTheme.foundryEmberLight.terminalBackgroundHex, "F6F0ED")
    }

    /// A theme change posts the cross-`NSHostingController` repaint notification keyed on theme IDENTITY —
    /// so even a SAME-lightness variant switch (Ember → Graphite, both dark) posts; an idempotent re-apply
    /// of the SAME theme does NOT.
    func testApplyPostsChangeNotificationOnIdentityChange() {
        let store = ThemeStore.shared
        store.active = .foundryEmber

        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: nil, queue: nil,
        ) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.apply(.foundryEmber) // no change → no post
        XCTAssertEqual(posts.value, 0)
        store.apply(.foundryGraphite) // SAME lightness, different variant → one post
        XCTAssertEqual(posts.value, 1)
        store.apply(.foundryGraphite) // idempotent → no post
        XCTAssertEqual(posts.value, 1)
        store.apply(.foundryEmberLight) // dark → light → one more post
        XCTAssertEqual(posts.value, 2)
    }

    // MARK: - dual-slot follow-OS + cross-module id round-trip

    /// With "Use separated theme for dark mode" ON, the OS appearance SELECTS the slot (light → primary
    /// `theme`, dark → `themeDark`) and an OS flip re-resolves LIVE. The `osIsDark` probe is stubbed (no NSApp).
    func testDualSlotFollowsOSAppearanceLive() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(
            theme: .foundryEmberLight, themeDark: .foundryGraphite, useSeparateDarkTheme: true,
        ))
        XCTAssertEqual(store.active.id, "foundry-ember-light", "OS light → the primary/light slot")
        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "foundry-graphite", "OS dark → the dark slot, live")
        dark = false
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "foundry-ember-light", "flip back to light, live")
    }

    /// An OS flip posts the cross-boundary repaint EXACTLY when the resolved theme actually changes (a
    /// follow-OS user), and a re-resolve with no OS change posts nothing.
    func testReresolvePostsOnOSFlipForSeparateDark() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(
            theme: .foundryEmberLight, themeDark: .foundryGraphite, useSeparateDarkTheme: true,
        ))
        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: store, queue: nil,
        ) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(posts.value, 1, "an OS flip to dark posts the cross-boundary repaint")
        store.reresolveForOSAppearance() // OS still dark → idempotent
        XCTAssertEqual(posts.value, 1, "re-resolving with no OS change posts nothing")
    }

    /// A NON-follow-OS user (separate-dark OFF, a concrete theme) does not change — nor post — on an OS flip.
    /// Revert-to-confirm: a resolver that ignored `useSeparateDarkTheme` and always followed the OS would fail.
    func testNonFollowOSThemeDoesNotChangeOnOSFlip() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(theme: .foundryEmber))
        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: store, queue: nil,
        ) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(posts.value, 0, "a fixed (non-follow-OS) theme doesn't change on an OS flip")
        XCTAssertEqual(store.active.id, "foundry-ember")
    }

    /// The legacy `.system` single choice follows the OS through `apply(appearance:)` + the live re-resolve.
    func testSystemChoiceFollowsOSThroughApplyAppearance() {
        let store = ThemeStore()
        store.osIsDark = { true }
        store.apply(appearance: AppearancePreferences(theme: .system))
        XCTAssertEqual(store.active.id, "foundry-ember", "OS dark → Foundry Ember")
        store.osIsDark = { false }
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "foundry-ember-light", "OS light → Foundry Ember Light, live")
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
        // The leaf's default ids match the shipped Ember / Ember-Light themes.
        XCTAssertEqual(ThemeStore.builtin(id: ThemeResolution.defaultDarkID)?.id, SlateTheme.foundryEmber.id)
        XCTAssertEqual(
            ThemeStore.builtin(id: ThemeResolution.defaultLightID)?.id, SlateTheme.foundryEmberLight.id,
        )
    }
}
#endif

// MARK: - PostCount (Sendable notification tally)

/// The notification-observer closure is `@Sendable`, so the post tally lives in a box rather than a
/// captured local `var`. Every post in these tests fires synchronously on the test thread — the box
/// exists purely to satisfy the capture checking, not to add synchronisation.
private final class PostCount: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}
