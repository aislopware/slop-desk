// SlateNativeText — the nerd-font SPLICE in the platform's own text type.
//
// The face itself, its registration and the run classification are `SlopDeskClientCore`
// (`NerdSymbolFont`); what a splice is FOR is that a starship segment or an nvim filetype glyph must
// draw as itself rather than as a notdef dot. TWO SPLICES, ONE CLASSIFICATION: the AppKit half is
// here because the Mac's chrome is `NSView` (docs/56 stage D), the SwiftUI half is
// ``SwiftUI/Text/nerdAware(_:size:)`` on the phone's floor. What neither may do is decide for itself
// which runs are symbol runs — that is `NerdSymbolFont.runs(of:)`, below both.

#if canImport(AppKit)
import AppKit
import SlopDeskClientCore

package extension NSAttributedString {
    /// An attributed string over `string` whose private-use runs (nerd-font glyphs) are set in the
    /// bundled Symbols Nerd Font at `font`'s size, while ordinary runs keep `font` itself.
    ///
    /// The AppKit twin of ``SwiftUI/Text/nerdAware(_:size:)``, and it differs in one way the frameworks
    /// force: SwiftUI can leave an ordinary run FONTLESS for an outer `.font(…)` to fill, while an
    /// `NSAttributedString` carries its own attributes to the label — so the caller's face is passed in
    /// rather than inherited.
    static func slateNerdAware(
        _ string: some StringProtocol, font: NSFont, color: NSColor,
    ) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let runs = NerdSymbolFont.runs(of: string)
        // The common case — no symbol anywhere — must stay ONE run, so ordinary titles pay nothing.
        guard NerdSymbolFont.registered, runs.contains(where: \.isSymbol) else {
            return NSAttributedString(string: String(string), attributes: attributes)
        }
        let symbol = NSFont(name: NerdSymbolFont.postScriptName, size: font.pointSize) ?? font
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
#endif
