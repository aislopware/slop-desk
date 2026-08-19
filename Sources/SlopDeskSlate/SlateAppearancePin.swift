// SlateAppearancePin — pins the WHOLE APP to the light appearance, once, at launch.
//
// This is all that survives of `ThemeStore` (deleted 2026-08-08 with the theme picker). There is no
// runtime theme to hold any more — `Slate.theme` is a constant — but the pin itself is still needed,
// and for the reason law 4 gives: the ground is Alucard's cream, so every semantic system colour in
// the chrome must resolve LIGHT or the navigator draws white-on-cream under an OS in dark mode. The
// app does not follow the OS appearance at all; the terminal glass is the one surface outside the
// pin, and it opts out locally through ``Slate/glassColorScheme``.
//
// `NSApp.appearance` (not per-window pins) so Settings, overlays, sheets and menus inherit it too —
// one appearance voice, never a split-tone half-and-half.

#if canImport(SwiftUI)
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The app-level light-appearance pin.
@MainActor
package enum SlateAppearancePin {
    /// Pin now if `NSApp` exists; otherwise arm a one-shot re-pin for the moment it does.
    ///
    /// The launch-time call site runs inside `App.init`, BEFORE `NSApplicationMain` creates `NSApp`,
    /// so the direct pin silently no-ops there — which used to leave the chrome on the OS appearance
    /// while the glass wore its own palette. The didFinishLaunching observer closes that window and
    /// removes itself.
    package static func install() {
        #if os(macOS)
        guard NSApp == nil else {
            pin()
            return
        }
        guard launchToken == nil else { return }
        launchToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil,
        ) { _ in
            MainActor.assumeIsolated {
                if let token = launchToken {
                    NotificationCenter.default.removeObserver(token)
                    launchToken = nil
                }
                pin()
            }
        }
        #endif
    }

    #if os(macOS)
    /// The armed one-shot launch observer, `nil` once it has fired (or if the pin landed directly).
    private static var launchToken: NSObjectProtocol?

    private static func pin() {
        NSApp?.appearance = NSAppearance(named: .aqua)
    }
    #endif
}
#endif
