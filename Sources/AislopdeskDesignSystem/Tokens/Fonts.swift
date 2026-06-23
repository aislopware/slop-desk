// Fonts — bundled-font registration entry point (ORCH-DECISIONS F2). We BUNDLE the freely licensed
// Hack (MIT, terminal/monospace) + Roboto (Apache-2.0, UI chrome) families as SwiftPM resources of
// `AislopdeskDesignSystem` (`.process("Resources/Fonts")`) so SwiftUI text and `ImageRenderer` resolve
// the SAME glyphs the Warp reference uses, for tight text odiff parity. We do NOT vendor Warp's
// proprietary fonts (F3) — only these open families.
//
// `register()` registers every bundled `.ttf` with the process-wide CoreText font manager from
// `Bundle.module`, so `Font.custom("Hack"/"Roboto", …)` resolves. It is graceful: a missing/duplicate
// face never throws, and when nothing registers the resolvers in `WarpType` fall back to the matching
// system font so headless builds and pre-bundle runs still render a sensible substitute.

import CoreGraphics
import CoreText
import Foundation
import SwiftUI

public enum Fonts {
    /// Fallback design intent when a bundled family is unavailable.
    public enum Fallback {
        case `default` // system UI font
        case monospaced // system monospaced
    }

    /// The bundled face file stems (in `Resources/Fonts`), all `.ttf`.
    private static let bundledFaces = [
        "Hack-Regular", "Hack-Bold", "Hack-Italic", "Hack-BoldItalic",
        "Roboto-Regular", "Roboto-Medium", "Roboto-Bold", "Roboto-Italic",
    ]

    /// Whether the custom families have been registered (set true once `register()` finds the .ttf).
    public private(set) nonisolated(unsafe) static var registered = false

    /// Guards `register()` against re-entrancy / re-registration across threads.
    private nonisolated(unsafe) static var didAttempt = false
    private static let lock = NSLock()

    /// Register the bundled Hack + Roboto faces with CoreText so SwiftUI + `ImageRenderer` resolve them
    /// by family name. Idempotent and graceful: a face that is missing or already registered is skipped
    /// (never throws). Returns `true` once at least one face is available (so the resolvers switch off
    /// the system fallback). Defaults to `Bundle.module` (the DesignSystem resource bundle); a caller may
    /// pass a different bundle (e.g. the app bundle for `ImageRenderer` from another module).
    @discardableResult
    public static func register(bundle: Bundle? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didAttempt { return registered }
        didAttempt = true

        // `Bundle.module` is internal to this module, so it can't be a public default-arg value; resolve
        // it here. A caller may still override (e.g. an app bundle for `ImageRenderer` from elsewhere).
        let resourceBundle = bundle ?? .module
        var anyAvailable = false
        for stem in bundledFaces {
            guard let url = resourceBundle.url(forResource: stem, withExtension: "ttf") else { continue }
            var cfError: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
                anyAvailable = true
            } else {
                // A duplicate registration (already registered this process) still means the face IS
                // available — treat "already registered" as success; only a genuine failure is ignored.
                if let err = cfError?.takeRetainedValue() {
                    let code = CFErrorGetCode(err)
                    // kCTFontManagerErrorAlreadyRegistered == 105.
                    if code == 105 { anyAvailable = true }
                }
            }
        }
        registered = anyAvailable
        return registered
    }

    /// The list of bundled family names this module ships (for tests / diagnostics).
    public static let bundledFamilies = [WarpType.monospaceFamily, WarpType.uiFamily]

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
