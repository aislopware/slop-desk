import Foundation

// MARK: - DesktopWindowPresentation (`desktop-window` policy)

/// How the dedicated remote-desktop window presents when it opens — the Parsec-style default
/// (docs/DECISIONS.md 2026-07-22: the desktop stream is always its OWN OS window, never a pane).
///
/// - ``window``: the default. A regular titled window (cascade-placed, user-resizable); the stream
///   letterboxes inside it.
/// - ``fullscreen``: enter NATIVE macOS fullscreen (its own Space) immediately after the window
///   opens. Exiting fullscreen leaves the same regular window on screen.
///
/// `String`-raw (the case names ARE the config tokens) + `CaseIterable` so it bridges to `Defaults`
/// (see `SettingsKey`) and the Settings picker can enumerate it. A stale / invalid persisted raw
/// value repairs to ``window`` via the `Defaults.PreferRawRepresentable` bridge.
public enum DesktopWindowPresentation: String, Codable, Sendable, CaseIterable {
    case window
    case fullscreen
}
