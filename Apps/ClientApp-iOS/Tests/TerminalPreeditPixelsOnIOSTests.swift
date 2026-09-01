// TerminalPreeditPixelsOnIOSTests — the phone's marked run, photographed.
//
// ⚠️ WHY THIS EXISTS AT ALL, given `TerminalCompositionOnIOSTests` already pins the document model.
// That suite proves the ARITHMETIC `UITextInput` asks for: offsets, clamping, the caret's range. It
// cannot say whether anything is drawn, and the whole preedit feature is a drawing. The gap was
// written off once as "needs a booted simulator", which is true of the GRID — `slopdesk-apple-metal`
// sets `framebufferOnly = true`, so its drawable cannot be read back — and false of the BAND, which
// is `CGContext` end to end and rasterises off-screen through `HostedRaster` like every other phone
// pixel rig. The band is also where the preedit goes whenever the app's own line editor owns the
// line, which is the case this feature was built for.
//
// It earned its keep immediately: `TerminalPromptBand.caretRect` took no composition, so while a
// conversion was in flight it reported the EDITOR's cursor while `drawComposition` drew the bar
// shifted into the marked run. An IME candidate window hangs off the reported rect, so for exactly
// the long conversions that need one it pointed at the start of the run while the caret sat at the
// end. `testTheCaretTheBandReportsIsTheCaretItDraws` is that defect's pin, and it is a pixel test
// because no arithmetic assertion could have caught a disagreement between two spellings of the
// same number — it takes photographing one and asking the other.
//
// ⚠️ THE ⌃R PANEL'S SUITE IS IN THIS FILE TOO, and shares its `Bitmap`/`Diff`. Both are `private`
// to a file rather than a target, and the iOS bundle's sources are a hand-kept list in
// `project.pbxproj` — so a second file would cost a third copy of the rig or a fourth thing to keep
// in sync. What the two suites have in common is the reason either exists: the band is the one part
// of this terminal that can be photographed off-screen, and both features are drawings whose
// arithmetic looks right on its own.

import CoreText
import SlopDeskWorkspaceCore
import UIKit
import XCTest
@testable import SlopDeskTerminal

@MainActor
final class TerminalPreeditPixelsOnIOSTests: XCTestCase {
    /// Wide enough that the marked run below never wraps, which is a different code path.
    private let width: CGFloat = 320
    /// The run is Japanese on purpose: a conversion long enough that a caret at its end is far from
    /// its start is the only shape in which the two spellings could visibly disagree.
    private let marked = "にほんご"

    // MARK: - The two claims

    /// The marked run is drawn UNDERLINED, and the bare line is not.
    ///
    /// The underline is the one mark in the band that spans a whole run contiguously, so the longest
    /// horizontal run of changed pixels IS it — glyph strokes break, a 2pt caret is 2pt wide.
    func testTheMarkedRunIsDrawnUnderlined() throws {
        let bare = try photograph(composition: nil)
        let composing = try photograph(composition: (marked, NSRange(location: 0, length: 0)))
        // At selection 0 the composition's caret sits exactly where the bare caret does, so the two
        // bars cancel and everything left in the diff belongs to the marked run itself.
        let changed = try XCTUnwrap(Diff(bare.pixels, composing.pixels), "the two renders differ in shape")
        XCTAssertGreaterThan(changed.longestRun, 0, "the marked run drew nothing at all")

        let runWidth = compositionWidth()
        XCTAssertGreaterThan(
            CGFloat(changed.longestRun) / bare.pixels.scale, runWidth * 0.8,
            "no mark spans the marked run — the preedit is drawn without its underline",
        )
    }

    /// The caret the band REPORTS is the caret it DRAWS, with a composition in flight.
    ///
    /// Two renders of one run differing only in where the composition's own caret sits: everything
    /// but the two bars is identical, so the changed columns bound them. What the band reports has to
    /// move by the same distance the bars did.
    func testTheCaretTheBandReportsIsTheCaretItDraws() throws {
        let head = try photograph(composition: (marked, NSRange(location: 0, length: 0)))
        let tail = try photograph(
            composition: (marked, NSRange(location: marked.utf16.count, length: 0)),
        )
        let changed = try XCTUnwrap(Diff(head.pixels, tail.pixels), "the two renders differ in shape")
        // Leftmost changed column is the head render's bar; rightmost is the tail's, plus its width.
        let drawn = CGFloat(changed.last - changed.first) / head.pixels.scale - caretWidth

        let reported = try XCTUnwrap(tail.caret).minX - (try XCTUnwrap(head.caret)).minX
        XCTAssertGreaterThan(
            reported, 1, "the reported caret did not move at all — it is ignoring the composition",
        )
        XCTAssertEqual(
            drawn, reported, accuracy: 1.5,
            "the candidate window would hang off a different point than the caret the user sees",
        )
    }

    // MARK: - The rig

    /// The band's caret bar, in points — `TerminalPromptBand.caretRect`'s own width.
    private let caretWidth: CGFloat = 2

    /// One render of the band over a two-character draft, plus the rect it reports for its caret.
    private func photograph(
        composition: (text: String, selection: NSRange)?,
    ) throws -> (pixels: Bitmap, caret: CGRect?) {
        let prompt = CommandPrompt()
        prompt.insert("ls")
        let view = PhoneTerminalPromptView(
            prompt: prompt, armed: { true }, composition: { composition },
            focusPane: {}, promptEdited: {},
        )
        let height = view.fittingHeight
        XCTAssertGreaterThan(height, 0, "an armed band with a draft in it has a height")
        let image = HostedRaster.image(view, width: width, height: height)
        let bitmap = try XCTUnwrap(Bitmap(image), "the rig photographed something with no backing")
        // The bare render must contain ink, or every comparison below is between two blank fields —
        // the silent failure `HostedRaster`'s own header exists to prevent.
        XCTAssertTrue(bitmap.hasVariation, "the band photographed as one flat colour")
        return (bitmap, view.caretRect)
    }

    /// How wide the marked run draws, asked of Core Text the way the band asks.
    private func compositionWidth() -> CGFloat {
        let metrics = TerminalPromptBand.Metrics.current
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: marked, attributes: [.init(kCTFontAttributeName as String): metrics.font],
        ))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        XCTAssertGreaterThan(width, 0, "the run measured as empty")
        return CGFloat(width)
    }
}

/// The ⌃R panel, photographed — the rows and the underline that says why each is there.
///
/// Arithmetic cannot settle either claim. The band's height is `accessoryRows × lineHeight` and the
/// rows are drawn from that same number, so a panel that counted one row while drawing four would
/// agree with itself and clip three; and the fuzzy underline is the only mark distinguishing a
/// ranked panel from a list of recent commands, which is exactly the "green tests, feature never
/// fires" shape.
@MainActor
final class TerminalSearchPanelPixelsOnIOSTests: XCTestCase {
    private let width: CGFloat = 420

    /// The panel is TALLER than the query row alone, by one row per match it draws.
    ///
    /// The regression this pins is the one the change could not avoid: `accessoryRows` answered `1`
    /// while a search was up, because a search used to have exactly one hit to show.
    func testThePanelGrowsTheBandByOneRowPerMatch() throws {
        let one = try photograph(history: ["cargo test"], query: "cargo")
        let three = try photograph(
            history: ["cargo test", "cargo build", "cargo clippy"], query: "cargo",
        )
        let row = TerminalPromptBand.Metrics.current.lineHeight
        XCTAssertEqual(
            three.height - one.height, row * 2, accuracy: 0.5,
            "the band did not make room for the rows it draws — the panel is clipped",
        )
        // And the rows it grew by carry INK rather than being reserved space nothing draws into.
        XCTAssertTrue(
            three.pixels.hasVariation(from: Int(one.height * three.pixels.scale)),
            "the band grew but drew nothing in the rows it grew by",
        )
    }

    /// The scalars the query matched are UNDERLINED, and an unqueried row is not.
    ///
    /// Two renders of the SAME single row: an empty query lists it with no positions, and a query
    /// that matches a run inside it underlines exactly that run. The row's text is identical in
    /// both, so everything the diff finds below the query row is the underline — and its longest
    /// horizontal run is the mark's width, since glyph strokes break and an underline does not.
    func testTheMatchedRunIsUnderlinedInThePanel() throws {
        let entry = "git commit --amend"
        let listed = try photograph(history: [entry], query: "")
        let matched = try photograph(history: [entry], query: "amend")
        let scale = listed.pixels.scale
        // Past the query row, so the two different queries printed on it are out of the comparison.
        let panelTop = Int((TerminalPromptBand.inset.height + TerminalPromptBand.Metrics.current
                .lineHeight * 2) * scale)
        let changed = try XCTUnwrap(
            Diff(listed.pixels, matched.pixels, from: panelTop),
            "the panel row is pixel-identical — the match drew no underline",
        )
        XCTAssertGreaterThan(
            CGFloat(changed.longestRun) / scale, runWidth(of: "amend") * 0.8,
            "no mark spans the matched run — the ranking is invisible to the reader",
        )
    }

    // MARK: - The rig

    /// One render of an armed band with a ⌃R session open over `history`.
    private func photograph(
        history: [String], query: String,
    ) throws -> (pixels: Bitmap, height: CGFloat) {
        let prompt = CommandPrompt()
        for command in history { prompt.recordHistory(command) }
        prompt.beginSearch()
        if !query.isEmpty { prompt.searchType(query) }
        XCTAssertTrue(prompt.isSearching)
        XCTAssertFalse(prompt.candidates.isEmpty, "the fixture matched nothing to draw")
        let view = PhoneTerminalPromptView(
            prompt: prompt, armed: { true }, composition: { nil }, focusPane: {}, promptEdited: {},
        )
        let height = view.fittingHeight
        let image = HostedRaster.image(view, width: width, height: height)
        let bitmap = try XCTUnwrap(Bitmap(image), "the rig photographed something with no backing")
        XCTAssertTrue(bitmap.hasVariation, "the band photographed as one flat colour")
        return (bitmap, height)
    }

    /// How wide a run draws, asked of Core Text the way the band asks.
    private func runWidth(of text: String) -> CGFloat {
        let metrics = TerminalPromptBand.Metrics.current
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.init(kCTFontAttributeName as String): metrics.font],
        ))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - Reading the bitmap

/// A rendered `UIImage` as one RGBA buffer.
///
/// `UIImage.slatePixel(atX:y:)` answers ONE pixel by redrawing the whole image into a 1×1 context,
/// which is right for a rig sampling three of them and quadratic for one comparing every column.
@MainActor
private struct Bitmap {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        width = cgImage.width
        height = cgImage.height
        scale = image.scale
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// Whether more than one colour is present — a blank photograph is the failure to catch first.
    var hasVariation: Bool { hasVariation(from: 0) }

    /// The same question asked of the rows at or below `row`, for a rig checking that a band which
    /// grew actually drew into the space it took.
    func hasVariation(from row: Int) -> Bool {
        let first = max(row, 0) * width
        guard bytes.count > 4, first < width * height else { return false }
        return (first + 1..<width * height).contains { pixel in
            (0..<4).contains { bytes[pixel * 4 + $0] != bytes[first * 4 + $0] }
        }
    }

    /// Whether the two bitmaps' pixel at `(x, y)` differs.
    func differs(from other: Self, x: Int, y: Int) -> Bool {
        let index = (y * width + x) * 4
        return bytes[index] != other.bytes[index]
            || bytes[index + 1] != other.bytes[index + 1]
            || bytes[index + 2] != other.bytes[index + 2]
    }
}

/// Where two renders of the same band disagree, in PIXEL columns.
@MainActor
private struct Diff {
    /// The leftmost and rightmost columns holding any changed pixel.
    let first: Int
    let last: Int
    /// The longest contiguous horizontal run of changed pixels in any single row.
    let longestRun: Int

    /// `from` skips the rows above it, for a comparison that has to exclude a header the two renders
    /// deliberately differ on — the ⌃R query line, which carries the query being varied.
    init?(_ a: Bitmap, _ b: Bitmap, from: Int = 0) {
        guard a.width == b.width, a.height == b.height, a.width > 0 else { return nil }
        var low = Int.max
        var high = Int.min
        var best = 0
        for y in max(from, 0)..<a.height {
            var run = 0
            for x in 0..<a.width {
                guard a.differs(from: b, x: x, y: y) else {
                    run = 0
                    continue
                }
                run += 1
                best = max(best, run)
                low = min(low, x)
                high = max(high, x)
            }
        }
        guard low <= high else { return nil }
        first = low
        last = high
        longestRun = best
    }
}
