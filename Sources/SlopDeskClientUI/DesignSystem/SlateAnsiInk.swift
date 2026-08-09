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
    /// The families the peek card will wear when the pane's OWN configured family is missing or
    /// unset — a Nerd Font build first, then the design system's mono, then the symbols-only face.
    static let terminalFaceFallbacks = [
        "JetBrainsMono Nerd Font",
        "JetBrainsMonoNL Nerd Font",
        mono,
        "Symbols Nerd Font",
    ]

    /// The SYMBOL cascade — families carrying the Nerd Font private-use area, appended behind
    /// whatever the primary face turns out to be.
    ///
    /// This is the fix for a shipped bug (user-reported 2026-08-09): the terminal was configured
    /// with plain `JetBrains Mono`, the card honoured it, and every prompt/`eza` icon drew as a
    /// missing-glyph box. libghostty does not have that problem because it carries a symbols
    /// fallback of its own — the pane and the card were BOTH right about the family and only the
    /// card was missing the cascade behind it. macOS's automatic fallback does not cover the PUA:
    /// no system face claims those code points, so without an explicit cascade the box is the
    /// correct answer to the wrong question.
    static let symbolFaceCascade = [
        "Symbols Nerd Font Mono",
        "Symbols Nerd Font",
        "JetBrainsMono Nerd Font Mono",
        "JetBrainsMono Nerd Font",
        "JetBrainsMonoNL Nerd Font Mono",
        "JetBrainsMonoNL Nerd Font",
    ]

    /// Every font family installed on this machine — resolved ONCE (families do not appear
    /// mid-session) so the peek card can pick a face per line without hitting the font manager.
    static let installedFamilies: Set<String> = {
        #if canImport(AppKit)
        Set(NSFontManager.shared.availableFontFamilies)
        #else
        Set(UIFont.familyNames)
        #endif
    }()

    /// One resolved face, keyed by everything that can change it — the card builds a font per RUN,
    /// and descriptor-with-cascade resolution is far too costly to repeat per frame.
    private struct TerminalFaceKey: Hashable {
        let size: CGFloat
        let family: String
        let fallbacks: String
        let bold: Bool
        let italic: Bool
    }

    @MainActor private static var terminalFaceCache: [TerminalFaceKey: Font] = [:]

    /// The face the TERMINAL is wearing, at `size`: the pane's configured `family` when it is
    /// installed, else the first installed entry of ``terminalFaceFallbacks``, else the system
    /// monospace (which is always there, and is what ``instrument(_:weight:)`` degrades to for the
    /// same reason) — with the pane's own comma-separated `fallbacks` and then
    /// ``symbolFaceCascade`` hung BEHIND it as a Core Text cascade list, so a code point the
    /// primary face does not carry is drawn by a face that does instead of by a box.
    ///
    /// `Font.custom` with a missing family falls back to the PROPORTIONAL system face silently — a
    /// preview of terminal output in a proportional face is not a preview of terminal output — so
    /// the family is checked against the installed set rather than being handed over hopefully.
    @MainActor
    static func terminalFace(
        _ size: CGFloat, family: String?, fallbacks: String = "",
        bold: Bool = false, italic: Bool = false,
    ) -> Font {
        let key = TerminalFaceKey(
            size: size, family: family ?? "", fallbacks: fallbacks, bold: bold, italic: italic,
        )
        if let cached = terminalFaceCache[key] { return cached }
        let face = resolveTerminalFace(key)
        terminalFaceCache[key] = face
        return face
    }

    /// The primary family and its cascade, in order and already filtered to what is installed.
    /// Split out — with the installed set INJECTABLE — so the resolution order is unit-pinnable on
    /// a machine that does not have the fonts (this one does not: a test that asserted against the
    /// real font server would pass or fail by which laptop ran it).
    static func terminalFaceChain(
        family: String?, fallbacks: String, installed: Set<String> = installedFamilies,
    ) -> (primary: String?, cascade: [String]) {
        var wanted: [String] = []
        if let family, !family.isEmpty { wanted.append(family) }
        wanted += terminalFaceFallbacks
        let primary = wanted.first { installed.contains($0) }
        // The pane's own fallback list first (the user named those), then the symbol faces.
        let declared = fallbacks
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = primary.map { Set([$0]) } ?? []
        let cascade = (declared + symbolFaceCascade).filter {
            installed.contains($0) && seen.insert($0).inserted
        }
        return (primary, cascade)
    }

    @MainActor
    private static func resolveTerminalFace(_ key: TerminalFaceKey) -> Font {
        let system = Font.system(size: key.size, design: .monospaced)
        #if canImport(AppKit)
        let chain = terminalFaceChain(family: key.family, fallbacks: key.fallbacks)
        guard let primary = chain.primary else { return styled(system, key) }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: primary]
        if !chain.cascade.isEmpty {
            attributes[.init(rawValue: kCTFontCascadeListAttribute as String)] = chain.cascade.map {
                NSFontDescriptor(fontAttributes: [.family: $0])
            }
        }
        var descriptor = NSFontDescriptor(fontAttributes: attributes)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if key.bold { traits.insert(.bold) }
        if key.italic { traits.insert(.italic) }
        // The traits go on the DESCRIPTOR, not on the SwiftUI font: `.weight()` / `.italic()` over
        // a descriptor-built face would re-resolve it and drop the cascade attribute with it.
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
        guard let font = NSFont(descriptor: descriptor, size: key.size) else { return styled(system, key) }
        return Font(font)
        #else
        return styled(system, key)
        #endif
    }

    /// The bold/italic pass for the SYSTEM fallback only — a descriptor-built face carries its
    /// traits already.
    private static func styled(_ font: Font, _ key: TerminalFaceKey) -> Font {
        var out = font
        if key.bold { out = out.weight(.bold) }
        if key.italic { out = out.italic() }
        return out
    }
}
#endif
