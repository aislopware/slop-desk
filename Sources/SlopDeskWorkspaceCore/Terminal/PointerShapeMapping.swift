import CSlopDeskFFI

// MARK: - OSC-22 pointer-shape mapping

/// A stable, AppKit-free token naming the cursor the GUI should adopt.
///
/// The cases mirror ghostty's macOS `CursorStyle` (`Helpers/Cursor.swift`) so the resolution is faithful
/// to upstream; the GUI surface owns the single `PointerShapeToken → NSCursor` switch (with the macOS-15
/// `columnResize`/`rowResize` availability handling), which is why this layer stays headless.
///
/// **The raw values are the wire.** They are the discriminants `slopdesk_pointer_shape_token` returns,
/// pinned to `slopdesk_terminal::pointer::PointerToken`. A case reordered here is a cursor swapped for
/// another cursor, with nothing to notice it — which is why the door's own suite asserts every one of
/// the fifteen numbers rather than the mapping alone.
public enum PointerShapeToken: Int32, CaseIterable, Sendable, Equatable {
    case arrow = 0
    case text = 1
    case verticalText = 2
    case pointer = 3
    case grab = 4
    case grabbing = 5
    case contextMenu = 6
    case crosshair = 7
    case notAllowed = 8
    case resizeLeft = 9
    case resizeRight = 10
    case resizeUp = 11
    case resizeDown = 12
    case resizeUpDown = 13
    case resizeLeftRight = 14
}

/// The OSC-22 pointer-shape → cursor-token face.
///
/// A terminal program selects the pointer shape with the CSS-named OSC 22 sequence
/// (`OSC 22 ; <name> ST`); libghostty parses it and emits a `GHOSTTY_ACTION_MOUSE_SHAPE` action whose
/// payload is a `ghostty_action_mouse_shape_e`. That raw `Int32` crosses to
/// `slopdesk_terminal::pointer`, which owns the table — including which shapes macOS has no native
/// cursor for and therefore leaves alone.
///
/// ## Why the raw value crosses unparsed
/// This file used to hold `OSCPointerShape`, a 34-case Swift enum mirroring the C one, purely so the
/// table below could switch over it. That made THREE copies of one declaration order — libghostty's
/// header, the Swift mirror, and the table — of which any two could drift while still compiling. The
/// raw int now travels and the crate that owns the meaning validates it (`docs/55`, §4).
public enum PointerShapeMapping {
    /// Resolve a raw `ghostty_action_mouse_shape_e` to the cursor token the GUI should adopt, or `nil`
    /// to KEEP the current cursor.
    ///
    /// `nil` covers a shape macOS has no native `NSCursor` for (help / progress / wait / cell / alias /
    /// copy / move / no-drop / all-scroll / {col,row,diagonal}-resize / zoom, which upstream ignores)
    /// AND an out-of-range value from a newer or corrupt libghostty. The two behave identically on
    /// purpose: keeping the cursor a person is already looking at beats inventing a substitute.
    public static func token(forRawValue raw: Int32) -> PointerShapeToken? {
        PointerShapeToken(rawValue: slopdesk_pointer_shape_token(raw))
    }
}
