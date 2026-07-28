#!/usr/bin/env swift
// window-census.swift — how many REAL on-screen windows a pid owns.
//
// WHY this exists: `scripts/check-macos.sh` has to assert "the app came up WINDOWED", and the two
// cheap ways to answer it both lie.
//
//   - `pgrep` answers "the process is alive". A macOS app with zero windows is a perfectly healthy
//     process sitting in its run loop.
//   - `slopdesk --socket … windows --json` answers off `WorkspaceControlBackend.listWindows()`,
//     which maps `WorkspaceStore.tree.sessions` — a value the App's `init()` builds before any
//     scene exists. It is a SESSION count with no window information in it. Nor does the socket
//     itself carry the claim: `ClientControlServer.start()` hands its listener to
//     `Thread.detachNewThread` and nothing ever calls `stop()`, so once bound it stays bound for the
//     process lifetime, scene teardown included. HW-observed 2026-07-28: close the app's window and
//     the process reports one "window" over the socket for as long as it lives.
//
// So the census is taken from the window server, which is the only thing that actually knows.
// `CGWindowListCopyWindowInfo` needs NO TCC for the fields used here — owner pid, window layer and
// bounds are public; only `kCGWindowName` (the TITLE) is gated behind Screen Recording, and this
// never reads it. That keeps check-macos.sh's promise that it needs neither Screen-Recording nor
// Accessibility TCC.
//
// WHAT COUNTS: an on-screen window owned by <pid>, at layer 0 (`kCGNormalWindowLevel` — the level a
// document window lives at, which excludes menus, popovers, tooltips, status items and the desktop),
// and at least 200×200pt (SwiftUI/AppKit mint tiny off-band helper windows; a real app window is not
// one of them).
//
// USAGE:  swift scripts/window-census.swift <pid>          # or compile once and run the binary
// OUTPUT: the count on stdout; one line per candidate on stderr (diagnostics for a red run).
// EXIT:   0 always when the pid parses — the COUNT is the answer, and "0 windows" is a legitimate
//         answer this gate must be able to read. 2 on a usage error.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = Int(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-census.swift <pid>\n".utf8))
    exit(2)
}

/// Smallest window this counts as the app's UI, in points.
let minimumSide = 200.0

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

var count = 0
for window in listing {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    let counted = layer == 0 && width >= minimumSide && height >= minimumSide
    let note = "  pid \(pid) window: layer=\(layer) \(Int(width))x\(Int(height))pt "
        + (counted ? "COUNTED" : "skipped") + "\n"
    FileHandle.standardError.write(Data(note.utf8))
    if counted { count += 1 }
}

print(count)
