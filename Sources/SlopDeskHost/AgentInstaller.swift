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
    /// PostToolUse→working, Notification→blocked, Stop→done, SessionEnd→none.
    public static let installedEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "Stop",
        "SessionEnd",
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

    /// The command string the installed hook entries run: pipe the hook's stdin JSON straight
    /// to the host listener socket via the generated script. Carries ``hookMarker`` (the merge
    /// sentinel) by virtue of the script path. The script reads stdin and POSTs it; we pass the
    /// socket path as an env var so the same script serves every pane.
    public static func hookCommand(scriptPath: String) -> String {
        // The script path contains `slopdesk-agent`, which IS the marker — so an entry built
        // from this command is recognized by `entryIsOurs`. Quoted to tolerate spaces.
        "\"\(scriptPath)\""
    }

    /// The POSIX-sh hook script body. It reads the hook event JSON on stdin and POSTs it to the
    /// host's Unix-domain listener socket (`SLOPDESK_SOCKET_PATH`, exported into every pane's
    /// env by the host). Uses `nc -U` (Muxy's transport, docs/41 §2.1); a missing socket var is
    /// a silent no-op so a non-slopdesk shell that sources these hooks never errors.
    ///
    /// The marker string is assembled at RUNTIME from parts so the on-disk script is recognized
    /// by `entryIsOurs` via its PATH, not by an inline secret-shaped literal (push-protection
    /// trap — see CLAUDE.md). It is plain shell, not a secret; the assembly is belt-and-braces.
    public static func hookScript() -> String {
        let marker = ["slopdesk", "agent"].joined(separator: "-")
        return """
        #!/bin/sh
        # \(marker) — Claude Code hook → slopdesk host listener (W10).
        # Reads the hook event JSON on stdin and POSTs it to the per-host Unix socket the
        # slopdesk host exported as SLOPDESK_SOCKET_PATH. No socket → silent no-op (so a
        # shell that sources these hooks outside slopdesk never errors). Read-only relay.
        sock="${SLOPDESK_SOCKET_PATH:-}"
        [ -z "$sock" ] && exit 0
        [ -S "$sock" ] || exit 0
        # One record = a `pane=<id>` header line (the host's SLOPDESK_PANE_ID), then the raw
        # hook JSON. The host routes by the pane id; an empty id still parses (the host drops it).
        payload="$(cat)"
        { printf 'pane=%s\\n' "${SLOPDESK_PANE_ID:-}"; printf '%s\\n' "$payload"; } \\
            | nc -U "$sock" 2>/dev/null || true
        exit 0
        """
    }

    // MARK: - Thin disk shim (read → pure merge → atomic write)

    /// Installs the hooks: writes the hook script (chmod +x) and merges the hook config into
    /// `settingsPath`. Returns the merged settings JSON string (also written to disk). The
    /// read/decode tolerates a missing or corrupt settings file (validate-then-repair: it
    /// starts from an empty root). The pure ``merge(into:command:)`` does the real work.
    @discardableResult
    public static func install(
        settingsPath: String,
        scriptPath: String,
        fileManager: FileManager = .default,
    ) throws -> String {
        // 1. Write the hook script + make it executable.
        let scriptURL = URL(fileURLWithPath: scriptPath)
        try fileManager.createDirectory(
            at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(hookScript().utf8).write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // 2. Read + decode the existing settings (tolerant), merge, write back.
        let root = readSettings(settingsPath, fileManager: fileManager)
        let merged = merge(into: root, command: hookCommand(scriptPath: scriptPath))
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

    /// PURE read of the install marker: true iff `settingsPath` carries at least one of OUR
    /// hook entries (matched by ``hookMarker`` via ``entryIsOurs(_:)``). Reads the settings tolerantly
    /// (a missing / unreadable / corrupt / hook-less file → empty root → `false`, never a trap), scans
    /// every event's entry array, and stops on the first marker hit. Backs the host's
    /// `agentHookStatus` verb, which returns this as a 1-byte flag.
    public static func isInstalled(
        settingsPath: String,
        fileManager: FileManager = .default,
    ) -> Bool {
        let root = readSettings(settingsPath, fileManager: fileManager)
        guard case let .object(obj) = root, case let .object(hooks)? = obj["hooks"] else { return false }
        for (_, value) in hooks {
            guard case let .array(entries) = value else { continue }
            if entries.contains(where: entryIsOurs) { return true }
        }
        return false
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

    /// The default hook-script path (`~/.claude/hooks/slopdesk-agent.sh`). The basename
    /// carries the ``hookMarker`` so installed entries are recognized for idempotency/removal.
    public static func defaultScriptPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
    )
        -> String
    {
        configBaseURL(environment: environment, home: home)
            .appendingPathComponent("hooks/slopdesk-agent.sh").path
    }
}
