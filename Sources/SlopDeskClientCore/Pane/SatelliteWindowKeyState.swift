// SatelliteWindowKeyState — the one bit a satellite window tells its content.
//
// A satellite is a plain `NSWindowController` in `SlopDeskMacUI` and its content is a pane leaf drawn
// one floor below it. The window knows whether it is KEY; the leaf needs to know, because for a video
// pane `isFocused` gates pointer/keycode forwarding (`RemotePaneContext.isActive`) and a background
// satellite that kept forwarding would fight the main window — or another satellite — for host input.
//
// It has no view in it and never did: one `Bool` behind `@Observable`, so a `didBecomeKey` /
// `didResignKey` on the window side lands as a re-render on the content side. It lived inside
// `SatellitePaneContent.swift` only because that is where its one reader was, which is exactly the
// accident docs/56 §3 names — a frameworkless type in a UI target is logic only one of the two halves
// can reach. The window that CONSTRUCTS it (`SatellitePaneWindows`) and the leaf that READS it are in
// two different targets, so the value belongs under both.

import Observation

/// Relays the satellite window's key state into whatever draws its content: `isKey` drives the pane
/// leaf's `isFocused`.
@MainActor
@Observable
package final class SatelliteWindowKeyState {
    package init() {}

    package var isKey = false
}
