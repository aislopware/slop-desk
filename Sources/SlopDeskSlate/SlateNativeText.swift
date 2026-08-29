// SlateNativeText — the nerd-font SPLICE, once, for both frameworks.
//
// The face itself, its registration and the run classification are `SlopDeskFontFaces`
// (`NerdSymbolFont`); what a splice is FOR is that a starship segment or an nvim filetype glyph must
// draw as itself rather than as a notdef dot. What neither renderer may do is decide for itself which
// runs are symbol runs — that is `NerdSymbolFont.runs(of:)`, below both.
//
// ⚠️ IT USED TO BE TWO SPLICES. This body sat here typed on `NSFont`/`NSColor`, and a
// character-identical twin sat in the phone's own design-system directory (NerdAwareText, deleted in
// the merge) typed on `UIFont`/`UIColor` — same name, same labels, same five statements, two `#if` arms that
// could never both compile. The diff between them was TWO TYPE NAMES, and this floor already vends
// both of them as one name each (``SlateNativeFont``, ``SlateNativeColor``, `SlateDesign.swift:72-81`).
// Written on those, the two bodies are one body and the `#if` shrinks to what it was always really
// gating: which framework declares `NSAttributedString.Key.foregroundColor`.
//
// `NSAttributedString` itself is Foundation on both platforms, and `init?(name:size:)` and
// `pointSize` are spelled identically on `NSFont` and `UIFont` — which is why the merge is a deletion
// and not a rewrite. This is the same finding as `SlateVectorDraw` and `SlatePlate`: the copy was
// never paying for a framework difference, it was paying for a type name.

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SlopDeskFontFaces

package extension NSAttributedString {
    /// An attributed string over `string` whose private-use runs (nerd-font glyphs) are set in the
    /// bundled Symbols Nerd Font at `font`'s size, while ordinary runs keep `font` itself.
    ///
    /// THE CALLER'S FACE IS PASSED IN, NOT INHERITED. An `NSAttributedString` carries its own
    /// attributes all the way to the label, so there is no outer style for a fontless run to pick up:
    /// every run leaves here already dressed. Both shells' call sites read identically as a result —
    /// `.slateNerdAware(title, font: base, color: ink)` is the same line in `MacPalette` and in
    /// `PhonePaletteCardView`.
    static func slateNerdAware(
        _ string: some StringProtocol, font: SlateNativeFont, color: SlateNativeColor,
    ) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let runs = NerdSymbolFont.runs(of: string)
        // The common case — no symbol anywhere — must stay ONE run, so ordinary titles pay nothing.
        guard NerdSymbolFont.registered, runs.contains(where: \.isSymbol) else {
            return NSAttributedString(string: String(string), attributes: attributes)
        }
        let symbol = SlateNativeFont(name: NerdSymbolFont.postScriptName, size: font.pointSize) ?? font
        let spliced = NSMutableAttributedString()
        for run in runs {
            spliced.append(NSAttributedString(
                string: run.text,
                attributes: run.isSymbol ? [.font: symbol, .foregroundColor: color] : attributes,
            ))
        }
        return spliced
    }
}
