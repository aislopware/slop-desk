// SettingsConfigFile — where the config file is, and what the two buttons over it do.
//
// docs/56 stage D, increment 49. Settings → Advanced → Config File is gated to `Platform::Mac` by the
// layout table (`~/.config` is a path iOS has none of), so unlike the cross-platform surfaces it has ONE
// renderer and its words stay with it, the way `MacOSIntegrationRows`' and `MacCLIInstallCard`'s do.
//
// What is here is the part a renderer cannot reach and must not re-derive: the resolved PATH, and the two
// actions over it. The path is `SlopDeskCLICore`'s answer — including the `SLOPDESK_CONFIG_FILE` env
// override, which is what makes the displayed path the file the app actually honours rather than the XDG
// default it would have used. `SlopDeskMacUI` does not depend on `SlopDeskCLICore`, so without this face the
// AppKit half would have to re-spell an XDG lookup that already exists, which is the second implementation
// the one-implementation rule refuses.

import Foundation
import SlopDeskCLICore
import SlopDeskWorkspaceCore // PreferencesStore

/// The Advanced → Config File group's two answers.
package enum SettingsConfigFile {
    /// The config file the app actually reads, env override and all.
    package static var resolvedPath: String { CLIConfig.resolvePath(override: nil) }

    /// The file to hand to the reader's editor, CREATED if it is not there yet.
    ///
    /// A fresh install has no `~/.config/slopdesk` directory and no file in it, and "Open Config File" that
    /// opens nothing is a button that looks broken. So the parent directory and an empty file are made
    /// first — a `try?` on each, because a failure here means the editor opens nothing, which is exactly
    /// what would have happened anyway.
    package static func prepared() -> URL {
        let path = resolvedPath
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil,
        )
        if !FileManager.default.fileExists(atPath: path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Re-read the config, exactly as the CLI's `config reload` does.
    ///
    /// The pair is the whole verb — the store re-applies what it holds, and the broadcast is what tells the
    /// live surfaces to pick the result up. Spelled here rather than at the button so this and
    /// `WorkspaceControlBackend.configReload` cannot come to mean two different things.
    @preconcurrency
    @MainActor
    package static func reload(_ store: PreferencesStore) {
        store.reapplyLiveSettings()
        NotificationCenter.default.post(name: WorkspaceControlBackend.configReloadNotification, object: nil)
    }
}
