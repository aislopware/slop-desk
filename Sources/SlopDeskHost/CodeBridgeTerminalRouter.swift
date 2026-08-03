// CodeBridgeTerminalRouter — which terminal pane a command from the embedded editor lands in, and
// what bytes it becomes.
//
// The embedded workbench ships its own integrated terminal. That shell is outside everything this
// app provides — no agent detection, no PTY fan-out to the other clients, no replay, no scrollback
// journal — so the editor's "run this" affordances are pointed at a real SlopDesk pane instead
// (`Resources/bridge/extension.js` contributes the menu items; `CodeBridgeServer` carries them).
//
// Pointing them somewhere means CHOOSING, and the editor cannot choose: focus is a client-side
// fact, and a project may have several panes across several clients. So the host picks, under
// rules whose failure mode is REFUSING rather than typing into the wrong shell:
//
//   1. the pane's cwd must live under the workbench's folder — a command meant for this project
//      never lands in another one;
//   2. no agent may be detected in it — typing a shell command at Claude Code's prompt sends it to
//      the AGENT, which is the one outcome that would be actively destructive;
//   3. its foreground process must be a SHELL — a pane sitting in vim, less, or a running build is
//      not waiting for a command line, and keystrokes there mean something else entirely.
//
// What survives all three is a pane at a prompt in this project, which is what the user means by
// "my terminal". Usually there is exactly one; the ranking below only settles the rest.
//
// Pure — no sockets, no sessions, no Darwin. `CodeBridgeServerTests` pins it directly.

import Foundation

/// One candidate pane, flattened from the host's live session for the router's benefit.
struct CodeBridgePane: Sendable, Equatable {
    let paneId: String
    let title: String
    /// The host-observed cwd (OSC-7 / prompt-edge probe), `nil` until observed. A pane whose cwd is
    /// unknown is never chosen: containment is what keeps a command inside its own project.
    let cwd: String?
    /// Whether an agent was detected in this pane (`AgentControlState.presence`).
    let hasAgent: Bool
    /// The foreground process basename (`PTYForegroundProbe`), `""` when it could not be read.
    let foreground: String
}

enum CodeBridgeTerminalRouter {
    /// Why no pane could take the command. Each maps to one sentence the editor shows the user —
    /// the point being that a refusal explains itself, since the alternative (silence) reads as
    /// a broken feature.
    enum Refusal: Error, Equatable {
        /// No pane of this project is open anywhere.
        case noPaneInProject
        /// Panes exist, but every one is running something or hosting an agent.
        case noIdlePane
    }

    /// Foreground processes that mean "sitting at a prompt". Login shells arrive with a leading
    /// dash (`-zsh`) from the process table, so both spellings are listed. Anything else — an
    /// editor, a pager, a build, an agent — means the pane is busy.
    static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh",
        "-sh", "-bash", "-zsh", "-fish", "-ksh", "-tcsh", "-csh",
    ]

    /// The pane that should receive a command issued from the workbench rooted at `root`, or why
    /// none can. `directory` is where the command is ABOUT (the acting file's folder) — used only
    /// to rank, never to filter, so a project with one shell always works no matter which file is
    /// open.
    static func choose(
        among panes: [CodeBridgePane], root: String, near directory: String?,
    ) -> Result<CodeBridgePane, Refusal> {
        let inProject = panes.filter { pane in
            guard let cwd = pane.cwd else { return false }
            return CodeBridgeServer.contains(root: root, path: cwd)
        }
        guard !inProject.isEmpty else { return .failure(.noPaneInProject) }
        let idle = inProject.filter { !$0.hasAgent && shellNames.contains($0.foreground) }
        guard var best = idle.first else { return .failure(.noIdlePane) }
        for candidate in idle.dropFirst() where prefers(candidate, over: best, near: directory) {
            best = candidate
        }
        return .success(best)
    }

    /// Ranking, in order: the pane standing CLOSEST to the acting file (most shared path
    /// components), then the deeper cwd, then the lower pane id. The last clause is not taste —
    /// it makes the choice reproducible for a given set of panes, which is what lets a test pin
    /// the behaviour at all.
    private static func prefers(
        _ candidate: CodeBridgePane, over incumbent: CodeBridgePane, near directory: String?,
    ) -> Bool {
        let candidateDepth = sharedComponents(candidate.cwd, directory)
        let incumbentDepth = sharedComponents(incumbent.cwd, directory)
        if candidateDepth != incumbentDepth { return candidateDepth > incumbentDepth }
        let candidateCWD = candidate.cwd ?? ""
        let incumbentCWD = incumbent.cwd ?? ""
        if candidateCWD.count != incumbentCWD.count { return candidateCWD.count > incumbentCWD.count }
        return candidate.paneId < incumbent.paneId
    }

    /// How many leading path COMPONENTS two absolute paths share (`/a/b/c` vs `/a/b/d` → 2). A
    /// component count, not a character count: `/a/bee` shares one component with `/a/b`, not four
    /// characters' worth.
    static func sharedComponents(_ lhs: String?, _ rhs: String?) -> Int {
        guard let lhs, let rhs else { return 0 }
        let left = lhs.split(separator: "/")
        let right = rhs.split(separator: "/")
        var shared = 0
        while shared < left.count, shared < right.count, left[shared] == right[shared] { shared += 1 }
        return shared
    }

    // MARK: Bytes

    /// The bytes a command line becomes on the PTY: the text, then a carriage RETURN — the byte a
    /// real Return key sends (the tty's `ICRNL` turns it into the newline the shell reads). Same
    /// convention as the agent-control `run` verb, deliberately: two ways to type into a pane
    /// should not disagree about what Enter is.
    static func keystrokes(for text: String) -> Data {
        Data((text + "\r").utf8)
    }

    /// `cd <dir>` for the pane. The quoting matters more than it looks: a project path with a
    /// space or a quote in it would otherwise become several arguments, and this text is typed
    /// into a live shell.
    static func changeDirectoryCommandLine(_ directory: String) -> String {
        "cd " + shellSingleQuoted(directory)
    }

    /// POSIX single-quote `value` so a shell reads it verbatim: wrap in `'…'`, rewriting each
    /// embedded `'` as `'\''` (close, escaped quote, reopen). Mirrors the client-side actuator's
    /// quoting (`LinkActionPolicy.shellSingleQuoted`) — the daemon does not link the client's
    /// workspace target, so the four lines live in both places rather than widening the daemon's
    /// dependency graph for them.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The sentence the editor shows when nothing could take the command.
    static func message(for refusal: Refusal) -> String {
        switch refusal {
        case .noPaneInProject:
            "SlopDesk: no terminal pane is open in this project."
        case .noIdlePane:
            "SlopDesk: every terminal pane in this project is busy (a command is running, or an agent has it)."
        }
    }
}
