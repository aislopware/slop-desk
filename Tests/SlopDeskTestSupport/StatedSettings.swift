// StatedSettings — how a test says "run this on a machine whose config file says X".
//
// Settings live in `config.toml` and resolve into one process-global ``AppConfig``. Nothing in the
// app writes one, so a test cannot arrange a setting the way the app does — it has to move the global
// itself, and a global a test moves and forgets to move back does not fail that test, it fails a
// LATER one, in another file, with a message about something else entirely.
//
// So the restore is not the caller's to remember. Every function here registers an XCTest teardown
// block that puts the previous configuration back, and teardown blocks run in reverse registration
// order, so a test that states three settings unwinds through exactly the readings it installed.
//
// The other half of the seam is ``AppConfig/withCurrent(_:_:)``, which scopes a configuration to one
// BODY rather than to one test. Use that when the reading has to be live for a specific call and back
// to normal for the assertion; use these when the whole test runs on the stated machine.
//
// This target exists only to be depended on by test targets. It is not a product.

import SlopDeskVideoProtocol
import XCTest

// `@nonobjc` on every one: `XCTestCase` is an Objective-C class, so five overloads that differ only
// in argument TYPE all mangle to the same `stateSetting::` selector and refuse to compile. Nothing
// here is ever called from Objective-C.

public extension XCTestCase {
    /// Runs the rest of this test with `path` answering `value`. Restored in teardown.
    @nonobjc
    func stateSetting(_ path: String, _ value: Bool) {
        stateConfig { $0.setting(path, value) }
    }

    /// Runs the rest of this test with `path` answering `value`. Restored in teardown.
    @nonobjc
    func stateSetting(_ path: String, _ value: Int) {
        stateConfig { $0.setting(path, value) }
    }

    /// Runs the rest of this test with `path` answering `value`. Restored in teardown.
    @nonobjc
    func stateSetting(_ path: String, _ value: Double) {
        stateConfig { $0.setting(path, value) }
    }

    /// Runs the rest of this test with `path` answering `value` — a free text, or a choice token.
    ///
    /// The token is passed as a STRING on purpose, even where the reader is an enum: half of what
    /// these tests pin is what happens to a token no case spells (a file hand-edited against a newer
    /// build), and that case is unwritable if the argument has to type-check as the enum.
    @nonobjc
    func stateSetting(_ path: String, _ value: String) {
        stateConfig { $0.setting(path, value) }
    }

    /// Runs the rest of this test with `path` answering `value`. Restored in teardown.
    @nonobjc
    func stateSetting(_ path: String, _ value: [String]) {
        stateConfig { $0.setting(path, value) }
    }

    /// Runs the rest of this test on a `[keybind]` table of `table`. Restored in teardown.
    @nonobjc
    func stateKeybinds(_ table: [String: String]) {
        stateConfig { $0.withKeybinds(table) }
    }

    /// Runs the rest of this test on an `[env]` overlay of `table`. Restored in teardown.
    @nonobjc
    func stateEnv(_ table: [String: String]) {
        stateConfig { $0.withEnv(table) }
    }

    /// Runs the rest of this test on the compiled-in answers alone — a machine with NO config file.
    ///
    /// Worth stating explicitly in a suite that asserts a default: without it the test passes on
    /// whatever the developer's own `~/.config/slopdesk/config.toml` happens to say.
    @nonobjc
    func stateCompiledDefaults() {
        stateConfig { _ in AppConfig.compiledDefaults }
    }

    /// The one writer: derive a configuration from the current one, install it, and register the
    /// restore before anything can read it.
    private func stateConfig(_ transform: (AppConfig) -> AppConfig) {
        let before = AppConfig.current
        addTeardownBlock { AppConfig.current = before }
        AppConfig.current = transform(before)
    }
}
