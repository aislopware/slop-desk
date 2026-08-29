// PanelChromeActions — which trailing verb the panel's chrome is carrying, per surface.
//
// The Mac's strip and the phone's bar both trail ONE action plate — reload — and both had typed the
// same four-armed switch to decide whether it shows at all. That answer is not a layout and not a
// word: it is the panel's own rule about which surfaces have something to reload, and a rule spelled
// once per shell is a rule that can disagree with itself the day a fifth surface arrives.
//
// It sits beside ``PanelChromeCopy``, which already owns what the plate SAYS, for the same reason and
// with the same boundary: the copy answers `nil` where there is no plate, and this answers whether
// the plate the copy has words for is on screen right now. They are kept apart because the two
// questions have different inputs — the mount gate is the strip's live reading, and no sentence
// depends on it.

// ``PanelSurface`` is this target's own (`App/WorkspaceChromeState.swift`) and a `Bool` is the
// standard library's, so this file imports nothing.

package enum PanelChromeActions {
    /// Whether the strip's trailing reload plate shows on `surface`.
    ///
    /// Desktop is announced-but-empty and has nothing to reload. The workbench has nothing to reload
    /// until it is MOUNTED — behind the open gate a reload would bump the poll generation and boot
    /// the very thing the gate exists to defer — so its answer is the caller's `codeReloadable`,
    /// which only the shell that holds the mount can read.
    package static func reloadShown(for surface: PanelSurface, codeReloadable: Bool) -> Bool {
        switch surface {
        case .code: codeReloadable
        case .simulators,
             .android: true
        case .desktop: false
        }
    }
}
