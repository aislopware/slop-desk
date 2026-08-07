// ThemeStore — the runtime theme holder that defeats the STATIC `Slate.theme` across the AppKit
// `NSSplitViewController` boundary.
//
// WHY a store and not a SwiftUI Environment value: the three columns are hosted in `NSHostingController`s
// inside `SlopDeskSplitViewController`, so a `.preferredColorScheme` / `@Environment` set on
// `WorkspaceRootView` does NOT cross into them (SlateDesign documents this; DECISIONS records the
// half-repaint bug). The `Slate.*` colour accessors therefore read this @Observable store instead of a
// compile-time `static let theme`. On a theme change the GUI must (a) repoint `active` here so SwiftUI
// re-reads the tokens, AND (b) re-inject each `NSHostingController` + re-pin `NSWindow.appearance`
// (handled in `SlopDeskSplitViewController`) — otherwise the window half-repaints.
//
// DEFAULT `.dracula`: a headless / no-store render resolves `Slate.theme` to the Dracula palette.
// The golden corpus is unaffected — chrome colour never crosses into the wire vectors
// (appearance is pure client chrome, never folded into `EnvConfig`/the sidecar).
//
// DUAL-SLOT FOLLOW-OS: `apply(appearance:)` resolves the active built-in theme id for the
// CURRENT OS appearance (via the pure leaf `ThemeResolution`) and repoints `active`. A macOS OS-appearance
// observer re-resolves LIVE on a system light/dark switch, so a follow-OS (or legacy `.system`) user sees
// the theme flip without a restart.

#if canImport(SwiftUI)
import Foundation
import Observation
import SlopDeskVideoProtocol
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The single live owner of the active ``SlateTheme``. Read by ``Slate/theme`` (so every token resolves the
/// runtime theme) and repointed by the appearance apply path. Default `.dracula` ⇒ byte-identical
/// headless.
@MainActor
@Observable
final class ThemeStore {
    /// The process-wide active store. `Slate.theme` reads `ThemeStore.shared.active`.
    static let shared = ThemeStore()

    /// Posted AFTER ``active`` changes so the AppKit shell (``SlopDeskSplitViewController``) can re-pin
    /// `NSWindow.appearance` + nudge the hosted columns — the cross-`NSHostingController` repaint SwiftUI's
    /// `@Observable` observation does not reach.
    static let didChangeNotification = Notification.Name("SlopDeskThemeStoreDidChange")

    /// The active theme. Default Dracula (dark) — the product default; a no-store / headless
    /// render resolves the same Dracula palette.
    var active: SlateTheme = .dracula

    /// The appearance prefs last applied — re-resolved on an OS-appearance flip so a dual-slot / `.system`
    /// user follows the system colour scheme LIVE. `nil` until the first ``apply(appearance:)`` (the OS
    /// observer is then a no-op — there is nothing to re-resolve).
    @ObservationIgnored private var lastAppearance: AppearancePreferences?

    /// OS-appearance probe (injectable for tests). Default reads `NSApp.effectiveAppearance` on macOS; a test
    /// supplies a stub to drive the dual-slot / live-switch logic with NO `NSApp`.
    @ObservationIgnored var osIsDark: () -> Bool = { ThemeStore.systemIsDark() }

    /// The live macOS OS-appearance observer token (`AppleInterfaceThemeChangedNotification`). Installed only
    /// on the singleton via ``observeOSAppearanceChanges()`` — never in a test instance, so no distributed
    /// observer leaks per test. Unconditional (NSObjectProtocol exists on every platform) to keep the
    /// `@Observable` body free of a `#if`-conditional stored property; iOS leaves it `nil`.
    @ObservationIgnored private var osObserverToken: NSObjectProtocol?

    /// One-shot `NSApplication.didFinishLaunching` token: the launch-time appearance apply runs in
    /// `App.init`, BEFORE `NSApplicationMain` creates `NSApp`, so the app-level pin silently no-ops
    /// there. This observer re-pins once the application object exists — without it a persisted
    /// theme launches into the OS appearance (dark glass under light chrome, the half-and-half the
    /// whole-app theme forbids). Unconditional stored property for the same `@Observable` reason as
    /// ``osObserverToken``.
    @ObservationIgnored private var launchRepinToken: NSObjectProtocol?

    init() {}

    // MARK: - Apply

    /// Apply the whole ``AppearancePreferences``: resolve the active built-in theme id for the
    /// CURRENT OS appearance (dual-slot / follow-OS — ``ThemeResolution``) and repoint ``active``. Remembers
    /// the model so the OS observer can re-resolve live on a system light/dark switch.
    func apply(appearance: AppearancePreferences) {
        lastAppearance = appearance
        applyResolved(for: appearance)
    }

    /// Apply a bare ``ThemeChoice`` (the legacy single-slot selection). A thin convenience over
    /// ``apply(appearance:)`` — wraps the choice in a primary-slot-only ``AppearancePreferences`` so it routes
    /// through the SAME dual-slot resolution (`.system` still follows the OS, `nil` ⇒ the compile-time default
    /// Dracula).
    func apply(_ choice: ThemeChoice?) {
        apply(appearance: AppearancePreferences(theme: choice))
    }

    /// Re-resolve the active theme from the LAST-applied appearance under the (now-changed) OS appearance.
    /// Invoked by the macOS OS-appearance observer AND directly by tests (with a stubbed ``osIsDark``). A no-op
    /// before the first ``apply(appearance:)``. Posts ``didChangeNotification`` only on a real identity change,
    /// so a non-follow-OS user's flip is a silent no-op (the resolved theme doesn't depend on the OS).
    func reresolveForOSAppearance() {
        guard let lastAppearance else { return }
        applyResolved(for: lastAppearance)
    }

    /// Resolve `appearance` → a concrete ``SlateTheme`` for the current OS appearance and repoint ``active``.
    /// An unknown built-in id gracefully falls back to the default theme — never a crash.
    private func applyResolved(for appearance: AppearancePreferences) {
        let id = ThemeResolution.activeBuiltinID(appearance: appearance, osIsDark: osIsDark())
        setActive(Self.builtin(id: id) ?? .dracula)
    }

    /// Repoint ``active`` and post the cross-boundary repaint notification on any theme CONTENT change (not
    /// just the `id`) — so a SAME-lightness variant switch (e.g. Classic → Spectrum) re-pins the AppKit
    /// columns (`SlopDeskSplitViewController.pinWindowAppearance` is notification-driven). An idempotent
    /// re-apply of an identical theme still posts nothing.
    private func setActive(_ resolved: SlateTheme) {
        let changed = resolved != active
        active = resolved
        // GLASS polarity — the theme's IDENTITY: a dark theme is a dark APP (Settings, palette,
        // sheets, menus), even though its frame chrome is inverted. The frame's flipped polarity is
        // a per-column pin inside `SlopDeskSplitViewController.pinWindowAppearance`, NOT the
        // app-level appearance (user-directed 2026-08-07: Dracula must not light up Settings).
        pinAppAppearance(isLight: resolved.isLight)
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Pin the WHOLE APP's appearance to the active theme's GLASS polarity (user-directed
    /// 2026-08-07, polish round): the theme choice drives every window — Settings, overlays,
    /// sheets, menus — so a dark theme is an all-dark app and a light theme an all-light one,
    /// never the split-tone half-and-half. The inverted FRAME chrome opts out per column
    /// (`SlopDeskSplitViewController.pinWindowAppearance`) rather than steering this pin — pinning
    /// the flip here inverted every auxiliary surface (light Settings under Dracula).
    /// `NSApp.appearance` (not per-window pins) so auxiliary windows inherit it too.
    /// Follow-OS users still follow the OS: the resolver flips the theme on an OS switch and this
    /// re-pins to match. Singleton-only — a test instance must not restyle the test-runner app.
    private func pinAppAppearance(isLight: Bool) {
        #if os(macOS)
        guard self === Self.shared else { return }
        guard let app = NSApp else {
            // The launch-time apply (`PreferencesStore` init inside `App.init`) runs before
            // `NSApplicationMain` — no `NSApp` yet. Defer to a one-shot didFinishLaunching re-pin;
            // dropping the pin here would leave the chrome on the OS appearance while the glass
            // wears the persisted theme.
            installLaunchRepinIfNeeded()
            return
        }
        app.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        #endif
    }

    #if os(macOS)
    /// Install the one-shot launch re-pin (idempotent). Fires after `NSApp` exists, re-pins the
    /// CURRENT theme polarity, and removes itself — later re-pins ride the normal apply path.
    private func installLaunchRepinIfNeeded() {
        guard launchRepinToken == nil else { return }
        launchRepinToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.launchRepinToken {
                    NotificationCenter.default.removeObserver(token)
                    self.launchRepinToken = nil
                }
                self.pinAppAppearance(isLight: self.active.isLight)
            }
        }
    }
    #endif

    // MARK: - Built-in lookup

    /// The shipped ``SlateTheme`` for a stable built-in id (the inverse of ``ThemeChoice/builtinID`` /
    /// `SlateTheme.id`), or `nil` for an unknown id (the caller substitutes the default). MIRRORS the
    /// `ThemeChoice` → id mapping; the end-to-end `ThemeStoreTests` round-trip pins both halves.
    static func builtin(id: String) -> SlateTheme? {
        switch id {
        case "dracula": .dracula
        case "alucard": .alucard
        default: nil
        }
    }

    // MARK: - OS appearance

    /// Whether the OS is currently in dark mode. NOT `NSApp.effectiveAppearance`: the app pins its own
    /// appearance to the theme's polarity (``pinAppAppearance(isLight:)``), so once pinned the app-level
    /// probe reports the PIN, not the OS — a follow-OS user's next OS flip would then re-resolve against
    /// the stale answer. The `AppleInterfaceStyle` defaults key is the OS-level truth the pin cannot
    /// shadow (`"Dark"` when dark, absent when light). The default backing for ``osIsDark``; a test
    /// overrides the closure instead.
    static func systemIsDark() -> Bool {
        #if os(macOS)
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        #else
        return false
        #endif
    }

    /// Resolve the OS appearance to an ``SlateTheme`` (Dark mode ⇒ Dracula, else Alucard).
    /// Kept for the legacy `.system` built-in resolution path / any non-dual-slot caller.
    static func systemTheme() -> SlateTheme {
        systemIsDark() ? .dracula : .alucard
    }

    /// Install the live macOS OS-appearance observer (idempotent). On a system light/dark switch it
    /// re-resolves the active slot from the last-applied appearance, so a dual-slot / `.system` user follows
    /// the system colour scheme LIVE (the ``didChangeNotification`` then re-pins the AppKit columns). Called
    /// ONCE on ``shared`` at app launch; NOT in tests (they drive ``reresolveForOSAppearance()`` directly with
    /// a stubbed ``osIsDark``), so no distributed observer leaks per test instance. A no-op on iOS (no
    /// distributed interface-style notification — the iOS appearance flip is a view-trait concern).
    func observeOSAppearanceChanges() {
        #if os(macOS)
        guard osObserverToken == nil else { return }
        osObserverToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            // The distributed notification can arrive a hair BEFORE `NSApp.effectiveAppearance` flips; hop to
            // the next main-actor tick so the probe reads the SETTLED appearance, then re-resolve.
            Task { @MainActor in self?.reresolveForOSAppearance() }
        }
        #endif
    }
}
#endif
