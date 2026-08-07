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
    /// The default theme is Foundry Ember — the SPLIT-TONE product default (light warm chrome
    /// around dark terminal glass), so its chrome-side `isLight` is TRUE.
    func testDefaultIsFoundryEmber() {
        let store = ThemeStore()
        XCTAssertTrue(store.active.isLight, "split-tone Ember wears light chrome ⇒ isLight")
        XCTAssertEqual(store.active.id, "foundry-ember")
    }

    func testApplyMapsThemeChoiceToTheTheme() {
        let store = ThemeStore()
        store.apply(.foundryEmber)
        XCTAssertEqual(store.active.id, "foundry-ember")
        XCTAssertTrue(store.active.isLight, "split-tone Ember: light chrome, dark glass")
        store.apply(.foundryEmberLight)
        XCTAssertEqual(store.active.id, "foundry-ember-light")
        XCTAssertTrue(store.active.isLight, "Foundry Ember Light is light")
        store.apply(.foundryGraphite)
        XCTAssertEqual(store.active.id, "foundry-graphite")
        XCTAssertFalse(store.active.isLight, "Foundry Graphite stays all-dark")
        store.apply(.foundryEmber)
        XCTAssertEqual(store.active.id, "foundry-ember")
        // nil (appearance reset/unset) resolves to the split-tone default under EITHER OS appearance —
        // the one signature theme reads correctly in both modes. The probe is stubbed for determinism.
        store.osIsDark = { true }
        store.active = .foundryEmberLight
        store.apply(nil)
        XCTAssertEqual(store.active.id, "foundry-ember", "nil in dark mode → the split-tone default")
        store.osIsDark = { false }
        store.active = .foundryEmberLight
        store.apply(nil)
        XCTAssertEqual(store.active.id, "foundry-ember", "nil in light mode → the split-tone default")
    }

    /// Each theme carries the libghostty terminal bg/fg for its TERMINAL surface. On the split-tone
    /// Ember the terminal glass (#27221E) deliberately DIVERGES from the light chrome face — the seed's
    /// `terminalFace` override; the all-dark variants still equal their chrome face.
    func testTerminalBackgroundMatchesChromeWindow() {
        // Foundry Ember terminal glass stays the pinned dark #27221E, no `#`.
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
        store.apply(.foundryEmberLight) // different identity → one more post
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

    /// The legacy `.system` single choice resolves to the split-tone default through `apply(appearance:)`
    /// and stays there across an OS flip (both per-appearance defaults are the one signature theme).
    func testSystemChoiceFollowsOSThroughApplyAppearance() {
        let store = ThemeStore()
        store.osIsDark = { true }
        store.apply(appearance: AppearancePreferences(theme: .system))
        XCTAssertEqual(store.active.id, "foundry-ember", "OS dark → Foundry Ember")
        store.osIsDark = { false }
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "foundry-ember", "OS light → still the split-tone Ember")
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
        // Both leaf default ids resolve to the shipped split-tone Ember (one signature default).
        XCTAssertEqual(ThemeStore.builtin(id: ThemeResolution.defaultDarkID)?.id, SlateTheme.foundryEmber.id)
        XCTAssertEqual(
            ThemeStore.builtin(id: ThemeResolution.defaultLightID)?.id, SlateTheme.foundryEmber.id,
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
