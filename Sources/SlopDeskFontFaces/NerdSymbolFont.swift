// NerdSymbolFont — the bundled Symbols Nerd Font, and the one place chrome text learns to draw it.
//
// The TERMINAL grid already renders nerd-font glyphs: ghostty embeds this exact face as its fallback.
// The CHROME did not — a program/agent title carrying a private-use glyph (Claude Code's mark, a
// starship segment, an nvim filetype icon) fell through the system cascade to a notdef dot, because
// private-use codepoints have no system fallback BY DESIGN (they mean nothing outside the font that
// defines them). So the app bundles the same face the terminal answers with, and `Text.nerdAware`
// splices it in for exactly the private-use runs — everything else keeps the caller's system font.
//
// Registration is process-scoped and lazy (first `nerdAware` call): no Info.plist coupling, works in
// the macOS app, the iOS app, and headless tests alike. The run splitter is pure so it is unit-pinned.

import CoreText
import Foundation

package enum NerdSymbolFont {
    /// The bundled face's PostScript name (`Symbols Nerd Font`) — what `Font.custom` resolves after
    /// registration.
    package static let postScriptName = "SymbolsNF"

    /// The bundled TTF — registration below, and the code sidebar's @font-face injection (the
    /// webview's WebContent process cannot see a `CTFontManager` process-scope registration, so it
    /// gets the same bytes as a data URI).
    package static var bundledFontURL: URL? {
        Bundle.module.url(
            forResource: "SymbolsNerdFont-Regular", withExtension: "ttf", subdirectory: "Fonts",
        )
    }

    /// One-shot process registration of the bundled TTF. `true` once the face is available (or already
    /// was — e.g. the user installed it system-wide, which `CTFontManager` reports as already-registered).
    package static let registered: Bool = {
        guard let url = bundledFontURL else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered (system-installed or a second bundle) still means the face resolves.
        let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) }
        return code == CTFontManagerError.alreadyRegistered.rawValue
            || code == CTFontManagerError.duplicatedName.rawValue
    }()

    /// Whether `scalar` sits in a Unicode PRIVATE-USE area — the space nerd fonts populate (the BMP PUA
    /// `U+E000–U+F8FF` plus planes 15/16, where the material-design set lives).
    package static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF,
             0xF0000...0xFFFFD,
             0x100000...0x10FFFD: true
        default: false
        }
    }

    /// `string` with its private-use glyphs REMOVED — for system-drawn surfaces (the window titlebar)
    /// no custom-font splice can reach, where a stripped word beats a notdef box. Whitespace stranded
    /// by the removal is tidied so `"\u{E0A0} repo"` comes back `"repo"`, not `" repo"`. Pure.
    package static func strippingSymbols(_ string: String) -> String {
        guard string.unicodeScalars.contains(where: isPrivateUse) else { return string }
        let kept = String(String.UnicodeScalarView(string.unicodeScalars.filter { !isPrivateUse($0) }))
        return kept
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Split `text` into maximal runs of private-use vs ordinary characters, in order. Pure — the
    /// splice below is driven entirely by this, so the classification is unit-pinned headlessly.
    /// A character counts as private-use when its FIRST scalar is (a nerd glyph followed by a variation
    /// selector stays one run).
    ///
    /// Two things here are load-bearing for the clock, and neither is visible in the answer.
    ///
    /// The scalar scan first. Almost every string that reaches this is an ordinary title with no nerd
    /// glyph anywhere, and the answer for one is a single run holding the whole string — so it is
    /// produced from one `Unicode.Scalar` walk and one `String` copy, without ever entering the
    /// per-`Character` loop. Both splice sites (`slateNerdAware`, `Text.nerdAware`) already discard
    /// that answer whole when nothing is a symbol; this makes producing it cost what discarding it
    /// is worth. It is also what keeps the ordering of THEIR `registered` guard from mattering: an
    /// unregistered face now short-circuits a scalar scan, not a character walk.
    ///
    /// The accumulator second. The obvious shape — read the last run back out of `out`, append to it,
    /// write it back — is QUADRATIC, and silently: `out.last` hands back a copy of the tuple, so the
    /// run's `String` is momentarily two-referenced and `append` copy-on-writes the whole run before
    /// adding one character. Growing a uniquely-referenced local instead keeps the append amortised
    /// O(1). Measured, `swiftc -O`, two runs agreeing: a plain 48-character title **3,563 → 104 ns**,
    /// a 240-character one **21,588 → 371 ns** (58×), a mixed 45-character one 2,649 → 1,220 ns. Every
    /// `.slateNerdAware` string in three overlays walks this once per keystroke.
    package static func runs(of text: some StringProtocol) -> [(text: String, isSymbol: Bool)] {
        guard text.unicodeScalars.contains(where: isPrivateUse) else {
            let whole = String(text)
            return whole.isEmpty ? [] : [(whole, false)]
        }
        var out: [(text: String, isSymbol: Bool)] = []
        var current = ""
        var currentIsSymbol = false
        for character in text {
            let symbol = character.unicodeScalars.first.map(isPrivateUse) ?? false
            if current.isEmpty {
                currentIsSymbol = symbol
            } else if symbol != currentIsSymbol {
                out.append((current, currentIsSymbol))
                current = ""
                currentIsSymbol = symbol
            }
            current.append(character)
        }
        if !current.isEmpty { out.append((current, currentIsSymbol)) }
        return out
    }
}

/// The bundled JetBrains Mono VARIABLE faces (upright + italic, weights 100–800 in one file each) —
/// the terminal's true face: libghostty embeds JetBrains Mono and renders it whenever the preferred
/// "SF Mono" does not resolve (it is absent on a stock system — verified via CoreText on both dev
/// machines). The code sidebar injects these bytes as @font-face data URIs so the embedded editor
/// shares the terminal's mono exactly (`CodeSidebarPageDressing`); the chrome itself keeps
/// `Slate.Typeface` (which independently prefers JetBrains Mono when installed). Vendored from the
/// same upstream release ghostty pins (OFL-1.1 — license beside the TTFs).
package enum JetBrainsMonoFont {
    /// The upright variable TTF (`JetBrainsMono[wght]`).
    package static var bundledUprightURL: URL? {
        Bundle.module.url(forResource: "JetBrainsMono-VF", withExtension: "ttf", subdirectory: "Fonts")
    }

    /// The italic variable TTF (`JetBrainsMono-Italic[wght]`).
    package static var bundledItalicURL: URL? {
        Bundle.module.url(forResource: "JetBrainsMono-Italic-VF", withExtension: "ttf", subdirectory: "Fonts")
    }
}
