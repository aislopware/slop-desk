// The macOS "Install SlopDesk CLI" controller.
//
// The "Install the CLI" flow (`spec/getting-started__first-launch.md` §3): symlink the bundled
// `slopdesk` executable to `/usr/local/bin/slopdesk` (a one-shot ADMIN escalation — a system privilege
// via `osascript … with administrator privileges`, NOT app crypto, per CLAUDE.md #8), the **Omit
// Prefix** shell-function injection (the `edit`/`view`/`watch`/`jump`/`learn` bare functions — built
// by the PURE `CLIShellShim` in `SlopDeskWorkspaceCore`), and the **Allow Overwrite** toggle.
//
// ## Hang-safety / compiled-only
// This controller spawns `osascript` (the admin prompt) + touches the filesystem; it is **compiled +
// code-reviewed only**, NEVER instantiated in a unit test (the same rule that excludes `ClientControlServer`
// / the video sessions). The PURE part — the shell-function snippet — lives in `CLIShellShim` and IS pinned
// (`FirstLaunchModelTests`). `#if os(macOS)` throughout: iOS has no `/usr/local/bin` and no `osascript`.

#if os(macOS)
import Darwin
import Defaults
import Foundation
import Observation
import SlopDeskWorkspaceCore // CLIShellShim

/// The `@MainActor @Observable` controller behind the "Install CLI" card (first-launch step 3 +
/// Settings → Shell). It owns the symlink install/uninstall (admin-escalated), the installed-state probe
/// (kept in sync with the `cliInstalled` `Defaults` flag), and the Omit-Prefix shim-file write. The view
/// observes ``phase`` / ``errorMessage`` for the button + status chrome.
@preconcurrency
@MainActor
@Observable
public final class CLIInstaller {
    /// Where the symlink lands. `/usr/local/bin` is a PATH-by-default location on macOS, so the installed
    /// `slopdesk` command works from any shell with no PATH edits.
    public static let symlinkPath = "/usr/local/bin/slopdesk"

    /// The card's transient phase — drives the button label + spinner.
    public enum Phase: Equatable, Sendable {
        /// No write in flight (the resting state).
        case idle
        /// An install / uninstall is running (the admin prompt is up / the symlink is being written).
        case working
        /// The last write failed — ``errorMessage`` carries the reason (a cancelled admin prompt, a denied
        /// privilege, …). NOT fatal; the card shows the message and re-enables the button.
        case failed
    }

    /// The current phase (default ``Phase/idle``).
    public private(set) var phase: Phase = .idle
    /// The last failure reason (cleared on a new attempt). `nil` when there is nothing to report.
    public private(set) var errorMessage: String?

    public init() {}

    /// Whether `/usr/local/bin/slopdesk` is a symlink that points at OUR bundled CLI. Probes the live
    /// filesystem (cheap `lstat` + `readlink`) and refreshes the `cliInstalled` `Defaults` mirror so the card
    /// reflects reality even if the symlink was removed out-of-band. Returns the resolved state.
    @discardableResult
    public func refreshInstalled() -> Bool {
        let installed = Self.isLinkedToBundle()
        if Defaults[.cliInstalled] != installed { Defaults[.cliInstalled] = installed }
        return installed
    }

    /// Install the symlink (admin-escalated). On success sets ``cliInstalled`` and returns `true`; on a
    /// cancelled / denied prompt records ``errorMessage`` + ``Phase/failed`` and returns `false`. Idempotent —
    /// `ln -sf` replaces an existing link.
    @discardableResult
    public func install() async -> Bool {
        guard let source = Self.bundledCLIPath() else {
            fail("Could not locate the bundled slopdesk binary in the app bundle.")
            return false
        }
        phase = .working
        errorMessage = nil
        // `mkdir -p` because /usr/local/bin may not exist on a clean macOS; `ln -sfh` replaces an existing link.
        let escapedSource = Self.singleQuoteForShell(source)
        let escapedTarget = Self.singleQuoteForShell(Self.symlinkPath)
        let shell = "mkdir -p /usr/local/bin && ln -sfh \(escapedSource) \(escapedTarget)"
        guard await Self.runWithAdmin(shell: shell) else {
            fail("Install was cancelled or admin privileges were denied.")
            return false
        }
        Defaults[.cliInstalled] = true
        phase = .idle
        return true
    }

    /// Remove the symlink (admin-escalated). On success clears ``cliInstalled``. Returns whether it succeeded.
    @discardableResult
    public func uninstall() async -> Bool {
        phase = .working
        errorMessage = nil
        let escapedTarget = Self.singleQuoteForShell(Self.symlinkPath)
        // Only remove a SYMLINK (never a real file the user may have placed) — `[ -L … ] && rm`.
        let shell = "[ -L \(escapedTarget) ] && rm -f \(escapedTarget) || true"
        guard await Self.runWithAdmin(shell: shell) else {
            fail("Uninstall was cancelled or admin privileges were denied.")
            return false
        }
        Defaults[.cliInstalled] = false
        phase = .idle
        return true
    }

    /// Persist + actuate the "Omit Prefix" / "Allow Overwrite" toggles: write the `CLIShellShim` snippet
    /// to the app-support shim file when enabled, or remove it when disabled. NO admin needed (a user-dir
    /// write). Sourcing this file into app-launched (remote) shells is the host's responsibility, not this
    /// controller's; the toggle here stays honest regardless — the file appears / disappears with the
    /// toggle, with the correct guarded/unguarded definitions.
    public func applyOmitPrefix(enabled: Bool, allowOverwrite: Bool) {
        let url = Self.shimFileURL()
        if enabled {
            let snippet = CLIShellShim.snippet(allowOverwrite: allowOverwrite)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try? snippet.data(using: .utf8)?.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Failure helper

    private func fail(_ message: String) {
        errorMessage = message
        phase = .failed
    }

    // MARK: - Bundle / path resolution

    /// The bundled `slopdesk` CLI inside the running app bundle. Tries the auxiliary-executable slot
    /// (`Contents/MacOS/slopdesk`) first, then a few conventional sibling locations, returning the first
    /// that exists. `nil` when running unbundled (e.g. `swift run`) — the card then surfaces an honest error.
    static func bundledCLIPath() -> String? {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "slopdesk")?.path,
           FileManager.default.fileExists(atPath: aux)
        {
            return aux
        }
        let root = Bundle.main.bundleURL
        let candidates = [
            root.appendingPathComponent("Contents/MacOS/slopdesk"),
            root.appendingPathComponent("Contents/Helpers/slopdesk"),
            root.appendingPathComponent("Contents/Resources/slopdesk"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        return nil
    }

    /// Whether ``symlinkPath`` is a symlink resolving to OUR bundled CLI (so a stale link to a different
    /// install does not read as "installed"). A best-effort `readlink` compare against ``bundledCLIPath()``.
    static func isLinkedToBundle() -> Bool {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else { return false }
        guard let bundled = bundledCLIPath() else {
            // Unbundled (dev) — treat any existing link as installed so the dev card is not stuck "Install".
            return fm.fileExists(atPath: symlinkPath)
        }
        // Compare resolved paths (the link may be relative / contain `..`). A relative target resolves
        // against the symlink's own directory.
        let resolved: URL = dest.hasPrefix("/")
            ? URL(fileURLWithPath: dest)
            : URL(fileURLWithPath: symlinkPath).deletingLastPathComponent().appendingPathComponent(dest)
        return resolved.standardizedFileURL.path
            == URL(fileURLWithPath: bundled).standardizedFileURL.path
    }

    /// `~/Library/Application Support/SlopDesk/cli-shims.sh` — sibling of the workspace / frecency / control
    /// sockets, the conventional slopdesk app-support home.
    static func shimFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("SlopDesk", isDirectory: true)
            .appendingPathComponent("cli-shims.sh", isDirectory: false)
    }

    // MARK: - Admin escalation (osascript)

    /// Single-quote `value` for embedding in a `/bin/sh -c` command (escapes embedded single quotes via the
    /// `'\''` idiom). The values here are our OWN bundle path / the fixed symlink target (not attacker input),
    /// but quoting defends against spaces / shell metacharacters in the install location.
    static func singleQuoteForShell(_ value: String) -> String {
        ShellQuoting.singleQuote(value)
    }

    /// Escape `value` for an AppleScript double-quoted string literal (backslash + double-quote).
    static func escapeForAppleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run `shell` with administrator privileges via `osascript` (the one-shot system admin prompt). Returns
    /// whether `osascript` exited 0 (a cancelled prompt / denied privilege exits non-zero). Runs OFF the main
    /// actor on a detached thread (the `Process` blocks until the modal prompt resolves) so the UI never
    /// hangs; mirrors the off-cooperative-pool discipline used for the control sockets.
    static func runWithAdmin(shell: String) async -> Bool {
        let appleScript = "do shell script \"\(escapeForAppleScriptLiteral(shell))\" "
            + "with administrator privileges"
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Detached (not the cooperative pool): the Process waits on a modal admin dialog.
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                // Discard output; we only care about the exit status.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
#endif
