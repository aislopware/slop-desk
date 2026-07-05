// E20 (config review fix) — the LIVE typed-key bridge the `slopdesk config` CLI drives.
//
// `WorkspaceControlBackend.configGet/Set/Unset/Show` route the documented render/appearance config
// keys (`reference__cli.md`: `theme`, `font-family`, `font-size`, `cursor-style`, …) through THESE
// methods so a `config set` genuinely reflows the terminal / retints the chrome live AND persists (the
// typed model's `didSet`), and `config get`/`config show` reflect the LIVE value — not a dead
// `slopdesk.cli.config.*` UserDefaults namespace nor a process-overlay write the renderer never reads.
//
// `theme` is resolved by the BACKEND (it needs the GUI `ThemeStore` / `ThemeCatalog`); every other render
// key this store owns outright lives here — pure + headless-testable. A key with NO live binding is
// intentionally NOT handled here: the backend returns an honest error for it rather than reporting a
// silent success (the anti-"reports success while doing nothing" rule the team applied to `tab badge`).

import Foundation
import SlopDeskVideoProtocol

public extension PreferencesStore {
    /// The LIVE value of a render/appearance config key, or `nil` when this store does not own the key
    /// (or owns it but it is unset — e.g. `density` before any selection — so the caller falls back to the
    /// catalog default). Reflects the in-memory typed model, so it round-trips a prior ``setRenderConfig(_:forKey:)``.
    func renderConfigValue(forKey key: String) -> String? {
        switch key {
        case "font-family": terminal.fontFamily
        case "font-size": Self.formatPointSize(terminal.fontSize)
        case "cursor-style": terminal.cursorStyle.rawValue
        case "cursor-style-blink": terminal.cursorBlink.rawValue
        case "scrollback-limit": String(terminal.scrollbackLines)
        case SettingsKey.density: appearance.density
        default: nil
        }
    }

    /// Apply a render/appearance config key LIVE, mutating the typed model whose `didSet` reflows the
    /// terminal / retints the chrome AND persists. Returns `false` for a key this store does not own OR a
    /// value that fails to parse (validate-then-drop) — so the caller emits an honest error, never a silent
    /// success.
    @discardableResult
    func setRenderConfig(_ value: String, forKey key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "font-family":
            guard !trimmed.isEmpty else { return false }
            terminal.fontFamily = trimmed
        case "font-size":
            guard let size = Double(trimmed), size.isFinite, size > 0 else { return false }
            terminal.fontSize = size
        case "cursor-style":
            guard let style = TerminalPreferences.CursorStyle(rawValue: trimmed) else { return false }
            terminal.cursorStyle = style
        case "cursor-style-blink":
            guard let blink = TerminalPreferences.CursorBlink(rawValue: trimmed) else { return false }
            terminal.cursorBlink = blink
        case "scrollback-limit":
            guard let lines = Int(trimmed), lines >= 0 else { return false }
            terminal.scrollbackLines = lines
        case SettingsKey.density:
            guard !trimmed.isEmpty else { return false }
            appearance.density = trimmed
        default:
            return false
        }
        return true
    }

    /// Reset a render/appearance config key to its model default (`config unset`). Returns `false`
    /// for a key this store does not own.
    @discardableResult
    func unsetRenderConfig(forKey key: String) -> Bool {
        let modelDefault = TerminalPreferences()
        switch key {
        case "font-family": terminal.fontFamily = modelDefault.fontFamily
        case "font-size": terminal.fontSize = modelDefault.fontSize
        case "cursor-style": terminal.cursorStyle = modelDefault.cursorStyle
        case "cursor-style-blink": terminal.cursorBlink = modelDefault.cursorBlink
        case "scrollback-limit": terminal.scrollbackLines = modelDefault.scrollbackLines
        case SettingsKey.density: appearance.density = nil
        default: return false
        }
        return true
    }

    /// Format a libghostty point size WITHOUT a trailing `.0` for integral sizes (so `config get font-size`
    /// round-trips `config set font-size 14` as `14`, not `14.0`) while preserving a real fraction (`13.5`).
    /// `Int(exactly:)` is the integral test — no float `==` (CLAUDE.md ordered-comparison convention).
    private static func formatPointSize(_ size: Double) -> String {
        if let whole = Int(exactly: size) { return String(whole) }
        return String(size)
    }
}
