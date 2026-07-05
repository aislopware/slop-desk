#if os(macOS)
import ApplicationServices
import CoreGraphics

// Private AX SPI: maps an `AXUIElement` window to its `CGWindowID`. TCC-gated (Accessibility), no
// SIP disable needed — the same trust the injector / geometry watcher / window placement already
// require. Declared ONCE for the whole host module (a second `@_silgen_name` of the same symbol
// would be a duplicate-symbol link error), and shared via ``axWindowID(of:)``.
//
// This is the standard, long-lived approach used by yabai / Hammerspoon to bridge the AX world to
// CGWindowIDs (there is no PUBLIC AXUIElement↔CGWindowID map — docs/05 §4). It is strictly more
// robust than the legacy frame-equality heuristic, which mis-binds when two windows share an
// identical frame (e.g. several panes stacked at the same origin on the shared virtual display).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The `CGWindowID` backing an AX window `element`, or `nil` if the SPI is unavailable / fails.
/// Main-actor because AX messaging is main-thread. The `wid != 0` guard matters: on macOS 15+ with
/// the screen locked the SPI returns `.success` but writes 0 (AeroSpace #445).
@MainActor
func axWindowID(of element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
    return wid
}
#endif
