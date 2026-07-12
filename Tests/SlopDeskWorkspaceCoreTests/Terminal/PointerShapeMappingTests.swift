import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure OSC-22 ``PointerShapeMapping`` table. The GUI surface
/// (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`) is a thin actuator that turns the
/// resolved ``PointerShapeToken`` into an `NSCursor`, so the faithful shape→token table is pinned here.
///
/// Faithful to ghostty's macOS `setCursorShape` (`SurfaceView_AppKit.swift`): every shape with a native
/// `NSCursor` resolves to its token; every shape upstream ignores resolves to `nil` ("keep current cursor").
/// None of these assertions is tautological — they encode the upstream mapping + the C enum's raw ordering,
/// not the function's own derivation; a wrong raw value or a dropped `default→arrow` case fails the suite.
final class PointerShapeMappingTests: XCTestCase {
    /// The raw values MUST match the `ghostty_action_mouse_shape_e` declaration order (`ghostty.h:672-707`),
    /// because the GUI hands us the C enum's integer payload directly. A reorder here silently mis-maps every
    /// shape, so pin the load-bearing anchors (and the full count) explicitly.
    func testRawValuesMatchCEnumDeclarationOrder() {
        XCTAssertEqual(OSCPointerShape.default.rawValue, 0)
        XCTAssertEqual(OSCPointerShape.contextMenu.rawValue, 1)
        XCTAssertEqual(OSCPointerShape.pointer.rawValue, 3)
        XCTAssertEqual(OSCPointerShape.crosshair.rawValue, 7)
        XCTAssertEqual(OSCPointerShape.text.rawValue, 8)
        XCTAssertEqual(OSCPointerShape.verticalText.rawValue, 9)
        XCTAssertEqual(OSCPointerShape.notAllowed.rawValue, 14)
        XCTAssertEqual(OSCPointerShape.grab.rawValue, 15)
        XCTAssertEqual(OSCPointerShape.grabbing.rawValue, 16)
        XCTAssertEqual(OSCPointerShape.nResize.rawValue, 20)
        XCTAssertEqual(OSCPointerShape.eResize.rawValue, 21)
        XCTAssertEqual(OSCPointerShape.sResize.rawValue, 22)
        XCTAssertEqual(OSCPointerShape.wResize.rawValue, 23)
        XCTAssertEqual(OSCPointerShape.ewResize.rawValue, 28)
        XCTAssertEqual(OSCPointerShape.nsResize.rawValue, 29)
        XCTAssertEqual(OSCPointerShape.zoomOut.rawValue, 33)
        // The C enum has exactly 34 shapes (0…33); a new shape must be added deliberately.
        XCTAssertEqual(OSCPointerShape.allCases.count, 34)
    }

    /// The shapes macOS has a native `NSCursor` for resolve to their token — mirrors upstream `setCursorShape`
    /// (`SurfaceView_AppKit.swift:505-556`). `default → arrow` is the "reset to arrow" anchor of the spec.
    func testMappedShapesResolveToTheirToken() {
        let expected: [OSCPointerShape: PointerShapeToken] = [
            .default: .arrow,
            .text: .text,
            .verticalText: .verticalText,
            .pointer: .pointer,
            .grab: .grab,
            .grabbing: .grabbing,
            .contextMenu: .contextMenu,
            .crosshair: .crosshair,
            .notAllowed: .notAllowed,
            .wResize: .resizeLeft,
            .eResize: .resizeRight,
            .nResize: .resizeUp,
            .sResize: .resizeDown,
            .nsResize: .resizeUpDown,
            .ewResize: .resizeLeftRight,
        ]
        for (shape, token) in expected {
            XCTAssertEqual(
                PointerShapeMapping.token(for: shape), token,
                "OSC-22 shape \(shape) must map to \(token)",
            )
        }
    }

    /// Every shape with NO native `NSCursor` resolves to `nil` (keep the current cursor) — upstream's
    /// "ignore unknown shapes". A naive table that guessed a substitute (e.g. mapping `move`/`copy` to some
    /// cursor) would FAIL this; the faithful behaviour is to leave the pointer unchanged.
    func testUnmappedShapesResolveToNil() {
        let unmapped: [OSCPointerShape] = [
            .help, .progress, .wait, .cell, .alias, .copy, .move, .noDrop, .allScroll,
            .colResize, .rowResize, .neResize, .nwResize, .seResize, .swResize,
            .neswResize, .nwseResize, .zoomIn, .zoomOut,
        ]
        for shape in unmapped {
            XCTAssertNil(
                PointerShapeMapping.token(for: shape),
                "OSC-22 shape \(shape) has no native NSCursor and must keep the current cursor (nil)",
            )
        }
    }

    /// Exhaustiveness guard: the mapped + unmapped partition covers ALL 34 shapes with no overlap, so the
    /// table can never silently drop a future shape into an undefined state.
    func testEveryShapeIsClassifiedExactlyOnce() {
        var mappedCount = 0
        var nilCount = 0
        for shape in OSCPointerShape.allCases {
            if PointerShapeMapping.token(for: shape) == nil { nilCount += 1 } else { mappedCount += 1 }
        }
        XCTAssertEqual(mappedCount, 15)
        XCTAssertEqual(nilCount, 19)
        XCTAssertEqual(mappedCount + nilCount, OSCPointerShape.allCases.count)
    }

    /// The raw-int convenience used by the `action_cb`: a valid raw resolves through, an out-of-range raw is
    /// dropped to `nil` (validate-then-drop on a future/corrupt enum value — never trap).
    func testRawValueConvenienceValidatesThenDrops() {
        XCTAssertEqual(PointerShapeMapping.token(forRawValue: 0), .arrow) // default
        XCTAssertEqual(PointerShapeMapping.token(forRawValue: 8), .text) // text
        XCTAssertEqual(PointerShapeMapping.token(forRawValue: 23), .resizeLeft) // w-resize
        XCTAssertNil(PointerShapeMapping.token(forRawValue: 2)) // help → no cursor
        XCTAssertNil(PointerShapeMapping.token(forRawValue: 34)) // out of range
        XCTAssertNil(PointerShapeMapping.token(forRawValue: -1)) // out of range
        XCTAssertNil(PointerShapeMapping.token(forRawValue: 9999)) // out of range
    }
}
