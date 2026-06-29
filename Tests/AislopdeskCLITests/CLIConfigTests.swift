import AislopdeskCLICore
import AislopdeskVideoProtocol
import XCTest

// Hang-safe tests for the `aislopdesk config path | validate` PURE helpers (otty-clone E20, WI-4). No
// file I/O: the path resolver takes its environment as a parameter, and the validator takes the file
// contents as a string. The malformed-line assertions are genuine behavioral contracts (the validator
// must reject them) — not tautologies against the validator's own output.
//
// `validate` is checked against the REAL keybind grammar (M2 fix): the production parser
// `KeybindGrammar.parseLine` is injected, so a line the launch bridge would silently ignore
// (`font-size = 14`) MUST be rejected — proving the validator no longer reports such files "valid".

/// The production keybind-value predicate `config validate` injects in `main.swift`.
private func isRealKeybind(_ value: String) -> Bool { KeybindGrammar.parseLine(value) != nil }

final class CLIConfigTests: XCTestCase {
    // MARK: - Path resolution

    func testResolvePathPrefersExplicitOverride() {
        XCTAssertEqual(CLIConfig.resolvePath(override: "/x.toml", environment: [:]), "/x.toml")
    }

    func testResolvePathEmptyOverrideFallsThrough() {
        let env = [CLIConfig.configFileEnvKey: "/from-env.toml"]
        XCTAssertEqual(CLIConfig.resolvePath(override: "", environment: env), "/from-env.toml")
    }

    func testResolvePathUsesEnvWhenNoOverride() {
        let env = [CLIConfig.configFileEnvKey: "/e.toml"]
        XCTAssertEqual(CLIConfig.resolvePath(override: nil, environment: env), "/e.toml")
    }

    func testDefaultPathHonorsXDG() {
        let env = ["XDG_CONFIG_HOME": "/cfg", "HOME": "/Users/me"]
        XCTAssertEqual(CLIConfig.resolvePath(override: nil, environment: env), "/cfg/aislopdesk/config.toml")
    }

    func testDefaultPathFallsBackToHomeDotConfig() {
        let env = ["HOME": "/Users/me"]
        XCTAssertEqual(CLIConfig.defaultPath(environment: env), "/Users/me/.config/aislopdesk/config.toml")
    }

    // MARK: - Validation (against the REAL keybind grammar)

    func testValidateAcceptsWellFormedKeybindConfig() {
        let contents = """
        # a comment
        keybind = cmd+t:new_tab
        keybind=cmd+1:goto_tab:1

        [section-header-is-tolerated]
        keybind = "ctrl+a:text:hello"
        """
        XCTAssertTrue(CLIConfig.validate(contents, isValidKeybindValue: isRealKeybind).isEmpty)
    }

    // The core M2 contract: an app-store key the launch bridge SILENTLY IGNORES must be REJECTED, not
    // reported "valid". (The old generic `key = value` validator passed this — revert-to-confirm-fail.)
    func testValidateRejectsKeyTheAppIgnores() {
        let errors = CLIConfig.validate("font-size = 14", isValidKeybindValue: isRealKeybind)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 1)
        XCTAssertTrue(errors.first?.message.contains("unknown key") ?? false)
        XCTAssertTrue(errors.first?.message.contains("font-size") ?? false)
    }

    func testValidateAcceptsBareValidKeybind() {
        XCTAssertTrue(CLIConfig.validate("keybind = cmd+t:new_tab", isValidKeybindValue: isRealKeybind).isEmpty)
    }

    // A malformed chord (`cmd+zzz` — a multi-char base key that is not a named key) fails the real
    // parser, so the keybind line is flagged with its 1-based line number.
    func testValidateRejectsMalformedKeybindChord() {
        let errors = CLIConfig.validate(
            "keybind = cmd+t:new_tab\nkeybind = cmd+zzz:new_tab", isValidKeybindValue: isRealKeybind,
        )
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 2)
        XCTAssertTrue(errors.first?.message.contains("malformed keybind") ?? false)
    }

    func testValidateRejectsLineMissingEquals() {
        let errors = CLIConfig.validate("keybind cmd+t:new_tab", isValidKeybindValue: isRealKeybind)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 1)
        XCTAssertTrue(errors.first?.message.contains("missing") ?? false)
    }

    func testValidateRejectsEmptyKeybindValue() {
        let errors = CLIConfig.validate("keybind =", isValidKeybindValue: isRealKeybind)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 1)
        XCTAssertTrue(errors.first?.message.contains("empty keybind value") ?? false)
    }

    func testValidateReportsEachBadLineNumber() {
        let errors = CLIConfig.validate(
            "keybind = cmd+t:new_tab\ntheme = Monokai\nfont-size 14", isValidKeybindValue: isRealKeybind,
        )
        XCTAssertEqual(errors.map(\.line), [2, 3])
    }
}
