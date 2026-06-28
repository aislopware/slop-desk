import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

// MARK: - SnippetAliasExpansionWiringTests (E16 ES-E16-4 — the live input-path wiring)

/// Pins that the at-prompt snippet-alias expander is WIRED into the real ``TerminalViewModel`` input path — the
/// gap the review flagged ("`SnippetAliasIndex.match` has zero production callers"). Drives the production
/// seams entirely in-memory (no NSEvent, no GhosttySurface, no window server — the hang-safety rule):
///   - `ingestOutput` feeds an OSC-133;A prompt mark → the expander's mirror is trusted,
///   - `sendInput` feeds the typed bytes → the expander mirrors the prompt line (the SAME seam the host sees),
///   - `expandSnippetAlias()` (the surface's Tab/Space actuator) sends the erase+inject bytes through that seam.
///
/// REVERT-TO-CONFIRM-FAIL: remove the `snippetExpander?.noteSent(...)` line from `sendInput` (the wiring) and
/// the mirror stays empty → `expandSnippetAlias()` returns false and forwards nothing → these assertions fail.
@MainActor
final class SnippetAliasExpansionWiringTests: XCTestCase {
    private static let gco = Snippet(name: "Checkout", body: "git checkout {{cursor}}", alias: "gco")
    private static let resolvedBody = Array("git checkout ".utf8)

    /// A model whose `snippetExpander` is wired exactly as ``WorkspaceStore/wireSnippetExpander(terminal:)``
    /// does — enabled, gated on the model's own `isAtShellPrompt`, resolving `gco` to its body. `inputSink`
    /// captures everything that reaches the host.
    private func makeModel() -> (TerminalViewModel, () -> [Data]) {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        model.inputSink = { sunk.append($0) }
        model.snippetExpander = SnippetAliasExpander(
            snippets: { [Self.gco] },
            isEnabled: { true },
            isAtPrompt: { [weak model] in model?.isAtShellPrompt ?? false },
            resolveBytes: { _ in Self.resolvedBody },
        )
        return (model, { sunk })
    }

    /// The OSC-133;A prompt mark (`ESC ] 133 ; A BEL`) the host emits at every shell prompt.
    private func promptMark() -> Data { Data("\u{1B}]133;A\u{07}".utf8) }

    /// The full live flow: prompt mark → type `gco` → Tab/Space actuator expands it in place. The last bytes the
    /// host sees are 3 DELs (erasing the echoed `gco`) then the resolved `git checkout ` body.
    func testTypedAliasExpandsThroughTheLiveInputPath() {
        let (model, sunk) = makeModel()

        model.ingestOutput(promptMark()) // OSC-133;A → expander trusts the empty line
        for ch in ["g", "c", "o"] { model.sendInput(Data(ch.utf8)) }

        XCTAssertTrue(model.expandSnippetAlias(), "a matching trailing alias at the prompt expands (swallows the key)")
        XCTAssertEqual(
            sunk().last,
            Data([0x7F, 0x7F, 0x7F] + Self.resolvedBody),
            "the host sees 3 DELs then the resolved body — the typed `gco` is replaced by `git checkout `",
        )
    }

    /// Without the OSC-133;A prompt mark the line is untrusted, so the actuator declines (returns false) and
    /// sends nothing extra — typing is never corrupted when shell integration is absent.
    func testNoPromptMarkMeansNoExpansion() {
        let (model, sunk) = makeModel()

        for ch in ["g", "c", "o"] { model.sendInput(Data(ch.utf8)) }
        let beforeCount = sunk().count

        XCTAssertFalse(model.expandSnippetAlias(), "no prompt mark → untrusted line → no expansion")
        XCTAssertEqual(sunk().count, beforeCount, "nothing extra is sent — the surface types the key normally")
    }

    /// A model with NO expander wired (headless / non-terminal) is a graceful no-op: `expandSnippetAlias()`
    /// returns false and the input path is unchanged.
    func testUnwiredModelIsANoOp() {
        let model = TerminalViewModel()
        var sunk: [Data] = []
        model.inputSink = { sunk.append($0) }

        model.ingestOutput(promptMark())
        for ch in ["g", "c", "o"] { model.sendInput(Data(ch.utf8)) }

        XCTAssertFalse(model.expandSnippetAlias(), "no expander → no-op false")
        XCTAssertEqual(sunk, [Data("g".utf8), Data("c".utf8), Data("o".utf8)], "only the typed bytes — unchanged")
    }
}
