import SlopDeskTestSupport
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the control VOCABULARIES — the tokens a user types in `config.toml`, the non-failable repair
/// that lets a file written against a newer build survive, the four-way→two-way projection — and the
/// one rule that reads two of those rows TOGETHER: the clipboard master switch.
///
/// ## What left this file
///
/// It used to also pin `TerminalControls`, a sixteen-field bundle read out of `[controls]` in one
/// crossing, and the `configValue` spellings each enum carried beside its own. Both existed for the
/// terminal config-TEXT builder; nothing parses that text any more (docs/68), the bundle had no
/// reader left, and the tests that asserted the emitted spellings were asserting about a string
/// nobody writes. Every row the bundle carried is read at the point of use through ``SettingsKey``.
@MainActor
final class TerminalControlsTests: XCTestCase {
    // MARK: - Enum raw values + repair

    /// The control enums' raw values are the tokens the USER types in `config.toml`. A rename here
    /// silently invalidates a file someone already wrote → pinned.
    func testEnumRawValuesArePinned() {
        XCTAssertEqual(ClipboardAccess.allCases.map(\.rawValue), ["allow", "deny", "ask"])
        XCTAssertEqual(RightClickAction.contextMenu.rawValue, "context-menu")
        XCTAssertEqual(RightClickAction.copyOrPaste.rawValue, "copy-or-paste")
        XCTAssertEqual(
            MouseShiftCapture.allCases.map(\.rawValue),
            ["disabled", "enabled", "always", "never"],
        )
        XCTAssertEqual(OptionAsAlt.allCases.map(\.rawValue), ["off", "both", "left", "right"])
        XCTAssertEqual(
            ScrollPastLast.allCases.map(\.rawValue),
            ["disabled", "last-line-with-content", "last-line-in-middle", "cursor-line"],
        )
        XCTAssertEqual(
            ScrollPastFirst.allCases.map(\.rawValue),
            ["disabled", "same-as-last", "first-line-with-content", "first-line-in-middle"],
        )
    }

    /// ⚠️ THE TRAP THIS TEST EXISTS FOR. The two overscroll vocabularies share ONE delivery — four
    /// runs each, past-LAST first — so ``ScrollPastFirst``'s `rawValue` reads at an OFFSET into it.
    /// An off-by-four there is silent: every token is still a real token, just the wrong end's, and
    /// `same-as-last` would come back spelled `cursor-line`.
    func testTheTwoOverscrollVocabulariesDoNotReadEachOthersHalfOfTheDelivery() {
        for last in ScrollPastLast.allCases {
            XCTAssertEqual(ScrollPastLast(rawValue: last.rawValue), last, "\(last)")
        }
        for first in ScrollPastFirst.allCases {
            XCTAssertEqual(ScrollPastFirst(rawValue: first.rawValue), first, "\(first)")
        }
        // `disabled` is the one token both ends spell, and it is the only one they may share.
        let shared = Set(ScrollPastLast.allCases.map(\.rawValue))
            .intersection(ScrollPastFirst.allCases.map(\.rawValue))
        XCTAssertEqual(shared, ["disabled"])
    }

    /// The codes ``TerminalRendererSurface/setOverscroll(pastLast:pastFirst:smooth:)`` sends are each
    /// case's place in the far side's own `ALL` order, and both vocabularies count from zero — the
    /// shared delivery does NOT offset the second one's code the way it offsets its token.
    func testTheOverscrollCodesCountFromZeroAtBothEnds() {
        XCTAssertEqual(ScrollPastLast.allCases.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(ScrollPastFirst.allCases.map(\.index), [0, 1, 2, 3])
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
        XCTAssertEqual(OptionAsAlt(rawValue: "both"), .both)
        XCTAssertEqual(OptionAsAlt(rawValue: "garbage"), .off)
        XCTAssertEqual(ScrollPastLast(rawValue: "cursor-line"), .cursorLine)
        XCTAssertEqual(ScrollPastLast(rawValue: "garbage"), .disabled)
        XCTAssertEqual(ScrollPastFirst(rawValue: "same-as-last"), .sameAsLast)
        // A token from the OTHER end is not a token at this one, and repairs rather than crossing.
        XCTAssertEqual(ScrollPastFirst(rawValue: "cursor-line"), .disabled)
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

    /// `OptionAsAlt.surfaceCode` is the byte the renderer's door takes, and it is deliberately NOT a
    /// cast of the enum's table position — a door's wire byte that happened to agree with a token
    /// order would be two facts sharing one number until someone reordered the table.
    func testOptionAsAltSurfaceCodesArePinned() {
        XCTAssertEqual(OptionAsAlt.off.surfaceCode, 0)
        XCTAssertEqual(OptionAsAlt.both.surfaceCode, 1)
        XCTAssertEqual(OptionAsAlt.left.surfaceCode, 2)
        XCTAssertEqual(OptionAsAlt.right.surfaceCode, 3)
    }

    // MARK: - The clipboard master switch

    /// With `controls.clipboard-shell-controlled` ON (the default), each direction answers its own row.
    func testTheClipboardGatesAnswerTheirOwnRowsWhileTheMasterSwitchIsOn() {
        stateCompiledDefaults()
        XCTAssertEqual(SettingsKey.clipboardRead, .ask)
        XCTAssertEqual(SettingsKey.clipboardWrite, .allow)
        stateSetting("controls.clipboard-read", ClipboardAccess.allow.rawValue)
        stateSetting("controls.clipboard-write", ClipboardAccess.deny.rawValue)
        XCTAssertEqual(SettingsKey.clipboardRead, .allow)
        XCTAssertEqual(SettingsKey.clipboardWrite, .deny)
    }

    /// ⚠️ THE REGRESSION THIS TEST EXISTS FOR. The master switch used to be folded in by the deleted
    /// control bundle, which only the deleted config builder read, while the live OSC-52 path asked
    /// `SettingsKey.clipboardWrite` directly and never saw the switch. Both directions must go DENY,
    /// whatever their own row says — a master switch honoured in one direction and not the other is
    /// the failure the single crossing exists to rule out.
    func testTheMasterSwitchDeniesBothDirectionsWhateverTheirOwnRowsSay() {
        stateCompiledDefaults()
        stateSetting("controls.clipboard-read", ClipboardAccess.allow.rawValue)
        stateSetting("controls.clipboard-write", ClipboardAccess.allow.rawValue)
        stateSetting("controls.clipboard-shell-controlled", false)
        XCTAssertEqual(SettingsKey.clipboardRead, .deny)
        XCTAssertEqual(SettingsKey.clipboardWrite, .deny)
    }

    /// A hand-edited token no case spells repairs on the way through the gate rather than trapping.
    func testTheGatesRepairAnUnknownToken() {
        stateCompiledDefaults()
        stateSetting("controls.clipboard-read", "future-token")
        XCTAssertEqual(SettingsKey.clipboardRead, .ask, "an invalid clipboard-read token repairs to ask")
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
}
