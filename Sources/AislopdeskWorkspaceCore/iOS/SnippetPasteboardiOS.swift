// SnippetPasteboardiOS — the iOS half of the `{{clipboard}}` snippet placeholder read (E16 WI-10).
//
// The reserved-snippet-var resolver (`ReservedSnippetVars`) is PURE — it only ever sees injected strings, so
// it stays headless + deterministic + testable without a real pasteboard. The LIVE read of the system
// clipboard is platform glue the app injects through `WorkspaceStore.snippetReservedValues`: on macOS the app
// reads `NSPasteboard.general` inline; on iOS it reads `UIPasteboard.general` through this helper.
//
// It lives in the `iOS/` folder (alongside the other UIKit-touching iOS glue, e.g. `PaneFocusCoordinator`)
// and is `#if os(iOS)`-gated so a macOS build never links it — mirroring how `ClipboardMonitor` is the
// macOS-only `NSPasteboard` reader.

#if os(iOS)
import Foundation
import UIKit

/// The iOS system-clipboard reader for the `{{clipboard}}` snippet placeholder. Reads `UIPasteboard.general`
/// at expand time (NOT pure — that is exactly why it is OUTSIDE the headless ``ReservedSnippetVars`` resolver).
@preconcurrency
@MainActor
public enum SnippetPasteboardiOS {
    /// The current general-pasteboard string, or `""` when the board holds no string (an image / empty board).
    /// Whatever the app's `{{clipboard}}` substitution injects into the snippet body verbatim.
    public static func clipboardString() -> String {
        UIPasteboard.general.string ?? ""
    }
}
#endif
