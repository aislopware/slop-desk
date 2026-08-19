// CodeSidebarKeyboardState — the app-wide observable answer to "does the embedded VS Code own the
// keyboard right now?". Set from the macOS webview's responder overrides (a direct click claims the
// keyboard, anything that takes it back resigns it — see `CodeSidebarWKWebView`) and re-derived on
// key-window changes by `CodeSidebarWebViewPool`; read by the pane tree so the workspace-focused
// terminal renders UNFOCUSED (hollow cursor, no focus chrome) while the user is typing in the
// panel — before this, the terminal kept its solid focused cursor while every keystroke actually
// went to the editor, and the two surfaces both LOOKED focused (user-reported 2026-08-03).
//
// Cross-platform on purpose (no AppKit import): the split tree that reads it compiles for iOS too,
// where no webview exists and the value just stays `false`.

import Observation

/// App-global keyboard-ownership flag for the embedded workbench. `@MainActor` — written from
/// responder overrides and window notifications, read from SwiftUI bodies; all main-thread.
@preconcurrency
@MainActor
@Observable
public final class CodeSidebarKeyboardState {
    public static let shared = CodeSidebarKeyboardState()

    /// `true` while a pooled code-panel webview is the key window's first responder.
    public private(set) var ownsKeyboard = false

    /// Deduped write — an unchanged value must not invalidate observers (the pane tree re-renders
    /// on every change).
    package func set(_ owns: Bool) {
        guard ownsKeyboard != owns else { return }
        ownsKeyboard = owns
    }

    /// Whether a pane that the WORKSPACE considers focused should still RENDER focused: not while
    /// the embedded workbench owns the keyboard — two surfaces must never both show a live cursor.
    /// Pure — pinned by `CodeSidebarKeyboardStateTests`.
    public static func paneRendersFocused(workspaceFocused: Bool, sidebarOwnsKeyboard: Bool) -> Bool {
        workspaceFocused && !sidebarOwnsKeyboard
    }
}
