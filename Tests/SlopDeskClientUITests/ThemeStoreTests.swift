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
    /// GLASS's own polarity, and since the flat round (user-directed 2026-08-08) the chrome wears
    /// the same polarity — one appearance voice, no frame flip.
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

    /// ONE ISLAND (user-directed 2026-08-08): the window holds exactly TWO tones. The GROUND —
    /// Alucard's published cream `#FFFBEB` — is the SAME in both profiles: every sunken surface (the
    /// navigator, the code panel, the band, the moat) stands on it, and the one lifted surface is
    /// the terminal canvas, whose tone IS the glass face by construction. Because the ground is
    /// light in both, the CHROME polarity is light in both — semantic ink pinned dark would draw
    /// white on cream. LINE is the in-island pane rule, still the ink tint — 10% dark vs 14.2%
    /// light, unequal on purpose so both themes step the same perceived lightness (OKLab ΔL ≈ 0.09).
    func testChromeLadderStructure() {
        // Dracula: a dark island on the cream ground — the Rio-Canario read.
        XCTAssertFalse(SlateTheme.dracula.isLight, "the glass stays dark")
        XCTAssertTrue(SlateTheme.dracula.chromeIsLight, "the ground is light, so the chrome is light")
        XCTAssertEqual(SlateTheme.dracula.chromeHexValue, 0x22212C, "the island IS the glass face")
        XCTAssertEqual(SlateTheme.dracula.groundHexValue, 0xFFFBEB, "Alucard's published cream, under both profiles")
        XCTAssertEqual(SlateTheme.dracula.chromeLineHexValue, 0x312F37, "10% ink #F8F8F2, for in-island rules")
        XCTAssertEqual(SlateTheme.dracula.chromeLiftHexValue, 0x2E2E3C, "rail offset +0C/+0D/+10 off the Pro face")
        // Alucard: the island and the ground are the SAME cream — the boundary is the corner and
        // the island's hairline edge, nothing else.
        XCTAssertTrue(SlateTheme.alucard.isLight, "the glass is light")
        XCTAssertTrue(SlateTheme.alucard.chromeIsLight, "the ground is light, so the chrome is light")
        XCTAssertEqual(SlateTheme.alucard.chromeHexValue, 0xFFFBEB, "the island IS the glass face")
        XCTAssertEqual(SlateTheme.alucard.groundHexValue, 0xFFFBEB, "its own face — ground and island coincide")
        XCTAssertEqual(SlateTheme.alucard.chromeLineHexValue, 0xD8D3C3, "14.2% ink #1F1F1F, for in-island rules")
        XCTAssertEqual(SlateTheme.alucard.chromeLiftHexValue, 0xFFFDF4)
    }

    /// The GROUND is one tone across the whole product — pinned as its own assertion because it is
    /// the single decision the layout rests on: three columns, one field, one island. A profile that
    /// re-invented its own ground would bring the many-islands clutter straight back.
    func testEveryProfileStandsOnTheSameGround() {
        let grounds = Set([SlateTheme.dracula, SlateTheme.alucard].map(\.groundHexValue))
        XCTAssertEqual(grounds, [0xFFFBEB], "one ground for every profile")
        XCTAssertTrue(
            [SlateTheme.dracula, SlateTheme.alucard].allSatisfy(\.chromeIsLight),
            "a light ground forces a light chrome polarity in every profile",
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
