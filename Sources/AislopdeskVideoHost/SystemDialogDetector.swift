#if os(macOS)
import CoreGraphics
import Foundation

/// Pure, unit-tested classifier behind the "show system popups/prompts in their own pane" feature.
///
/// A SYSTEM dialog is a cross-process modal window that NO app-pane would ever capture — the prime
/// case (the user's ask) being a `SecurityAgent` login/admin **password** prompt. The host enumerates
/// the on-screen windows, runs this classifier, and answers the client's `listSystemDialogs` poll with
/// the matches; the client auto-spawns an ephemeral pane per dialog.
///
/// **HW-grounded (probe 2026-06-12, Tahoe 26.5.1):** `SCShareableContent` DOES list the SecurityAgent
/// prompt (own window, layer 1000, onScreen), and `desktopIndependentWindow` captures it with real
/// pixels — it is NOT capture-blocked. But while it is up `IsSecureEventInputEnabled() == true`, so
/// synthetic KEYSTROKES are OS-dropped: a secure dialog is **view + click only**, the password must be
/// typed on the host. That truth is carried per-dialog as ``Dialog/isSecure`` so the client can label it.
///
/// **Scope (v1):** system AUTH prompts only — `SecurityAgent` / `coreauthd`. These never overlap with a
/// streamed app window (different system pid, never a child of an app window) nor with the DIALOG-EXPAND
/// union (which handles app-OWNED save/open panels in the streamed pane). The allowlists below are the
/// single expansion point — adding a new system-prompt source is one entry.
public enum SystemDialogDetector {
    /// One enumerated on-screen window (the fields ``classify(_:minSize:)`` reads). Built from an
    /// `SCWindow` on the host; kept as a plain value so the classifier is pure + testable off-device.
    public struct WindowSnapshot: Equatable, Sendable {
        public var windowID: UInt32
        public var ownerName: String
        public var bundleID: String
        public var isOnScreen: Bool
        public var title: String
        public var frame: CGRect
        public init(
            windowID: UInt32,
            ownerName: String,
            bundleID: String,
            isOnScreen: Bool,
            title: String,
            frame: CGRect,
        ) {
            self.windowID = windowID
            self.ownerName = ownerName
            self.bundleID = bundleID
            self.isOnScreen = isOnScreen
            self.title = title
            self.frame = frame
        }
    }

    /// A classified system dialog (shape mirrors the wire ``SystemDialogSummary``).
    public struct Dialog: Equatable, Sendable {
        public var windowID: UInt32
        public var owner: String
        public var title: String
        public var width: Int
        public var height: Int
        /// `true` ⇒ Secure Event Input class (password/auth) — view + click only, keystrokes OS-dropped.
        public var isSecure: Bool
        public init(windowID: UInt32, owner: String, title: String, width: Int, height: Int, isSecure: Bool) {
            self.windowID = windowID
            self.owner = owner
            self.title = title
            self.width = width
            self.height = height
            self.isSecure = isSecure
        }
    }

    /// Secure auth processes — raise Secure Event Input (view + click, no typing). Matched by bundle id
    /// OR owner name (the name is the resilient signal across macOS builds; SCWindow gives both).
    static let secureBundleIDs: Set<String> = ["com.apple.SecurityAgent", "com.apple.coreauthd"]
    static let secureOwnerNames: Set<String> = ["SecurityAgent", "coreauthd"]

    /// Non-secure system-prompt sources (view + FULL interaction). Empty in v1 — the expansion point for
    /// e.g. standalone system alerts. (App-owned save/open panels are deliberately NOT here: DIALOG-EXPAND
    /// already folds them into the streamed pane; surfacing them again would double up.)
    static let systemBundleIDs: Set<String> = []
    static let systemOwnerNames: Set<String> = []

    /// Reject sub-`minSize` windows (offscreen helpers, 1×1 indicators) — a real prompt is well above this.
    public static let minSize = 60

    /// Classify one window, or `nil` if it is not a surfaced system dialog. Pure.
    public static func classify(_ w: WindowSnapshot, minSize: Int = minSize) -> Dialog? {
        let width = Int(w.frame.width.rounded()), height = Int(w.frame.height.rounded())
        guard w.isOnScreen, width >= minSize, height >= minSize else { return nil }
        let isSecure = secureBundleIDs.contains(w.bundleID) || secureOwnerNames.contains(w.ownerName)
        let isSystem = isSecure || systemBundleIDs.contains(w.bundleID) || systemOwnerNames.contains(w.ownerName)
        guard isSystem else { return nil }
        let label = w.ownerName.isEmpty ? w.bundleID : w.ownerName
        return Dialog(
            windowID: w.windowID,
            owner: label,
            title: w.title,
            width: width,
            height: height,
            isSecure: isSecure,
        )
    }

    /// Classify a whole snapshot into the system dialogs to surface (order preserved).
    public static func detect(_ windows: [WindowSnapshot], minSize: Int = minSize) -> [Dialog] {
        windows.compactMap { classify($0, minSize: minSize) }
    }
}
#endif
