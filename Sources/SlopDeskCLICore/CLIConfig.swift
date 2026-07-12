import Foundation

// `slopdesk config path | edit | validate` — the LOCAL (no-socket) config-file ops. These operate
// on the optional user config FILE (XDG-style: `~/.config/slopdesk/`), which
// is the persisted source a launch-time bridge reads. The RUNNING-app config ops
// (`get`/`set`/`unset`/`show`/`reload`, incl. `--transient`) go over the control socket instead;
// only `path`/`edit`/`validate` are pure file ops, so the path resolution + the validator live here,
// PURE and unit-tested (the `edit` $EDITOR spawn lives in the compiled-only `main.swift`).
//
// **The split is deliberate and documented: not every `config` subcommand acts on the
// SAME file.** slopdesk's launch-time bridge (`KeybindConfigLoader`) reads ONLY the
// `keybind = <chord>:<action>` lines of `config.toml`; every other key (font-size, theme, …) is
// silently ignored there and instead lives in the running app's `PreferencesStore`, reached by
// `get`/`set`/`unset`/`show`/`reload` over the socket. So `path`/`edit`/`validate` target the KEYBIND
// config file, and `validate` checks the file against the REAL grammar the app honours: a line that
// isn't a parseable `keybind` directive (e.g. `font-size = 14`) is flagged — never silently called
// "valid" — because the app would ignore it. (The `config` help spells this split out explicitly.)

public enum CLIConfig {
    /// Env override for the config-file location (the `--config-file` flag takes precedence over this).
    public static let configFileEnvKey = "SLOPDESK_CONFIG_FILE"

    /// Resolve the config-file path: explicit `--config-file` > ``configFileEnvKey`` env > the XDG
    /// default. Pure (env injected) so the resolution order is unit-testable.
    public static func resolvePath(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override, !override.isEmpty { return override }
        if let env = environment[configFileEnvKey], !env.isEmpty { return env }
        return defaultPath(environment: environment)
    }

    /// `$XDG_CONFIG_HOME/slopdesk/config.toml`, else `~/.config/slopdesk/config.toml` (XDG Base Directory convention).
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return xdg + "/slopdesk/config.toml"
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return home + "/.config/slopdesk/config.toml"
    }

    /// One config-file syntax problem (1-based line number + reason).
    public struct ValidationError: Equatable, Sendable {
        public let line: Int
        public let message: String

        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }
    }

    /// Validate the file against the ACTUAL keybind-file grammar the launch bridge honours.
    ///
    /// The app's `KeybindConfigLoader` reads ONLY `keybind = <chord>:<action>` lines from `config.toml`
    /// and silently ignores every other key, so a generic `key = value` check would falsely call a file
    /// full of ignored keys (`font-size = 14`) "valid". This validates the truth instead: blank lines,
    /// `#` comments, and `[section]` headers are skipped; every OTHER line must be a `keybind = <value>`
    /// assignment whose `<value>` parses as a binding directive. A non-`keybind` key, a missing `=`, an
    /// empty value, or a malformed `<chord>:<action>` is reported (1-based line number). Returns every
    /// problem found (empty ⇒ valid).
    ///
    /// PURE — no file I/O and NO dependency on the keybind grammar module: the caller injects
    /// `isValidKeybindValue` (in production, `{ KeybindGrammar.parseLine($0) != nil }`); tests pass the
    /// same real parser, so the validator's verdict tracks exactly what the app will and won't honour.
    public static func validate(
        _ contents: String,
        isValidKeybindValue: (String) -> Bool,
    ) -> [ValidationError] {
        var errors: [ValidationError] = []
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Skip blank lines, `#` comments, and `[section]` headers (the only non-directive lines the
            // launch bridge tolerates without acting on them).
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                errors.append(ValidationError(
                    line: index + 1, message: "missing '=' (expected keybind = <chord>:<action>)",
                ))
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "keybind" else {
                let shown = key.isEmpty ? "(empty)" : key
                errors.append(ValidationError(
                    line: index + 1,
                    message: "unknown key '\(shown)': the app reads only 'keybind' lines from this file, "
                        + "so this line has no effect (set app config via `slopdesk config set`)",
                ))
                continue
            }
            // Mirror the loader's lenient quoting: an optional surrounding pair of double quotes is stripped.
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            let unquoted = value
            guard !unquoted.isEmpty else {
                errors.append(ValidationError(line: index + 1, message: "empty keybind value"))
                continue
            }
            if !isValidKeybindValue(unquoted) {
                errors.append(ValidationError(
                    line: index + 1, message: "malformed keybind '\(unquoted)' (expected <chord>:<action>)",
                ))
            }
        }
        return errors
    }
}
