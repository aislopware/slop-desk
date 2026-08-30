// NerdSymbolFont — the bundled Symbols Nerd Font, and the one place chrome text learns to draw it.
//
// The TERMINAL grid already renders nerd-font glyphs: ghostty embeds this exact face as its fallback.
// The CHROME did not — a program/agent title carrying a private-use glyph (Claude Code's mark, a
// starship segment, an nvim filetype icon) fell through the system cascade to a notdef dot, because
// private-use codepoints have no system fallback BY DESIGN (they mean nothing outside the font that
// defines them). So the app bundles the same face the terminal answers with, and
// `NSAttributedString.slateNerdAware` (`SlopDeskSlate/SlateNativeText.swift`) splices it in for
// exactly the private-use runs — everything else keeps the caller's system font.
//
// Registration is process-scoped and lazy (first `nerdAware` call): no Info.plist coupling, works in
// the macOS app, the iOS app, and headless tests alike. The run splitter is pure so it is unit-pinned.

import CoreText
import CSlopDeskFFI
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

    /// The Unicode private-use ranges, read from `slopdesk_private_use_ranges` ONCE per process.
    ///
    /// The sanitizer DROPS these codepoints so an agent reads clean text; this file SPLICES the
    /// bundled face over exactly them so a human sees a glyph instead of a notdef box. Opposite
    /// operations over one set — so the set is spelled once, on the far side, and crosses here as a
    /// table rather than being typed again.
    ///
    /// ⚠️ IT WAS TYPED TWICE UNTIL 2026-08-26, and the two disagreed: the Rust copy was missing plane
    /// 16 entirely (`U+100000–U+10FFFD`, where the material-design icon set lives) and ran two
    /// codepoints past the end of plane 15 into a pair of noncharacters. Neither side could see the
    /// other, so neither had a test that could say so. `rust/slopdesk-sanitize/src/plaintext.rs`
    /// carries the detail.
    ///
    /// Read once and kept, never per scalar: this classifies every character of a title that is
    /// redrawn on every keystroke, and `runs(of:)` below is measured in nanoseconds. A door per
    /// scalar would be the right rule at the wrong rate.
    private static let privateUseRanges: [ClosedRange<UInt32>] = {
        let needed = Int(slopdesk_private_use_ranges(nil, 0))
        guard needed > 0, needed.isMultiple(of: 8) else { return [] }
        var blob = [UInt8](repeating: 0, count: needed)
        let written = blob.withUnsafeMutableBufferPointer {
            Int(slopdesk_private_use_ranges($0.baseAddress, $0.count))
        }
        guard written == needed else { return [] }
        return stride(from: 0, to: needed, by: 8).compactMap { offset in
            let low = beUInt32(blob, at: offset)
            let high = beUInt32(blob, at: offset + 4)
            // A door that answered a descending pair would be a door with a bug; refusing the pair
            // is what keeps that from becoming a trap inside `ClosedRange`.
            return low <= high ? low...high : nil
        }
    }()

    /// One big-endian `u32` out of the door's blob.
    private static func beUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    /// Whether `scalar` sits in a Unicode PRIVATE-USE area — the space nerd fonts populate (the BMP
    /// PUA `U+E000–U+F8FF` plus planes 15 and 16, where the material-design set lives).
    package static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        privateUseRanges.contains { $0.contains(scalar.value) }
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
    /// per-`Character` loop. The splice — `slateNerdAware`, ONE site now that the SwiftUI
    /// `Text.nerdAware` is gone and the two framework bodies have merged — already discards that
    /// answer whole when nothing is a symbol; this makes producing it cost what discarding it is
    /// worth. It is also what keeps the ordering of ITS `registered` guard from mattering: an
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
