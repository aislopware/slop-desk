import ApplicationServices // AXIsProcessTrusted
import CoreGraphics // CGPreflightScreenCaptureAccess
import Foundation

/// One row in the TCC (privacy/permission) checklist (research §C1).
///
/// Each row describes a macOS privacy permission the GUI-video / remote-input host features
/// require, how to (re)check whether it is currently granted, the human note explaining why,
/// and the deep-link that jumps straight to the exact System Settings pane.
struct TCCRow: Identifiable {
    let id: String
    /// Display title, e.g. "Screen Recording".
    let title: String
    /// One-line rationale shown under the title.
    let note: String
    /// Whether macOS warns that the grant only takes effect after a relaunch (Screen Recording).
    let requiresRelaunch: Bool
    /// Re-checked EVERY render (research §C1: "grants go stale" — never cache the result).
    /// `@Sendable` so the row (and the `static let rows` global) is concurrency-safe; the
    /// closures wrap static preflight calls (`CGPreflightScreenCaptureAccess` / `AXIsProcessTrusted`)
    /// which are themselves thread-safe.
    let isGranted: @Sendable () -> Bool
    /// The exact System Settings pane to open via `NSWorkspace.shared.open`.
    let settingsURL: URL
}

/// macOS TCC permission preflight + deep-links for the host's GUI-video / remote-input features.
///
/// Research §C1 (the "make-or-break" deliverable): every remote-desktop product lives or dies
/// on getting **Screen Recording** (for `aislopdesk-videohostd`'s screen capture) and
/// **Accessibility** (for host CGEvent keyboard/mouse injection) granted. Both require an app
/// restart and cannot be auto-granted, so the universal pattern is a checklist with a live
/// status dot per permission and an "Enable…" button that deep-links to the exact pane.
///
/// These are CHECKLIST-ONLY for the MVP — the actual video host (`aislopdesk-videohostd`) is not
/// wired into this app yet. The rows document and route the permissions the later video task
/// will consume.
enum TCC {
    /// Screen Recording grant — re-preflighted on every call (grants go stale; never cache).
    /// `CGPreflightScreenCaptureAccess()` returns the current state WITHOUT prompting; the
    /// prompt/grant flow happens in System Settings (we deep-link there).
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Accessibility (AX) trust — re-checked on every call. `AXIsProcessTrusted()` reads the
    /// current state without prompting; the user toggles it in the deep-linked pane.
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// The checklist rows, in onboarding order (Screen Recording first — it is the
    /// relaunch-gated one and the bigger blocker).
    static let rows: [TCCRow] = [
        TCCRow(
            id: "screen-recording",
            title: "Screen Recording",
            note: "Needed for the GUI-video screen-share feature.",
            requiresRelaunch: true,
            isGranted: screenRecordingGranted,
            settingsURL: URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            )!,
        ),
        TCCRow(
            id: "accessibility",
            title: "Accessibility",
            note: "Needed for remote keyboard & mouse input.",
            requiresRelaunch: false,
            isGranted: accessibilityGranted,
            settingsURL: URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            )!,
        ),
    ]

    /// Whether ANY required permission is currently missing — drives the red menu-bar glyph
    /// (research §C1: "Red menu-bar glyph whenever any required perm is missing"). Re-evaluated
    /// each time it is read.
    static var anyPermissionMissing: Bool {
        rows.contains { !$0.isGranted() }
    }
}
