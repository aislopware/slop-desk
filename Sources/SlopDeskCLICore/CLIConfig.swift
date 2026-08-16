import CSlopDeskFFI
import Foundation
import SlopDeskArena

// `slopdesk config path | edit | validate` — the Swift face of `rust/slopdesk-cli`'s `config`.
// These operate on the optional user config FILE (XDG-style: `~/.config/slopdesk/`), which is the
// persisted source a launch-time bridge reads. The RUNNING-app config ops
// (`get`/`set`/`unset`/`show`/`reload`, incl. `--transient`) go over the control socket instead;
// only `path`/`edit`/`validate` are pure file ops (the `edit` $EDITOR spawn lives in the
// compiled-only `main.swift`).
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
    public static let configFileEnvKey = CLICompletions
        .answer { out, cap in slopdesk_cli_config_env_key(out, cap) }

    /// Resolve the config-file path: explicit `--config-file` > ``configFileEnvKey`` env > the XDG
    /// default. The ORDER is `config.rs`'s; the environment is read here and passed by value,
    /// because asking the environment is I/O and the crate does none.
    public static func resolvePath(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        candidates(environment) { xdg, home, fallback in
            let explicit = Array((override ?? "").utf8)
            let fromEnv = Array((environment[configFileEnvKey] ?? "").utf8)
            return explicit.withUnsafeBufferPointer { flag in
                fromEnv.withUnsafeBufferPointer { env in
                    CLICompletions.answer { out, cap in
                        slopdesk_cli_config_path(
                            flag.baseAddress, flag.count, env.baseAddress, env.count,
                            xdg.baseAddress, xdg.count, home.baseAddress, home.count,
                            fallback.baseAddress, fallback.count, out, cap,
                        )
                    }
                }
            }
        }
    }

    /// `$XDG_CONFIG_HOME/slopdesk/config.toml`, else `~/.config/slopdesk/config.toml` (XDG Base Directory convention).
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        candidates(environment) { xdg, home, fallback in
            CLICompletions.answer { out, cap in
                slopdesk_cli_config_default_path(
                    xdg.baseAddress, xdg.count, home.baseAddress, home.count,
                    fallback.baseAddress, fallback.count, out, cap,
                )
            }
        }
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
    /// full of ignored keys (`font-size = 14`) "valid". `config.rs` validates the truth instead: blank
    /// lines, `#` comments, and `[section]` headers are skipped; every OTHER line must be a
    /// `keybind = <value>` assignment whose `<value>` parses as a binding directive.
    ///
    /// The grammar is `slopdesk-terminal`'s `keybind` — the same one ``KeybindGrammar`` parses live
    /// bindings with — so the verdict tracks exactly what the app will honour. It used to cross back
    /// as a C callback into Swift, once per line; both ends of that round trip are now the same
    /// side of the door.
    public static func validate(_ contents: String) -> [ValidationError] {
        let bytes = Array(contents.utf8)
        return bytes.withUnsafeBufferPointer { file -> [ValidationError] in
            let shape = slopdesk_cli_config_validate(file.baseAddress, file.count, nil, 0, nil, 0)
            let room = shape.count
            guard room > 0 else { return [] }
            var records = [SlopDeskCliConfigError](
                repeating: SlopDeskCliConfigError(), count: shape.count,
            )
            var arena = Data(count: shape.arena_len)
            records.withUnsafeMutableBufferPointer { out in
                arena.withUnsafeMutableBytes { pool in
                    _ = slopdesk_cli_config_validate(
                        file.baseAddress, file.count,
                        out.baseAddress, out.count, pool.baseAddress, pool.count,
                    )
                }
            }
            return records.map { record in
                let message = ArenaText.text(
                    arena, offset: Int(record.message.offset), length: Int(record.message.length),
                )
                return ValidationError(line: record.line, message: message)
            }
        }
    }

    /// Lends the three environment values the path rules read, each as bytes for exactly one call.
    private static func candidates(
        _ environment: [String: String],
        _ ask: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>) -> String,
    ) -> String {
        let xdg = Array((environment["XDG_CONFIG_HOME"] ?? "").utf8)
        let home = Array((environment["HOME"] ?? "").utf8)
        let fallback = Array(NSHomeDirectory().utf8)
        return xdg.withUnsafeBufferPointer { xdg in
            home.withUnsafeBufferPointer { home in
                fallback.withUnsafeBufferPointer { fallback in ask(xdg, home, fallback) }
            }
        }
    }
}
