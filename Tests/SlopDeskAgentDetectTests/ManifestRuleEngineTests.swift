import XCTest
@testable import SlopDeskAgentDetect

/// Parity suite for the herdr detect-engine port: each test mirrors one upstream pin from
/// `src/detect/manifest/tests.rs` (fixtures carried verbatim), plus schema/limit rejections.
final class ManifestRuleEngineTests: XCTestCase {
    private func detect(
        _ agent: AgentKind,
        _ screen: String,
        title: String = "",
        progress: String = "",
    ) -> AgentScreenDetection {
        AgentManifestCatalog.detect(
            agent: agent,
            input: AgentDetectionInput(screen: screen, oscTitle: title, oscProgress: progress),
        )
    }

    private func compiled(_ rulesTOML: String) throws -> CompiledAgentManifest {
        let toml = "id = \"codex\"\n" + rulesTOML
        return try CompiledAgentManifest(manifest: AgentManifest.parse(toml: toml))
    }

    // MARK: Core semantics

    func testKnownAgentNoMatchDefaultsToIdleFallback() {
        let result = detect(.codex, "ordinary prompt text")
        XCTAssertEqual(result.state, .idle)
        XCTAssertFalse(result.visibleIdle)
        XCTAssertEqual(result.fallbackReason, AgentScreenDetection.knownAgentIdleFallbackReason)
    }

    func testRuleSemanticsApplyGatesPriorityAndLineRegex() throws {
        let manifest = try compiled(#"""
        [[rules]]
        id = "low_contains"
        state = "idle"
        priority = 1
        contains = ["match"]

        [[rules]]
        id = "high_nested_gates"
        state = "working"
        priority = 10
        contains = ["match"]
        all = [
          { any = [{ regex = ["w[io]n"] }, { contains = ["fallback"] }] },
        ]
        not = [
          { contains = ["blocked"] },
        ]

        [[rules]]
        id = "line_regex"
        state = "blocked"
        priority = 20
        line_regex = ["^exact line$"]
        """#)

        let high = manifest.evaluate(AgentDetectionInput(screen: "match win"))
        XCTAssertEqual(high.state, .working)
        XCTAssertEqual(high.matchedRuleID, "high_nested_gates")

        let notGate = manifest.evaluate(AgentDetectionInput(screen: "match win blocked"))
        XCTAssertEqual(notGate.state, .idle)
        XCTAssertEqual(notGate.matchedRuleID, "low_contains")

        let line = manifest.evaluate(AgentDetectionInput(screen: "before\nexact line\nafter"))
        XCTAssertEqual(line.state, .blocked)
        XCTAssertEqual(line.matchedRuleID, "line_regex")
    }

    func testPriorityTiesKeepTheFirstDeclaredRule() throws {
        let manifest = try compiled(#"""
        [[rules]]
        id = "first"
        state = "working"
        priority = 5
        contains = ["x"]

        [[rules]]
        id = "second"
        state = "blocked"
        priority = 5
        contains = ["x"]
        """#)
        let result = manifest.evaluate(AgentDetectionInput(screen: "x"))
        XCTAssertEqual(result.matchedRuleID, "first")
        XCTAssertEqual(result.state, .working)
    }

    func testAllBundledManifestsParseAndValidate() {
        for agent in AgentKind.screenManifestAgents {
            XCTAssertNotNil(AgentManifestCatalog.compiled[agent], "missing bundled manifest for \(agent.label)")
        }
        XCTAssertEqual(AgentManifestCatalog.compiled.count, 19)
    }

    func testNilAgentIsUnknownAndHookOnlyAgentsFallBackIdle() {
        XCTAssertEqual(
            AgentManifestCatalog.detect(agent: nil, input: AgentDetectionInput(screen: "anything")).state,
            .unknown,
        )
        XCTAssertEqual(detect(.omp, "anything").state, .idle)
    }

    // MARK: Validation rejections (herdr manifest_validation_* pins)

    private func assertRejected(_ toml: String, _ note: String, line: UInt = #line) {
        XCTAssertThrowsError(try AgentManifest.parse(toml: toml), note, line: line)
    }

    func testValidationRejectsUnknownFieldsEmptyRulesInvalidRegionsAndRegexes() {
        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "typo"
        state = "idle"
        contain = ["match"]
        """#, "typo'd field name")

        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "no_matchers"
        state = "idle"
        """#, "rule without matchers")

        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "bad_region"
        state = "idle"
        region = "bottom_recent"
        contains = ["x"]
        """#, "invalid region name")

        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "bad_regex"
        state = "idle"
        regex = ["["]
        """#, "invalid top-level regex")

        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "bad_nested"
        state = "idle"
        contains = ["x"]
        any = [{ line_regex = ["["] }]
        """#, "invalid nested line_regex")

        assertRejected(#"""
        id = "codex"
        rules = []
        """#, "no rules")
    }

    func testValidationKeepsSkipRulesNeutral() {
        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "skip_idle"
        state = "idle"
        skip_state_update = true
        contains = ["x"]
        """#, "skip with non-unknown state")

        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "skip_visible"
        state = "unknown"
        skip_state_update = true
        visible_blocker = true
        contains = ["x"]
        """#, "skip with a visible flag")
    }

    func testValidationRejectsExcessiveRuleCountDepthAndMatchers() {
        var tooManyRules = "id = \"codex\"\n"
        for index in 0...AgentManifest.maxRulesPerManifest {
            tooManyRules += "[[rules]]\nid = \"r\(index)\"\nstate = \"idle\"\ncontains = [\"x\"]\n"
        }
        assertRejected(tooManyRules, "129 rules")

        var nest = "{ contains = [\"x\"] }"
        for _ in 0..<AgentManifest.maxGateDepth + 1 {
            nest = "{ all = [\(nest)] }"
        }
        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "deep"
        state = "idle"
        all = [\#(nest)]
        """#, "9 levels of nesting")

        let needles = (0...AgentManifest.maxMatchersPerGate).map { "\"n\($0)\"" }
            .joined(separator: ", ")
        assertRejected(#"""
        id = "codex"
        [[rules]]
        id = "wide"
        state = "idle"
        contains = [\#(needles)]
        """#, "33 matchers in one gate")
    }

    func testTopNonEmptyLinesRequiresEngineThreeWhenDeclared() {
        assertRejected(#"""
        id = "codex"
        min_engine_version = 2
        [[rules]]
        id = "top"
        state = "idle"
        region = "top_non_empty_lines(2)"
        contains = ["x"]
        """#, "top_non_empty_lines below engine 3")

        XCTAssertNoThrow(try AgentManifest.parse(toml: #"""
        id = "codex"
        min_engine_version = 3
        [[rules]]
        id = "top"
        state = "idle"
        region = "top_non_empty_lines(2)"
        contains = ["x"]
        """#))
    }

    func testTopNonEmptyLinesRequiresACanonicalPositiveBoundedCount() {
        XCTAssertNotNil(ManifestRegion.parse("top_non_empty_lines(1)"))
        XCTAssertNotNil(ManifestRegion.parse("top_non_empty_lines(65535)"))
        XCTAssertNil(ManifestRegion.parse("top_non_empty_lines(0)"))
        XCTAssertNil(ManifestRegion.parse("top_non_empty_lines(01)"))
        XCTAssertNil(ManifestRegion.parse("top_non_empty_lines(+1)"))
        XCTAssertNil(ManifestRegion.parse("top_non_empty_lines(65536)"))
        XCTAssertNil(ManifestRegion.parse("top_non_empty_lines(999999999999999999999)"))
    }

    // MARK: Regions

    func testBottomNonEmptyLinesUsesBottomOccurrenceForRepeatedText() {
        let region = ManifestRegion.bottomNonEmptyLines(2)
        XCTAssertEqual(region.resolveScreen("marker\nold\n\nmiddle\nmarker\nnew\n"), "marker\nnew\n")
    }

    func testTopNonEmptyLinesUsesTopOccurrenceForRepeatedText() {
        let region = ManifestRegion.topNonEmptyLines(2)
        XCTAssertEqual(region.resolveScreen("\nmarker\nold\n\nmiddle\nmarker\nnew\n"), "\nmarker\nold\n")
    }

    func testBottomLinesKeepsBlankLinesAndSuffixBytes() {
        XCTAssertEqual(ManifestRegion.bottomLines(2).resolveScreen("a\nb\n\nc"), "\nc")
        XCTAssertEqual(ManifestRegion.bottomLines(10).resolveScreen("a\nb"), "a\nb")
    }

    func testAfterLastHorizontalRuleFallsBackToWholeContent() {
        XCTAssertEqual(ManifestRegion.afterLastHorizontalRule.resolveScreen("no rules here"), "no rules here")
        XCTAssertEqual(
            ManifestRegion.afterLastHorizontalRule.resolveScreen("above\n────────\nbelow\n"),
            "below\n",
        )
    }

    func testPromptBoxBodyNeedsTwoRules() {
        XCTAssertEqual(ManifestRegion.promptBoxBody.resolveScreen("────\nonly one rule\n"), "")
        XCTAssertEqual(
            ManifestRegion.promptBoxBody.resolveScreen("above\n────\n❯ type here\n────\n"),
            "❯ type here\n",
        )
    }

    func testHorizontalRulePermitsTrailingAnnotationOnLongRuns() {
        XCTAssertTrue(ManifestRegion.isHorizontalRule("────────"))
        XCTAssertTrue(ManifestRegion.isHorizontalRule("─── (bypass permissions on) ─"))
        XCTAssertFalse(ManifestRegion.isHorizontalRule("── tail"))
        XCTAssertFalse(ManifestRegion.isHorizontalRule("plain text"))
        XCTAssertFalse(ManifestRegion.isHorizontalRule(""))
    }

    // MARK: Claude (bundled manifest, herdr fixtures verbatim)

    func testClaudeOscTitleBraillePrefixIsWorking() {
        let result = detect(.claude, "", title: "⠂ project")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.matchedRuleID, "osc_title_working")
        XCTAssertTrue(result.visibleWorking)
    }

    func testClaudeOscTitleStaticPrefixIsIdle() {
        let result = detect(.claude, "", title: "✳ Claude Code")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.matchedRuleID, "osc_title_idle")
        XCTAssertTrue(result.visibleIdle)
    }

    func testClaudeOscProgress43AloneDoesNotForceWorking() {
        let result = detect(.claude, "", progress: "4;3;")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.fallbackReason, AgentScreenDetection.knownAgentIdleFallbackReason)
        XCTAssertFalse(result.visibleWorking)
    }

    func testClaudeBlockerScreenOutranksStaleOscProgress() {
        let screen = "──────────\n  1. Yes\n  2. No\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"
        let result = detect(.claude, screen, title: "✳ Task title", progress: "4;3;")
        XCTAssertEqual(result.state, .blocked)
        XCTAssertTrue(result.visibleBlocker)
    }

    func testClaudeOscProgress40IsIdle() {
        let result = detect(.claude, "", progress: "4;0;")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.matchedRuleID, "osc_progress_idle")
    }

    func testClaudeBlockerScreenOutranksOscIdleTitle() {
        let screen = "do you want to proceed?\nbash command: rm -rf /tmp/test\n"
            + "❯ 1. Yes\n   2. No\n\nEsc to cancel · Tab to amend · ctrl+e to explain\n"
        let result = detect(.claude, screen, title: "✳ Claude Code")
        XCTAssertEqual(result.state, .blocked)
        XCTAssertTrue(result.visibleBlocker)
    }

    func testClaudeEmptyOscEmptyScreenIsIdleFallback() {
        let result = detect(.claude, "")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.fallbackReason, AgentScreenDetection.knownAgentIdleFallbackReason)
        XCTAssertFalse(result.visibleIdle)
    }

    func testClaudeTranscriptViewerFreezes() {
        let screen = "showing detailed transcript\nctrl+o to toggle\n"
        let result = detect(.claude, screen)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.matchedRuleID, "transcript_viewer")
        XCTAssertTrue(result.skipStateUpdate)
        XCTAssertTrue(AgentManifestCatalog.shouldSkipStateUpdate(agent: .claude, screen: screen))
    }

    func testClaudeLivePromptBoxIsVisibleIdle() {
        let screen = "some output\n──────────\n❯ \n──────────\n? for shortcuts\n"
        let result = detect(.claude, screen)
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.matchedRuleID, "live_prompt_box")
        XCTAssertTrue(result.visibleIdle)
    }

    // MARK: Codex (bundled manifest, herdr fixtures verbatim)

    func testCodexOscTitleBrailleSpinnerIsWorking() {
        let result = detect(.codex, "", title: "⠋ llm-proxy")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.matchedRuleID, "osc_title_working")
        XCTAssertTrue(result.visibleWorking)
    }

    func testCodexOscTitleActionRequiredIsBlocked() {
        let result = detect(.codex, "", title: "[ . ] Action Required | llm-proxy")
        XCTAssertEqual(result.state, .blocked)
        XCTAssertEqual(result.matchedRuleID, "osc_title_blocked")
        XCTAssertTrue(result.visibleBlocker)
    }

    func testCodexOscTitlePlainIsIdle() {
        let result = detect(.codex, "", title: "llm-proxy")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.matchedRuleID, "osc_title_idle")
        XCTAssertTrue(result.visibleIdle)
    }

    func testCodexBackgroundTerminalScreenDoesNotOverrideOscIdle() {
        let screen = "background terminal running · /ps to view · /stop to close\n"
        let result = detect(.codex, screen, title: "llm-proxy")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.matchedRuleID, "osc_title_idle")
        XCTAssertTrue(result.visibleIdle)
    }

    func testCodexScreenWorkingFallbackHandlesStaticOscTitle() {
        let screen = "• I’ll run it and wait for completion.\n\n"
            + "◦ Working (1m 16s • esc to interrupt) · 1 background…\n\n"
            + "› Use /skills to list available skills\n\ngpt-5.6-sol default · /work\n"
        let result = detect(.codex, screen, title: "project")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.matchedRuleID, "screen_working_fallback")
        XCTAssertTrue(result.visibleWorking)
    }

    func testCodexOscWorkingRemainsPreferredOverScreenFallback() {
        let screen = "• Working (4s • esc to interrupt)\n\n"
            + "› Use /skills to list available skills\n\ngpt-5.6-sol default · /work\n"
        let result = detect(.codex, screen, title: "⠸ project")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.matchedRuleID, "osc_title_working")
        XCTAssertTrue(result.visibleWorking)
    }

    func testCodexScreenBlockerOutranksWorkingFallback() {
        let screen = "• Working (4s • esc to interrupt)\n"
            + "› 1. Yes, proceed\nPress enter to confirm or esc to cancel\n"
        let result = detect(.codex, screen, title: "project")
        XCTAssertEqual(result.state, .blocked)
        XCTAssertEqual(result.matchedRuleID, "live_strong_blocker")
        XCTAssertTrue(result.visibleBlocker)
        XCTAssertFalse(result.visibleWorking)
    }

    func testCodexWeakBlockerOutranksWorkingFallback() {
        let screen = "• Working (4s • esc to interrupt)\n"
            + "do you want to continue? [y/n]\n› Use /skills to list available skills\n"
        let result = detect(.codex, screen, title: "project")
        XCTAssertEqual(result.state, .blocked)
        XCTAssertEqual(result.matchedRuleID, "weak_blocker")
        XCTAssertFalse(result.visibleWorking)
    }

    func testCodexTranscriptViewerOutranksWorkingFallback() {
        let screen = "• Working (4s • esc to interrupt)\n› transcript\n"
            + "↑/↓ to scroll · pgup/pgdn to move · home/end to jump · q to quit · esc to edit prev\n"
        let result = detect(.codex, screen, title: "project")
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.matchedRuleID, "transcript_viewer")
        XCTAssertTrue(result.skipStateUpdate)
        XCTAssertFalse(result.visibleWorking)
    }

    func testCodexScreenWorkingFallbackIgnoresStaleAndPromptText() {
        let screens = [
            "◦ Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n"
                + "› Use /skills to list available skills\ngpt-5.6-sol default · /work\n",
            "› Explain the text ◦ Working (1m 16s • esc to interrupt)\ngpt-5.6-sol default · /work\n",
            "  ◦ Working (1m 16s • esc to interrupt)\n"
                + "› Use /skills to list available skills\ngpt-5.6-sol default · /work\n",
        ]
        for screen in screens {
            let result = detect(.codex, screen, title: "project")
            XCTAssertEqual(result.state, .idle, screen)
            XCTAssertEqual(result.matchedRuleID, "osc_title_idle", screen)
            XCTAssertTrue(result.visibleIdle, screen)
            XCTAssertFalse(result.visibleWorking, screen)
        }
    }

    func testCodexScreenWorkingFallbackIgnoresInterruptedShortTerminal() {
        let screen = "◦ Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n›\n"
        let result = detect(.codex, screen, title: "project")
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.matchedRuleID, "osc_title_idle")
        XCTAssertTrue(result.visibleIdle)
    }

    func testCodexOscWorkingBeatsWeakBlockerScreen() {
        let result = detect(.codex, "do you want to continue? [y/n]\n", title: "⠋ llm-proxy")
        XCTAssertEqual(result.state, .working)
        XCTAssertEqual(result.matchedRuleID, "osc_title_working")
    }
}
