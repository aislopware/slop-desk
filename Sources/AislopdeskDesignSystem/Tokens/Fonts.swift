// Fonts — registration entry point (ORCH-DECISIONS F2). We will BUNDLE Hack (MIT) + Roboto
// (Apache-2.0) into the app later for tight text parity. We do NOT vendor Warp's proprietary fonts
// (F3) — only reference the open families by name. For now `register()` is a graceful no-op when the
// .ttf isn't bundled yet, and `font(...)` falls back to the matching system font so headless builds
// and pre-bundle app runs render with a sensible substitute.

import CoreGraphics
import SwiftUI

public enum Fonts {
    /// Fallback design intent when a bundled family is unavailable.
    public enum Fallback {
        case `default` // system UI font
        case monospaced // system monospaced
    }

    /// Whether the custom families have been registered (set true once `register()` finds the .ttf).
    public private(set) nonisolated(unsafe) static var registered = false

    /// Register the bundled fonts. No-ops gracefully if the .ttf assets aren't bundled yet (F2: the
    /// fonts ship with the app target later). Safe to call multiple times.
    @discardableResult
    public static func register(bundle _: Bundle = .main) -> Bool {
        // Intentionally a no-op until the Hack/Roboto .ttf assets are bundled into the app target.
        // When they are, this will register them via CTFontManagerRegisterFontsForURL and set
        // `registered = true`. Until then we fall back to system fonts (see `font(...)`).
        registered
    }

    /// Resolve a `Font` for `family` at `size`/`weight`. Uses the custom family when registered,
    /// otherwise the system fallback so nothing is invisible before bundling.
    public static func font(
        family: String,
        size: CGFloat,
        weight: Font.Weight,
        fallback: Fallback,
    ) -> Font {
        if registered {
            return .custom(family, fixedSize: size).weight(weight)
        }
        switch fallback {
        case .default:
            return .system(size: size, weight: weight)
        case .monospaced:
            return .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
