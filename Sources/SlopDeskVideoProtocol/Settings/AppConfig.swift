import CSlopDeskFFI
import Foundation
import Synchronization

// MARK: - AppConfig (every setting the app runs on, resolved once)

/// The whole configuration surface as one immutable value: the file's answers where it gave any,
/// the compiled-in best default everywhere else.
///
/// ## Why there is no settings window any more
///
/// Every key here has an answer chosen to be right for a first-run install, and the app applies it
/// without being asked. The file exists to DISAGREE with one — that is the whole of its job, which
/// is why the shape is Ghostty's: install it and it works, and `config.toml` is what you open on the
/// day you want something else. A window that offers 110 switches spends its screen space asking a
/// question the program should already have answered.
///
/// ## Where the answers come from
///
/// `slopdesk-settings::config::table` — one Rust table naming every key, its type, its domain and
/// its default. This side holds NO default of its own: an absent key is absent because the table
/// declared it absent (the video flags, whose numbers belong to the daemon), never because Swift
/// forgot to look. The same table generates `docs/config.schema.json`, so an editor completes the
/// key, prints the sentence and underlines a value outside its range.
///
/// ## The cost
///
/// One crossing at launch and one per reload — never per draw. The snapshot arrives as a single
/// JSON object with five maps BY TYPE plus the two free tables, because every read on this side is
/// typed at the call site and a nested document would only be re-flattened here.
public struct AppConfig: Sendable, Equatable {
    /// Every declared boolean, by dotted path.
    public let flags: [String: Bool]
    /// Every declared whole number.
    public let ints: [String: Int]
    /// Every declared real number.
    public let floats: [String: Double]
    /// Every declared string — a free text, a choice token, or a named scale stop.
    public let texts: [String: String]
    /// Every declared string list.
    public let lists: [String: [String]]
    /// The `[keybind]` table: chord → action id.
    public let keybinds: [String: String]
    /// The `[env]` table: raw `SLOPDESK_*` name → value, applied last and above every typed key.
    public let env: [String: String]
    /// Every path the table DECLARES, whether or not this reading answers it.
    ///
    /// Not the union of the five maps: a key declared with no default is absent from them until
    /// somebody sets it. This is what tells "no such key" apart from "declared but unset".
    public let declaredPaths: Set<String>
    /// One line per thing wrong with the file, in reading order. Empty for a file that is fine, and
    /// empty for a machine with no file at all — an install without one is the supported shape.
    public let diagnostics: [String]

    public init(
        flags: [String: Bool] = [:],
        ints: [String: Int] = [:],
        floats: [String: Double] = [:],
        texts: [String: String] = [:],
        lists: [String: [String]] = [:],
        keybinds: [String: String] = [:],
        env: [String: String] = [:],
        declaredPaths: Set<String>? = nil,
        diagnostics: [String] = [],
    ) {
        self.flags = flags
        self.ints = ints
        self.floats = floats
        self.texts = texts
        self.lists = lists
        self.keybinds = keybinds
        self.env = env
        // A test that builds a configuration by hand states only the keys it cares about; the paths
        // it answered ARE the ones it declared, which keeps every such call site free of a list.
        self.declaredPaths = declaredPaths
            ?? Set(flags.keys).union(ints.keys).union(floats.keys).union(texts.keys).union(lists.keys)
        self.diagnostics = diagnostics
    }

    // MARK: Reading one key

    /// A declared boolean. `false` for a path no key declares — which is a programming error the
    /// `every_path_the_app_reads_is_one_the_table_declares` test catches, not a state to handle.
    public func flag(_ path: String) -> Bool { flags[path] ?? false }

    /// A declared whole number, or `0` for an undeclared path.
    public func int(_ path: String) -> Int { ints[path] ?? 0 }

    /// A declared real number, or `0` for an undeclared path.
    public func double(_ path: String) -> Double { floats[path] ?? 0 }

    /// A declared string, or `""` for an undeclared path.
    public func text(_ path: String) -> String { texts[path] ?? "" }

    /// A declared string list, or `[]` for an undeclared path.
    public func list(_ path: String) -> [String] { lists[path] ?? [] }

    /// A key the table declares WITHOUT a default — the video and agent flags, whose numbers belong
    /// to the daemon that reads them. `nil` until somebody writes one, which is what keeps an
    /// untouched install's env overlay empty and its golden corpus unmoved.
    public func optionalInt(_ path: String) -> Int? { ints[path] }
    /// The real-numbered half of ``optionalInt(_:)``.
    public func optionalDouble(_ path: String) -> Double? { floats[path] }
    /// The boolean half of ``optionalInt(_:)``.
    public func optionalFlag(_ path: String) -> Bool? { flags[path] }
    /// The string half of ``optionalInt(_:)``.
    public func optionalText(_ path: String) -> String? { texts[path] }

    /// A choice key as the Swift enum whose raw values ARE the table's tokens. `fallback` stands in
    /// for a token no case spells, which the schema already refuses and only a hand-edited file
    /// reaching an older binary can produce.
    public func choice<T: RawRepresentable>(_ path: String, _ fallback: T) -> T
        where T.RawValue == String
    {
        texts[path].flatMap(T.init(rawValue:)) ?? fallback
    }

    // MARK: Building a variant (the test seam, and nothing else)

    /// This configuration with one boolean answered differently.
    ///
    /// The ONLY writer in the codebase. A test that needs a non-default setting states it here and
    /// restores the previous value; nothing shipping writes a setting, because a setting written by
    /// a program is one the user cannot see in their own file.
    public func setting(_ path: String, _ value: Bool) -> Self {
        var next = flags
        next[path] = value
        return replacing(flags: next)
    }

    /// This configuration with one whole number answered differently.
    public func setting(_ path: String, _ value: Int) -> Self {
        var next = ints
        next[path] = value
        return replacing(ints: next)
    }

    /// This configuration with one real number answered differently.
    public func setting(_ path: String, _ value: Double) -> Self {
        var next = floats
        next[path] = value
        return replacing(floats: next)
    }

    /// This configuration with one string — a free text or a choice token — answered differently.
    public func setting(_ path: String, _ value: String) -> Self {
        var next = texts
        next[path] = value
        return replacing(texts: next)
    }

    /// This configuration with one list answered differently.
    public func setting(_ path: String, _ value: [String]) -> Self {
        var next = lists
        next[path] = value
        return replacing(lists: next)
    }

    /// This configuration with a different `[keybind]` table.
    public func withKeybinds(_ table: [String: String]) -> Self {
        replacing(keybinds: table)
    }

    /// This configuration with a different `[env]` table — the raw `SLOPDESK_*` overlay, which folds
    /// last and beats every typed key that maps to the same variable.
    public func withEnv(_ table: [String: String]) -> Self {
        replacing(env: table)
    }

    private func replacing(
        flags: [String: Bool]? = nil,
        ints: [String: Int]? = nil,
        floats: [String: Double]? = nil,
        texts: [String: String]? = nil,
        lists: [String: [String]]? = nil,
        keybinds: [String: String]? = nil,
        env: [String: String]? = nil,
    ) -> Self {
        Self(
            flags: flags ?? self.flags,
            ints: ints ?? self.ints,
            floats: floats ?? self.floats,
            texts: texts ?? self.texts,
            lists: lists ?? self.lists,
            keybinds: keybinds ?? self.keybinds,
            env: env ?? self.env,
            declaredPaths: declaredPaths,
            diagnostics: diagnostics,
        )
    }
}

// MARK: - Running a body on a stated configuration (the other half of the test seam)

public extension AppConfig {
    /// Runs `body` with ``current`` set to `config`, and puts the previous one back afterwards.
    ///
    /// The counterpart to ``setting(_:_:)-(String,Bool)``: that builds the configuration, this is how
    /// a test INSTALLS it. Both live here rather than in a test helper because ``current`` is a
    /// process-global — a test that sets it and forgets to restore it does not fail, it fails the
    /// NEXT test, in a different file, with a message about something else. `defer` makes that
    /// impossible even when the body throws.
    ///
    /// Nothing shipping calls this. The app moves ``current`` exactly once, in `ConfigFile.reload`,
    /// where the point is that the new reading STAYS.
    static func withCurrent<T>(_ config: AppConfig, _ body: () throws -> T) rethrows -> T {
        let before = current
        current = config
        defer { current = before }
        return try body()
    }

    /// ``withCurrent(_:_:)`` for an `async` body.
    static func withCurrent<T>(_ config: AppConfig, _ body: () async throws -> T) async rethrows -> T {
        let before = current
        current = config
        defer { current = before }
        return try await body()
    }
}

// MARK: - Loading

public extension AppConfig {
    /// The compiled-in answers alone — what a machine with no config file runs on.
    ///
    /// Read from the far side rather than written here, so "the default" has exactly one spelling.
    /// A path nothing can exist at is how the resolver is asked for the empty file's reading.
    static let compiledDefaults: AppConfig = load(path: "/var/empty/slopdesk/no-such-config.toml")

    /// The configuration this process is running on.
    ///
    /// Loaded on first read and held until ``reload()``. A `Mutex` rather than an actor: every
    /// consumer is a synchronous accessor on a hot path (the notification gates, the badge gates,
    /// the terminal builder), and a lock around a struct copy is cheaper than the hop an actor
    /// would cost each of them.
    static var current: AppConfig {
        get {
            loaded.withLock { held in
                if let held { return held }
                let fresh = load(path: resolvedPath())
                held = fresh
                return fresh
            }
        }
        set { loaded.withLock { $0 = newValue } }
    }

    /// Re-read the file and publish it as ``current``, answering what was read.
    ///
    /// The caller re-applies: there is no observation here, because the four things a change can
    /// affect (the terminal config string, the keybinding overrides, the chrome density, the env
    /// overlay) are applied by one object that knows the order they go in.
    @discardableResult
    static func reload() -> AppConfig {
        let fresh = load(path: resolvedPath())
        current = fresh
        return fresh
    }

    /// The config file this process reads: `$SLOPDESK_CONFIG_FILE`, else
    /// `$XDG_CONFIG_HOME/slopdesk/config.toml`, else `~/.config/slopdesk/config.toml`.
    ///
    /// On iOS none of those is reachable from the Files app, so the app's own Documents directory
    /// decides instead — the one place a user can put a file INTO a sandboxed app. The environment
    /// is read on the far side; only the two paths this side owns cross.
    ///
    /// `explicit` is the CLI's `--config-file`, which beats every rule above; `nil` (the app) lets
    /// the platform answer.
    static func resolvedPath(explicit override: String? = nil) -> String {
        let explicit = Array((override ?? platformExplicitPath()).utf8)
        let fallback = Array(NSHomeDirectory().utf8)
        return explicit.withUnsafeBufferPointer { explicit in
            fallback.withUnsafeBufferPointer { fallback in
                lentText { out, cap in
                    slopdesk_config_path(
                        explicit.baseAddress, explicit.count,
                        fallback.baseAddress, fallback.count,
                        out, cap,
                    )
                }
            }
        }
    }

    /// Reads and resolves the file at `path`. A file that is not there resolves to the compiled-in
    /// answers with no diagnostic.
    static func load(path: String) -> AppConfig {
        let bytes = Array(path.utf8)
        let json = bytes.withUnsafeBufferPointer { path in
            lentText { out, cap in
                slopdesk_config_snapshot(path.baseAddress, path.count, out, cap)
            }
        }
        return decode(json)
    }

    /// Makes `path` openable — its directory, the schema beside it, and a starter file if there is
    /// none — and answers whether the starter was seeded.
    ///
    /// Every one of those is a filesystem effect, so all three are one door rather than three
    /// `FileManager` calls here: the near side does not decide where the schema goes or what a fresh
    /// file says, any more than it decides how the file PARSES.
    @discardableResult
    static func prepare(path: String) -> Bool {
        let bytes = Array(path.utf8)
        return bytes.withUnsafeBufferPointer { path in
            slopdesk_config_prepare(path.baseAddress, path.count)
        }
    }

    /// The JSON Schema the file is described by — what `slopdesk config schema` prints and what
    /// `docs/config.schema.json` is checked against.
    static func jsonSchema() -> String {
        lentText { out, cap in slopdesk_config_schema(out, cap) }
    }

    /// The environment variable that overrides the file location, for the one caller that prints
    /// where the path came from.
    static var fileEnvironmentKey: String {
        lentText { out, cap in slopdesk_config_env_key(out, cap) }
    }

    /// The snapshot's own shape: five maps by type, the two free tables, the declared paths, the
    /// diagnostics.
    private struct Snapshot: Decodable {
        let flag: [String: Bool]
        let int: [String: Int]
        let float: [String: Double]
        let text: [String: String]
        let list: [String: [String]]
        let keybind: [String: String]
        let env: [String: String]
        let declared: [String]
        let diagnostics: [String]
    }

    /// Decodes one snapshot. A snapshot that will not decode is a boundary bug rather than user
    /// input — the far side wrote it — so it answers the empty configuration and every accessor
    /// falls to its zero, which is visible immediately rather than subtly wrong.
    private static func decode(_ json: String) -> AppConfig {
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return AppConfig() }
        return AppConfig(
            flags: snapshot.flag,
            ints: snapshot.int,
            floats: snapshot.float,
            texts: snapshot.text,
            lists: snapshot.list,
            keybinds: snapshot.keybind,
            env: snapshot.env,
            declaredPaths: Set(snapshot.declared),
            diagnostics: snapshot.diagnostics,
        )
    }

    /// The path this platform insists on, or `""` to let the environment decide.
    private static func platformExplicitPath() -> String {
        #if os(iOS)
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask,
        ).first else { return "" }
        return documents.appendingPathComponent("config.toml", isDirectory: false).path
        #else
        return ""
        #endif
    }
}

/// The held configuration. File-private state on an `enum` extension is not expressible, so it
/// lives here. A `Mutex` rather than a `nonisolated(unsafe) var` beside a lock: the value and the
/// lock over it are the same declaration, so there is no unguarded spelling of the variable for a
/// later reader to reach for.
private let loaded = Mutex<AppConfig?>(nil)
