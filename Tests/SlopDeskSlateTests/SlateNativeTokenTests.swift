// SlateNativeTokenTests — the token layer has ONE value per rung, and the two frameworks see it.
//
// `Slate.Native` is the value floor (an `NSColor`); every SwiftUI rung is `Color(slateNative:)` over
// it (docs/56 stage D — an `NSView` fills with an `NSColor`, so the AppKit surfaces cannot read the
// `Color` form and a second AppKit palette would be the duplicate implementation `CLAUDE.md` bans).
// These pin that the derivation is lossless, and that the ONE rung whose native form is not a literal
// — `Line/subtle`, the separator at a fraction of its own alpha — kept SwiftUI's `.opacity(_:)`
// meaning (SCALE the alpha) rather than `withAlphaComponent`'s (REPLACE it), which would have turned
// a whisper of a hairline into a solid rule.

#if os(macOS)
import AppKit
import SwiftUI
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

    // MARK: The bridge

    /// A SwiftUI rung is the native rung — the wrap and the unwrap cancel, in BOTH appearances, for a
    /// semantic system colour, a light-pinned ink and a dynamic pair alike.
    func testEverySwiftUIRungResolvesToItsNativeValue() {
        for dark in [false, true] {
            assertSame(NSColor(Slate.Surface.face), Slate.Native.Surface.face, dark: dark, "surface/face")
            assertSame(NSColor(Slate.Text.secondary), Slate.Native.Text.secondary, dark: dark, "text/secondary")
            assertSame(NSColor(Slate.Text.tertiary), Slate.Native.Text.tertiary, dark: dark, "text/tertiary")
            assertSame(NSColor(Slate.StatusInk.err), Slate.Native.StatusInk.err, dark: dark, "statusInk/err")
            assertSame(NSColor(Slate.Line.overlayRim), Slate.Native.Line.overlayRim, dark: dark, "line/overlayRim")
            // The two PANE STATUS PILL fills. `PaneStatusPillInk` used to be resolved by two
            // independently-maintained tables, one per renderer, which is why this pinned them against
            // each other from inside the floor — a cross-half test naming both UI halves at once is the
            // one thing a UI half's own tests may not do. Docs/56 batch 3 collapsed the pair into one
            // switch (``Slate/paneStatusPillFill(_:)`` / ``Slate/Native/paneStatusPillFill(_:)``), so
            // `NSColor(Slate.Status.secureInput)` and `Slate.Native.Status.secureInput` are no longer
            // two tables' answers to compare — they are the same literal token, wrapped and unwrapped.
            // Kept here anyway: it is still the rung `Slate.paneStatusPillFill` and
            // `Slate.Native.paneStatusPillFill` both resolve to, and this is where every rung's bridge
            // is pinned.
            assertSame(
                NSColor(Slate.Status.secureInput),
                Slate.Native.Status.secureInput,
                dark: dark,
                "status/secureInput",
            )
            assertSame(NSColor(Slate.Status.syncInput), Slate.Native.Status.syncInput, dark: dark, "status/syncInput")
        }
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

    /// A named motion is ONE curve: the SwiftUI rung and the CoreAnimation rung are built from the
    /// same control points, so the split shell's column slide and the titlebar strip that lands with
    /// it cannot drift apart. (The `emphasizedControlPoints` constant that used to name that curve a
    /// second time for AppKit is gone with this.)
    func testTheColumnSlideIsOneCurveForBothFrameworks() {
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

    /// The AppKit instrument voice is the SAME face the SwiftUI chrome sets — JetBrains Mono where
    /// it is installed, SF Mono where it is not, never the proportional system face.
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
