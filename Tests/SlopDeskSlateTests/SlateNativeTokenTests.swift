// SlateNativeTokenTests — the token layer has ONE value per rung, and it is the native one.
//
// ``Slate/Native`` is the whole floor now: an `NSColor` on the Mac, a `UIColor` on the phone, and no
// third spelling above either (the `Color`-typed mirror it used to carry was the duplicate
// implementation `CLAUDE.md` bans, and it is gone — with it went the bridge test that pinned the two
// halves against each other, which had nothing left to compare). What is still worth pinning is what
// the values themselves DERIVE: the ONE rung whose native form is not a literal — `Line/subtle`, the
// separator at a fraction of its own alpha — SCALES the alpha rather than REPLACING it
// (`withAlphaComponent`'s meaning), which would have turned a whisper of a hairline into a solid rule.

#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskSlate

@MainActor
final class SlateNativeTokenTests: XCTestCase {
    /// sRGB components as the given appearance resolves them.
    private func rgba(_ color: NSColor, dark: Bool = false) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
    }

    private func assertSame(
        _ lhs: NSColor, _ rhs: NSColor, dark: Bool = false, _ message: String,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        let a = rgba(lhs, dark: dark), b = rgba(rhs, dark: dark)
        XCTAssertEqual(a.r, b.r, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.a, b.a, accuracy: 0.001, message, file: file, line: line)
    }

    // MARK: The one derived rung

    /// `subtle` is the separator at 60 % OF ITS OWN alpha — same hue, alpha scaled, never replaced.
    func testSubtleScalesTheSeparatorsOwnAlphaRatherThanReplacingIt() {
        for dark in [false, true] {
            let divider = rgba(Slate.Native.Line.divider, dark: dark)
            let subtle = rgba(Slate.Native.Line.subtle, dark: dark)
            XCTAssertEqual(subtle.r, divider.r, accuracy: 0.001, "the hue is the separator's")
            XCTAssertEqual(subtle.g, divider.g, accuracy: 0.001, "the hue is the separator's")
            XCTAssertEqual(subtle.b, divider.b, accuracy: 0.001, "the hue is the separator's")
            XCTAssertEqual(
                subtle.a, divider.a * Slate.Opacity.muted, accuracy: 0.001,
                "SCALED, not replaced — `withAlphaComponent` here would draw a solid rule",
            )
        }
    }

    /// The two accent washes are the accent at a rung of the alpha ladder, not a second purple.
    func testTheAccentWashesAreTheAccentAtALadderRung() {
        for dark in [false, true] {
            let accent = rgba(Slate.Native.accent, dark: dark)
            for (wash, alpha, name) in [
                (Slate.Native.State.selected, Slate.Opacity.wash, "selected"),
                (Slate.Native.State.accentMuted, Slate.Opacity.faint, "accentMuted"),
            ] {
                let got = rgba(wash, dark: dark)
                XCTAssertEqual(got.r, accent.r, accuracy: 0.001, name)
                XCTAssertEqual(got.g, accent.g, accuracy: 0.001, name)
                XCTAssertEqual(got.b, accent.b, accuracy: 0.001, name)
                XCTAssertEqual(got.a, accent.a * alpha, accuracy: 0.001, name)
            }
        }
    }

    // MARK: The profile's own tones

    /// The authored chrome tones are the profile's published hexes — the cream ground (law 4) and the
    /// glass face (law 1: the island IS the terminal's surface, never a second tone).
    func testTheAuthoredTonesAreTheProfilesOwnHexes() {
        assertSame(Slate.Native.Surface.field, NSColor(slateHex: 0xFFFBEB), "the ground is Alucard's cream")
        assertSame(Slate.Native.Surface.island, Slate.Native.Terminal.face, "the island IS the glass face")
        assertSame(Slate.Native.Terminal.face, NSColor(slateHex: 0x22212C), "the Dracula Pro face")
        assertSame(
            Slate.Native.Terminal.rim, NSColor(slateHex: SlateTheme.mix(0x454158, 0x7970A9)),
            "the rim is the plate lifted halfway to the comment ink",
        )
        assertSame(
            Slate.Native.Terminal.ok, NSColor(slateHex: 0x8AFF80),
            "the on-glass ok ink is the profile's own ANSI green, not the system's",
        )
    }

    // MARK: The motion rungs

    /// A named motion is ONE curve: ``SlateCurve``'s stored control points and the
    /// `CAMediaTimingFunction` it hands a `CAAnimation` are the same four numbers, so the split
    /// shell's column slide and the titlebar strip that lands with it cannot drift apart. (The
    /// `emphasizedControlPoints` constant that used to name that curve a second time is gone.)
    func testTheColumnSlideIsOneCurve() {
        let curve = Slate.Motion.columnSlide
        XCTAssertEqual(curve.duration, Slate.Anim.columnSlideDuration, "the delay token reads the rung")
        var points = [Float](repeating: 0, count: 2)
        curve.timingFunction.getControlPoint(at: 1, values: &points)
        XCTAssertEqual(Double(points[0]), curve.x1, accuracy: 0.0001)
        XCTAssertEqual(Double(points[1]), curve.y1, accuracy: 0.0001)
        curve.timingFunction.getControlPoint(at: 2, values: &points)
        XCTAssertEqual(Double(points[0]), curve.x2, accuracy: 0.0001)
        XCTAssertEqual(Double(points[1]), curve.y2, accuracy: 0.0001)
    }

    /// The instrument voice is the ONE face every chrome reading wears — JetBrains Mono where it is
    /// installed, SF Mono where it is not, never the proportional system face.
    func testTheNativeInstrumentVoiceIsAMonoFaceAtTheAskedSize() {
        let font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold)
        XCTAssertEqual(font.pointSize, Slate.Typeface.small, "the size ladder is the same ladder")
        XCTAssertTrue(
            font.familyName == Slate.Typeface.mono || (font.fontDescriptor.symbolicTraits.contains(.monoSpace)),
            "a chrome label in the instrument voice is mono or it is not the instrument voice",
        )
    }
}
#endif
