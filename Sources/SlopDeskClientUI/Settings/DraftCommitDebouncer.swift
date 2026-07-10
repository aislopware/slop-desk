// DraftCommitDebouncer — draft→commit debouncing for free-text settings fields (stability audit).
//
// WHY: a store-backed `TextField` bound straight to `$store.terminal.<stringField>` writes through the
// model's `didSet` on EVERY keystroke — `persistTerminal()` (JSONEncoder + UserDefaults) plus
// `applyTerminal()` → `TerminalConfigBroadcaster.publish` → every live `GhosttyTerminalView` reloads the
// libghostty config and re-measures/resizes the PTY grid, per character typed. Free-text fields instead
// hold a LOCAL draft and commit through this helper:
//   - once after a short idle pause (live preview still works — one trailing commit per typing burst),
//   - immediately on submit / focus loss (`flush`).
// Discrete controls (steppers / toggles / pickers / sliders) stay write-through — each change is intentional.
//
// CONTRACT (pinned by `DraftCommitDebouncerTests`): typing k characters produces at most ONE commit after
// idle (not k), the committed value is the FINAL text, and `flush` commits immediately while cancelling any
// pending idle commit so it can never double-fire.

import Foundation

/// A tiny trailing-edge debouncer for draft-backed text fields: `schedule` (re)arms a one-shot idle commit
/// (each call resets the timer, so a burst of keystrokes yields exactly one trailing commit of the LAST
/// scheduled closure); `flush` commits NOW and disarms; `cancel` disarms without committing.
@preconcurrency
@MainActor
final class DraftCommitDebouncer {
    /// The armed one-shot idle commit (nil ⇒ nothing pending).
    private var pending: Task<Void, Never>?
    /// The idle pause before a scheduled commit fires. Injected so tests run on a short deterministic clock.
    private let idle: Duration

    init(idle: Duration = .milliseconds(500)) {
        self.idle = idle
    }

    /// (Re)schedule `commit` to run once after the idle pause. Each call CANCELS the previously scheduled
    /// commit, so only the latest closure (capturing the latest draft) ever fires.
    func schedule(_ commit: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { [idle] in
            do {
                try await Task.sleep(for: idle)
            } catch {
                return // cancelled — a newer schedule / flush / cancel superseded this commit
            }
            commit()
        }
    }

    /// Run `commit` immediately (submit / focus loss / teardown), cancelling any pending idle commit so the
    /// same edit can never commit twice.
    func flush(_ commit: @MainActor () -> Void) {
        cancel()
        commit()
    }

    /// Drop any pending commit without running it (external resync / discard).
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
