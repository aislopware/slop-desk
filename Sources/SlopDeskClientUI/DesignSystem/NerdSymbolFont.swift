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

#if canImport(SwiftUI)
import CoreText
import SwiftUI

enum NerdSymbolFont {
    /// The bundled face's PostScript name (`Symbols Nerd Font`) — what `Font.custom` resolves after
    /// registration.
    static let postScriptName = "SymbolsNF"

    /// One-shot process registration of the bundled TTF. `true` once the face is available (or already
    /// was — e.g. the user installed it system-wide, which `CTFontManager` reports as already-registered).
    static let registered: Bool = {
        guard let url = Bundle.module.url(
            forResource: "SymbolsNerdFont-Regular", withExtension: "ttf", subdirectory: "Fonts",
        ) else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered (system-installed or a second bundle) still means the face resolves.
        let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) }
        return code == CTFontManagerError.alreadyRegistered.rawValue
            || code == CTFontManagerError.duplicatedName.rawValue
    }()

    /// Whether `scalar` sits in a Unicode PRIVATE-USE area — the space nerd fonts populate (the BMP PUA
    /// `U+E000–U+F8FF` plus planes 15/16, where the material-design set lives).
    static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
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
    static func strippingSymbols(_ string: String) -> String {
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
    static func runs(of text: some StringProtocol) -> [(text: String, isSymbol: Bool)] {
        var out: [(text: String, isSymbol: Bool)] = []
        for character in text {
            let symbol = character.unicodeScalars.first.map(isPrivateUse) ?? false
            if var last = out.last, last.isSymbol == symbol {
                last.text.append(character)
                out[out.count - 1] = last
            } else {
                out.append((String(character), symbol))
            }
        }
        return out
    }
}

extension Text {
    /// A `Text` over `string` whose private-use runs (nerd-font glyphs) render in the bundled Symbols
    /// Nerd Font at `size`, while ordinary runs carry NO font of their own — the caller's outer
    /// `.font(...)` fills them, so weight/size styling composes exactly as on a plain `Text`.
    static func nerdAware(_ string: some StringProtocol, size: CGFloat) -> Text {
        let runs = NerdSymbolFont.runs(of: string)
        // The common case — no symbol anywhere — must stay a PLAIN Text (no splice, no custom font),
        // so ordinary titles pay nothing and render byte-identically to before.
        guard NerdSymbolFont.registered, runs.contains(where: \.isSymbol) else {
            return Text(String(string))
        }
        return .spliced(runs.map { run in
            run.isSymbol
                ? Text(run.text).font(.custom(NerdSymbolFont.postScriptName, size: size))
                : Text(run.text)
        })
    }
}
#endif
