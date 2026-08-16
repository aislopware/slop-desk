import Foundation
import SlopDeskProtocol
import SlopDeskSupervisor

/// hostd's side of `slopdesk-codeseed` — the program that owns the code panel's workbench PROFILE.
///
/// ## What moved, and what did not
/// Everything this type asks about is a decision ABOUT FILES: what a pristine settings file should
/// say, whether the one on disk is still a seed we wrote, which extension folders an older hostd
/// left behind, what argv and environment the child needs. None of it wants a process handle, and
/// all of it was ~2.7k lines of Swift string and `JSONSerialization` work that a language with sum
/// types and one JSON vocabulary says in a third of the space (`docs/DECISIONS.md`, stage 22).
///
/// ``CodeServerManager`` kept the SUPERVISION — the handle, the readiness probe, the learned port,
/// the prewarm, the lock. Those are bookkeeping only the process holding the child can do.
///
/// ## Why forking is affordable here
/// Every question below is asked at most ONCE per hostd lifetime except the font sync, which rides
/// a verb a client sends on connect and on a preference change. `ensure`, the ~1 Hz poll, asks
/// nothing: its answers are already cached in the `static let`s. A fork per boot is not a budget.
///
/// ## The refusal
/// A host with no `slopdesk-codeseed` reports the code panel **unavailable** rather than launching
/// a workbench with guessed arguments. `--auth none` on a guessed port is not a degraded panel, it
/// is a different program; ``launchArguments()`` answering `nil` is what stops it.
enum CodeSeed {
    /// Names the `slopdesk-codeseed` to run. The E2E harness points it at its own build.
    static let binaryEnvKey = "SLOPDESK_CODESEED_BIN"

    /// The binary, or `nil` on a machine that has none (→ the panel reports unavailable).
    static func locate() -> String? {
        RustServicePaths.locate(
            "slopdesk-codeseed", crate: "slopdesk-codeseed", overrideVariable: binaryEnvKey,
        )
    }

    // MARK: - The six questions

    /// Seeds and repairs the whole profile — settings, both extensions, the retired sweep.
    ///
    /// Fire-and-forget by contract: a seed is a nicety, and a host that cannot run this comes up
    /// with an unthemed workbench rather than none. Returns whether anything changed, which is
    /// worth nothing to the caller and everything to a test.
    @discardableResult
    static func seed() -> Bool {
        ask(["seed"])?["changed"] as? Bool ?? false
    }

    /// The child's argv. `nil` ⇒ no binary, and the caller must not spawn.
    static let launchArguments: [String]? = ask(["launch-args"])?["arguments"] as? [String]

    /// The environment a code-server child launches with: this process's, plus the delta the seeder
    /// decides (the marketplace gallery unless the operator exported their own, and the bridge
    /// socket the seeded extension dials back on).
    ///
    /// A missing binary leaves the parent environment unchanged — the honest degradation, and one
    /// only the CLI paths can reach, since the spawn already refused above.
    static let childEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        for pair in ask(["child-env"])?["environment"] as? [[String]] ?? [] {
            guard pair.count == 2, let key = pair.first, let value = pair.last else { continue }
            environment[key] = value
        }
        return environment
    }()

    /// The bundled marketplace extensions absent from the profile registry — what the one-shot
    /// `--install-extension` pass before the first spawn has to fetch. Empty on a missing binary:
    /// with no seeder there is nothing to install FOR.
    static func missingBundledExtensions() -> [String] {
        ask(["missing-extensions"])?["missing"] as? [String] ?? []
    }

    /// Folds a client's font spec into the live settings file. `false` when nothing changed.
    @discardableResult
    static func syncEditorFont(_ spec: MetadataCodec.CodeFontSpec) -> Bool {
        let answer = ask([
            "sync-font",
            "--family", spec.family,
            "--size", String(spec.size),
            "--line-height", String(spec.lineHeight),
        ])
        return answer?["changed"] as? Bool ?? false
    }

    /// The four paths the profile lives at, resolved the way the CHILD resolves them.
    struct Paths: Sendable {
        var dataDir: String
        var userSettings: String
        var extensionsDir: String
        /// Where ``CodeBridgeServer`` listens — pid-free, so a workbench that outlived a hostd
        /// reconnects to the same name (`docs/51` §1).
        var bridgeSocket: String
    }

    /// The profile's paths, asked once. `nil` on a missing binary; the only caller that needs one
    /// runs after the spawn has already been refused.
    static let paths: Paths? = {
        guard let answer = ask(["paths"]),
              let dataDir = answer["dataDir"] as? String,
              let userSettings = answer["userSettings"] as? String,
              let extensionsDir = answer["extensionsDir"] as? String,
              let bridgeSocket = answer["bridgeSocket"] as? String
        else { return nil }
        return Paths(
            dataDir: dataDir, userSettings: userSettings, extensionsDir: extensionsDir,
            bridgeSocket: bridgeSocket,
        )
    }()

    // MARK: - The fork

    /// Runs one subcommand to completion and decodes the single JSON object it prints.
    ///
    /// `nil` for every failure — no binary, a non-zero exit, output that is not one JSON object.
    /// The distinction between those is not one any caller acts on differently: each of the six
    /// questions already has a defined answer for "the seeder could not say", and it is never an
    /// error the operator is asked to resolve.
    ///
    /// Synchronous on purpose. Five of the six callers hold ``CodeServerManager``'s lock, and the
    /// work is a fork of a ~1 MiB static binary that reads a handful of files.
    static func ask(_ arguments: [String]) -> [String: Any]? {
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
        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
