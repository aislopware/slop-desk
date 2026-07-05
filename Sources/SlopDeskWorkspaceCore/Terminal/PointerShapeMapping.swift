import Foundation

// MARK: - E8 WI-9 (H14): OSC-22 pointer-shape mapping

/// Swift mirror of libghostty's `ghostty_action_mouse_shape_e` C enum (`terminal.MouseShape`,
/// `CGhostty/ghostty.h:672-707`). The raw values are pinned to the C enum's declaration order so an
/// `Int32` delivered by a `GHOSTTY_ACTION_MOUSE_SHAPE` action maps 1:1 WITHOUT importing `CGhostty`
/// into this headless, AppKit-free module — keeping the shape→cursor table unit-testable.
///
/// A terminal program selects the pointer shape with the CSS-named OSC 22 sequence
/// (`OSC 22 ; <name> ST`); libghostty parses it and emits a `GHOSTTY_ACTION_MOUSE_SHAPE` action whose
/// payload is one of these. The GUI surface (`GhosttyTerminalView`, compile-only behind
/// `#if canImport(CGhostty)`) reads the raw int and asks ``PointerShapeMapping`` to resolve a
/// ``PointerShapeToken`` it can turn into an `NSCursor`.
public enum OSCPointerShape: Int32, CaseIterable, Sendable, Equatable {
    case `default` = 0
    case contextMenu = 1
    case help = 2
    case pointer = 3
    case progress = 4
    case wait = 5
    case cell = 6
    case crosshair = 7
    case text = 8
    case verticalText = 9
    case alias = 10
    case copy = 11
    case move = 12
    case noDrop = 13
    case notAllowed = 14
    case grab = 15
    case grabbing = 16
    case allScroll = 17
    case colResize = 18
    case rowResize = 19
    case nResize = 20
    case eResize = 21
    case sResize = 22
    case wResize = 23
    case neResize = 24
    case nwResize = 25
    case seResize = 26
    case swResize = 27
    case ewResize = 28
    case nsResize = 29
    case neswResize = 30
    case nwseResize = 31
    case zoomIn = 32
    case zoomOut = 33
}

/// A stable, AppKit-free token naming the cursor the GUI should adopt for a given ``OSCPointerShape``.
///
/// The cases mirror ghostty's macOS `CursorStyle` (`Helpers/Cursor.swift`) so the resolution is faithful
/// to upstream; the GUI surface owns the single `PointerShapeToken → NSCursor` switch (with the macOS-15
/// `columnResize`/`rowResize` availability handling), which is why this layer can stay headless and pinned.
public enum PointerShapeToken: String, CaseIterable, Sendable, Equatable {
    case arrow
    case text
    case verticalText
    case pointer
    case grab
    case grabbing
    case contextMenu
    case crosshair
    case notAllowed
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight
}

/// The PURE, headless OSC-22 pointer-shape → cursor-token table (H14).
///
/// It mirrors ghostty's macOS `setCursorShape` (`SurfaceView_AppKit.swift:505-556`) EXACTLY for the shapes
/// macOS has a native `NSCursor` for, and returns `nil` for every shape upstream "ignores" — there is no
/// native `NSCursor` for help / progress / wait / cell / alias / copy / move / no-drop / all-scroll /
/// {col,row,diagonal}-resize / zoom, so the faithful behaviour is to KEEP the current cursor (a `nil` the
/// GUI treats as "no change") rather than invent a substitute. `GHOSTTY_MOUSE_SHAPE_DEFAULT` maps to
/// ``PointerShapeToken/arrow`` — this is the "reset to arrow on default / program exit" the plan calls out
/// (a program leaving a custom shape, e.g. `btop`/`yazi` exiting back to the shell, re-emits the default).
public enum PointerShapeMapping {
    /// Resolve a parsed ``OSCPointerShape`` to the cursor token the GUI should adopt, or `nil` to keep the
    /// current cursor (shapes with no native `NSCursor`, mirroring upstream's "ignore unknown shapes").
    public static func token(for shape: OSCPointerShape) -> PointerShapeToken? {
        switch shape {
        case .default: .arrow
        case .text: .text
        case .verticalText: .verticalText
        case .pointer: .pointer
        case .grab: .grab
        case .grabbing: .grabbing
        case .contextMenu: .contextMenu
        case .crosshair: .crosshair
        case .notAllowed: .notAllowed
        case .wResize: .resizeLeft
        case .eResize: .resizeRight
        case .nResize: .resizeUp
        case .sResize: .resizeDown
        case .nsResize: .resizeUpDown
        case .ewResize: .resizeLeftRight
        // No native NSCursor — upstream `setCursorShape` keeps the current cursor for all of these.
        case .help,
             .progress,
             .wait,
             .cell,
             .alias,
             .copy,
             .move,
             .noDrop,
             .allScroll,
             .colResize,
             .rowResize,
             .neResize,
             .nwResize,
             .seResize,
             .swResize,
             .neswResize,
             .nwseResize,
             .zoomIn,
             .zoomOut:
            nil
        }
    }

    /// Convenience for the C `action_cb`: validate a raw `ghostty_action_mouse_shape_e` value (read as an
    /// `Int32`) and resolve it. An out-of-range / unknown raw int (a future or corrupt enum value) returns
    /// `nil` — validate-then-drop: the surface keeps its current cursor rather than trapping on a bad value.
    public static func token(forRawValue raw: Int32) -> PointerShapeToken? {
        guard let shape = OSCPointerShape(rawValue: raw) else { return nil }
        return token(for: shape)
    }
}
