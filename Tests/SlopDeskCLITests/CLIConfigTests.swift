// The `slopdesk config` reading half, as pure functions over an ``AppConfig``.
//
// What this file used to pin is gone with the surface it pinned: a hand-rolled `resolvePath`, a
// `defaultPath` that re-implemented the XDG rules, and a line-by-line `validate` with its own idea of
// which keys exist. All three were a SECOND answer to a question `slopdesk-settings` already answers —
// the resolver, the parser and the diagnostics are one table now, read by the app through the same
// ``AppConfig``. A CLI that disagreed with the app about where the file is, or about whether a key is
// real, is the exact drift the port existed to end.
//
// So what is pinned here is what the CLI still decides on its own: the RENDERING. `config get` prints
// one value bare, `config show` prints the whole resolved configuration as TOML, and the promise those
// two make is re-pasteability — `config show` piped back into the file must resolve to what was
// printed. That is checked by round-tripping through the real parser rather than by eyeballing a
// string, because a quoting bug reads as valid TOML right up until it does not.
//
// Hang-safe: one temporary file per case, no daemons, no sockets.

import SlopDeskCLICore
import SlopDeskVideoProtocol
import XCTest

final class CLIConfigTests: XCTestCase {
    /// Resolves `contents` as if it were the user's config file.
    private func loaded(_ contents: String) throws -> AppConfig {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-config-\(UUID().uuidString).toml", isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AppConfig.load(path: url.path)
    }

    // MARK: - Where the file is

    /// `--config-file` beats everything, and the CLI gets that answer from the same resolver the app
    /// does rather than from rules of its own.
    func testAnExplicitPathIsTheResolvedPath() {
        XCTAssertEqual(CLIConfig.path(override: "/x.toml"), "/x.toml")
    }

    /// `config path` prints the override's NAME beside the path, so the reader can see why it is that
    /// path — the env key comes from the far side, not from a literal typed here.
    func testTheEnvironmentKeyIsTheOneTheAppHonours() {
        XCTAssertEqual(CLIConfig.environmentKey, AppConfig.fileEnvironmentKey)
        XCTAssertFalse(CLIConfig.environmentKey.isEmpty)
    }

    // MARK: - Diagnostics

    /// No file is the SUPPORTED shape, not an error: an install that never wrote one runs on the
    /// compiled-in answers, and `config validate` must say so.
    func testAMissingFileHasNoDiagnostics() {
        XCTAssertTrue(CLIConfig.diagnostics(override: "/var/empty/slopdesk/no-such-config.toml").isEmpty)
    }

    /// A key the table does not declare is REPORTED — the whole point of validating. It is also
    /// dropped rather than fatal, so the rest of the file still resolves.
    func testAnUndeclaredKeyIsReportedAndTheRestStillLoads() throws {
        let config = try loaded("""
        [terminal]
        no-such-key = 14
        font-size = 17
        """)
        XCTAssertEqual(config.diagnostics.count, 1, "one problem, one sentence")
        XCTAssertTrue(
            config.diagnostics[0].contains("no-such-key"),
            "the diagnostic names the key: \(config.diagnostics[0])",
        )
        XCTAssertEqual(config.double("terminal.font-size"), 17, "the good row still loaded")
    }

    // MARK: - `config get`

    func testGetRendersEachTypeBare() throws {
        let config = try loaded("""
        [terminal]
        font-size = 17
        font-family = "Berkeley Mono"

        [controls]
        copy-on-select = true
        scroll-multiplier = 2.5
        """)
        // A point size is a REAL number in the table (a face can sit at 13.5), so it renders as one
        // — `17`, pasted back, resolves to the same 17.0.
        XCTAssertEqual(CLIConfig.value(of: "terminal.font-size", in: config), "17.0")
        XCTAssertEqual(CLIConfig.value(of: "terminal.font-family", in: config), "Berkeley Mono")
        XCTAssertEqual(CLIConfig.value(of: "controls.copy-on-select", in: config), "true")
        XCTAssertEqual(CLIConfig.value(of: "controls.scroll-multiplier", in: config), "2.5")
    }

    /// A key with no default that the file never set is ABSENT, not empty — the caller prints "unset"
    /// rather than a zero nobody chose. The video flags are the family that has no default.
    func testAnUnsetDefaultlessKeyIsNil() {
        let config = AppConfig.compiledDefaults
        XCTAssertNil(CLIConfig.value(of: "video.qp-sharp", in: config))
        XCTAssertTrue(
            config.declaredPaths.contains("video.qp-sharp"),
            "precondition: the key is declared — this is 'unset', not 'no such key'",
        )
    }

    func testAKeyTheTableDoesNotDeclareIsNil() {
        XCTAssertNil(CLIConfig.value(of: "terminal.no-such-key", in: AppConfig.compiledDefaults))
    }

    // MARK: - `config show`

    /// The re-pasteability promise, checked the only way that means anything: print the resolved
    /// configuration, load THAT back, and require the two to be equal.
    func testShowRoundTripsThroughTheRealParser() throws {
        let config = try loaded("""
        [terminal]
        font-size = 17
        font-family = "Berkeley Mono"

        [controls]
        copy-on-select = true

        [keybind]
        "shift+cmd+e" = "split_right"

        [env]
        EDITOR = "hx"
        """)
        XCTAssertTrue(config.diagnostics.isEmpty, "precondition: \(config.diagnostics)")

        let printed = try loaded(CLIConfig.show(config))
        XCTAssertTrue(printed.diagnostics.isEmpty, "`config show` printed a file it rejects: \(printed.diagnostics)")
        XCTAssertEqual(printed, config, "show > config.toml must resolve to exactly what was shown")
    }

    /// A value with a quote and a backslash in it survives the round trip — the one rendering rule
    /// this module owns, and the one that fails silently.
    func testShowEscapesQuotesAndBackslashes() throws {
        let config = try loaded(#"""
        [env]
        AWKWARD = "a \"quoted\" \\ thing"
        """#)
        XCTAssertEqual(config.env["AWKWARD"], #"a "quoted" \ thing"#, "precondition: it parsed")
        XCTAssertEqual(try loaded(CLIConfig.show(config)).env["AWKWARD"], config.env["AWKWARD"])
    }

    /// Every row is under its own section header, in path order — a flat dump of `a.b = …` lines would
    /// be valid TOML and unreadable.
    func testShowGroupsRowsUnderSectionHeaders() {
        let lines = CLIConfig.show(AppConfig.compiledDefaults).split(separator: "\n", omittingEmptySubsequences: true)
        var section: String?
        for line in lines {
            if line.hasPrefix("[") {
                section = String(line)
                continue
            }
            XCTAssertNotNil(section, "a row before any header: \(line)")
            // The KEY half only: a real-numbered VALUE legitimately carries a dot, and checking the
            // whole line would call `font-size = 13.0` an escaped path.
            let key = line.prefix { $0 != "=" }
            XCTAssertFalse(key.contains("."), "a dotted key escaped its section: \(line)")
        }
        XCTAssertNotNil(section, "the compiled defaults render at least one section")
    }

    /// An empty `[keybind]` / `[env]` header is not printed — an empty section invites someone to fill
    /// it in under a grammar they then have to guess.
    func testShowOmitsTheEmptyFreeTables() {
        let printed = CLIConfig.show(AppConfig.compiledDefaults)
        XCTAssertFalse(printed.contains("[keybind]"))
        XCTAssertFalse(printed.contains("[env]"))
    }

    // MARK: - `config schema`

    /// The schema the CLI prints is the one the app writes beside the file — one generator, so an
    /// editor's completion cannot disagree with what the app accepts.
    func testTheSchemaIsTheAppsSchema() {
        XCTAssertEqual(CLIConfig.schema, AppConfig.jsonSchema())
        XCTAssertTrue(CLIConfig.schema.contains("\"$schema\""), "it is a JSON Schema document")
    }
}
