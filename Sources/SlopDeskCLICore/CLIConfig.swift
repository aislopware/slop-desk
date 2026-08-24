import Foundation
import SlopDeskVideoProtocol

// `slopdesk config path | edit | validate | schema | show | get <key>` — the reading half of the CLI.
//
// EVERY form here reads. There is no `set` and no `unset`: the file is the truth, and a program that
// writes a user's config file makes a setting the user cannot see in their own file. That ruling is
// why this module lost `resolvePath(override:environment:)`, `defaultPath(environment:)` and the
// line-by-line `validate` it used to run — the path rules, the parse and the verdict are all
// `slopdesk-settings`'s now, reached through ``AppConfig``, which the APP reads through as well. One
// resolver, one set of defaults, one place a key is declared.
//
// The `edit` $EDITOR spawn lives in the compiled-only `main.swift`; what is here is pure.

public enum CLIConfig {
    /// Where the config file is: `--config-file` if given, else `$SLOPDESK_CONFIG_FILE`, else
    /// `$XDG_CONFIG_HOME/slopdesk/config.toml`, else `~/.config/slopdesk/config.toml`.
    public static func path(override: String? = nil) -> String {
        AppConfig.resolvedPath(explicit: override)
    }

    /// The environment variable that overrides that path — printed beside it so `config path` says
    /// where the answer came from.
    public static var environmentKey: String { AppConfig.fileEnvironmentKey }

    /// The JSON Schema describing every key, written out of the same table the file resolves
    /// against. This is what `docs/config.schema.json` is checked against and what an editor reads
    /// to complete a key and underline a value outside its range.
    public static var schema: String { AppConfig.jsonSchema() }

    /// Everything wrong with the file at ``path``, in reading order — one sentence per problem.
    ///
    /// Empty means the file is fine, AND empty means there is no file: an install without one is
    /// the supported shape, so it cannot be an error. A refused value is reported here and DROPPED,
    /// never fatal — the rest of the file still loads and the row's own default answers.
    ///
    /// Two sources, because they are two different kinds of wrong. The table's own diagnostics are
    /// per-ROW — an undeclared key, a value outside its range — and `slopdesk-settings` answers
    /// them as it parses. The `[keybind]` conflicts are per-PAIR: no single row is wrong, and the
    /// problem only exists once both have been folded to a canonical chord.
    public static func diagnostics(override: String? = nil) -> [String] {
        let config = loaded(override: override)
        return config.diagnostics + KeybindConfigLoader.conflicts(table: config.keybinds)
    }

    /// The file at ``path(override:)``, resolved. One read per call — the CLI is a process that
    /// answers one question and exits, so there is nothing to cache and nothing to invalidate.
    public static func loaded(override: String? = nil) -> AppConfig {
        AppConfig.load(path: path(override: override))
    }

    /// One resolved value, rendered bare (no quotes, no `key =`) so a shell can capture it, or `nil`
    /// for a key the table does not declare.
    ///
    /// A key with NO default that the file never sets (the video and agent flags, whose numbers
    /// belong to the daemon) is absent, not empty — the caller reports "unset" rather than printing
    /// a zero nobody chose.
    public static func value(of key: String, in config: AppConfig) -> String? {
        if let flag = config.flags[key] { return flag ? "true" : "false" }
        if let int = config.ints[key] { return String(int) }
        if let float = config.floats[key] { return String(float) }
        if let text = config.texts[key] { return text }
        if let list = config.lists[key] { return list.joined(separator: ",") }
        return nil
    }

    /// The WHOLE resolved configuration as TOML — every key with the value this machine is actually
    /// running on, grouped under its section header in path order.
    ///
    /// Deliberately re-pasteable: `slopdesk config show > ~/.config/slopdesk/config.toml` yields a
    /// file that resolves to exactly what was printed. That is the one honest way to answer "what am
    /// I running on" for a program whose whole point is that it never wrote the file. The starter
    /// file the app creates is the opposite shape — comments only — because a file full of defaults
    /// pins them, and then a retuned default never reaches the person who took the sample.
    public static func show(_ config: AppConfig) -> String {
        var lines: [String] = []
        var section = ""
        for key in declaredKeys(config) {
            guard let value = rendered(key, config) else { continue }
            let head = key.prefix(while: { $0 != "." })
            if head != section {
                section = String(head)
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(section)]")
            }
            lines.append("\(key.dropFirst(section.count + 1)) = \(value)")
        }
        appendFreeTable("keybind", config.keybinds, quotingKeys: true, into: &lines)
        appendFreeTable("env", config.env, quotingKeys: false, into: &lines)
        return lines.joined(separator: "\n")
    }

    /// Every declared path, sorted, so the rendering is stable across runs and diffable.
    private static func declaredKeys(_ config: AppConfig) -> [String] {
        var keys = Set(config.flags.keys)
        keys.formUnion(config.ints.keys)
        keys.formUnion(config.floats.keys)
        keys.formUnion(config.texts.keys)
        keys.formUnion(config.lists.keys)
        return keys.sorted()
    }

    /// One value as TOML — strings and list members quoted, numbers and booleans bare.
    private static func rendered(_ key: String, _ config: AppConfig) -> String? {
        if let flag = config.flags[key] { return flag ? "true" : "false" }
        if let int = config.ints[key] { return String(int) }
        if let float = config.floats[key] { return String(float) }
        if let text = config.texts[key] { return quoted(text) }
        if let list = config.lists[key] { return "[\(list.map(quoted).joined(separator: ", "))]" }
        return nil
    }

    /// The `[keybind]` / `[env]` tables, whose keys are the USER's own rather than the table's.
    /// Omitted entirely when empty — printing an empty header would invite someone to fill it in
    /// under a section name they then have to guess the grammar of.
    private static func appendFreeTable(
        _ name: String, _ table: [String: String], quotingKeys: Bool, into lines: inout [String],
    ) {
        guard !table.isEmpty else { return }
        if !lines.isEmpty { lines.append("") }
        lines.append("[\(name)]")
        for key in table.keys.sorted() {
            let value = table[key] ?? ""
            lines.append("\(quotingKeys ? quoted(key) : key) = \(quoted(value))")
        }
    }

    /// A TOML basic string: the two characters that can end it early, escaped, and nothing else —
    /// every value that reaches here came back OUT of the parser, so it is already well-formed text.
    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
