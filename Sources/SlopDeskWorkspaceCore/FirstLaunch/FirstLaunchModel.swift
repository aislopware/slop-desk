import Defaults
import Foundation

// MARK: - E20 WI-9 (ES-E20-4): the first-launch gating model (PURE, headless-testable)

/// One step of the guided first-launch checklist
/// (`docs/ui-shell/spec/getting-started__first-launch.md`): On-Launch, Set-as-Default-Terminal, Install-CLI, Theme,
/// Install-Claude-hooks. PURE (a `String`-raw `CaseIterable`) so the gating is exhaustively unit-pinned and
/// the view can enumerate it. The two macOS-only steps (the `/usr/local/bin` install + the OS default-handler
/// registration) are marked ``isMacOnly`` so ``FirstLaunchModel/steps(for:)`` drops them on iOS — iOS keeps
/// the cross-platform steps (On-Launch, Theme, Install-Claude-hooks), per the E20 carry-over §3 iOS rule.
public enum FirstLaunchStep: String, CaseIterable, Identifiable, Sendable {
    /// Step 1 — On Launch (Restore Last Session vs New Window). Cross-platform (E7 already ships it).
    case onLaunch
    /// Step 2 — Set as Default Terminal (LOCAL OS handler; the remote / "Common Apps" case is
    /// honestly-disabled per the E20 exclusion). **macOS-only.**
    case defaultTerminal
    /// Step 3 — Install the `slopdesk` CLI (`/usr/local/bin` symlink + Omit-Prefix + Allow-Overwrite).
    /// **macOS-only.**
    case installCLI
    /// Step 4 — Change Theme (the E15 theme picker). Cross-platform.
    case theme
    /// Step 5 — Install Claude Code hooks (the E13 install card). Cross-platform. **Claude only.**
    case installClaudeHooks

    public var id: String { rawValue }

    /// Whether this step depends on macOS-only OS integration (the `/usr/local/bin` symlink / the
    /// `LSSetDefaultHandlerForURLScheme` registration). iOS omits these — it has no `/usr/local/bin` and no
    /// user-facing default-terminal concept — so the iOS first-launch keeps only the cross-platform steps.
    public var isMacOnly: Bool {
        switch self {
        case .defaultTerminal,
             .installCLI:
            true
        case .onLaunch,
             .theme,
             .installClaudeHooks:
            false
        }
    }

    /// The step's headline (first-launch checklist wording).
    public var title: String {
        switch self {
        case .onLaunch: "On Launch"
        case .defaultTerminal: "Set as Default Terminal"
        case .installCLI: "Install the SlopDesk CLI"
        case .theme: "Change Theme"
        case .installClaudeHooks: "Install Agent Integration"
        }
    }

    /// The step's one-line subtitle (first-launch checklist wording).
    public var subtitle: String {
        switch self {
        case .onLaunch:
            "Choose what happens when SlopDesk opens — restore your last session or start fresh."
        case .defaultTerminal:
            "Register SlopDesk as the system handler for terminal scripts and `ssh://` links."
        case .installCLI:
            "Add `slopdesk` to your PATH so you can drive the app from any shell."
        case .theme:
            "Pick a colour theme. You can fine-tune it later in Settings → Appearance."
        case .installClaudeHooks:
            "Let Claude Code stream its live state back to SlopDesk for tab badges and notifications."
        }
    }

    /// An SF-Symbol name for the step's leading glyph (header chrome).
    public var systemImage: String {
        switch self {
        case .onLaunch: "play.circle"
        case .defaultTerminal: "terminal"
        case .installCLI: "chevron.left.forwardslash.chevron.right"
        case .theme: "paintpalette"
        case .installClaudeHooks: "bolt.horizontal.circle"
        }
    }
}

/// The platform whose step set the first-launch flow presents. Resolved at the call site (the view passes
/// ``FirstLaunchModel/currentPlatform``); kept explicit so the pure gating is testable for BOTH platforms on
/// a single host (the iOS step set is asserted from a macOS test run — no simulator needed).
public enum FirstLaunchPlatform: String, Sendable, CaseIterable {
    case macOS
    case iOS
}

/// The PURE gating model behind the guided first-launch sheet (E20 WI-9 / ES-E20-4). It owns three things,
/// all headless-testable (revert-to-confirm-fail): (1) **whether** to present (first run only — the
/// ``hasCompletedFirstLaunch`` `Defaults` flag, suppressed under automation); (2) the **ordered step set**
/// for the platform (macOS gets all five; iOS drops the two macOS-only OS-integration steps); (3) the
/// **navigation + per-step completion** state the view binds to (advance / back / mark-complete / finish).
///
/// `@MainActor @Observable` (mirrors ``AgentHooksController``) so the SwiftUI sheet observes `index` /
/// `completed` live; the GATING decisions are `nonisolated static` pure functions so the unit tests pin them
/// without an actor hop or a constructed view. The persistence write is injected (``finish()`` → `onFinish`)
/// so a test drives the whole state machine against a captured flag instead of `Defaults.standard`.
@preconcurrency
@MainActor
@Observable
public final class FirstLaunchModel {
    /// The ordered steps for this run's platform (macOS: all five; iOS: the three cross-platform steps).
    public let steps: [FirstLaunchStep]
    /// The current step index into ``steps`` (always in-bounds — ``advance()`` / ``back()`` clamp).
    public private(set) var index: Int = 0
    /// The set of steps the user has actioned (Install CLI succeeded, hooks installed, …). Drives the per-step
    /// checkmark; never gates navigation (every step is skippable — first-launch is non-blocking).
    public private(set) var completed: Set<FirstLaunchStep> = []

    /// Injected persistence for ``finish()`` (default flips the ``hasCompletedFirstLaunch`` `Defaults` flag);
    /// a unit test passes a closure over a captured flag so it never touches `Defaults.standard`. The closure
    /// is stored in (and only called from) this `@MainActor` model, so it needs no explicit isolation.
    private let onFinish: (Bool) -> Void

    /// - Parameters:
    ///   - platform: which step set to present (default ``currentPlatform`` — `.macOS` on a Mac build).
    ///   - onFinish: persistence sink for ``finish()`` (default ``defaultPersistCompletion(_:)``).
    public init(
        platform: FirstLaunchPlatform = FirstLaunchModel.currentPlatform,
        onFinish: @escaping (Bool) -> Void = { FirstLaunchModel.defaultPersistCompletion($0) },
    ) {
        steps = Self.steps(for: platform)
        self.onFinish = onFinish
    }

    // MARK: - Pure gating (nonisolated static → unit-pinned with no actor hop / no view)

    /// The ordered step set for `platform`: every step in declaration order, minus the macOS-only steps on
    /// iOS. The order is fixed (On-Launch → Default-Terminal → Install-CLI → Theme →
    /// Claude-hooks); the relative order of the cross-platform steps is identical on both platforms.
    public nonisolated static func steps(for platform: FirstLaunchPlatform) -> [FirstLaunchStep] {
        FirstLaunchStep.allCases.filter { platform == .macOS || !$0.isMacOnly }
    }

    /// Whether the guided sheet should present: only on a fresh install (`hasCompleted == false`) and never
    /// under automation (an E2E / autoconnect launch must go straight to the workspace — the sheet would
    /// steal focus from the autoconnect path). The app passes its `hasAutomationEnvironment()` result.
    public nonisolated static func shouldPresent(hasCompleted: Bool, automationActive: Bool = false) -> Bool {
        !hasCompleted && !automationActive
    }

    /// The build's platform (`.macOS` on a Mac slice, `.iOS` under `#if os(iOS)`).
    public nonisolated static var currentPlatform: FirstLaunchPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }

    /// The default ``finish()`` sink — persists the `hasCompletedFirstLaunch` flag so the sheet never
    /// re-presents. Overridden in tests with a captured-flag closure (no `Defaults.standard` write).
    public nonisolated static func defaultPersistCompletion(_ done: Bool) {
        Defaults[.hasCompletedFirstLaunch] = done
    }

    // MARK: - Navigation state (@MainActor — the view binds these)

    /// The step the sheet currently shows. In-bounds by construction (``steps`` is never empty — the
    /// cross-platform steps always survive the platform filter — and ``index`` is clamped).
    public var currentStep: FirstLaunchStep { steps[clampedIndex] }

    /// Whether the current step is the first (the Back button hides / disables).
    public var isFirstStep: Bool { index <= 0 }

    /// Whether the current step is the last (the primary button becomes "Done" / "Get Started").
    public var isLastStep: Bool { index >= steps.count - 1 }

    /// The 1-based step number for the "Step N of M" header chrome.
    public var stepNumber: Int { clampedIndex + 1 }

    /// The total step count for "Step N of M" / the progress dots.
    public var stepCount: Int { steps.count }

    private var clampedIndex: Int { Swift.min(Swift.max(index, 0), steps.count - 1) }

    // MARK: - Mutations

    /// Move to the next step (no-op + `false` at the last step). Returns whether the index moved so the view
    /// can branch the primary button to ``finish()`` at the end without re-deriving ``isLastStep``.
    @discardableResult
    public func advance() -> Bool {
        guard index < steps.count - 1 else { return false }
        index += 1
        return true
    }

    /// Move to the previous step (no-op + `false` at the first step).
    @discardableResult
    public func back() -> Bool {
        guard index > 0 else { return false }
        index -= 1
        return true
    }

    /// Jump directly to `step` if it is part of this platform's step set (the progress-dot tap / a deep link).
    public func go(to step: FirstLaunchStep) {
        guard let target = steps.firstIndex(of: step) else { return }
        index = target
    }

    /// Record that the user actioned `step` (drives the per-step ✓). Idempotent; never gates navigation.
    public func markComplete(_ step: FirstLaunchStep) { completed.insert(step) }

    /// Whether `step` has been actioned.
    public func isComplete(_ step: FirstLaunchStep) -> Bool { completed.contains(step) }

    /// Persist that first-launch is done (sets ``hasCompletedFirstLaunch`` via the injected sink) so the sheet
    /// never re-presents. The view dismisses the sheet after calling this. Idempotent.
    public func finish() { onFinish(true) }
}

// MARK: - CLIShellShim (E20 WI-9 — the "Omit Prefix" shell-function snippet; PURE)

/// The PURE builder for the "Omit `slopdesk` Prefix" shell snippet — the `edit`/`view`/`watch`/
/// `jump`/`learn` functions exposed in app-launched shells so a user can type `edit foo.txt` instead of
/// `slopdesk edit foo.txt` (`docs/ui-shell/spec/getting-started__first-launch.md` §3). No I/O — a
/// string/byte builder only — so it is unit-pinned without touching the filesystem (``CLIInstaller`` does the
/// actual write under `#if os(macOS)`). The set is fixed and **Claude-aware by omission**: it never surfaces a
/// non-Claude agent verb.
public enum CLIShellShim {
    /// The bare command names exposed when "Omit Prefix" is ON, in documented order. Each wraps
    /// `slopdesk <name> "$@"`. (No agent-specific names — `watch:claude` stays a full subcommand, never a
    /// bare function.)
    public static let functionNames = ["edit", "view", "watch", "jump", "learn"]

    /// The POSIX-sh snippet defining the prefix-less functions. When `allowOverwrite` is `false` each function
    /// is defined ONLY if no command of that name already exists (`command -v <name>` fails) — so a user's own
    /// `edit`/`view`/… is never clobbered ("Allow Overwrite" OFF, the safe default); when `true` they are
    /// defined unconditionally. `binary` is the resolved CLI command (default `slopdesk`). Pure — the caller
    /// owns where/whether to source it.
    public static func snippet(allowOverwrite: Bool, binary: String = "slopdesk") -> String {
        var lines: [String] = [
            "# SlopDesk CLI — prefix-less shell functions (Omit Prefix).",
            "# Managed by SlopDesk; edits here are overwritten when the toggle changes.",
        ]
        for name in functionNames {
            let define = "\(name)() { \(binary) \(name) \"$@\"; }"
            if allowOverwrite {
                lines.append(define)
            } else {
                // Define only when nothing of that name resolves yet (alias / function / builtin / PATH exe).
                lines.append("command -v \(name) >/dev/null 2>&1 || \(define)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
