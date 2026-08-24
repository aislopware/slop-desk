// ConfigFile — where `config.toml` is, what ⌘, opens, and what a reload re-applies.
//
// There is no settings window, so ⌘, does the one thing left to do with a setting: it opens the
// file that decides. What is here is the part a renderer cannot reach and must not re-derive — the
// resolved PATH (including the `SLOPDESK_CONFIG_FILE` override, which is what makes the opened file
// the one the app actually honours), the first-write that makes the path openable, and the reload.

#if os(macOS)
import AppKit // NSWorkspace.open — ⌘, hands the file to the reader's own editor
#endif
import Foundation
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore // PreferencesStore.reapplyLiveSettings

/// The config file, as the app reaches it.
public enum ConfigFile {
    /// The config file the app actually reads, environment override and all.
    public static var resolvedPath: String { AppConfig.resolvedPath() }

    /// The file to hand to the reader's editor, CREATED if it is not there yet — along with the
    /// JSON Schema beside it and the `#:schema` line that points at it.
    ///
    /// A fresh install has no `~/.config/slopdesk` and no file in it, and ⌘, that opens nothing is a
    /// shortcut that looks broken. So the directory and a starter file are made first.
    ///
    /// The starter file is a COMMENT and a schema pointer, never a dump of the defaults. A file
    /// pre-filled with every key at its default value is a file that pins today's answers forever:
    /// the next release improves a default and nobody gets it, because their file already says the
    /// old number. Every key is absent on purpose, and absent means "whatever this build thinks is
    /// best".
    ///
    /// `try?` on each step, because a failure means the editor opens nothing — which is exactly what
    /// would have happened anyway.
    public static func prepared() -> URL {
        let path = resolvedPath
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: nil,
        )
        try? AppConfig.jsonSchema().write(
            to: directory.appendingPathComponent("config.schema.json", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        if !FileManager.default.fileExists(atPath: path) {
            try? starter.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// What a brand-new `config.toml` says: how to find the schema, and that saying nothing is fine.
    private static let starter = """
    #:schema ./config.schema.json

    # slopdesk configuration.
    #
    # Everything has a best-by-default answer already applied — this file exists to disagree with
    # one. An empty file is a complete file; a key is only written here to change it.
    #
    # `slopdesk config show` prints every setting as resolved, `slopdesk config schema` prints the
    # schema this points at, and an editor with JSON-Schema support completes the key, shows what it
    # does and underlines a value outside its range.

    """

    #if os(macOS)
    /// Opens the config file in whatever the reader edits text with — what ⌘, does now.
    ///
    /// The whole of "Settings" on this platform. `NSWorkspace.open` hands the file to the user's own
    /// editor rather than to one this app wrote, which is the same trade as the file itself: the
    /// editor already has the reader's keybindings, their theme and, if it speaks JSON Schema, the
    /// completion and the range checks the schema beside the file describes.
    public static func openInEditor() {
        NSWorkspace.shared.open(prepared())
    }
    #endif

    /// Re-read the file and re-apply it if it moved. Answers whether anything changed.
    ///
    /// This is what makes "the app re-reads the file on its own" true: it runs on every activation,
    /// which is the moment a reader who just saved the file in their editor comes back to look. No
    /// watcher, no `config reload` verb, no notification — the app is already being handed the one
    /// event that matters.
    ///
    /// The equality check is not an optimisation, it is the feature. ``PreferencesStore`` bumps the
    /// terminal-config generation unconditionally, so re-applying an IDENTICAL reading still rebuilds
    /// every live terminal's config and re-measures its grid — a visible flash on every ⌘Tab back.
    /// ``AppConfig`` is `Equatable`; an unchanged file does nothing at all.
    ///
    /// The ``ConfigRevision`` bump is the OTHER half of re-applying, and it sits behind the same
    /// guard: ``PreferencesStore`` pushes the settings that are pushed (the terminal config, the
    /// keybindings), while the handful a view must re-read live — the secure-input pair, the
    /// satellite pointer grant, the auto-hide mode — re-read themselves off this edge.
    @preconcurrency
    @MainActor
    @discardableResult
    public static func reload(_ store: PreferencesStore) -> Bool {
        let before = AppConfig.current
        guard AppConfig.reload() != before else { return false }
        store.reapplyLiveSettings()
        ConfigRevision.shared.bump()
        return true
    }
}
