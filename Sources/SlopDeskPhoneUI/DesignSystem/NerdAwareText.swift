// NerdAwareText — the nerd-font splice as a SwiftUI `Text`.
//
// The AppKit twin is ``SlopDeskSlate/SlateNativeText`` and the classification both read is
// `NerdSymbolFont.runs(of:)` (`SlopDeskClientCore`) — see that file's header for why the splice is
// written twice and the decision once.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskFontFaces
import SwiftUI

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
