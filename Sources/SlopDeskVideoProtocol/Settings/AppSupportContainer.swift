import Foundation

/// The one directory every SlopDesk sidecar lives in — `<Application Support>/SlopDesk` — and the
/// one environment variable that moves it.
///
/// **Why this is not just `FileManager.urls(for: .applicationSupportDirectory …)` at each call
/// site.** `HOME` does not move Application Support. It does not even move `NSHomeDirectory()`:
/// Core Foundation resolves the user's home from the account record unless `CFFIXED_USER_HOME` is
/// set, so a process launched with `HOME=/tmp/scratch` still writes
/// `/Users/<real>/Library/Application Support/SlopDesk/`. Four automation gates isolated their host
/// daemons with `HOME` alone and believed the container went with it; what actually happened is that
/// each run swept the developer's own scrollback journals (the journal sweep keeps
/// the newest 256) and left its own behind.
///
/// `CFFIXED_USER_HOME` does move it, and the CLIENT gates use exactly that. It is the wrong tool for
/// a DAEMON: it relocates `NSHomeDirectory()` for everything downstream — the login shell hostd
/// spawns, the cwd a pane defaults to, the volume `HostVitalsSampler` measures — and pointing
/// `slopdesk-hostd` at one made `check-launch-restore.sh` flake three runs in five. So the daemons
/// get this instead: one variable that moves the CONTAINER and nothing else.
///
/// `SLOPDESK_SCROLLBACK_DIR` / `SLOPDESK_WORKSPACE_STATE_DIR` still name their own file's location
/// and still win where they are set — a unit test that wants only the journals in a temp dir keeps
/// working unchanged. This is the base they fall back to.
public enum SlopDeskAppSupport {
    /// Moves the whole container. Set it and no file below can reach the real one.
    public static let directoryEnvKey = "SLOPDESK_APP_SUPPORT_DIR"

    /// The container, or `nil` when the OS won't vend an Application-Support URL (never on macOS).
    ///
    /// An empty value is treated as unset — the shell idiom `FOO="${BAR}"` with `BAR` unset is the
    /// usual way this variable arrives empty, and silently writing to `/` would be worse than
    /// writing to the real container.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> URL? {
        if let override = environment[directoryEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("SlopDesk", isDirectory: true)
    }
}
