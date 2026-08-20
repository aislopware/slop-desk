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

import CoreText
import SlopDeskProtocol
import SlopDeskVideoProtocol

package enum CodeFontSync {
    /// The embedded JetBrainsMono cell-height ratio (see the header) — the fallback whenever the
    /// preferred family does not resolve, because that is precisely when the terminal falls back
    /// to the embedded face too.
    package static let embeddedMonoRatio = 1.32

    /// The spec for the live terminal prefs. `resolveRatio` is the installed-font metrics probe
    /// (injectable so tests stay deterministic against the machine's font library).
    package static func spec(
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

    /// CoreText metrics ratio for an INSTALLED family at `size` — (ascent + descent + leading) /
    /// size, the same face-height-over-em walk ghostty's metrics take. `nil` when the family does not
    /// resolve (→ the embedded fallback above) or `size` is not positive.
    ///
    /// CoreText, not AppKit, and the gate that used to sit here was SCOPE rather than necessity: the
    /// question is "what are this face's vertical metrics", the phone's terminal asks it of the same
    /// faces, and answering `nil` off AppKit pinned the phone's editor at 1.32 forever — so the code
    /// panel's lines never lined up with the terminal beside them on iOS. ``InstalledFontFamilies``
    /// two files over already answers the neighbouring question this way, on both halves.
    ///
    /// `NSFont(name:size:)`'s `nil` was doing double duty — resolve AND metrics — and CoreText will
    /// not hand that back: `CTFontCreateWithName` NEVER fails, it substitutes a system fallback face.
    /// So "did it resolve" is asked of the ANSWER (``resolves(_:to:)``), which is also what keeps the
    /// embedded-face fallback honest: a substituted Helvetica's ratio is not the ratio libghostty
    /// will render, and silently shipping it is worse than falling back on purpose.
    ///
    /// The AppKit metrics this replaces were the same numbers: `NSFont.ascender` / `.descender` /
    /// `.leading` are `CTFontGetAscent` / `-CTFontGetDescent` / `CTFontGetLeading`. CoreText's descent
    /// is POSITIVE, which is why the old body's sign flip is gone rather than moved.
    package static func installedFontRatio(family: String, size: Double) -> Double? {
        guard size > 0 else { return nil }
        let font = CTFontCreateWithName(family as CFString, CGFloat(size), nil)
        guard resolves(font, to: family) else { return nil }
        // Plain adds (never fused) per the float invariant.
        let height = Double(CTFontGetAscent(font)) + Double(CTFontGetDescent(font))
            + Double(CTFontGetLeading(font))
        return height / size
    }

    /// Whether `font` is the face `name` asked for rather than the substitute CoreText hands back for
    /// a name it cannot resolve. Both spellings count, because both are what a user may have typed
    /// into the font field: the FAMILY ("JetBrains Mono", what the picker offers) and the PostScript
    /// name ("JetBrainsMono-Regular", what a config file often carries).
    private static func resolves(_ font: CTFont, to name: String) -> Bool {
        let family = CTFontCopyFamilyName(font) as String
        if family.caseInsensitiveCompare(name) == .orderedSame { return true }
        let postScript = CTFontCopyPostScriptName(font) as String
        return postScript.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Whether an ensure round should carry the font push (verb 20). Pure — pinned by
    /// `CodeFontSyncTests`.
    ///
    /// Three no's. No endpoint at all (nothing connected) has nowhere to send it. An
    /// `.unavailable` host has no code-server and never will this session — the poll keeps turning
    /// every ~3.6 s while the panel is open, and each round would patch a settings file no
    /// workbench is ever going to read. And a spec byte-identical to the last one sent is a
    /// round-trip that can only produce the answer "nothing changed", queued behind real metadata
    /// work. `.starting` DOES push: the seed has to land before the booting workbench reads its
    /// settings, so waiting for `.ready` would be a reload late.
    package static func shouldPush(
        endpoint: MetadataCodec.ServiceEndpoint?,
        spec: MetadataCodec.CodeFontSpec,
        lastSent: MetadataCodec.CodeFontSpec?,
    ) -> Bool {
        guard let endpoint, endpoint.state != .unavailable else { return false }
        return spec != lastSent
    }
}
