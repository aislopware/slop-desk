// DraftCommitDebouncerTests — the draft→commit contract for free-text settings fields (stability audit).
//
// FINDING (FontSettingsView): every `$store.terminal.<stringField>` text binding wrote through
// `PreferencesStore.terminal`'s `didSet` on EVERY keystroke — JSON persist + `applyTerminal()` →
// `TerminalConfigBroadcaster.publish` → every live terminal reloads libghostty config + PTY-resizes, per
// character typed. The fix holds a local draft in `FontFamilyComboBox` and commits via
// ``DraftCommitDebouncer``. These tests pin BOTH shapes:
//   - the BASELINE (documentation): k store mutations ⇒ k broadcaster generation bumps — the per-keystroke
//     cost a write-through binding pays,
//   - the CONTRACT: k draft edits through the debouncer ⇒ exactly ONE commit after idle, whose value is the
//     FINAL text; submit/blur (`flush`) commits immediately and the pending idle commit never double-fires.

import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DraftCommitDebouncerTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "DraftCommitDebouncerTests." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeStore(_ name: String = #function) -> PreferencesStore {
        PreferencesStore(defaults: makeIsolatedDefaults(name), sidecarURL: nil)
    }

    override func tearDown() {
        // Restore the process-wide state the store's apply paths mutate (same discipline as
        // `PreferencesStoreApplyTests`) so a later test isn't polluted.
        EnvConfig.overlay = [:]
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    /// The keystroke burst a user typing "Fira Code" produces — 9 successive draft values.
    private static let typingBurst = [
        "F", "Fi", "Fir", "Fira", "Fira ", "Fira C", "Fira Co", "Fira Cod", "Fira Code",
    ]

    // MARK: - Baseline (documents the pre-fix per-keystroke shape)

    /// BASELINE: a write-through binding (the OLD `TextField(text: $store.terminal.fontFamily)` path)
    /// commits per mutation — 9 keystrokes ⇒ 9 broadcaster generation bumps (9 libghostty reloads + PTY
    /// resizes on every live terminal). This is the cost the draft-commit fix removes for free-text fields;
    /// it remains CORRECT for discrete controls (steppers / toggles / pickers), which stay write-through.
    func testWriteThroughStoreMutationBumpsGenerationPerKeystroke() {
        let store = makeStore()
        let before = TerminalConfigBroadcaster.shared.generation

        for draft in Self.typingBurst {
            store.terminal.fontFamily = draft // what a per-keystroke binding write does
        }

        XCTAssertEqual(
            TerminalConfigBroadcaster.shared.generation, before + Self.typingBurst.count,
            "write-through commits once per mutation — the per-keystroke reload the draft fix avoids",
        )
        XCTAssertEqual(store.terminal.fontFamily, "Fira Code")
    }

    // MARK: - Contract: one trailing commit per burst, final value wins

    /// CONTRACT: k draft edits scheduled through the debouncer collapse to exactly ONE store commit after
    /// idle (not k), and the committed value is the FINAL text. Asserted at the REAL seam — the
    /// `PreferencesStore.terminal` `didSet` → broadcaster generation, which must bump exactly once.
    func testBurstCollapsesToSingleTrailingCommitOfFinalValue() async {
        let store = makeStore()
        let debouncer = DraftCommitDebouncer(idle: .milliseconds(50))
        let before = TerminalConfigBroadcaster.shared.generation
        var commits = 0
        let committed = expectation(description: "one trailing commit")

        for draft in Self.typingBurst {
            // Mirrors `FontFamilyComboBox`'s `.onChange(of: draft)`: reschedule with the latest draft.
            debouncer.schedule {
                commits += 1
                store.terminal.fontFamily = draft
                committed.fulfill() // fulfills once — a double commit over-fulfills and FAILS the test
            }
        }
        XCTAssertEqual(commits, 0, "no commit before the idle pause elapses")

        await fulfillment(of: [committed], timeout: 5)
        // Give any (buggy) extra scheduled commits a chance to fire before asserting exactly-once.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(commits, 1, "k keystrokes produce exactly 1 commit after idle, not k")
        XCTAssertEqual(store.terminal.fontFamily, "Fira Code", "the committed value is the FINAL text")
        XCTAssertEqual(
            TerminalConfigBroadcaster.shared.generation, before + 1,
            "the store didSet → broadcaster publish fires exactly once per burst",
        )
    }

    // MARK: - Contract: flush (submit / blur) commits immediately, never double-fires

    /// CONTRACT: `flush` (the submit / focus-loss edge) commits synchronously AND cancels the pending idle
    /// commit — the same edit can never land twice.
    func testFlushCommitsImmediatelyAndCancelsThePendingIdleCommit() async {
        let debouncer = DraftCommitDebouncer(idle: .milliseconds(50))
        var commits = 0

        debouncer.schedule { commits += 1 } // the armed idle commit a blur must supersede
        debouncer.flush { commits += 1 }
        XCTAssertEqual(commits, 1, "flush commits synchronously (blur/submit is immediate)")

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(commits, 1, "the superseded idle commit never fires after flush")
    }

    /// CONTRACT: `cancel` disarms the pending idle commit without running it (external resync / discard).
    func testCancelDropsThePendingCommitWithoutRunningIt() async {
        let debouncer = DraftCommitDebouncer(idle: .milliseconds(50))
        var commits = 0

        debouncer.schedule { commits += 1 }
        debouncer.cancel()

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(commits, 0, "a cancelled idle commit never fires")
    }
}
