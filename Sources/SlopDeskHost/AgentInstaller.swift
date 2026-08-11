import Foundation
import SlopDeskInspector

/// `slopdesk integration install claude` (docs/41 §4.2 signal 2, docs/42). The
/// OPT-IN hooks enricher (Decision #5: detection works WITHOUT this via the foreground watcher;
/// the installer is SECOND). It writes a small hook script + MERGES a Claude Code hooks config
/// into the user's `~/.claude/settings.json` so every SessionStart / Stop / Notification /
/// SessionEnd / … POSTs the hook stdin JSON to the host's ``AgentHookListener`` socket.
///
/// **Pure merge / thin file shim split (testability).** The MERGE + UNMERGE + script-text
/// generation are PURE functions on `JSONValue` / `String` (``AgentInstaller`` static methods),
/// unit-tested in `AgentInstallerTests`:
/// - **idempotent** — re-running ``merge(into:command:)`` does not duplicate our hook entries;
/// - **preserves** — existing unrelated settings AND existing unrelated hooks are untouched;
/// - **removable** — ``remove(from:)`` strips exactly our entries, leaving the rest intact.
///
/// The actual disk read/write is the thin ``install(settingsPath:scriptPath:socketPath:)`` /
/// ``uninstall(settingsPath:)`` shim around the pure core (a `Data` read + atomic write).
///
/// **Hook config shape** (Claude Code `settings.json`, docs/41 §2.6): `hooks` is a map of
/// `EventName → [ { matcher?, hooks: [ { type: "command", command } ] } ]`. We tag OUR command
/// blocks with a sentinel marker (``hookMarker``) so the merge can find + de-dupe + remove only
/// the entries we own, never the user's.
public enum AgentInstaller {
    /// A sentinel substring embedded in every command we install, so the pure merge can
    /// identify OUR hook command blocks (for idempotency + removal) without touching the
    /// user's own hooks for the same event.
    public static let hookMarker = "slopdesk-agent"

    /// The Claude Code hook events we install (docs/41 §2.6). Each drives a ``ClaudeStatus``
    /// transition through the status machine: SessionStart→idle, UserPromptSubmit/PreToolUse/
    /// PostToolUse→working (PreToolUse of `AskUserQuestion`→blocked), PermissionRequest/
    /// Notification→blocked, Stop/StopFailure→done, SessionEnd→none, PreCompact→(no status; it arms
    /// the compaction marker so the `Stop` ending a `/compact` lands on idle rather than announcing
    /// a finished task). Deliberately NOT installed: SubagentStart/SubagentStop (a subagent
    /// completing after the main turn stopped must never revive an idle pane — the herdr bug class).
    ///
    /// PreCompact was in that same excluded list until 2026-08-10, on the reading that it has "no
    /// status meaning". It has no status of its OWN — that much was right — but it is the only
    /// signal that distinguishes the two things a `Stop` can mean, and without it finishing a
    /// `/compact` fired the full done treatment (banner, Submarine, unread badge) for housekeeping
    /// the user had just run and watched (user-reported).
    public static let installedEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        // A tool that FAILS or is interrupted emits this INSTEAD of `PostToolUse`, with the same
        // `tool_use_id` — the only thing that can resolve that call's block-ledger entry.
        "PostToolUseFailure",
        "PermissionRequest",
        // …and its "no" answer. The next `PreToolUse` would clear the block too (a permission
        // dialog is modal), but that is an inference standing in for an announcement.
        "PermissionDenied",
        // MCP structured input: the same block a permission dialog is, with its own id namespace.
        // Otherwise caught only by text-classifying a `Notification` as `elicitation_dialog`.
        "Elicitation",
        "ElicitationResult",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionEnd",
        "PreCompact",
    ]

    // MARK: - Pure merge / unmerge (JSONValue → JSONValue)

    /// Merges our hook entries (one per ``installedEvents`` event, each running `command`) into
    /// a decoded `settings.json` root, returning the new root. PURE + idempotent:
    /// - a non-object root is replaced by a fresh `{ "hooks": { … } }` (validate-then-repair —
    ///   a corrupt settings file never traps);
    /// - existing unrelated top-level keys are preserved;
    /// - existing unrelated hook entries for the same event are preserved (we APPEND our block);
    /// - re-running first REMOVES our prior entries (marker match) then re-appends, so the
    ///   result is identical no matter how many times it runs (no duplication).
    public static func merge(into root: JSONValue, command: String) -> JSONValue {
        // Start from a clean slate of OUR entries: strip any we previously installed so a
        // re-run cannot duplicate (idempotency), then append the current command.
        let stripped = remove(from: root)
        guard case let .object(obj) = stripped else {
            // Corrupt / non-object settings → build a minimal valid root carrying only hooks.
            return .object(["hooks": freshHooks(command: command)])
        }

        var newObj = obj
        let existingHooks: [String: JSONValue] = {
            if case let .object(h)? = obj["hooks"] { return h }
            return [:]
        }()

        var hooks = existingHooks
        for event in installedEvents {
            let ourBlock = commandBlock(command: command)
            if case let .array(entries)? = hooks[event] {
                // Append our block to the user's existing entries for this event.
                hooks[event] = .array(entries + [ourBlock])
            } else {
                hooks[event] = .array([ourBlock])
            }
        }
        newObj["hooks"] = .object(hooks)
        return .object(newObj)
    }

    /// Removes exactly OUR hook entries (matched by ``hookMarker`` in a command block) from a
    /// decoded settings root, returning the new root. PURE: the user's own hooks + all other
    /// settings survive; an event whose only entries were ours is dropped from `hooks`; an
    /// emptied `hooks` map is removed entirely (clean uninstall). A non-object root is returned
    /// unchanged (nothing of ours to strip; validate-then-drop).
    public static func remove(from root: JSONValue) -> JSONValue {
        guard case let .object(obj) = root else { return root }
        guard case let .object(hooks)? = obj["hooks"] else { return root }

        var newHooks: [String: JSONValue] = [:]
        for (event, value) in hooks {
            guard case let .array(entries) = value else {
                newHooks[event] = value // not an array we manage — keep verbatim
                continue
            }
            let kept = entries.filter { !entryIsOurs($0) }
            if !kept.isEmpty {
                newHooks[event] = .array(kept)
            }
            // else: the event had only our entries → drop the now-empty event key.
        }

        var newObj = obj
        if newHooks.isEmpty {
            newObj["hooks"] = nil // emptied → remove the hooks key entirely
        } else {
            newObj["hooks"] = .object(newHooks)
        }
        return .object(newObj)
    }

    /// True when a single hook ENTRY (`{ matcher?, hooks: [ { type, command } ] }`) is one of
    /// ours — i.e. it contains a command block whose command carries the ``hookMarker``.
    static func entryIsOurs(_ entry: JSONValue) -> Bool {
        guard case let .object(e) = entry, case let .array(blocks)? = e["hooks"] else { return false }
        for block in blocks {
            if case let .object(b) = block, let cmd = b["command"]?.stringValue,
               cmd.contains(hookMarker)
            {
                return true
            }
        }
        return false
    }

    /// One hook ENTRY for an event: `{ "hooks": [ { "type": "command", "command": <cmd> } ] }`.
    /// No `matcher` (matches all of the event) — the listener classifies the payload itself.
    static func commandBlock(command: String) -> JSONValue {
        .object([
            "hooks": .array([
                .object([
                    "type": .string("command"),
                    "command": .string(command),
                ]),
            ]),
        ])
    }

    /// A fresh `hooks` object (every installed event → one block) for the corrupt-root path.
    static func freshHooks(command: String) -> JSONValue {
        var hooks: [String: JSONValue] = [:]
        for event in installedEvents {
            hooks[event] = .array([commandBlock(command: command)])
        }
        return .object(hooks)
    }

    // MARK: - Pure text generators (the command + the hook script)

    /// The command string the installed hook entries run: the relay binary, which reads the
    /// hook's stdin JSON and POSTs it to the host listener socket. Carries ``hookMarker`` (the
    /// merge sentinel) by virtue of the installed path. The socket path arrives as an env var,
    /// so one binary serves every pane.
    public static func hookCommand(hookPath: String) -> String {
        // The path contains `slopdesk-agent`, which IS the marker — so an entry built from this
        // command is recognized by `entryIsOurs`. Quoted to tolerate spaces.
        "\"\(hookPath)\""
    }

    /// The basename of the relay binary as it ships beside the host executable.
    public static let binaryName = "slopdesk-hook"

    /// Where the relay binary ships: beside the running host executable. `swift build` drops
    /// hostd in `.build/<config>/` and `make hook` stages the Rust binary next to it, so dev
    /// runs and an installed bundle resolve the same way.
    public static func bundledBinaryPath(
        executableURL: URL? = Bundle.main.executableURL,
    )
        -> String?
    {
        executableURL?.deletingLastPathComponent().appendingPathComponent(binaryName).path
    }

    // MARK: - Thin disk shim (read → pure merge → atomic write)

    /// Installs the hooks: copies the relay binary to `hookPath` (chmod +x) and merges the hook
    /// config into `settingsPath`. Returns the merged settings JSON string (also written to
    /// disk). The read/decode tolerates a missing or corrupt settings file (validate-then-repair:
    /// it starts from an empty root). The pure ``merge(into:command:)`` does the real work.
    ///
    /// The relay is a compiled binary rather than a shell script because Claude Code runs hooks
    /// SYNCHRONOUSLY on `PreToolUse`/`PostToolUse` — twice per tool call, on the agent's critical
    /// path. The `sh` + `cat` + `nc` script it replaces cost ~12.4ms per invocation, of which
    /// ~10ms was forking three processes to move ~60 bytes over a socket whose round-trip is
    /// ~11µs; the binary costs ~3.3ms, nearly all of it the one unavoidable fork/exec.
    ///
    /// ⚠️ The relay stays SYNCHRONOUS on purpose. Backgrounding it would let two deliveries race
    /// and land `Stop` before the `PreToolUse` it follows, and the host's per-pane handler is a
    /// state machine that reads order as meaning. It bounds its write instead (2s), so a wedged
    /// host costs a moment rather than Claude Code's 30s hook timeout.
    ///
    /// Throws if `binarySource` is missing — an install that silently wired settings to a
    /// non-existent command would look installed and relay nothing.
    @discardableResult
    public static func install(
        settingsPath: String,
        hookPath: String,
        binarySource: String?,
        fileManager: FileManager = .default,
    ) throws -> String {
        // 1. Stage the relay binary + make it executable.
        guard let binarySource, fileManager.fileExists(atPath: binarySource) else {
            throw AgentInstallerError.relayBinaryMissing(binarySource)
        }
        let hookURL = URL(fileURLWithPath: hookPath)
        try fileManager.createDirectory(
            at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        // Copy cannot overwrite, and the old binary may be mid-exec from another pane's hook;
        // replacing the item swaps the inode instead of writing through it.
        let staged = hookURL.deletingLastPathComponent()
            .appendingPathComponent("\(binaryName).staging")
        try? fileManager.removeItem(at: staged)
        try fileManager.copyItem(at: URL(fileURLWithPath: binarySource), to: staged)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if fileManager.fileExists(atPath: hookPath) {
            _ = try fileManager.replaceItemAt(hookURL, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: hookURL)
        }

        // 2. Read + decode the existing settings (tolerant), merge, write back.
        let root = readSettings(settingsPath, fileManager: fileManager)
        let merged = merge(into: root, command: hookCommand(hookPath: hookPath))
        return try writeSettings(merged, to: settingsPath, fileManager: fileManager)
    }

    /// Uninstalls the hooks: strips our entries from `settingsPath` (the script file is left in
    /// place — harmless, and a re-install reuses it). Returns the updated settings JSON string.
    @discardableResult
    public static func uninstall(
        settingsPath: String,
        fileManager: FileManager = .default,
    ) throws -> String {
        let root = readSettings(settingsPath, fileManager: fileManager)
        let stripped = remove(from: root)
        return try writeSettings(stripped, to: settingsPath, fileManager: fileManager)
    }

    /// PURE read of the install marker: true iff `settingsPath` carries one of OUR hook entries
    /// (matched by ``hookMarker`` via ``entryIsOurs(_:)``) for EVERY event in ``installedEvents``.
    /// Reads the settings tolerantly (a missing / unreadable / corrupt / hook-less file → empty root
    /// → `false`, never a trap). Backs the host's `agentHookStatus` verb, which returns this as a
    /// 1-byte flag.
    ///
    /// ⚠️ ALL, not ANY. A settings file written by an older build carries the events THAT build
    /// knew; answering "installed" for it leaves the new ones — `PostToolUseFailure`,
    /// `PermissionDenied`, `Elicitation`/`ElicitationResult` — permanently unregistered, and the
    /// Settings row that would offer the fix reads as already done. Under-reporting is the safe
    /// direction: ``merge(into:command:)`` is idempotent, so re-installing over a complete install
    /// is a no-op, while the reverse is a silently degraded pane forever.
    public static func isInstalled(
        settingsPath: String,
        fileManager: FileManager = .default,
    ) -> Bool {
        let root = readSettings(settingsPath, fileManager: fileManager)
        guard case let .object(obj) = root, case let .object(hooks)? = obj["hooks"] else { return false }
        return installedEvents.allSatisfy { event in
            guard case let .array(entries)? = hooks[event] else { return false }
            return entries.contains(where: entryIsOurs)
        }
    }

    /// Reads + decodes `settings.json`, returning an empty object root on a missing / unreadable
    /// / non-JSON file (validate-then-repair — never traps on a corrupt settings file).
    static func readSettings(_ path: String, fileManager: FileManager) -> JSONValue {
        guard let data = fileManager.contents(atPath: path),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .object([:])
        }
        return root
    }

    /// Encodes `root` (sorted keys, pretty) and writes it atomically to `path`, creating the
    /// parent dir. Returns the written JSON string.
    @discardableResult
    static func writeSettings(_ root: JSONValue, to path: String, fileManager: FileManager) throws -> String {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(root)
        try data.write(to: url, options: .atomic)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The Claude config base dir (`$CLAUDE_CONFIG_DIR` if set, else `~/.claude`, docs/41 §2.6),
    /// as a file URL. Pure-Swift `URL` path building (no Cocoa `NSString` path API).
    static func configBaseURL(environment: [String: String], home: String) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            // Tilde-expand a `~`-prefixed override without the Cocoa path API.
            let expanded = dir.hasPrefix("~")
                ? home + dir.dropFirst()
                : dir
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
    }

    /// The default Claude Code settings path (`~/.claude/settings.json`), honoring
    /// `CLAUDE_CONFIG_DIR` (docs/41 §2.6) when set.
    public static func defaultSettingsPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
    )
        -> String
    {
        configBaseURL(environment: environment, home: home)
            .appendingPathComponent("settings.json").path
    }

    /// The default installed-relay path (`~/.claude/hooks/slopdesk-agent`). The basename
    /// carries the ``hookMarker`` so installed entries are recognized for idempotency/removal.
    public static func defaultHookPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
    )
        -> String
    {
        configBaseURL(environment: environment, home: home)
            .appendingPathComponent("hooks/slopdesk-agent").path
    }
}

/// Why an install could not complete. Only the staging step throws — the settings merge is
/// validate-then-repair and never traps.
public enum AgentInstallerError: Error, CustomStringConvertible {
    /// The relay binary was not found beside the host executable (`make hook` not run, or a
    /// bundle built without staging it).
    case relayBinaryMissing(String?)

    public var description: String {
        switch self {
        case let .relayBinaryMissing(path):
            "the agent hook relay binary is missing\(path.map { " at \($0)" } ?? "") — run `make hook`"
        }
    }
}
