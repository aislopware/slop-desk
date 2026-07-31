// TextSplice — the one splice point for multi-styled text runs. SwiftUI's `Text + Text` operator is
// deprecated (macOS 26) in favour of `Text` interpolation, which carries a styled `Text` into another
// while preserving its ink/weight/font. Every surface that builds a flowing run out of differently-styled
// segments (the fzf match highlights, the switcher's place line) folds through here, so the interpolation
// idiom lives in exactly one place.

#if canImport(SwiftUI)
import SwiftUI

extension Text {
    /// Splice styled `Text` segments into ONE `Text` so the result wraps/truncates as a single run while
    /// each segment keeps its own styling. An empty array yields an empty `Text`.
    static func spliced(_ segments: [Text]) -> Text {
        segments.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
    }
}
#endif
