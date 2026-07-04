// SessionAccent — the per-session colour IDENTITY slot (visible-design pass, 2026-07-04).
//
// Every session owns one of `paletteCount` accent slots, derived DETERMINISTICALLY from its
// `SessionID` UUID (FNV-1a folded modulo the palette) — the Arc-Spaces idiom of "each space has a
// colour" without storing anything: no schema change, no migration (the no-backcompat rule), and the
// same session recolours identically after every restart because the UUID persists. The palette
// itself is a CONSTRAINED, curated set (the UI maps the index to one of 8 Monokai-family chromatics)
// rather than a free hash-to-hue — free hues collide with pane content and read as a broken theme.
//
// Pure + headlessly testable; the colour values live UI-side (`SessionAccentPalette`).

import Foundation

public enum SessionAccent {
    /// How many identity slots exist. The UI palette ships exactly this many colours; tests pin the
    /// contract so the two can never drift.
    public static let paletteCount = 8

    /// The stable palette slot for a session: FNV-1a over the UUID's 16 raw bytes, folded modulo
    /// ``paletteCount``. Always in `0..<paletteCount`.
    public static func index(for id: SessionID) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        withUnsafeBytes(of: id.raw.uuid) { raw in
            for byte in raw {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        return Int(hash % UInt64(paletteCount))
    }
}
