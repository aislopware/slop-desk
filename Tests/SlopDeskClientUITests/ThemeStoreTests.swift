// ThemeStore tests — the runtime theme holder that defeats the STATIC `Slate.theme` across the
// AppKit `NSSplitViewController` boundary. Pure logic only: `apply(_:)` mapping, the default Dracula
// invariant, and the IDENTITY-keyed cross-boundary change notification. NO
// SCStream/VT/Metal/VideoWindowView is touched.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class ThemeStoreTests: XCTestCase {
    /// The default terminal profile is Dracula — the dark glass product default. `isLight` is the
    /// GLASS's own polarity; the CHROME polarity is the frame's (inverted — the Canario structure
    /// both shipped profiles wear, round-8 verdict, user-directed 2026-08-07).
    func testDefaultIsDracula() {
        let store = ThemeStore()
        XCTAssertFalse(store.active.isLight, "Dracula is dark glass ⇒ isLight is false")
        XCTAssertEqual(store.active.id, "dracula")
    }

    func testApplyMapsThemeChoiceToTheTheme() {
        let store = ThemeStore()
        store.apply(.dracula)
        XCTAssertEqual(store.active.id, "dracula")
        XCTAssertFalse(store.active.isLight, "Dracula: dark glass")
        store.apply(.alucard)
        XCTAssertEqual(store.active.id, "alucard")
        XCTAssertTrue(store.active.isLight, "Alucard is light glass")
        // nil (appearance reset/unset) FOLLOWS the OS (whole-app theme, user-directed 2026-08-07):
        // OS dark → Dracula, OS light → Alucard. The probe is stubbed for determinism.
        store.osIsDark = { true }
        store.active = .alucard
        store.apply(nil)
        XCTAssertEqual(store.active.id, "dracula", "nil in dark mode → the dark default")
        store.osIsDark = { false }
        store.active = .dracula
        store.apply(nil)
        XCTAssertEqual(store.active.id, "alucard", "nil in light mode → the light default")
    }

    /// Each profile carries the libghostty terminal bg/fg for its glass — the pinned cell colours:
    /// the Dracula Pro glass verbatim, and Alucard's cream from the public spec.
    func testTerminalBackgroundMatchesPublishedPalette() {
        XCTAssertEqual(SlateTheme.dracula.terminalBackgroundHex, "22212C")
        XCTAssertEqual(SlateTheme.dracula.terminalForegroundHex, "F8F8F2")
        XCTAssertEqual(SlateTheme.alucard.terminalBackgroundHex, "FFFBEB")
        XCTAssertEqual(SlateTheme.alucard.terminalForegroundHex, "1F1F1F")
    }

    /// Both shipped profiles are INVERTED (the Canario frame, round-8 verdict): the floor is the
    /// authored frame pole (opposite polarity, the glass's hue family) and the CHROME polarity is
    /// the flip of the glass polarity. Pinned values lock the picked frame depths — Dracula's is
    /// the lavender-gradient pair from the liquid-glass round (the Pro-band plate #C3BAF0 pulled
    /// 22%/35% toward the deep accent, user-directed 2026-08-07); the trial's paler #AFACD2 was
    /// rejected as washed.
    func testFrameStructure() {
        // Dracula: dark glass, mid-light violet frame, light chrome standing on it.
        XCTAssertFalse(SlateTheme.dracula.isLight, "the glass stays dark")
        XCTAssertTrue(SlateTheme.dracula.chromeIsLight, "the chrome flips light onto the frame")
        XCTAssertEqual(SlateTheme.dracula.floorHexValue, 0xB0A2EA, "the picked dark-theme frame")
        XCTAssertEqual(SlateTheme.dracula.floorDeepHexValue, 0xA493E7, "the frame gradient's deep pole")
        // Alucard: cream glass, deep violet frame, dark chrome standing on it.
        XCTAssertTrue(SlateTheme.alucard.isLight, "the glass is light")
        XCTAssertFalse(SlateTheme.alucard.chromeIsLight, "the chrome flips dark onto the frame")
        XCTAssertEqual(SlateTheme.alucard.floorHexValue, 0x4C4869, "the picked light-theme frame")
        XCTAssertEqual(
            SlateTheme.alucard.floorDeepHexValue, 0x4C4869,
            "no authored gradient — the deep pole equals the floor",
        )
    }

    /// A theme change posts the cross-`NSHostingController` repaint notification keyed on theme
    /// IDENTITY; an idempotent re-apply of the SAME theme does NOT.
    func testApplyPostsChangeNotificationOnIdentityChange() {
        let store = ThemeStore.shared
        store.active = .dracula

        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: nil, queue: nil,
        ) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        store.apply(.dracula) // no change → no post
        XCTAssertEqual(posts.value, 0)
        store.apply(.alucard) // different identity → one post
        XCTAssertEqual(posts.value, 1)
        store.apply(.alucard) // idempotent → no post
        XCTAssertEqual(posts.value, 1)
        store.apply(.dracula) // back → one more post
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
            theme: .alucard, themeDark: .dracula, useSeparateDarkTheme: true,
        ))
        XCTAssertEqual(store.active.id, "alucard", "OS light → the primary/light slot")
        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "dracula", "OS dark → the dark slot, live")
        dark = false
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "alucard", "flip back to light, live")
    }

    /// An OS flip posts the cross-boundary repaint EXACTLY when the resolved theme actually changes (a
    /// follow-OS user), and a re-resolve with no OS change posts nothing.
    func testReresolvePostsOnOSFlipForSeparateDark() {
        let store = ThemeStore()
        var dark = false
        store.osIsDark = { dark }
        store.apply(appearance: AppearancePreferences(
            theme: .alucard, themeDark: .dracula, useSeparateDarkTheme: true,
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
        store.apply(appearance: AppearancePreferences(theme: .alucard))
        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: store, queue: nil,
        ) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        dark = true
        store.reresolveForOSAppearance()
        XCTAssertEqual(posts.value, 0, "a fixed (non-follow-OS) theme doesn't change on an OS flip")
        XCTAssertEqual(store.active.id, "alucard")
    }

    /// The legacy `.system` single choice FOLLOWS the OS through `apply(appearance:)` — the built-in
    /// pair flips live on an OS switch (user-directed 2026-08-07, whole-app theme).
    func testSystemChoiceFollowsOSThroughApplyAppearance() {
        let store = ThemeStore()
        store.osIsDark = { true }
        store.apply(appearance: AppearancePreferences(theme: .system))
        XCTAssertEqual(store.active.id, "dracula", "OS dark → Dracula")
        store.osIsDark = { false }
        store.reresolveForOSAppearance()
        XCTAssertEqual(store.active.id, "alucard", "OS light → Alucard (follow-OS)")
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
        // The leaf default ids resolve to the built-in pair (dark → Dracula, light → Alucard).
        XCTAssertEqual(ThemeStore.builtin(id: ThemeResolution.defaultDarkID)?.id, SlateTheme.dracula.id)
        XCTAssertEqual(ThemeStore.builtin(id: ThemeResolution.defaultLightID)?.id, SlateTheme.alucard.id)
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
