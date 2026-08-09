// SlateAnsiInk — resolves a wire ``AnsiColor`` to an actual colour, and the TERMINAL's own face to
// an actual font. Both live here because both are the VIEW's knowledge: the parser in WorkspaceCore
// reports "palette slot 2" and "bold", and only the design layer knows which green slot 2 is on this
// profile and which installed family the pane is wearing (user-directed 2026-08-09 — the ladder's
// peek shows a command's output the way the terminal showed it, colours and nerd-font glyphs
// included).

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Slate {
    /// The ANSI ink resolver — a wire colour slot to a drawable colour, on THIS profile's palette.
    @MainActor
    enum Ansi {
        /// Resolves `colour` against the profile's 16-entry palette (the very entries libghostty is
        /// configured with, so a slot means the same thing in the card as it does in the cells), the
        /// xterm 6×6×6 cube, and the 24-step greyscale ramp. A direct 24-bit colour is drawn as sent.
        static func ink(_ colour: AnsiColor) -> Color {
            switch colour {
            case let .rgb(r, g, b):
                Color(
                    .sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
                    opacity: 1,
                )
            case let .indexed(slot):
                indexed(slot)
            }
        }

        /// Slot 0–15 come from the PROFILE (so the card's red is the terminal's red); 16–231 are the
        /// standard cube; 232–255 the grey ramp. The cube and ramp are the xterm definitions — they
        /// are not a profile's to redefine, and libghostty derives them the same way.
        private static func indexed(_ slot: UInt8) -> Color {
            let palette = SlateTheme.app.ansiPalette
            if slot < 16 {
                let index = Int(slot)
                if palette.indices.contains(index), let hex = UInt32(palette[index], radix: 16) {
                    return Color(slateHex: hex)
                }
                return Slate.Terminal.ink
            }
            if slot < 232 {
                // The 6×6×6 cube: each axis steps 0, 95, 135, 175, 215, 255.
                let offset = Int(slot) - 16
                let level = { (step: Int) in step == 0 ? 0.0 : Double(55 + step * 40) / 255 }
                return Color(
                    .sRGB,
                    red: level(offset / 36 % 6),
                    green: level(offset / 6 % 6),
                    blue: level(offset % 6),
                    opacity: 1,
                )
            }
            // The 24-step grey ramp: 8, 18, … 238.
            let grey = Double(8 + (Int(slot) - 232) * 10) / 255
            return Color(.sRGB, red: grey, green: grey, blue: grey, opacity: 1)
        }
    }
}

extension Slate.Typeface {
    /// The families the peek card will wear, in order of preference, once the pane's OWN configured
    /// family (which may be empty, meaning "the default") has been tried. The Nerd Font build comes
    /// FIRST: a shell prompt, a test runner and a git status all emit private-use-area glyphs, and a
    /// face without them draws a row of boxes — which is the one way a faithful preview can look
    /// broken while being byte-correct.
    static let terminalFaceFallbacks = [
        "JetBrainsMono Nerd Font",
        "JetBrainsMonoNL Nerd Font",
        mono,
        "Symbols Nerd Font",
    ]

    /// Every font family installed on this machine — resolved ONCE (families do not appear
    /// mid-session) so the peek card can pick a face per line without hitting the font manager.
    private static let installedFamilies: Set<String> = {
        #if canImport(AppKit)
        Set(NSFontManager.shared.availableFontFamilies)
        #else
        Set(UIFont.familyNames)
        #endif
    }()

    /// The face the TERMINAL is wearing, at `size`: the pane's configured `family` when it is
    /// installed, else the first installed fallback, else the system monospace (which is always
    /// there, and is what ``instrument(_:weight:)`` degrades to for the same reason).
    ///
    /// `Font.custom` with a missing family falls back to the PROPORTIONAL system face silently — a
    /// preview of terminal output in a proportional face is not a preview of terminal output — so
    /// the family is checked against the installed set rather than being handed over hopefully.
    static func terminalFace(
        _ size: CGFloat, family: String?, bold: Bool = false, italic: Bool = false,
    ) -> Font {
        var candidates = terminalFaceFallbacks
        if let family, !family.isEmpty { candidates.insert(family, at: 0) }
        let resolved = candidates.first { installedFamilies.contains($0) }
        var font: Font = resolved.map { Font.custom($0, size: size) }
            ?? Font.system(size: size, design: .monospaced)
        if bold { font = font.weight(.bold) }
        if italic { font = font.italic() }
        return font
    }
}
#endif
