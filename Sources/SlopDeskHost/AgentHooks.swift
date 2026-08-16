import Foundation
import SlopDeskSupervisor

/// hostd's side of `slopdesk-agenthooks` — the program that owns Claude Code's hooks config.
///
/// ## What moved
/// The install was a `settings.json` merge: read a file the user also edits by hand, strip the
/// entries carrying our marker, append one per event, write it back sorted and pretty. Every line of
/// that is a decision about JSON and a file, and the marker it turns on is the BASENAME of the relay
/// binary — which is built by the crate that now performs the merge. Keeping the two apart meant one
/// name spelled in two languages, and getting it wrong is silent: a marker that no longer matches
/// the installed command turns uninstall into a no-op and install into a duplicator, with no error
/// anywhere (`docs/DECISIONS.md`, stage 23).
///
/// ## Why forking is affordable here
/// All three questions ride a person: `install`/`uninstall` are a Settings row someone clicked or a
/// `slopdesk-hostd integration …` someone typed, and `status` is the reply to a verb a client sends
/// on connect and when that row is shown. None is on a poll, and none is on the agent's path — the
/// RELAY is, and it is a different binary that this one only copies.
///
/// ## The refusal
/// A host with no `slopdesk-agenthooks` reports the hooks NOT installed and fails install/uninstall
/// rather than merging a settings file itself. Half an installer here — one that wrote entries
/// pointing at a relay it could not stage — is the one outcome worse than no installer: it looks
/// installed and relays nothing.
public enum AgentHooks {
    /// Names the `slopdesk-agenthooks` to run. The E2E harness points it at its own build.
    public static let binaryEnvKey = "SLOPDESK_AGENTHOOKS_BIN"

    /// The installer's basename as it ships beside the host executable.
    public static let binaryName = "slopdesk-agenthooks"

    /// Where the installer ships: beside the running host executable. `swift build` drops hostd in
    /// `.build/<config>/` and `make build` stages both Rust binaries next to it, so a dev run and an
    /// installed bundle resolve the same way — and, because the installer copies the relay from its
    /// OWN directory, resolving one here resolves both.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
    ) -> String? {
        RustServicePaths.locateBeside(
            binaryName, overrideVariable: binaryEnvKey,
            environment: environment, executableURL: executableURL,
        )
    }

    // MARK: - The three questions

    /// What an install or uninstall touched — the paths the CLI path prints back to whoever typed
    /// the command. `error` is non-`nil` exactly when the subcommand failed.
    public struct Answer: Sendable {
        public var settings: String
        public var hook: String?
        public var error: String?
    }

    /// Stages the relay and merges our entries into the user's `settings.json`.
    public static func install() -> Answer? { answer(["install"]) }

    /// Strips exactly our entries. The staged relay is left where it is — a re-install reuses it.
    public static func uninstall() -> Answer? { answer(["uninstall"]) }

    /// Whether EVERY event we install is currently registered.
    ///
    /// `false` for a missing binary, an unreadable settings file, and — deliberately — a file an
    /// older build wrote that is missing an event this one installs. Under-reporting is the safe
    /// direction: the merge is idempotent, so re-installing over a complete install costs nothing,
    /// while over-reporting leaves a pane silently degraded forever.
    public static func isInstalled() -> Bool {
        ask(["status"])?["installed"] as? Bool ?? false
    }

    // MARK: - The fork

    /// Runs one subcommand and folds its object into an ``Answer``. `nil` only when there was no
    /// answer at all (no binary, or output that is not one JSON object).
    private static func answer(_ arguments: [String]) -> Answer? {
        guard let object = ask(arguments) else { return nil }
        return Answer(
            settings: object["settings"] as? String ?? "",
            hook: object["hook"] as? String,
            error: object["error"] as? String,
        )
    }

    /// Runs one subcommand to completion and decodes the single JSON object it prints.
    ///
    /// The object is returned for a FAILING exit too — the installer reports what went wrong in it,
    /// and that message is the only thing a person who typed the command can act on. `nil` is
    /// reserved for the cases where nothing was said: no binary, or output that is not one object.
    ///
    /// Synchronous on purpose: each caller is already answering someone who is waiting.
    public static func ask(_ arguments: [String]) -> [String: Any]? {
        guard let binary = locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read BEFORE waiting: a subcommand whose answer outgrows the pipe buffer would otherwise
        // block on the write while this side blocks on the exit.
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
