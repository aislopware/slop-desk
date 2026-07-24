import Foundation
import SlopDeskAgentDetect

/// The single fused status state a sidebar tab row carries (see
/// `docs/ui-shell/spec/terminal-features__progress-state.md`, "Tab badges reflect the current progress state per tab").
///
/// PURE value type, **no SwiftUI**: HOW each kind renders lives in the view layer
/// (`SlopDeskClientUI` `StatusPresentation` — lifecycle = the trailing ring mark's hue,
/// privilege = a trailing text marker) so this resolver unit-tests headless. There is
/// deliberately **no `.none` case** — the absence of a state is `TabBadgeKind?` `nil`, not a sentinel.
///
/// Each case maps to a state described in `progress-state.md` → "The full badge set".
public enum TabBadgeKind: Equatable, Sendable {
    /// **Running (agent)** — a WORKING code agent (`ClaudeStatus.working`). The "agent is thinking"
    /// state (the accent ring mark in the view layer). Split from a program's
    /// ``commandRunning`` so the sidebar reads "the AGENT is working" distinctly from "a program reports
    /// progress" (herdr's `Working` vs `Unknown` distinction).
    case running
    /// **Running (command)** — an active `OSC 9;4;1`/`3` PROGRESS report with NO agent working: a program
    /// explicitly says "I'm loading". Renders nothing of its own — the running command's text titles
    /// the row. Ranks just below ``running`` and above ``commandBusy``.
    case commandRunning
    /// **Busy (command)** — a plain busy shell (`isBusy`, no OSC 9;4 report): a foreground command is
    /// running, nothing more is known. Renders nothing of its own. Ranks just below
    /// ``commandRunning`` and above the privilege badges.
    case commandBusy
    /// **Completed** — the fresh clean finish (`OSC 133;D` exit 0 / an agent that just finished its
    /// turn), emitted ONLY while the caller reports the completion is still
    /// ``CompletionFreshness/fresh``; once it ``CompletionFreshness/settled`` the same inputs decay to
    /// ``finished``. Both wear the SAME green title ink in the view layer — the split survives for
    /// the freshness machinery and the control backend's badge tokens. Freshness is an INPUT (the store
    /// mirrors a per-pane `completedAt` and compares it to "now"), so this resolver stays clock-free.
    case completed
    /// **Finished** — the "unread output" marker for a command that exited 0 and has settled past the
    /// ``completed`` flash (and for an agent that went done and is still unread). The green title ink
    /// that holds until the tab is viewed (cleared on focus). No timestamp lives here; the settle
    /// decision is the store's.
    case finished
    /// **Error** — the red title ink, static. A command exited non-zero (`OSC 9;4;2` / a `.failure`
    /// completion) or an agent reported an error.
    case error
    /// **Awaiting input** — the amber title ink, static. A code agent is blocked on
    /// approval/input (`ClaudeStatus.needsPermission`) or a plain command is stopped at an
    /// interactive prompt. The most-urgent state — it wins the precedence.
    case awaitingInput
    /// **Caffeinate** — the `∞` trailing marker. A sleep-blocking session (`caffeinate` foreground).
    /// Surfaces only when the shell is otherwise at rest (below the active states).
    case caffeinate
    /// **Sudo** — the `#` trailing marker. A privileged session (`sudo`/`su` foreground). Surfaces
    /// only when the shell is otherwise at rest (below the active states, above ``caffeinate``).
    case sudo

    /// Whether this badge is ATTENTION-class — "finished or waiting on you", the states the titlebar's
    /// bell-style dot (``WorkspaceStore/hasUnseenAttention``) rolls up. The live activity markers
    /// (``running``/``commandRunning``) and the at-rest privilege badges (``sudo``/``caffeinate``) are
    /// NOT attention: the dot means unread, not busy.
    public var needsAttention: Bool {
        switch self {
        case .awaitingInput,
             .completed,
             .error,
             .finished: true
        case .caffeinate,
             .commandBusy,
             .commandRunning,
             .running,
             .sudo: false
        }
    }

    /// Whether this badge is a BUSY tier — "something is in flight" (a working agent, an OSC 9;4
    /// progress report, or a bare busy shell). The sidebar rows render busy as the trailing ring
    /// mark on the accent/muted inks, the attention kinds as the same ring on the attention hues,
    /// and only the privilege markers occupy the slot.
    /// The disjoint complement of ``needsAttention`` plus the privilege markers.
    public var isBusyTier: Bool {
        switch self {
        case .commandBusy,
             .commandRunning,
             .running: true
        case .awaitingInput,
             .caffeinate,
             .completed,
             .error,
             .finished,
             .sudo: false
        }
    }
}

/// The PURE fusion policy that collapses the four per-pane badge signals into the single
/// ``TabBadgeKind`` a tab row shows. One badge per row; most-urgent wins.
///
/// **Fixed precedence** (distilled from `progress-state.md` + `parallel-tasks.md`):
///
/// ```
/// awaitingInput  >  error  >  running(agent)  >  AGENT completed/finished  >  commandRunning  >
///   commandBusy  >  sudo  >  caffeinate  >  COMMAND completed/finished  >  nil
/// ```
///
/// A working AGENT (``running``) outranks a program's progress report (``commandRunning``), which
/// outranks the plain busy dot (``commandBusy``) — if a pane is somehow several, the most-informative
/// signal wins. The activity tiers sit above the privilege badges (a running `sudo …` shows activity, not
/// the shield). The AGENT finish sits ABOVE the busy tiers (the agent process itself keeps the shell
/// busy for its whole lifetime — a finished turn must not be shadowed); a COMMAND's clean exit sits
/// BELOW them (a newly-running command supersedes the previous exit).
///
/// Headless + deterministic: no SwiftUI, no clock, no I/O. The only inputs are the agent verdict, the
/// stored completion badge, the busy bit, and the (untrusted) foreground-process string — which is
/// classified by an **allow-set on its lowercased basename**, never `contains`, and defaults to "no
/// privilege badge" for anything unknown / `nil` (validate-then-default; no force-unwrap).
public enum TabBadgeResolver {
    /// Whether a clean completion (`.success` exit / agent `.done`) is still showing its brief success
    /// FLASH or has SETTLED into the persistent unread marker. A pure, clock-free input the resolver
    /// switches the completed/finished branch on — the caller (the store) decides it by comparing an
    /// EPHEMERAL per-pane `completedAt` mirror against "now", so this resolver never reads a clock.
    public enum CompletionFreshness: Sendable, Equatable {
        /// Just completed — render the brief ``TabBadgeKind/completed`` flash.
        case fresh
        /// Settled past the flash — render the persistent ``TabBadgeKind/finished`` unread marker
        /// (held until the tab is viewed). Also the default for a completion with no recorded stamp.
        case settled
    }

    /// Basenames that mark a **privileged** session (the shield). A small allow-set; matched exactly
    /// against the lowercased basename of the foreground process.
    private static let sudoBasenames: Set<String> = ["sudo", "su"]
    /// Basenames that mark a **sleep-blocking** session (the coffee cup).
    private static let caffeinateBasenames: Set<String> = ["caffeinate"]

    /// Resolve the one badge for a row, by fixed precedence (most-urgent wins).
    ///
    /// - Parameters:
    ///   - agent: the rolled-up `ClaudeStatus` for the pane (`needsPermission` ⇒ awaiting input,
    ///     `working` ⇒ running, `done` ⇒ completed; `idle`/`none` contribute nothing).
    ///   - completion: the stored OSC-133 exit-code badge (`.failure` ⇒ error, `.success` ⇒ completed),
    ///     or `nil` for none.
    ///   - isBusy: the live "command running" bit (`PaneSessionHandle.isShellBusy`) ⇒ running.
    ///   - foregroundProcess: the last foreground-process string the host reported (wire type 26),
    ///     possibly a bare name or a full path; UNTRUSTED. Classified by lowercased basename into
    ///     `sudo`/`caffeinate`, else ignored.
    ///   - completionFreshness: whether a clean completion (`.success` / agent `.done`) is still a
    ///     ``CompletionFreshness/fresh`` FLASH or has ``CompletionFreshness/settled`` into the
    ///     persistent unread marker. Supplied by the store (an ephemeral `completedAt` vs "now"); defaults to
    ///     ``CompletionFreshness/settled`` so an un-stamped completion shows the persistent marker.
    ///   - progress: the live OSC 9;4 ``PaneProgress`` (wire type 32), or `nil` when there is no
    ///     active indicator. ``PaneProgress/error`` resolves to the ``error`` alert (a held-red `9;4;2`,
    ///     ranked with a failed exit); an active ``PaneProgress/indeterminate``/``PaneProgress/determinate``
    ///     resolves to the ``running`` tier — reusing the EXISTING tiers, no new badge kind. Outranks a
    ///     stale completion dot (progress-error sits at the error tier, above completed/finished).
    ///   - unseenAgentDone: the client's UNREAD agent-finish latch (``WorkspaceStore/paneUnseenDone``) —
    ///     true from an agent `.done` edge the user was not watching until the pane is visited. Keeps the
    ///     finished marker alive across the host's own done→idle decay (the host forgets, the client
    ///     remembers until seen — the t3code/herdr unread-completion model).
    /// - Returns: the badge to render, or `nil` when the row is all-clear.
    public static func badge(
        agent: ClaudeStatus,
        completion: PaneCompletionBadge?,
        isBusy: Bool,
        foregroundProcess: String?,
        completionFreshness: CompletionFreshness = .settled,
        progress: PaneProgress? = nil,
        unseenAgentDone: Bool = false,
    ) -> TabBadgeKind? {
        // 1. Awaiting input — a blocked agent demands a human; highest urgency.
        if agent == .needsPermission { return .awaitingInput }

        // 2. Error — a failed command (non-zero exit) OR a held-red OSC 9;4;2 progress error. Either at the
        // error tier, above a running spinner and a stale completion dot. (Unwrap first, then match the
        // non-optional case so there is no optional-pattern ambiguity.)
        if completion == .failure { return .error }
        if let progress, case .error = progress { return .error }

        // 3. Activity — a WORKING agent gets the agent tier (``running``); an active OSC 9;4;1/3
        // progress gets the quiet ``commandRunning`` tier; a merely-busy shell gets the bare
        // ``commandBusy`` tier (the busy split is informational — the view layer renders all three
        // through the title, never a trailing glyph). Most-informative wins. (A progress `.error`
        // already returned at the error tier above, so `isRunning` here is exactly the "still going" states.)
        if agent == .working { return .running }

        // 3a. Agent finish — the completed/finished marker for a FINISHED AGENT TURN (a live `.done`,
        // or the client's unread latch outliving the host's done→idle decay). Deliberately ABOVE the
        // busy tiers: the `claude` process keeps the shell's OSC-133 block open for its whole
        // interactive lifetime, so `isBusy` stays true for hours — checked later, a finished turn
        // would be shadowed by the busy tier forever and the finish could never show. An agent
        // turn ending IS the completion signal; the agent process staying alive at its prompt is not
        // "busy" in any sense the user cares about. (A plain COMMAND's `.success` stays below
        // `isBusy` — there a newly-running command genuinely supersedes the previous exit.)
        if agent == .done || unseenAgentDone {
            switch completionFreshness {
            case .fresh: return .completed
            case .settled: return .finished
            }
        }

        if let progress, progress.isRunning { return .commandRunning }
        if isBusy { return .commandBusy }

        // 4 + 5. Privilege badges, only when the shell is at rest: sudo (shield) > caffeinate (coffee).
        if let privilege = privilegeBadge(forProcess: foregroundProcess) { return privilege }

        // 6. Completed/finished — a plain command's clean exit. While the completion is FRESH it shows
        // the brief `.completed` flash; once the caller reports it SETTLED it decays to the
        // persistent `.finished` unread marker (held until the tab is viewed). Freshness is an input — no clock here.
        if completion == .success {
            switch completionFreshness {
            case .fresh: return .completed
            case .settled: return .finished
            }
        }

        // 7. All-clear.
        return nil
    }

    /// Classify the (untrusted) foreground-process string into a privilege badge by its **lowercased
    /// basename** against the allow-sets. `nil`/empty/unknown ⇒ no badge (validate-then-default). Never
    /// uses `contains` (which would misfire on e.g. `sudoedit-helper`), never force-unwraps.
    private static func privilegeBadge(forProcess process: String?) -> TabBadgeKind? {
        guard let name = basename(of: process) else { return nil }
        if sudoBasenames.contains(name) { return .sudo }
        if caffeinateBasenames.contains(name) { return .caffeinate }
        return nil
    }

    /// The lowercased last path component of `process`, or `nil` when there is nothing to classify.
    /// `"/usr/bin/sudo"` → `"sudo"`, `"caffeinate"` → `"caffeinate"`, `""`/`"/"`/`nil` → `nil`.
    private static func basename(of process: String?) -> String? {
        guard let process else { return nil }
        let trimmed = process.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Last non-empty `/`-delimited component. An all-slashes string yields no component → nil.
        guard let component = trimmed.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        return component.lowercased()
    }
}
