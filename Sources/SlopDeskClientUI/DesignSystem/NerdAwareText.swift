// NerdAwareText — the SwiftUI splice over `NerdSymbolFont`.
//
// The face itself, its registration and the run classification are `SlopDeskClientCore`: the code
// sidebar injects the same bytes as @font-face data URIs and never draws a `Text`. What is left here
// is the one thing that is a view — turning the pure runs into a styled `Text` (docs/56).

#if canImport(SwiftUI)
import SlopDeskClientCore
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
