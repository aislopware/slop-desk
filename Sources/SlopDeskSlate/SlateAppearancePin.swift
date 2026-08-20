// SlateAppearancePin — pins the WHOLE APP to the CHROME polarity, once, at launch, on BOTH clients.
//
// This is all that survives of `ThemeStore` (deleted 2026-08-08 with the theme picker). There is no
// runtime theme to hold any more — `Slate.theme` is a constant — but the pin itself is still needed,
// and for the reason law 4 gives: the ground is Alucard's cream, so every semantic system colour in
// the chrome must resolve LIGHT or the navigator draws white-on-cream under an OS in dark mode. The
// app does not follow the OS appearance at all; the terminal glass is the one surface outside the
// pin, and it opts out locally through ``Slate/glassColorScheme``.
//
// ⚠️ THE REQUIREMENT IS THE GROUND'S, SO IT BELONGS TO BOTH PLATFORMS. The cream is
// ``Slate/Surface/field``, a FIXED hex on either OS, and the ink standing on it is the system's own
// label ladder — the same pairing on the phone as on the Mac. `NavigatorColumn` paints
// `Surface.field` and draws ``Slate/Text/primary`` on it, exactly as the Mac's navigator does, and
// on iOS that rung is `UIColor.label`: WHITE under an OS in dark mode, on a cream that does not
// move, at ~1.1 : 1. The whole floating family inherits the same fault one level up —
// ``SlatePaperCard`` states in its own header that "the card stands on the CHROME's polarity … so
// every one of those inks resolves dark on the cream without a single call site changing", which is
// a sentence that is only true while something is holding that polarity. The iOS arm below is not a
// courtesy port of a Mac feature; it is the half of one pin that the ground has always required.
//
// WHAT ACTUALLY DIFFERS BETWEEN THE TWO ARMS IS ARITY, and it is why they are not the same code:
//
//   * macOS has ONE `NSApp`, and it does not exist yet inside `App.init`. So the Mac arm arms a
//     ONE-SHOT `didFinishLaunching` observer and removes it the moment it fires — after that there
//     is nothing left in the process that could ever need pinning.
//   * iOS has N `UIWindowScene`s, arriving across the whole life of the process
//     (`UIApplicationSceneManifest` declares `UIApplicationSupportsMultipleScenes`, so an iPad can
//     open a second window an hour in). A one-shot would leave that window on the OS appearance, so
//     the phone's observer STAYS ARMED for the life of the process.
//
// THE OVERRIDE LANDS ON THE SCENE, NOT ON A WINDOW OR ON A VIEW, and that is what makes it reach the
// three places this client actually needs it to reach:
//
//   * `.sheet` / `.fullScreenCover` — the settings sheet, the cheat sheet, the first-launch sheet,
//     the code panel. Each is presented into the scene's own window, so each inherits the scene's
//     traits. A `preferredColorScheme` at the root of the `WindowGroup` is a modifier on the
//     presentation CONTAINING it, which is the one thing a summoned surface is outside of.
//   * the `UIView`s hosted inside SwiftUI by `UIViewRepresentable` (the terminal input host, the
//     search field, the device screens, the code panel's `WKWebView`). None of those read SwiftUI's
//     `\.colorScheme`; all of them inherit the window's trait collection.
//   * windows that DO NOT EXIST YET. `traitOverrides` is inherited by every window the scene owns,
//     including ones SwiftUI has not created; `UIWindow.overrideUserInterfaceStyle` set in a loop is
//     a snapshot of the windows that happened to exist when the loop ran, which is the same staleness
//     the one-shot-versus-armed split above is about. One mechanism, not two.
//
// It also survives an OS appearance flip mid-session by construction, on both platforms: an override
// is not a default, so the system's change never reaches through it and there is nothing to re-apply.
//
// The POLARITY ITSELF IS SPELLED ONCE — ``Slate/chromeColorScheme`` — and each arm derives its
// platform's value from that rung rather than restating `.aqua` / `.light`. That is already the rung
// a subtree climbing back OUT of the glass reads (``SlatePaperCapsule``); a pin holding its own copy
// would be the one place in the app that did not follow if it ever moved.

#if canImport(SwiftUI)
import Foundation
import SwiftUI // ColorScheme — `Slate.chromeColorScheme`, the one spelling of the polarity
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The app-level chrome-appearance pin.
@MainActor
package enum SlateAppearancePin {
    /// Pin every appearance container this app owns, and keep pinning the ones that arrive later.
    ///
    /// Called from each shell's `App.init`, which on BOTH platforms runs BEFORE the thing that has to
    /// be pinned exists: `NSApplicationMain` creates `NSApp` afterwards, and the first
    /// `UIWindowScene` connects afterwards. The direct pin therefore silently no-ops at the launch
    /// call site — which is what used to leave the chrome on the OS appearance while the glass wore
    /// its own palette — so each arm pins whatever is already there and observes for what is not.
    /// See the file header for why the Mac's observer disarms itself and the phone's does not.
    package static func install() {
        #if canImport(AppKit)
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
        #elseif canImport(UIKit)
        // Idempotent: a second `install()` must not stack a second observer on the same scenes.
        guard sceneToken == nil else { return }
        // Whatever is already connected — empty at the `App.init` call site, non-empty for any later
        // caller, and the same both-paths shape the Mac arm's `NSApp == nil` guard has.
        for scene in UIApplication.shared.connectedScenes { pin(scene) }
        // ⚠️ THE NOTIFICATION ITSELF IS NOT READ, and that is a concurrency requirement rather than a
        // style choice: `Notification` is not `Sendable`, so reaching for its `object` inside the
        // `MainActor` body sends a non-sendable value across an isolation boundary and Swift 6 refuses
        // it — the one error `scripts/check-ios.sh` catches that a standalone `swiftc -typecheck` of
        // this file does not. So the arm does what the Mac's `{ _ in }` already does: it ignores the
        // payload and re-derives the work. Re-pinning every connected scene is idempotent (an override
        // assigned twice is the same override), self-healing if a scene was ever missed, and correct
        // for the scene that just arrived, which `connectedScenes` already names by the time this
        // posts.
        sceneToken = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: nil,
        ) { _ in
            MainActor.assumeIsolated {
                for scene in UIApplication.shared.connectedScenes { pin(scene) }
            }
        }
        #endif
    }

    #if canImport(AppKit)
    /// The armed one-shot launch observer, `nil` once it has fired (or if the pin landed directly).
    private static var launchToken: NSObjectProtocol?

    /// Pin the one application object. `NSApp.appearance` rather than per-window pins, so Settings,
    /// overlays, sheets and menus inherit it too — one appearance voice, never a split-tone
    /// half-and-half.
    private static func pin() {
        let name: NSAppearance.Name = Slate.chromeColorScheme == .dark ? .darkAqua : .aqua
        NSApp?.appearance = NSAppearance(named: name)
    }
    #elseif canImport(UIKit)
    /// The scene observer, armed for the LIFE OF THE PROCESS. It is the ONE piece of this file that
    /// is deliberately never removed: a second window can connect at any moment on iPad, and a
    /// window that connects unpinned is a window drawing the system's dark label ladder on the
    /// cream. There is nothing to balance it against — the pin outlives every scene it pins.
    private static var sceneToken: NSObjectProtocol?

    /// Pin one scene. Non-window scenes (there are none in this app today, but `connectedScenes` is
    /// typed for them) have no traits to override and are skipped rather than force-cast.
    private static func pin(_ scene: UIScene?) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.traitOverrides.userInterfaceStyle =
            Slate.chromeColorScheme == .dark ? .dark : .light
    }
    #endif
}
#endif
