// CodeFontSync — derives the ``MetadataCodec/CodeFontSpec`` the code panel pushes to the host
// (verb 20): the CLIENT's live terminal font truth, folded into the shared workbench settings so
// the embedded editor reads like the terminal beside it — the CURRENT prefs, not the defaults.
//
// The line-height maths mirrors what the terminal ACTUALLY renders: libghostty derives the cell
// height from the resolved face's metrics, then applies the `adjust-cell-height` percentage the
// ``LineHeightMode`` maps to. For an INSTALLED family, CoreText supplies the metrics; for a family
// CoreText cannot resolve (the shipping default — "SF Mono" and "JetBrains Mono" resolve on
// neither machine), libghostty falls back to its EMBEDDED JetBrainsMono face, whose hhea metrics
// (1020/−300/0 on upm 1000, through `Metrics.zig`'s rounding) pin the ratio at exactly 1.32.

#if canImport(SwiftUI)
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SlopDeskProtocol
import SlopDeskVideoProtocol

enum CodeFontSync {
    /// The embedded JetBrainsMono cell-height ratio (see the header) — the fallback whenever the
    /// preferred family does not resolve, because that is precisely when the terminal falls back
    /// to the embedded face too.
    static let embeddedMonoRatio = 1.32

    /// The spec for the live terminal prefs. `resolveRatio` is the installed-font metrics probe
    /// (injectable so tests stay deterministic against the machine's font library).
    static func spec(
        terminal: TerminalPreferences,
        resolveRatio: (String, Double) -> Double? = installedFontRatio,
    ) -> MetadataCodec.CodeFontSpec {
        let size = terminal.fontSize
        let base = resolveRatio(terminal.fontFamily, size) ?? embeddedMonoRatio
        let percent = terminal.lineHeight.adjustCellHeightPercent ?? 0
        // Plain multiply/divide (bit-exact floats invariant — never fused), then round to two
        // decimals: the editor setting is a human-visible ratio, and sub-percent jitter from
        // metrics division would churn the synced file for nothing.
        let ratio = base * (1.0 + percent / 100.0)
        let rounded = (ratio * 100).rounded() / 100
        return MetadataCodec.CodeFontSpec(family: terminal.fontFamily, size: size, lineHeight: rounded)
    }

    /// CoreText metrics ratio for an INSTALLED family at `size` — (ascender + |descender| +
    /// leading) / size, the same face-height-over-em walk ghostty's metrics take. `nil` when the
    /// family does not resolve (→ the embedded fallback above).
    static func installedFontRatio(family: String, size: Double) -> Double? {
        #if canImport(AppKit)
        guard size > 0, let font = NSFont(name: family, size: CGFloat(size)) else { return nil }
        // descender is NEGATIVE in AppKit; plain adds (never fused) per the float invariant.
        let height = Double(font.ascender) + Double(-font.descender) + Double(font.leading)
        return height / size
        #else
        return nil
        #endif
    }
}
#endif
