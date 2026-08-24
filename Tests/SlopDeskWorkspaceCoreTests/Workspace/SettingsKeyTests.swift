// `SettingsKey`, after the settings GUI came out.
//
// What this file used to pin is gone with the thing it pinned. There were ~90 `<name>Key` string
// constants here, each asserted equal to a literal, because a rename silently orphaned a user's
// `UserDefaults` entry and the app read the default instead. There is no `UserDefaults` entry to
// orphan any more: a setting is a PATH in `config.toml`, the reader typed it, and the equivalent
// break is a path the table stops declaring — which is not a Swift question. That one is answered
// in `slopdesk-invariants`, which can read both the accessors here and the table in
// `slopdesk-settings`; a test in this process could only restate the literals it is checking.
//
// So what is left is what a Swift test is the right place for: that each accessor READS the file
// rather than a compiled-in constant, that the ones with a fixed set of tokens repair a token the
// file does not name, that the four composite readings fold their parts in the right order, and
// that the four survivors in `Defaults` are STATE — things the app learned, which it still writes.
//
// Hang-safe: pure reads off a stated ``AppConfig``, no daemons, no sockets, no disk.

import Defaults
import SlopDeskTestSupport
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class SettingsKeyTests: XCTestCase {
    // MARK: - Every accessor reads the FILE

    /// A flag the file sets is the flag the accessor answers, both ways — the property that makes
    /// the whole surface a projection rather than a copy. One row per family, because the families
    /// are what a table rename would split.
    func testAFlagTheFileSetsIsTheFlagTheAccessorAnswers() {
        for state in [true, false] {
            stateSetting("general.redact-secrets", state)
            stateSetting("notifications.osc", state)
            stateSetting("badges.agent-complete", state)
            stateSetting("controls.copy-on-select", state)
            stateSetting("controls.link-detection", state)

            XCTAssertEqual(SettingsKey.redactSecretsEnabled, state)
            XCTAssertEqual(SettingsKey.oscNotificationsEnabled, state)
            XCTAssertEqual(SettingsKey.agentBadgeWhenCompleteEnabled, state)
            XCTAssertEqual(SettingsKey.copyOnSelectEnabled, state)
            XCTAssertEqual(SettingsKey.linkDetectionEnabled, state)
        }
    }

    /// The numbers, likewise. The window geometry is four ints the table declares separately and a
    /// transposition between them would be invisible in any single-row check.
    func testTheNumbersComeOffTheirOwnRows() {
        stateSetting("window.cols", 132)
        stateSetting("window.rows", 43)
        stateSetting("window.width-px", 1600)
        stateSetting("window.height-px", 900)
        stateSetting("controls.scroll-multiplier", 2.5)
        stateSetting("badges.busy-delay-seconds", 0.0)

        XCTAssertEqual(SettingsKey.windowCols, 132)
        XCTAssertEqual(SettingsKey.windowRows, 43)
        XCTAssertEqual(SettingsKey.windowWidthPx, 1600)
        XCTAssertEqual(SettingsKey.windowHeightPx, 900)
        XCTAssertEqual(SettingsKey.scrollMultiplierValue, 2.5)
        XCTAssertEqual(SettingsKey.tabBadgeBusyDelaySecondsValue, 0, "0 is a chosen value, not 'unset'")
    }

    func testTheTextRowsComeOffTheirOwnRows() {
        stateSetting("appearance.density", "compact")
        XCTAssertEqual(SettingsKey.density, "compact")
    }

    // MARK: - A token the file does not name

    /// A hand-edited file is UNTRUSTED text, and every enum-valued row is one typo from a token no
    /// case has. Each repairs to its own declared default rather than trapping or answering the
    /// first case — the app must start on a file with a typo in it, and start behaving the way a
    /// file without that row behaves.
    func testAnUnknownTokenRepairsToTheDeclaredDefault() {
        // The shipped answers, read through the SAME accessors, so a rename of a default token in
        // the table cannot make this test pass by restating the old one.
        stateCompiledDefaults()
        let shipped = (
            newTabPosition: SettingsKey.newTabPosition,
            autoHideTabsPanel: SettingsKey.autoHideTabsPanel,
            windowSize: SettingsKey.windowSize,
        )

        stateSetting("general.on-launch", "no-such-token")
        stateSetting("shell.new-tab-position", "no-such-token")
        stateSetting("shell.auto-hide-tabs-panel", "no-such-token")
        stateSetting("shell.close-confirm-window", "no-such-token")
        stateSetting("window.size", "no-such-token")
        stateSetting("controls.option-as-alt", "no-such-token")
        stateSetting("controls.link-cmd-click", "no-such-token")
        stateSetting("controls.auto-detect-link-schemes", "no-such-token")

        XCTAssertEqual(SettingsKey.onLaunch, .restoreLastSession)
        XCTAssertEqual(SettingsKey.newTabPosition, shipped.newTabPosition)
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, shipped.autoHideTabsPanel)
        XCTAssertEqual(SettingsKey.closeConfirmWindow, .process)
        XCTAssertEqual(SettingsKey.windowSize, shipped.windowSize)
        XCTAssertEqual(SettingsKey.optionAsAlt, .off)
        XCTAssertEqual(SettingsKey.linkCmdClick, .open)
        XCTAssertEqual(SettingsKey.autoDetectLinkSchemes, .all)
    }

    /// And a token the file DOES name is honoured — otherwise the repair above would pass on an
    /// accessor that ignored the file entirely.
    func testATokenTheFileNamesIsHonoured() {
        stateSetting("general.on-launch", "new-window")
        stateSetting("shell.auto-hide-tabs-panel", "always")
        stateSetting("controls.option-as-alt", "left")

        XCTAssertEqual(SettingsKey.onLaunch, .newWindow)
        XCTAssertEqual(SettingsKey.autoHideTabsPanel, .always)
        XCTAssertEqual(SettingsKey.optionAsAlt, .left)
    }

    // MARK: - The composite readings

    /// ``SettingsKey/notificationSettings`` is the ONE seam the poster reads, so a part folded into
    /// the wrong field would silence the wrong event. Each part is stated to a DISTINCT value so no
    /// two fields can be swapped without the assertion noticing.
    func testTheNotificationSeamFoldsEveryPartIntoItsOwnField() {
        stateSetting("notifications.osc", true)
        stateSetting("notifications.on-finish", false)
        stateSetting("notifications.on-error", true)
        stateSetting("notifications.on-watch-finish", false)
        stateSetting("notifications.while-foreground", "off")
        stateSetting("notifications.agent-task-complete", true)
        stateSetting("notifications.agent-await-input", false)

        let settings = SettingsKey.notificationSettings
        XCTAssertTrue(settings.appNotificationsEnabled)
        XCTAssertFalse(settings.notifyOnFinish)
        XCTAssertTrue(settings.notifyOnError)
        XCTAssertFalse(settings.notifyOnWatchFinish)
        XCTAssertEqual(settings.notifyWhileForeground, .off)
        XCTAssertTrue(settings.agentNotifyTaskComplete)
        XCTAssertFalse(settings.agentNotifyAwaitInput)
    }

    /// The two badge seams are SEPARATE gates over the same three shapes — an agent's spinner and a
    /// command's are chosen independently, and folding one set into the other would silence a badge
    /// the reader never turned off. Stated in opposition so a crossed wire is visible.
    func testTheAgentAndCommandBadgeGatesAreSeparate() {
        stateSetting("badges.agent-processing", true)
        stateSetting("badges.agent-complete", false)
        stateSetting("badges.agent-awaiting-input", true)
        stateSetting("badges.command-finish", false)
        stateSetting("badges.command-fail", true)
        stateSetting("badges.command-await-input", false)

        XCTAssertEqual(
            SettingsKey.agentBadgeGates,
            AgentBadgeGates(badgeWhileProcessing: true, badgeWhenComplete: false, badgeWhenAwaitingInput: true),
        )
        XCTAssertEqual(
            SettingsKey.commandBadgeGates,
            CommandBadgeGates(whenCommandFinishes: false, whenCommandFails: true, whenCommandAwaitsInput: false),
        )
    }

    /// The link-scheme policy is a MODE plus a list, and the list is only read in one of the two
    /// modes. A policy that carried the custom list while the mode said `all` would underline a
    /// scheme the reader restricted away, and one that dropped it in `custom` mode would underline
    /// nothing at all.
    func testTheSchemePolicyReadsTheListOnlyInCustomMode() {
        stateSetting("controls.custom-link-schemes", ["ssh", "slack"])

        stateSetting("controls.auto-detect-link-schemes", "all")
        XCTAssertEqual(SettingsKey.linkSchemePolicy, .all, "the list is present and deliberately unread")

        stateSetting("controls.auto-detect-link-schemes", "custom")
        XCTAssertEqual(SettingsKey.linkSchemePolicy, .custom(["ssh", "slack"]))
    }

    /// Hint patterns are TWO parallel lists in the file — the regexes and their actions — because a
    /// TOML array of tables would make the common case (a pattern with no action) noisier to write
    /// than the whole feature is worth. The zip is therefore this side's, and it has three cases
    /// only a test states: a pair, a pattern whose action is missing entirely, and a pattern whose
    /// action is present but empty. An empty PATTERN is dropped — it would match everything.
    func testTheHintPatternsZipTheirTwoLists() {
        stateSetting("controls.hint-patterns", ["ERR-\\d+", "", "TODO", "FIXME"])
        stateSetting("controls.hint-pattern-actions", ["open", "open", ""])

        XCTAssertEqual(
            SettingsKey.hintPatternList,
            [
                HintPattern(regex: "ERR-\\d+", action: "open"),
                HintPattern(regex: "TODO", action: nil),
                HintPattern(regex: "FIXME", action: nil),
            ],
            "an empty pattern is dropped; an empty or absent action is nil, and the pairing survives it",
        )
    }

    func testNoHintPatternsIsAnEmptyList() {
        stateCompiledDefaults()
        XCTAssertTrue(SettingsKey.hintPatternList.isEmpty)
    }

    // MARK: - The four survivors in `Defaults`

    /// The line between the two stores, stated once. A `config.toml` path is something the reader
    /// CHOSE and the app never writes; a `Defaults` key is something the app LEARNED and only the
    /// app writes. These four are the whole of the second list — and `savedWindowFrame` is the only
    /// settable accessor left in the file, which is what makes the rest a pure projection.
    func testTheStateKeysAreTheFourTheAppWrites() {
        XCTAssertEqual(
            [
                SettingsKey.codeSidebarCollapsedKey,
                SettingsKey.codeSidebarWidthKey,
                SettingsKey.openedCodeProjectsKey,
                SettingsKey.windowSavedFrameKey,
            ],
            ["shell.codeSidebarCollapsed", "shell.codeSidebarWidth", "shell.openedCodeProjects", "window.savedFrame"],
        )
        for key in [
            SettingsKey.codeSidebarCollapsedKey,
            SettingsKey.codeSidebarWidthKey,
            SettingsKey.openedCodeProjectsKey,
            SettingsKey.windowSavedFrameKey,
        ] {
            XCTAssertFalse(
                AppConfig.compiledDefaults.declaredPaths.contains(key),
                "\(key) is state the app writes — a config path would invite the reader to set it",
            )
        }
    }

    func testTheWindowFrameRoundTripsThroughTheStateStore() {
        let before = SettingsKey.savedWindowFrame
        addTeardownBlock { @MainActor in SettingsKey.savedWindowFrame = before }

        SettingsKey.savedWindowFrame = "120 340 1280 800 0 0 2560 1415 "
        XCTAssertEqual(SettingsKey.savedWindowFrame, "120 340 1280 800 0 0 2560 1415 ")
    }

    /// A fresh install hides the code panel and has opened nothing — the defaults a first launch
    /// runs on now that there is no onboarding to set them.
    func testTheStateDefaultsAreAFreshInstall() {
        let suite = SettingsKey.store
        for key in [SettingsKey.codeSidebarCollapsedKey, SettingsKey.openedCodeProjectsKey] {
            suite.removeObject(forKey: key)
        }
        XCTAssertTrue(Defaults[.codeSidebarCollapsed])
        XCTAssertTrue(Defaults[.openedCodeProjects].isEmpty)
    }

    // MARK: - The test suite itself

    /// Every state key binds the SAME suite, and under XCTest that suite is a per-process one — so a
    /// test that writes state cannot leave it in the developer's own domain. The env override is
    /// what an automation run sets to get the same isolation outside XCTest.
    func testTheStateStoreIsAPerProcessSuiteUnderTest() {
        XCTAssertNotEqual(SettingsKey.store, .standard)
        XCTAssertEqual(
            SettingsKey.suiteName(testProcessSuite: "under.xctest", environment: [:]),
            "under.xctest",
            "the XCTest suite wins outright — an automation env var must not redirect a test's writes",
        )
        XCTAssertEqual(
            SettingsKey.suiteName(
                testProcessSuite: nil, environment: [SettingsKey.defaultsSuiteEnvKey: "run.42"],
            ),
            "run.42",
        )
        XCTAssertNil(
            SettingsKey.suiteName(testProcessSuite: nil, environment: [SettingsKey.defaultsSuiteEnvKey: ""]),
            "an empty override is no override — `.standard`, not a suite named the empty string",
        )
        XCTAssertNil(SettingsKey.suiteName(testProcessSuite: nil, environment: [:]))
    }
}
