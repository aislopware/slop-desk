// NerdAwareText — the SPLICE over `NerdSymbolFont`, in both of the app's text types.
//
// The face itself, its registration and the run classification are `SlopDeskClientCore`: the code
// sidebar injects the same bytes as @font-face data URIs and never draws a `Text`. What is left here
// is the one thing that is a view — turning the pure runs into styled text (docs/56).
//
// TWO SPLICES, ONE CLASSIFICATION, for the reason ``Slate/Native`` exists: the Mac's ⌃⇥ readout is an
// `NSView` (docs/56 stage D) and the phone's chrome is SwiftUI, and both have to draw a starship
// segment or an nvim filetype glyph rather than a notdef dot. What they may not do is each decide
// which runs are symbol runs — that is `NerdSymbolFont.runs(of:)`, below both.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SwiftUI

#if canImport(AppKit)
import AppKit

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
