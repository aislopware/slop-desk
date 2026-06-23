// WarpType — typography tokens (warp-tokens-layout.md §1). Font FAMILY names only (open Hack/Roboto,
// per ORCH-DECISIONS F2/F3 — we do NOT vendor Warp's proprietary fonts; we reference the freely
// licensed Hack (MIT) / Roboto (Apache-2.0) by family name and bundle them later). Sizes/weights/
// line-heights are quoted verbatim with file:line in the spec.

import CoreGraphics
import SwiftUI

public enum WarpType {
    // MARK: Families (open, bundled later — see Fonts.swift)

    /// Terminal/monospace family — Hack (app/src/appearance.rs:285).
    public static let monospaceFamily = "Hack"
    /// UI/sans family — Roboto (app/src/appearance.rs:312).
    public static let uiFamily = "Roboto"

    // MARK: Sizes (px) — the authoritative scale (warp-tokens-layout.md §1b)

    /// Base UI text: labels, list items, buttons (appearance.rs:11).
    public static let uiSize: CGFloat = 12
    /// Command-palette items (appearance.rs:12).
    public static let paletteSize: CGFloat = 14
    /// Section/dialog/pane headers (appearance.rs:8).
    public static let headerSize: CGFloat = 18
    /// Overline / eyebrow / tab subtitle / path (appearance.rs:9).
    public static let overlineSize: CGFloat = 10
    /// Terminal text default (user-settable) (appearance.rs:123).
    public static let monospaceSize: CGFloat = 13
    /// Floor for any UI font size (builder.rs:51).
    public static let minSize: CGFloat = 5

    // MARK: Weights (warp-tokens-layout.md §1c)

    public static let bodyWeight: Font.Weight = .regular
    public static let buttonWeight: Font.Weight = .semibold
    public static let titleWeight: Font.Weight = .semibold

    // MARK: Line-height ratios (warp-tokens-layout.md §1d)

    /// UI text (spans, paragraphs) (text.rs:33).
    public static let uiLineHeight: CGFloat = 1.2
    /// Formatted/markdown/terminal blocks (formatted_text_element.rs:82).
    public static let docLineHeight: CGFloat = 1.4

    // MARK: Resolved SwiftUI fonts (registration-aware via Fonts.swift)

    /// A monospace UI font at `size` (Hack if bundled, else system monospaced).
    public static func mono(_ size: CGFloat, weight: Font.Weight = bodyWeight) -> Font {
        Fonts.font(family: monospaceFamily, size: size, weight: weight, fallback: .monospaced)
    }

    /// A sans UI font at `size` (Roboto if bundled, else system).
    public static func ui(_ size: CGFloat, weight: Font.Weight = bodyWeight) -> Font {
        Fonts.font(family: uiFamily, size: size, weight: weight, fallback: .default)
    }

    // Role helpers (the common chrome roles).
    public static var label: Font { ui(uiSize) }
    public static var paletteItem: Font { ui(paletteSize) }
    public static var header: Font { ui(headerSize, weight: titleWeight) }
    public static var overline: Font { ui(overlineSize) }
    public static var terminal: Font { mono(monospaceSize) }
}
