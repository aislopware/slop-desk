// NerdAwareText — the nerd-font splice as an `NSAttributedString`.
//
// The AppKit twin is ``SlopDeskSlate/SlateNativeText`` and the classification both read is
// `NerdSymbolFont.runs(of:)` (`SlopDeskClientCore`) — see that file's header for why the splice is
// written twice and the decision once.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskFontFaces
import UIKit

extension NSAttributedString {
    /// An attributed string over `string` whose private-use runs (nerd-font glyphs) are set in the
    /// bundled Symbols Nerd Font at `font`'s size, while ordinary runs keep `font` itself.
    ///
    /// TWO SPLICES, ONE CLASSIFICATION, and the last clause is the one that matters: which runs are
    /// symbol runs is `NerdSymbolFont.runs(of:)` and never a renderer's own decision. This is the same
    /// function `SlopDeskSlate/SlateNativeText` carries for AppKit, in UIKit's spelling — the two `#if`
    /// arms are disjoint, so the NAME is deliberately the same and a Mac call site ports across
    /// verbatim.
    ///
    /// THE CALLER'S FACE IS PASSED IN, NOT INHERITED. An `NSAttributedString` carries its own attributes
    /// all the way to the label, so there is no outer style for a fontless run to pick up: every run
    /// leaves here already dressed.
    static func slateNerdAware(
        _ string: some StringProtocol, font: UIFont, color: UIColor,
    ) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let runs = NerdSymbolFont.runs(of: string)
        // The common case — no symbol anywhere — must stay ONE run, so ordinary titles pay nothing.
        guard NerdSymbolFont.registered, runs.contains(where: \.isSymbol) else {
            return NSAttributedString(string: String(string), attributes: attributes)
        }
        let symbol = UIFont(name: NerdSymbolFont.postScriptName, size: font.pointSize) ?? font
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
