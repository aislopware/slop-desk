import Foundation

// MARK: - RecipeReplayMode (`Command Replay` setting)

/// How a recipe's captured commands are replayed on open. Two independent settings pick a mode: one for
/// internally-saved recipes (default ``auto``) and one for externally-opened `.ottyrecipe` files (default
/// ``askOnce``) — see `SettingsKey`/`Defaults`. Raw `String` values back the `Defaults` serialization.
public enum RecipeReplayMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// All commands run automatically in sequence.
    case auto
    /// Commands are shown; one Enter runs all.
    case askOnce
    /// Commands are fed one at a time; Enter for each.
    case manually
    /// The layout opens; no commands execute.
    case skip

    /// The label shown in the Settings → Recipes → Command Replay dropdowns.
    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .askOnce: "Ask Once"
        case .manually: "Manually"
        case .skip: "Skip"
        }
    }
}

// MARK: - RecipeReplayMachine (pure replay state machine + shell-handoff pause)

/// The pure state machine that sequences a recipe's captured commands into the focused pane, honoring the
/// four ``RecipeReplayMode``s and the shell-handoff pause.
///
/// It is **I/O-free**: it owns the command queue and emits "inject these commands now" intents (an ordered
/// `[String]` returned from each transition); the store (`WorkspaceStore+Recipes`, WI-9) performs the actual
/// injection via the existing verbatim terminal seam and feeds prompt-return / Enter signals back in. Value
/// type (`mutating` transitions) so it is trivially testable headlessly.
///
/// **Mode behavior** (spec replay-mode table):
/// - ``RecipeReplayMode/auto`` — `start()` injects the queue in sequence, stopping after an interactive
///   command (``InteractiveCommandMatcher``) until ``noteReturnedToPrompt()`` or ``confirm()``.
/// - ``RecipeReplayMode/askOnce`` — `start()` shows the commands (awaits confirmation); the first
///   ``confirm()`` runs them all (with the same handoff pause).
/// - ``RecipeReplayMode/manually`` — each ``confirm()`` feeds exactly ONE command.
/// - ``RecipeReplayMode/skip`` — nothing is ever injected.
///
/// **Shell-handoff pause:** after injecting a command the matcher deems interactive (`ssh`, `tmux attach`,
/// `docker exec -it`, …), an Auto / Ask-Once run PAUSES (``State/paused``) so the queued commands are NOT
/// fed into the inner shell; it resumes on the local prompt-return edge (``noteReturnedToPrompt()``) or a
/// manual continue (``confirm()``). This pause is THE reason the matcher exists — without it, the command
/// after an `ssh` would inject straight into the remote session.
///
/// **Wire posture:** 100% client-side — nothing here touches the wire / golden corpus.
public struct RecipeReplayMachine: Sendable {
    // MARK: State

    /// Why the machine is paused mid-run.
    public enum PauseReason: Sendable, Equatable {
        /// Paused right after injecting an interactive command (carries that command, for the UI).
        case interactiveCommand(String)
        /// Paused by an explicit ``RecipeReplayMachine/pause(reason:)`` (user / store request).
        case manual
    }

    /// The machine's lifecycle state.
    public enum State: Sendable, Equatable {
        /// Not started yet.
        case idle
        /// Waiting for the user's Enter (Ask-Once before the first run, Manually before each command).
        case awaitingConfirmation
        /// Actively draining the queue (transient — a synchronous drain ends in `paused` or `finished`).
        case running
        /// Paused mid-run — see ``PauseReason``.
        case paused(PauseReason)
        /// The queue is fully injected.
        case finished
    }

    // MARK: Stored

    /// The replay mode in effect.
    public let mode: RecipeReplayMode
    /// The full ordered command queue (also the list shown to the user in Ask-Once / the trust prompt).
    public let commands: [String]

    private let matcher: InteractiveCommandMatcher
    /// Current lifecycle state.
    public private(set) var state: State
    /// The commands injected so far, in order (cumulative log — drives tests + the replay HUD).
    public private(set) var injected: [String]
    /// Index of the next command to inject.
    private var index: Int

    public init(
        mode: RecipeReplayMode,
        commands: [String],
        matcher: InteractiveCommandMatcher = .default,
    ) {
        self.mode = mode
        self.commands = commands
        self.matcher = matcher
        state = .idle
        injected = []
        index = 0
    }

    // MARK: Derived

    /// `true` once the whole queue has been injected.
    public var isFinished: Bool { state == .finished }

    /// The commands not yet injected, in order.
    public var pendingCommands: [String] {
        guard index < commands.count else { return [] }
        return Array(commands[index...])
    }

    // MARK: Transitions

    /// Begin replay. Returns the commands to inject immediately (Auto runs until the first interactive
    /// command; Ask-Once / Manually inject nothing yet and await ``confirm()``; Skip injects nothing ever).
    @discardableResult
    public mutating func start() -> [String] {
        guard state == .idle else { return [] }
        switch mode {
        case .skip:
            state = .finished
            return []
        case .auto:
            return drain()
        case .askOnce,
             .manually:
            if commands.isEmpty {
                state = .finished
                return []
            }
            state = .awaitingConfirmation
            return []
        }
    }

    /// The user pressed Enter. In Ask-Once it runs the whole queue (first confirm); in Manually it feeds the
    /// next single command; while ``State/paused`` (either reason) it is the "manual continue" that resumes.
    /// Returns the commands injected by this confirm.
    @discardableResult
    public mutating func confirm() -> [String] {
        switch state {
        case .awaitingConfirmation:
            switch mode {
            case .askOnce:
                drain()
            case .manually:
                injectOne()
            case .auto,
                 .skip:
                []
            }
        case .paused:
            resumeFromPause()
        case .idle,
             .running,
             .finished:
            []
        }
    }

    /// The inner shell returned to a local prompt (the OSC-133;A edge after a handoff). Resumes ONLY an
    /// interactive-command pause; a manual pause and every other state are no-ops (an ordinary command's
    /// prompt-return needs no machine action — Auto already ran ahead to the next gate).
    @discardableResult
    public mutating func noteReturnedToPrompt() -> [String] {
        if case .paused(.interactiveCommand) = state {
            return resumeFromPause()
        }
        return []
    }

    /// Explicitly pause an active run (store / user request). No-op once finished or idle.
    public mutating func pause(reason: PauseReason = .manual) {
        switch state {
        case .running,
             .awaitingConfirmation:
            state = .paused(reason)
        case .idle,
             .paused,
             .finished:
            break
        }
    }

    // MARK: Drain core

    /// Inject from ``index`` forward until the queue empties or an interactive command is injected (after
    /// which we PAUSE so the next command is not fed into the handoff). Used by Auto and by an Ask-Once run.
    private mutating func drain() -> [String] {
        state = .running
        var out: [String] = []
        while index < commands.count {
            let command = commands[index]
            out.append(command)
            injected.append(command)
            index += 1
            if matcher.isInteractive(command) {
                state = .paused(.interactiveCommand(command))
                return out
            }
        }
        state = .finished
        return out
    }

    /// Inject exactly one command (Manually). Awaits the next confirm if more remain, else finishes.
    private mutating func injectOne() -> [String] {
        guard index < commands.count else {
            state = .finished
            return []
        }
        let command = commands[index]
        injected.append(command)
        index += 1
        state = index < commands.count ? .awaitingConfirmation : .finished
        return [command]
    }

    /// Resume after a pause: Auto / Ask-Once continue draining the queue; Manually returns to awaiting the
    /// next per-command confirm; Skip finishes.
    private mutating func resumeFromPause() -> [String] {
        switch mode {
        case .auto,
             .askOnce:
            return drain()
        case .manually:
            state = index < commands.count ? .awaitingConfirmation : .finished
            return []
        case .skip:
            state = .finished
            return []
        }
    }
}
