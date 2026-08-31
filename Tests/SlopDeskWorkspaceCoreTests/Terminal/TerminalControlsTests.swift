import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``TerminalControls`` bundle — the `from(config:)` factory's path→field mapping
/// (anti-mapping-error: every field is set to a NON-default value, so a swapped / dropped path fails), the
/// control enums' raw values + non-failable repair — which is what makes a hand-edited token from a newer
/// build survive — and the `MouseShiftCapture.configValue` libghostty-vt tokens the config builder emits.
///
/// All headless, and every case builds its OWN ``AppConfig`` rather than moving the process-global: the
/// factory takes the configuration as an argument precisely so the reading under test never has to be
/// installed anywhere.
@MainActor
final class TerminalControlsTests: XCTestCase {
    // MARK: - Defaults / init parity

    /// The struct's init defaults mirror the config table's, so `from(...)` on the compiled-in answers
    /// (a machine with NO config file) equals a default-constructed ``TerminalControls``. This pins the
    /// "factory terminal" invariant — and it is the assertion that catches a default retuned in the
    /// Rust table and not in the Swift struct.
    func testFactoryFromCompiledDefaultsEqualsDefaults() {
        let controls = TerminalControls.from(config: .compiledDefaults)
        XCTAssertEqual(controls, TerminalControls())
        // Spot-check the default values directly (independent of the init defaults).
        XCTAssertFalse(controls.copyOnSelect)
        XCTAssertTrue(controls.trimTrailing)
        XCTAssertTrue(controls.clearOnTyping)
        XCTAssertFalse(controls.clearOnCopy)
        XCTAssertEqual(controls.clipboardRead, .ask)
        XCTAssertEqual(controls.clipboardWrite, .allow)
        XCTAssertEqual(controls.allowShiftClick, .enabled)
        XCTAssertEqual(controls.rightClickAction, .contextMenu)
        XCTAssertEqual(controls.scrollMultiplier, 1.0)
    }

    /// Anti-mapping-error: every declared path is answered with a value DISTINCT from its default, so a
    /// factory that reads the wrong path (or drops one) produces a mismatch this catches. Revert-to-fail:
    /// swap any two reads in `from(config:)` and a field below diverges. The enum rows are stated as their
    /// bare token, which is what the user types in the file.
    func testFactoryReadsEveryDeclaredPath() {
        let config = AppConfig.compiledDefaults
            .setting("controls.copy-on-select", true)
            .setting("controls.trim-trailing-spaces", false)
            .setting("controls.clear-selection-on-typing", false)
            .setting("controls.clear-selection-on-copy", true)
            .setting("controls.paste-protection", false)
            .setting("controls.paste-bracketed-safe", false)
            .setting("controls.clipboard-read", ClipboardAccess.deny.rawValue)
            .setting("controls.clipboard-write", ClipboardAccess.deny.rawValue)
            .setting("controls.mouse-hide-while-typing", false)
            .setting("controls.shift-click", MouseShiftCapture.always.rawValue)
            .setting("controls.click-to-move", false)
            .setting("controls.allow-mouse-capture", false)
            .setting("controls.right-click-action", RightClickAction.copyOrPaste.rawValue)
            .setting("controls.shift-arrow-select", false)
            .setting("controls.scroll-multiplier", 2.5)

        let controls = TerminalControls.from(config: config)
        XCTAssertEqual(
            controls,
            TerminalControls(
                copyOnSelect: true,
                trimTrailing: false,
                clearOnTyping: false,
                clearOnCopy: true,
                pasteProtection: false,
                bracketedSafe: false,
                clipboardRead: .deny,
                clipboardWrite: .deny,
                hideMouseWhileTyping: false,
                allowShiftClick: .always,
                clickToMove: false,
                allowMouseCapture: false,
                rightClickAction: .copyOrPaste,
                shiftArrowSelect: false,
                scrollMultiplier: 2.5,
            ),
        )
    }

    /// A token no case spells — a file hand-edited against a newer build — decodes through the factory
    /// and repairs to the default rather than trapping (the non-failable `init(rawValue:)`).
    func testFactoryRepairsAnUnknownEnumToken() {
        let config = AppConfig.compiledDefaults
            .setting("controls.clipboard-read", "future-token")
            .setting("controls.shift-click", "garbage")
        let controls = TerminalControls.from(config: config)
        XCTAssertEqual(controls.clipboardRead, .ask, "an invalid clipboard-read token repairs to ask")
        XCTAssertEqual(controls.allowShiftClick, .enabled, "an invalid shift-capture token repairs to enabled")
    }

    // MARK: - Enum raw values + repair

    /// The control enums' raw values are the tokens the USER types in `config.toml` (and, for clipboard,
    /// the ones libghostty-vt reads). A rename here silently invalidates a file someone already wrote →
    /// pinned.
    func testEnumRawValuesArePinned() {
        XCTAssertEqual(ClipboardAccess.allCases.map(\.rawValue), ["allow", "deny", "ask"])
        XCTAssertEqual(RightClickAction.contextMenu.rawValue, "context-menu")
        XCTAssertEqual(RightClickAction.copyOrPaste.rawValue, "copy-or-paste")
        XCTAssertEqual(
            MouseShiftCapture.allCases.map(\.rawValue),
            ["disabled", "enabled", "always", "never"],
        )
    }

    /// Each enum's non-failable `init(rawValue:)` maps a known token to its case and repairs an unknown
    /// one to the default (never traps) — what a file written against a newer build must survive.
    func testEnumInitRepairsUnknownToken() {
        XCTAssertEqual(ClipboardAccess(rawValue: "deny"), .deny)
        XCTAssertEqual(ClipboardAccess(rawValue: "garbage"), .ask)
        XCTAssertEqual(RightClickAction(rawValue: "copy-or-paste"), .copyOrPaste)
        XCTAssertEqual(RightClickAction(rawValue: ""), .contextMenu)
        XCTAssertEqual(MouseShiftCapture(rawValue: "always"), .always)
        XCTAssertEqual(MouseShiftCapture(rawValue: "nope"), .enabled)
    }

    /// `MouseShiftCapture.configValue` is the libghostty-vt `mouse-shift-capture` token the config builder emits. This is a
    /// REAL ORACLE, not a restatement of the mapping: the "Allow Shift with Mouse Click" setting's axis ("hold ⇧ to
    /// *select text* even when the running app captures the mouse") is the INVERSE of libghostty-vt's
    /// `mouse-shift-capture` axis (whether ⇧ is *captured into the mouse protocol and sent to the program*).
    /// Per the vendored ghostty `Config.zig`: `false` = ⇧ extends the selection (libghostty-vt's own default,
    /// program may override); `true` = ⇧ is sent to the program (program may override); `never` = ⇧ ALWAYS
    /// extends selection (program can't override); `always` = ⇧ ALWAYS goes to the program (can't override).
    /// So "⇧ selects" must yield a *don't-capture* token and "⇧ goes to the program" a *capture* token.
    func testMouseShiftCaptureConfigValue() {
        // The tokens libghostty-vt interprets as "⇧ extends the selection" (the intent when shift-select is
        // ALLOWED). The default/soft form must be `false` — libghostty-vt's own default — so the factory neither
        // inverts the meaning NOR overrides the upstream default.
        let extendsSelectionTokens = Set(["false", "never"])
        // The tokens libghostty-vt interprets as "⇧ is sent to the running program" (selection NOT extended).
        let capturesTokens = Set(["true", "always"])

        // Default = ⇧ extends the selection, soft → libghostty-vt's own default `false`.
        XCTAssertEqual(
            MouseShiftCapture.enabled.configValue, "false",
            "the default (⇧ extends selection) must emit libghostty's `false` — the exact token whose docs say "
                + "the shift key is NOT sent to the program and extends the selection",
        )
        XCTAssertTrue(extendsSelectionTokens.contains(MouseShiftCapture.enabled.configValue))

        // Allow-shift OFF (soft) = ⇧ goes to the program → a capture token.
        XCTAssertEqual(MouseShiftCapture.disabled.configValue, "true")
        XCTAssertTrue(
            capturesTokens.contains(MouseShiftCapture.disabled.configValue),
            "with shift-select disabled, ⇧ must be sent to the program (a capture token), not extend selection",
        )

        // Hard forms: `.always` = ⇧ ALWAYS extends selection (program can't override) → libghostty-vt `never`;
        // `.never` = ⇧ NEVER extends selection / always forwarded to the program → libghostty-vt `always`.
        XCTAssertEqual(
            MouseShiftCapture.always.configValue, "never",
            "⇧ ALWAYS extends selection maps to libghostty `never` (extend-selection, program can't override)",
        )
        XCTAssertTrue(extendsSelectionTokens.contains(MouseShiftCapture.always.configValue))
        XCTAssertEqual(
            MouseShiftCapture.never.configValue, "always",
            "⇧ NEVER extends selection maps to libghostty `always` (sent to program, program can't override)",
        )
        XCTAssertTrue(capturesTokens.contains(MouseShiftCapture.never.configValue))

        // The factory terminal (default-constructed) keeps the shift-to-select escape hatch.
        XCTAssertEqual(
            TerminalControls().allowShiftClick.configValue, "false",
            "a factory TerminalControls must emit the shift-extends-selection token, not capture ⇧ to the program",
        )
    }

    /// `MouseShiftCapture.extendsSelection` is the binary projection a caller that only wants ON/OFF reads.
    /// It must map BOTH "⇧ extends selection" forms (soft `.enabled`, hard `.always`) to ON and BOTH "⇧ goes
    /// to the program" forms (soft `.disabled`, hard `.never`) to OFF, so the two HARD tokens read sanely
    /// instead of mis-projecting through a bare `== .enabled` check.
    func testMouseShiftCaptureExtendsSelectionProjection() {
        XCTAssertTrue(MouseShiftCapture.enabled.extendsSelection, "the soft default extends selection → ON")
        XCTAssertTrue(MouseShiftCapture.always.extendsSelection, "hard always-extend reads ON, not OFF")
        XCTAssertFalse(MouseShiftCapture.disabled.extendsSelection, "soft forward-to-program → OFF")
        XCTAssertFalse(MouseShiftCapture.never.extendsSelection, "hard never-extend reads OFF")
    }

    /// `OptionAsAlt`'s raw values are the kebab-readable tokens the file carries; `configValue` is the
    /// libghostty-vt `macos-option-as-alt` token (`false`/`true`/`left`/`right`) the config builder emits.
    /// The two axes DIFFER (`both` persists as `both`, emits `true`), so this is a real oracle, not a restate of
    /// the rawValue. The factory keeps OFF (Option composes accented characters by default).
    func testOptionAsAltRawValuesAndConfigValue() {
        XCTAssertEqual(OptionAsAlt.allCases.map(\.rawValue), ["off", "both", "left", "right"])
        XCTAssertEqual(OptionAsAlt.off.configValue, "false")
        XCTAssertEqual(OptionAsAlt.both.configValue, "true", "BOTH Option keys maps to libghostty `true`")
        XCTAssertEqual(OptionAsAlt.left.configValue, "left")
        XCTAssertEqual(OptionAsAlt.right.configValue, "right")
        // Validate-then-repair: an unknown / hostile token resolves to OFF (never traps).
        XCTAssertEqual(OptionAsAlt(rawValue: "both"), .both)
        XCTAssertEqual(OptionAsAlt(rawValue: "garbage"), .off)
        // The factory bundle keeps Option free for accented characters.
        XCTAssertEqual(TerminalControls().optionAsAlt, .off)
        XCTAssertEqual(TerminalControls().optionAsAlt.configValue, "false")
    }

    /// `from(config:)` reads `controls.option-as-alt`. Revert-to-fail: drop the `optionAsAlt:` read in the
    /// factory and the field stays `.off` instead of what the file says.
    func testFactoryReadsOptionAsAlt() {
        let config = AppConfig.compiledDefaults.setting("controls.option-as-alt", OptionAsAlt.left.rawValue)
        XCTAssertEqual(TerminalControls.from(config: config).optionAsAlt, .left)
    }

    // MARK: - OSC-52 read confirm decision

    /// The pure OSC-52 clipboard-READ resolution decision. The deleted fork's GUI-only
    /// `confirm_read_clipboard_cb` callback used to drive this. ``ClipboardAccess/silentClipboardRead(text:)``
    /// decides the SILENT (no-dialog) outcome: ``ClipboardAccess/allow`` hands the program the real
    /// clipboard text, ``ClipboardAccess/deny`` hands back EMPTY (a well-formed but empty OSC-52 reply —
    /// the clipboard is never leaked), and ``ClipboardAccess/ask`` returns `nil` (the embedder must
    /// prompt). Pinning it headlessly proves the no-leak deny contract — and that allow ≠ deny on the SAME
    /// input — without a `TerminalSurfaceDriver`.
    func testSilentClipboardReadResolvesAllowDenyAsk() {
        XCTAssertEqual(
            ClipboardAccess.allow.silentClipboardRead(text: "secret"), "secret",
            "allow hands the program the real clipboard text",
        )
        XCTAssertEqual(
            ClipboardAccess.deny.silentClipboardRead(text: "secret"), "",
            "deny replies EMPTY — the clipboard is never leaked",
        )
        XCTAssertNil(
            ClipboardAccess.ask.silentClipboardRead(text: "secret"),
            "ask defers to the confirmation sheet (nil = prompt the user)",
        )
    }

    // MARK: - Codable

    /// `TerminalControls` is `Codable` (it round-trips through JSON unchanged) — the pure-value contract the
    /// config builder + any future persistence rely on.
    func testCodableRoundTrip() throws {
        let original = TerminalControls(
            copyOnSelect: true,
            clipboardRead: .deny,
            allowShiftClick: .always,
            scrollMultiplier: 1.75,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalControls.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
