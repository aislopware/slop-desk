import XCTest
@testable import SlopDeskAgentDetect

/// ⚠️ DIVERGES FROM herdr (2026-08-11). A nested gate may now carry its OWN `region`, so a rule can
/// veto on evidence that does not live where the rule looks. herdr has no such thing: there, a
/// `not` is always evaluated against the rule's region, which is why `live_prompt_box`'s five
/// footer needles were dead code — a dialog's footer sits below the last horizontal rule, outside
/// `prompt_box_body` by construction, so the veto never saw the thing it was written to stop.
///
/// This is the structural fix. It is not specific to that one rule, and it costs herdr parity for
/// the `claude` manifest only (`scripts/herdr-differential.py`).
final class ManifestCrossRegionGateTests: XCTestCase {
    private func compiled(_ rulesTOML: String) throws -> CompiledAgentManifest {
        try CompiledAgentManifest(manifest: AgentManifest.parse(toml: "id = \"codex\"\n" + rulesTOML))
    }

    // MARK: The capability

    /// A gate's region overrides the rule's, for that gate only — the rule keeps looking where it
    /// always looked, and its siblings are unaffected.
    func testANestedGateReadsItsOwnRegionNotTheRulesOne() throws {
        let manifest = try compiled(#"""
        [[rules]]
        id = "caret_unless_footer"
        state = "idle"
        priority = 100
        region = "prompt_box_body"
        line_regex = ['^\s*❯']
        not = [
          { region = "after_last_horizontal_rule", contains = ["esc to cancel"] },
        ]
        """#)

        let rule = String(repeating: "─", count: 20)
        // The caret is inside `prompt_box_body`; the footer is below the LAST rule, two regions away.
        let dialog = ["question?", rule, "❯ 1. yes", "  2. no", rule, "Esc to cancel"]
            .joined(separator: "\n")
        XCTAssertNil(
            manifest.evaluate(AgentDetectionInput(screen: dialog)).matchedRuleID,
            "the cross-region veto sees a footer the rule's own region cannot",
        )

        // Same caret, no footer anywhere — nothing to veto with, so the rule fires.
        let bare = ["done", rule, "❯ ", rule, "  ? for shortcuts"].joined(separator: "\n")
        XCTAssertEqual(manifest.evaluate(AgentDetectionInput(screen: bare)).matchedRuleID, "caret_unless_footer")
    }

    /// The same override on a POSITIVE gate, and nested one level deeper.
    func testACrossRegionGateAlsoWorksInsideAnyAndAll() throws {
        let manifest = try compiled(#"""
        [[rules]]
        id = "caret_with_footer"
        state = "blocked"
        priority = 100
        region = "prompt_box_body"
        line_regex = ['^\s*❯']
        all = [
          { any = [
            { region = "after_last_horizontal_rule", contains = ["esc to cancel"] },
            { region = "after_last_horizontal_rule", contains = ["enter to select"] },
          ] },
        ]
        """#)

        let rule = String(repeating: "─", count: 20)
        let dialog = ["q?", rule, "❯ 1. yes", rule, "Enter to select"].joined(separator: "\n")
        XCTAssertEqual(manifest.evaluate(AgentDetectionInput(screen: dialog)).matchedRuleID, "caret_with_footer")

        let elsewhere = ["Enter to select", rule, "❯ 1. yes", rule, "nothing here"].joined(separator: "\n")
        XCTAssertNil(
            manifest.evaluate(AgentDetectionInput(screen: elsewhere)).matchedRuleID,
            "the needle exists on screen but not in the gate's region — that is the whole point",
        )
    }

    // MARK: Validation

    func testABogusRegionOnANestedGateRejectsTheManifest() {
        for gate in ["any", "all", "not"] {
            XCTAssertThrowsError(
                try compiled(#"""
                [[rules]]
                id = "bad_nested_region"
                state = "idle"
                contains = ["x"]
                \#(gate) = [{ region = "bottom_recent", contains = ["y"] }]
                """#),
                "a nested \(gate) gate must validate its region like a rule does",
            )
        }
    }

    // MARK: The bundled claude manifest, which is why this exists

    /// The reported bug's screen: an `AskUserQuestion` dialog. Whole or torn, it must never read as
    /// an idle prompt box — the one verdict strong enough to lower a hand nobody lowered.
    func testTheClaudeDialogNeverReadsAsAnIdlePromptBox() {
        let rule = String(repeating: "─", count: 60)
        let body = [
            "  Reading docs/46-gates-env-paths.md",
            rule,
            "←  ☐ Next step  ☐ Language  ✔ Submit  →",
            "What should I do next in this repo?",
            "❯ 1. Run make test-touched",
            "  2. Review the current diff",
            "  3. Type something.",
            rule,
            "  4. Chat about this",
            "",
        ]

        // Whole: the footer is present, and the cross-region veto is what stops the caret.
        let whole = AgentManifestCatalog.detect(
            agent: .claude,
            input: AgentDetectionInput(
                screen: (body + ["Enter to select · Tab/Arrow keys to navigate · Esc to cancel"])
                    .joined(separator: "\n"),
            ),
        )
        XCTAssertEqual(whole.state, .blocked)
        XCTAssertEqual(whole.matchedRuleID, "live_blocked_form")

        // Torn: the repaint erased the footer before rewriting it, so the cross-region veto has
        // nothing left to find — the OPTION LIST veto is what covers this one.
        let torn = AgentManifestCatalog.detect(
            agent: .claude,
            input: AgentDetectionInput(screen: body.joined(separator: "\n")),
        )
        XCTAssertNotEqual(torn.matchedRuleID, "live_prompt_box")
        XCTAssertFalse(torn.visibleIdle)
    }

    /// ⚠️ DIVERGES FROM herdr (2026-08-11). Upstream omits `visible_blocker` on
    /// `legacy_no_prompt_blocker` — alone among its blocked rules. A pane blocked through THAT rule
    /// therefore carried a different visibility than one blocked through any other, so a screen
    /// that alternated between them flipped the flag and published a type-27 saying something had
    /// changed when only the matching rule had. It also cost the 800 ms stable-blocker refresh.
    /// A blocker the human can see is a visible blocker; every blocked rule now agrees.
    func testEveryBlockedRuleInTheClaudeManifestIsAVisibleBlocker() throws {
        let manifest = try XCTUnwrap(AgentManifestCatalog.compiled[.claude])
        let inconsistent = manifest.manifest.rules
            .filter { $0.state == .blocked && !$0.visibleBlocker }
            .map(\.id)
        XCTAssertEqual(inconsistent, [], "a blocked rule that is not a visible blocker flaps the flag")
    }

    // MARK: The key itself — declared, scoped, and honoured

    /// A gate region is an ENGINE-3 key. An engine that predates it ignores the key silently, and
    /// silently ignoring a VETO is how a rule fires on the screen it was written to skip — so a
    /// manifest that uses one must declare an engine that honours it. (`claude` does; the guard is
    /// what keeps the next manifest honest.)
    func testAGateRegionRequiresAnEngineThatHonoursIt() throws {
        let body = """
        id = "probe"
        version = "1"
        min_engine_version = %@
        [[rules]]
        id = "r"
        state = "blocked"
        region = "prompt_box_body"
        contains = ["needle"]
        not = [
          { region = "after_last_horizontal_rule", contains = ["esc to cancel"] },
        ]
        """
        XCTAssertThrowsError(try AgentManifest.parse(toml: String(format: body, "2"))) { error in
            let message = (error as? AgentManifest.ValidationError)?.message ?? ""
            XCTAssertTrue(message.contains("gate region"), "unexpected: \(message)")
        }
        XCTAssertNoThrow(try AgentManifest.parse(toml: String(format: body, "3")))
        // …and with no declared floor at all the manifest takes the running engine, as before.
        XCTAssertNoThrow(
            try AgentManifest.parse(
                toml: String(format: body, "3").replacingOccurrences(
                    of: "min_engine_version = 3\n", with: "",
                ),
            ),
        )
    }

    /// A RULE's `region` belongs to the rule. Copying it onto the rule's root gate as an
    /// "override" changes no verdict, but it re-resolves the region text on every evaluation and
    /// makes every rule in every manifest look like it uses the cross-region feature.
    func testARuleRegionIsNotCopiedOntoItsRootGate() throws {
        let manifest = try AgentManifest.parse(toml: """
        id = "probe"
        version = "1"
        [[rules]]
        id = "r"
        state = "idle"
        region = "prompt_box_body"
        contains = ["needle"]
        """)
        XCTAssertEqual(manifest.rules.first?.region, "prompt_box_body")
        XCTAssertNil(manifest.rules.first?.gate.region, "the root gate inherits; it does not override")
    }

    /// …and the rule it vetoes still fires for the thing it was written for. A human typing at a
    /// real prompt box is `visible_idle`, which is what drives the settled-idle mark.
    func testARealIdlePromptBoxIsStillAVisibleIdle() {
        let rule = String(repeating: "─", count: 60)
        for typed in ["", "make test", "1. this looks like an option but is not"] {
            let screen = ["  Done.", rule, "❯ \(typed)", rule, "  ? for shortcuts", ""]
                .joined(separator: "\n")
            let result = AgentManifestCatalog.detect(
                agent: .claude,
                input: AgentDetectionInput(screen: screen),
            )
            XCTAssertEqual(result.state, .idle, "typed: \(typed)")
            XCTAssertTrue(result.visibleIdle, "typed: \(typed)")
            XCTAssertEqual(result.matchedRuleID, "live_prompt_box", "typed: \(typed)")
        }
    }
}
