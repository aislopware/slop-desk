import Foundation
import SlopDeskProtocol
import SlopDeskSupervisor

/// hostd's side of `slopdesk-probe` — the program that answers the metadata RPC's git, directory and
/// session questions.
///
/// ## What moved, and what did not
/// Four of ``MetadataQuerying``'s ten methods are subprocess and filesystem work with no handle
/// behind them: `gitDiff`, `listDirectory`, `listAgentSessions`, `readAgentSession`. Every one of
/// them was untestable in Swift for the reason the whole file carries — the hang-safety rule keeps a
/// real `Process` out of a unit test, so the slug convention and the diff-base ladder were
/// compiled-and-reviewed only. In Rust they are ordinary functions over strings with the process
/// boundary at the edge, and they are covered (`docs/DECISIONS.md`, stage 24). ``TerminfoResolver``'s
/// host probe joined them for the same reason (stage 25).
///
/// `gitStatus` was the fifth and has left entirely: ``HostGitStatus`` answers it IN PROCESS through
/// `slopdesk-git`, so the verb the repo watcher polls on a cadence costs no spawn at all.
///
/// ``HostMetadataProbe`` kept the five that need something a fork does not have: `paneWorkingDirectory`,
/// `processes` and `ports` are anchored to the pane's PTY master fd (`tcgetpgrp`, `ptsname`) and to
/// `proc_pidinfo` over every live pid; `hostVitals` reads a CPU baseline that has to outlive the
/// request; `hostName` is one `ProcessInfo` field and not worth a spawn.
///
/// ## Why forking is affordable here
/// Every verb left here rides a PERSON: a folder someone expanded, a diff someone opened, a session
/// list someone asked for. A fork per click is affordable in a way a fork per filesystem event is
/// not, which is the line `gitStatus` crossed when the project-scoped ``RepoStatusWatcher`` began
/// polling it on a cadence — and why that one is linked rather than forked.
///
/// ## The degradation
/// A host with no `slopdesk-probe` answers `nil` — the verb's `.notFound` — for every question here.
/// That is the same answer each verb already had for a path that does not resolve, so a missing
/// binary costs the file tree and the diff, and nothing else notices.
enum HostProbe {
    /// Names the `slopdesk-probe` to run. The E2E harness points it at its own build.
    static let binaryEnvKey = "SLOPDESK_PROBE_BIN"

    /// The probe's basename as it ships beside the host executable.
    static let binaryName = "slopdesk-probe"

    /// Where the probe ships: beside the running host executable. It is a ROOT-workspace binary, so
    /// its cargo target directory is `rust/target/` rather than the per-crate one
    /// ``RustServicePaths/locate(_:crate:overrideVariable:environment:fileManager:executable:)``
    /// walks for — `make build` stages it next to hostd, exactly like the hook relay's installer.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
    ) -> String? {
        RustServicePaths.locateBeside(
            binaryName, overrideVariable: binaryEnvKey,
            environment: environment, executableURL: executableURL,
        )
    }

    // MARK: - The five questions

    /// The unified diff of a repo-root-relative `file`. Empty `Data` is a real answer (an unchanged
    /// file); `nil` is the verb's `.notFound`.
    static func gitDiff(cwd: String, file: String) -> Data? {
        askBytes(["git-diff", "--cwd", cwd, "--file", file])
    }

    /// One level of `absolutePath`, sorted. `nil` when it is not a directory.
    static func listDirectory(absolutePath: String) -> [MetadataCodec.DirEntry]? {
        guard let answer = ask(["list-dir", "--path", absolutePath]),
              let entries = answer["entries"] as? [[String: Any]]
        else { return nil }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return MetadataCodec.DirEntry(isDir: entry["isDir"] as? Bool ?? false, name: name)
        }
    }

    /// The agent sessions discoverable for `project`, newest first. Empty is valid.
    static func listAgentSessions(project: String) -> [MetadataCodec.AgentSessionInfo] {
        guard let answer = ask(["list-sessions", "--project", project]),
              let sessions = answer["sessions"] as? [[String: Any]]
        else { return [] }
        return sessions.compactMap { session in
            guard let id = session["id"] as? String, let kind = session["kind"] as? Int else { return nil }
            return MetadataCodec.AgentSessionInfo(
                agentKindByte: UInt8(truncatingIfNeeded: kind),
                id: id,
                title: session["title"] as? String ?? "",
                cwd: session["cwd"] as? String ?? project,
                mtimeMS: (session["mtimeMS"] as? Int).map(Int64.init) ?? 0,
            )
        }
    }

    /// The raw transcript bytes for an absolute session `id`, confined to the known session roots by
    /// the probe itself — a second check under the builder's own.
    static func readAgentSession(id: String) -> Data? {
        askBytes(["read-session", "--id", id])
    }

    /// What a `TERM` resolution came back with: the entry to advertise, and whether getting there
    /// meant falling back.
    struct Terminfo: Sendable {
        var term: String
        var fellBack: Bool
    }

    /// Resolves `requested` against this host's terminfo database, answering `fallback` when the
    /// host cannot honour it. `nil` on a missing binary — the caller decides what a host that cannot
    /// be asked should advertise.
    static func terminfo(requested: String, fallback: String) -> Terminfo? {
        guard let answer = ask(["terminfo", "--requested", requested, "--fallback", fallback]),
              let term = answer["term"] as? String
        else { return nil }
        return Terminfo(term: term, fellBack: answer["fellBack"] as? Bool ?? false)
    }

    // MARK: - The fork

    /// Runs one subcommand and decodes the single JSON object it prints. `nil` for every failure —
    /// no binary, a non-zero exit, output that is not one object. Each caller above already has a
    /// defined answer for "the probe could not say".
    private static func ask(_ arguments: [String]) -> [String: Any]? {
        guard let (data, status) = run(arguments), status == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Runs one subcommand whose answer is opaque BYTES.
    ///
    /// An exit of 0 is an answer EVEN WHEN IT IS EMPTY — an unchanged file has an empty diff, and
    /// folding that to `nil` would report `.notFound` for a file that is right there. A missing
    /// subject is the probe's own exit code, which is why it has one; `check-supervisor.sh` §16 pins
    /// this method against the tidy-up that collapses the two.
    private static func askBytes(_ arguments: [String]) -> Data? {
        guard let (data, status) = run(arguments), status == 0 else { return nil }
        return data
    }

    /// Runs the probe to completion, returning its stdout and exit status.
    ///
    /// Synchronous on purpose: every caller is already answering a client that is waiting on this
    /// request id. Read BEFORE waiting — a 15 MiB diff would otherwise block the child on its write
    /// while this side blocks on its exit.
    private static func run(_ arguments: [String]) -> (Data, Int32)? {
        guard let binary = locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }
}
