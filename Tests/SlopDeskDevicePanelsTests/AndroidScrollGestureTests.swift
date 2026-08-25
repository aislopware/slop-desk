// AndroidScrollGestureTests — the FACE, not the machine.
//
// The machine — one contact that moves, the re-grip at the edge, the margin — is
// `slopdesk_devicepanel::scroll` and is pinned there, shared with the simulator lane. What these hold
// is the conversion that stays on THIS side, and both halves of it have already shipped wrong once:
//
//   - the message must be `INJECT_TOUCH_EVENT`, never `INJECT_SCROLL_EVENT`. The latter works — it
//     arrives as `ACTION_SCROLL` — and it costs the scroll every piece of feedback Android gives,
//     because over-scroll, edge glow and fling all come off the touch path;
//   - it must carry the VIDEO's pixels paired with the VIDEO's size. `scrcpy`'s `PositionMapper`
//     compares that pair against the size it is encoding and DROPS the event on any difference, with
//     no error the client can see.

#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

final class AndroidScrollGestureTests: XCTestCase {
    private let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)

    /// A 1:1 surface, so a case can read the finger's position in the same numbers it planted it
    /// with. The panel is almost never at 1:1 — that conversion is pinned on its own below.
    private var surface: AndroidScreenLayout.Surface {
        AndroidScreenLayout.Surface(fitted: fitted, video: fitted.size)
    }

    private let degenerate = AndroidScreenLayout.Surface(fitted: .zero, video: .zero)

    /// THE assertion in this file: everything a gesture emits is `INJECT_TOUCH_EVENT` (2), and the
    /// actions run down → move → up, so the device sees a dragged finger with a history to compute a
    /// fling from.
    func testEveryContactBecomesATouchEventAndNeverAWheelNotch() {
        let gesture = AndroidScrollGesture()
        var emitted: [Data] = gesture.accept(
            delta: CGSize(width: 0, height: -20), isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        XCTAssertEqual(actions(emitted), [
            AndroidMotionAction.down.rawValue, AndroidMotionAction.move.rawValue,
        ])

        for _ in 0..<40 {
            emitted += gesture.accept(
                delta: CGSize(width: 0, height: -12), isPrecise: true, phase: .changed,
                pointer: CGPoint(x: 100, y: 200), surface: surface,
            )
        }
        let close = gesture.accept(
            delta: .zero, isPrecise: true, phase: .ended,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        XCTAssertEqual(actions(close), [AndroidMotionAction.up.rawValue])
        XCTAssertNil(gesture.finger)

        emitted += close
        // The type bytes as literals: `slopdesk_androidd::control` owns the numbering now, and a
        // Swift constant re-exported so a test could name it would be layout knowledge back here.
        XCTAssertFalse(types(emitted).contains(3), "INJECT_SCROLL_EVENT — a notch, with no kinetics")
        XCTAssertTrue(types(emitted).allSatisfy { $0 == 2 }, "INJECT_TOUCH_EVENT — a dragged finger")
    }

    /// The panel first shipped pairing panel points with the panel's size, and every scroll, drag and
    /// tap was silently discarded while the toolbar's keycodes (which carry no geometry) kept working.
    func testTheWireCarriesVideoPixelsAndTheVideosSize() throws {
        let scaled = AndroidScreenLayout.Surface(
            fitted: fitted, video: CGSize(width: 460, height: 1024),
        )
        let gesture = AndroidScrollGesture()
        let opening = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), surface: scaled,
        )
        let bytes = try [UInt8](XCTUnwrap(opening.first))
        XCTAssertEqual(bytes.count, 32)

        // The contact is still tracked in panel points…
        XCTAssertEqual(gesture.finger, CGPoint(x: 100, y: 200))
        // …and reported in the video's grid: half the width, half the height.
        XCTAssertEqual(readInt32(bytes, at: 10), 230)
        XCTAssertEqual(readInt32(bytes, at: 14), 512)
        XCTAssertEqual(readUInt16(bytes, at: 18), 460)
        XCTAssertEqual(readUInt16(bytes, at: 20), 1024)
    }

    /// The last addressable pixel, not the size itself: a frame's rows are `0..<height`, so a contact
    /// dragged onto the bottom edge must not name a row that does not exist.
    func testAContactAtTheFarEdgeStopsOneShortOfTheSize() {
        let scaled = AndroidScreenLayout.Surface(
            fitted: fitted, video: CGSize(width: 460, height: 1024),
        )
        XCTAssertEqual(scaled.pixels(CGPoint(x: 200, y: 400)), CGPoint(x: 459, y: 1023))
    }

    /// A surface the stream has not yet named a size for produces NOTHING. A message built from one
    /// would be discarded by the device anyway, and this is the guard that stays on this side because
    /// the video's size is a fact only this lane has.
    func testADegenerateSurfaceProducesNothing() {
        let gesture = AndroidScrollGesture()
        XCTAssertTrue(gesture.accept(
            delta: CGSize(width: 0, height: -10), isPrecise: true, phase: .began,
            pointer: .zero, surface: degenerate,
        ).isEmpty)
    }

    /// A door answering zero contacts must come back as NO messages — an unmatched `up` would land on
    /// the device as a phantom release.
    func testNoContactsComesBackAsNoMessages() {
        let gesture = AndroidScrollGesture()
        XCTAssertTrue(gesture.lift(in: surface).isEmpty)

        _ = gesture.accept(
            delta: .zero, isPrecise: true, phase: .began,
            pointer: CGPoint(x: 100, y: 200), surface: surface,
        )
        gesture.abandon()
        XCTAssertNil(gesture.finger)
        XCTAssertTrue(gesture.lift(in: surface).isEmpty)
    }

    // MARK: Helpers

    /// The action byte of each emitted touch message.
    private func actions(_ messages: [Data]) -> [UInt8] {
        messages.map { $0[$0.index($0.startIndex, offsetBy: 1)] }
    }

    private func types(_ messages: [Data]) -> [UInt8] {
        messages.map { $0[$0.startIndex] }
    }

    private func readInt32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3]))
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}
#endif
