// Generated from herdr's bundled agent-detection manifests (Apache-2.0,
// github.com/ogulcancelik/herdr `src/detect/manifests/*.toml`) — carried VERBATIM so upstream
// rule updates can be pasted in unchanged. Do not hand-edit rule content here; sync from
// upstream instead. Embedded as raw-string literals (no resource bundle) so the headless
// daemon and every app target load them with zero deployment surface.

// Manifest TOML is carried verbatim — upstream lines stay unwrapped.
// swiftlint:disable line_length

/// The bundled manifest TOML per screen-manifest agent (herdr's exact files).
enum BundledAgentManifests {
    static let all: [(AgentKind, String)] = [
        (.pi, piTOML),
        (.claude, claudeTOML),
        (.codex, codexTOML),
        (.gemini, geminiTOML),
        (.cursor, cursorTOML),
        (.devin, devinTOML),
        (.antigravity, antigravityTOML),
        (.cline, clineTOML),
        (.openCode, opencodeTOML),
        (.githubCopilot, githubcopilotTOML),
        (.kimi, kimiTOML),
        (.kiro, kiroTOML),
        (.droid, droidTOML),
        (.amp, ampTOML),
        (.grok, grokTOML),
        (.hermes, hermesTOML),
        (.kilo, kiloTOML),
        (.qodercli, qodercliTOML),
        (.maki, makiTOML),
    ]

    static let piTOML = #"""
    id = "pi"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["herdr:pi"]

    [[rules]]
    id = "working_literal"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["Working..."]
    """#

    static let claudeTOML = #"""
    id = "claude"
    version = "2026.08.11.1"
    # 3, not 2: the cross-region gate vetoes below are an engine-3 key, and an engine that ignored
    # them would drop every veto and read a repainting dialog as an idle prompt.
    min_engine_version = 3
    updated_at = "2026-08-11T00:00:00Z"
    aliases = ["claude-code"]

    [[rules]]
    id = "osc_title_working"
    state = "working"
    priority = 1100
    region = "osc_title"
    visible_working = true
    regex = ['^[\x{2800}-\x{28FF}] ']

    [[rules]]
    id = "btw_overlay_working"
    state = "working"
    priority = 975
    region = "bottom_non_empty_lines(5)"
    visible_working = true
    line_regex = [
      '^\s*/btw(?:\s|$)',
      '(?i)esc to close\s*$',
    ]

    [[rules]]
    id = "transcript_viewer"
    state = "unknown"
    priority = 1000
    region = "bottom_non_empty_lines(3)"
    skip_state_update = true
    contains = ["showing detailed transcript"]
    any = [
      { contains = ["ctrl+o", "to toggle"] },
      { contains = ["ctrl+e", "show all"] },
      { contains = ["ctrl+e", "collapse"] },
      { contains = ["↑↓ scroll"] },
      { contains = ["? for shortcuts"] },
    ]

    [[rules]]
    id = "live_blocked_form"
    state = "blocked"
    priority = 980
    region = "after_last_horizontal_rule"
    visible_blocker = true
    contains = ["enter to select", "esc to cancel"]
    any = [
      { contains = ["tab/arrow keys to navigate"] },
      { contains = ["arrow keys to navigate"] },
      { contains = ["arrows to navigate"] },
      { contains = ["↑/↓ to navigate"] },
      { contains = ["↑↓ to navigate"] },
    ]

    [[rules]]
    id = "dynamic_workflow_prompt"
    state = "blocked"
    priority = 980
    region = "whole_recent"
    visible_blocker = true
    contains = ["run a dynamic workflow?", "esc to cancel"]

    [[rules]]
    id = "live_prompt_box"
    state = "idle"
    priority = 950
    region = "prompt_box_body"
    visible_idle = true
    line_regex = ['^\s*❯']
    not = [
      { contains = ["enter to select"] },
      { contains = ["esc to cancel"] },
      { contains = ["tab/arrow keys"] },
      { contains = ["arrow keys to navigate"] },
      { contains = ["↑/↓ to navigate"] },
      # ⚠️ DIVERGES FROM herdr (2026-08-11) — and this is the entry that matters.
      #
      # The five needles above are DEAD. They are evaluated against this rule's own region, and a
      # modal dialog's footer sits BELOW the last horizontal rule — outside `prompt_box_body` by
      # construction. So they never saw the thing they were written to veto, while the dialog's
      # focused option (`❯ 1. …`) satisfied the `^\s*❯` caret above. One torn mid-repaint read of an
      # `AskUserQuestion` therefore reported an IDLE PROMPT BOX with `visible_idle` — the strongest
      # idle verdict the engine can produce — for a pane blocked on a human.
      #
      # This one looks where the evidence actually is. `after_last_horizontal_rule` is exactly
      # `live_blocked_form`'s region, so the two rules are now strict complements: if a live form
      # footer is on screen, this rule cannot fire, whatever the caret above it looks like.
      { region = "after_last_horizontal_rule", any = [
        { contains = ["enter to select"] },
        { contains = ["esc to cancel"] },
        { contains = ["tab/arrow keys"] },
        { contains = ["arrow keys to navigate"] },
        { contains = ["arrows to navigate"] },
        { contains = ["↑/↓ to navigate"] },
        { contains = ["↑↓ to navigate"] },
      ] },
      # …and the same veto read off the OPTION LIST rather than the footer, because a repaint
      # ERASES lines before it rewrites them: mid-frame the footer is gone from every region, and
      # the cross-region needle above has nothing left to find. The list survives, because it is
      # what the caret is sitting in. `❯ 1. …` accompanied by a SIBLING `  2. …` is a menu, not
      # somebody's typing — requiring the sibling is what keeps a human who types "1. foo" at a
      # real prompt from being vetoed (and even then the cost is only losing `visible_idle`: the
      # `✳` title rule still reports the pane idle).
      { all = [
        { line_regex = ['^\s*❯\s+\d+\.\s'] },
        { line_regex = ['^\s{2,}\d+\.\s'] },
      ] },
    ]

    [[rules]]
    id = "model_picker_menu"
    state = "unknown"
    priority = 900
    region = "whole_recent"
    skip_state_update = true
    contains = ["select model", "enter to set as default", "esc to cancel"]
    not = [
      { contains = ["do you want to proceed?"] },
      { contains = ["enter to select"] },
    ]

    [[rules]]
    id = "bash_permission_prompt"
    state = "blocked"
    priority = 850
    region = "whole_recent"
    visible_blocker = true
    contains = ["do you want to proceed?"]
    any = [
      { contains = ["bash command"] },
      { contains = ["bash("] },
      { contains = ["contains expansion"] },
      { contains = ["tab to amend"] },
      { contains = ["ctrl+e to explain"] },
    ]
    all = [
      { any = [{ line_regex = ['(?i)^\s*❯?\s*yes\b'] }, { line_regex = ['(?i)^\s*1\.\s*yes\b'] }, { line_regex = ['(?i)^\s*2\.\s*no\b'] }] },
    ]

    [[rules]]
    id = "generic_permission_prompt"
    state = "blocked"
    priority = 840
    region = "after_last_horizontal_rule"
    visible_blocker = true
    contains = ["do you want to proceed?", "esc to cancel"]
    all = [
      { any = [
        { line_regex = ['(?i)^\s*❯?\s*1\.\s*yes\b'] },
        { line_regex = ['(?i)^\s*2\.\s*yes\b'] },
        { line_regex = ['(?i)^\s*2\.\s*no\b'] },
        { line_regex = ['(?i)^\s*3\.\s*no\b'] },
      ] },
    ]

    [[rules]]
    id = "legacy_no_prompt_blocker"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    # ⚠️ DIVERGES FROM herdr (2026-08-11): upstream omits `visible_blocker` here, alone among the
    # blocked rules. That made a pane blocked through THIS rule carry a different visibility than a
    # pane blocked through any other, so alternating between them flipped `visible_blocker` and
    # published a type-27 saying something had changed when only the matching rule had. It also cost
    # the 800 ms stable-blocker refresh. A blocker the human can see is a visible blocker.
    visible_blocker = true
    any = [
      { contains = ["do you want to"], any = [{ contains = ["yes"] }, { contains = ["❯"] }] },
      { contains = ["would you like to"], any = [{ contains = ["yes"] }, { contains = ["❯"] }] },
      { contains = ["waiting for permission"] },
      { contains = ["do you want to allow this connection?"] },
      { contains = ["tab to amend"] },
      { contains = ["ctrl+e to explain"] },
      { contains = ["do you want to proceed?", "esc to cancel"] },
      { contains = ["review your answers"] },
      { contains = ["skip interview and plan immediately"] },
    ]
    not = [
      { regex = ['(?m)^\s*❯\s*$'] },
    ]

    [[rules]]
    id = "osc_title_idle"
    state = "idle"
    priority = 250
    region = "osc_title"
    visible_idle = true
    regex = ['^\x{2733} ']

    [[rules]]
    id = "osc_progress_idle"
    state = "idle"
    priority = 250
    region = "osc_progress"
    regex = ['^4;0']
    """#

    static let codexTOML = #"""
    id = "codex"
    version = "2026.07.18.1"
    min_engine_version = 2
    updated_at = "2026-07-18T00:00:00Z"

    [[rules]]
    id = "osc_title_blocked"
    state = "blocked"
    priority = 1100
    region = "osc_title"
    visible_blocker = true
    contains = ["Action Required"]

    [[rules]]
    id = "osc_title_working"
    state = "working"
    priority = 1050
    region = "osc_title"
    visible_working = true
    regex = ['(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)']

    [[rules]]
    id = "transcript_viewer"
    state = "unknown"
    priority = 1000
    region = "after_last_prompt_marker"
    skip_state_update = true
    contains = ["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"]
    any = [
      { contains = ["esc to edit prev"] },
      { contains = ["esc/← to edit prev"] },
    ]

    [[rules]]
    id = "live_strong_blocker"
    state = "blocked"
    priority = 900
    region = "after_last_prompt_marker"
    visible_blocker = true
    any = [
      { contains = ["press enter to confirm or esc to cancel"] },
      { contains = ["enter to submit answer"] },
      { contains = ["enter to submit all"] },
      { contains = ["allow command?"] },
    ]

    [[rules]]
    id = "weak_blocker"
    state = "blocked"
    priority = 600
    region = "whole_recent"
    any = [
      { contains = ["[y/n]"] },
      { contains = ["yes (y)"] },
      { contains = ["do you want to"], any = [{ contains = ["yes"] }, { contains = ["❯"] }] },
      { contains = ["would you like to"], any = [{ contains = ["yes"] }, { contains = ["❯"] }] },
    ]

    [[rules]]
    id = "screen_working_fallback"
    state = "working"
    priority = 500
    region = "bottom_non_empty_lines(3)"
    visible_working = true
    line_regex = ['^[•◦]\s+Working \([^)]*esc to interrupt\)(?: · .*)?$']
    not = [{ contains = ["■ Conversation interrupted"] }]

    [[rules]]
    id = "osc_title_idle"
    state = "idle"
    priority = 100
    region = "osc_title"
    visible_idle = true
    regex = ['\S']
    not = [
      { regex = ['(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)'] },
      { contains = ["Action Required"] },
    ]
    """#

    static let geminiTOML = #"""
    id = "gemini"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"

    [[rules]]
    id = "apply_or_allow_change"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["│ Apply this change"] },
      { contains = ["│ Allow execution"] },
      { all = [{ contains = ["yes"] }, { any = [{ contains = ["waiting for user confirmation"] }, { contains = ["│ Do you want to proceed"] }, { contains = ["do you want to proceed?"] }] }] },
      { line_regex = ['(?i)^\s*❯.*(yes|allow)'] },
    ]

    [[rules]]
    id = "esc_cancel_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["esc to cancel"]
    """#

    static let cursorTOML = #"""
    id = "cursor"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["cursor-agent"]

    [[rules]]
    id = "write_file_approval"
    state = "blocked"
    priority = 320
    region = "bottom_non_empty_lines(8)"
    visible_blocker = true
    contains = ["write to this file?", "proceed (y)"]
    any = [
      { contains = ["reject & propose changes"] },
      { contains = ["esc or n or p"] },
      { contains = ["add write("] },
    ]

    [[rules]]
    id = "approval_prompt"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["waiting for approval", "run this command?"], any = [{ contains = ["run (once) (y)"] }, { contains = ["skip (esc or n)"] }] },
      { contains = ["(y) (enter)"] },
      { line_regex = ['(?i)^\s*allow .*\(y\)'] },
      { contains = ["keep (n)"] },
      { contains = ["skip (esc or n)"] },
      { line_regex = ['(?i)^\s*(run |.*\(y\).*(allow|run \(once\)|→ run))'] },
    ]

    [[rules]]
    id = "stop_hint_working"
    state = "working"
    priority = 100
    region = "bottom_non_empty_lines(6)"
    visible_working = true
    contains = ["ctrl+c to stop"]

    [[rules]]
    id = "background_task_status_working"
    state = "working"
    priority = 95
    region = "bottom_non_empty_lines(5)"
    visible_working = true
    line_regex = ['(?i)\b[1-9][0-9]*\s+background\s+tasks?\b']

    [[rules]]
    id = "spinner_working"
    state = "working"
    priority = 90
    region = "bottom_non_empty_lines(8)"
    visible_working = true
    line_regex = ['^\s*(⬡|⬢|[\u2800-\u28FF]+)\s+\p{Alphabetic}+\w*ing\b']
    """#

    static let devinTOML = #"""
    id = "devin"
    version = "2026.06.15.1"
    min_engine_version = 1
    updated_at = "2026-06-15T00:00:00Z"
    aliases = ["devin-cli", "devin cli"]

    [[rules]]
    id = "workspace_trust_prompt"
    state = "blocked"
    priority = 300
    region = "bottom_non_empty_lines(8)"
    visible_blocker = true
    contains = [
      "do you trust the authors of this directory?",
      "with untrusted content.",
      "yes, trust ",
    ]

    [[rules]]
    id = "permission_prompt"
    state = "blocked"
    priority = 290
    region = "bottom_non_empty_lines(8)"
    visible_blocker = true
    contains = ["approve once", "select", "confirm", "esc cancel"]

    [[rules]]
    id = "running_tools_footer"
    state = "working"
    priority = 200
    region = "bottom_non_empty_lines(8)"
    visible_working = true
    contains = ["running tools", "esc to interrupt"]
    not = [
      { contains = ["approve once", "esc cancel"] },
    ]

    [[rules]]
    id = "guide_while_working"
    state = "working"
    priority = 190
    region = "bottom_non_empty_lines(6)"
    visible_working = true
    contains = ["guide devin while it works"]
    not = [
      { contains = ["approve once", "esc cancel"] },
    ]

    [[rules]]
    id = "tool_reading_timeout"
    state = "working"
    priority = 180
    region = "bottom_non_empty_lines(8)"
    visible_working = true
    contains = ["reading shell ", "timeout:"]
    not = [
      { contains = ["approve once", "esc cancel"] },
    ]

    [[rules]]
    id = "welcome_prompt_footer"
    state = "idle"
    priority = 120
    region = "bottom_non_empty_lines(8)"
    visible_idle = true
    contains = ["ask devin to build", "features, fix bugs", "your code"]
    line_regex = ['^\s*❭ Ask Devin to build']
    not = [
      { contains = ["approve once", "esc cancel"] },
      { contains = ["running tools", "esc to interrupt"] },
      { contains = ["guide devin while it works"] },
    ]

    [[rules]]
    id = "live_prompt_footer"
    state = "idle"
    priority = 100
    region = "bottom_non_empty_lines(6)"
    visible_idle = true
    contains = ["context:"]
    line_regex = ['^\s*❭']
    not = [
      { contains = ["approve once", "esc cancel"] },
      { contains = ["running tools", "esc to interrupt"] },
      { contains = ["guide devin while it works"] },
    ]
    """#

    static let antigravityTOML = #"""
    id = "agy"
    version = "2026.06.24.1"
    min_engine_version = 1
    updated_at = "2026-06-24T00:00:00Z"
    aliases = ["antigravity", "antigravity-cli"]

    [[rules]]
    id = "permission_prompt"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    contains = ["requesting permission for:"]
    any = [
      { contains = ["do you want to proceed?"] },
      { contains = ["tab amend", "edit command"] },
    ]

    [[rules]]
    id = "spinner_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    line_regex = ['^\s*[\u2800-\u28FF]+\s+\p{Alphabetic}+\w*ing\b']

    [[rules]]
    id = "background_tasks_working"
    state = "working"
    priority = 90
    region = "bottom_non_empty_lines(5)"
    visible_working = true
    line_regex = ['(?i)·\s*[1-9][0-9]*\s+task']
    """#

    static let clineTOML = #"""
    id = "cline"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"

    [[rules]]
    id = "tool_permission"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["let cline use this tool"] },
      { contains = ["[act mode]", "execute command?", "yes"] },
      { contains = ["[act mode]", "use this tool?", "yes"] },
      { contains = ["[plan mode]", "execute command?", "yes"] },
      { contains = ["[plan mode]", "use this tool?", "yes"] },
    ]

    [[rules]]
    id = "default_cline_working"
    state = "working"
    priority = -10
    region = "whole_recent"
    visible_working = true
    regex = ['(?s).+']
    """#

    static let opencodeTOML = #"""
    id = "opencode"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["open-code", "herdr:opencode"]

    [[rules]]
    id = "permission_required"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["△ Permission required"] },
      { contains = ["esc dismiss"], any = [{ contains = ["enter confirm"] }, { contains = ["enter submit"] }, { contains = ["enter toggle"] }], all = [{ any = [{ contains = ["↑↓ select"] }, { contains = ["⇆ tab"] }] }] },
    ]

    [[rules]]
    id = "interrupt_hint_working"
    state = "working"
    priority = 110
    region = "whole_recent"
    visible_working = true
    any = [
      { contains = ["esc to interrupt"] },
      { contains = ["ctrl+c to interrupt"] },
      { contains = ["press esc to interrupt"] },
      { line_regex = ['(?i).*opencode.*esc (again to )?interrupt'] },
    ]

    [[rules]]
    id = "progress_bar_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    regex = ['(■|⬝){4,}']
    """#

    static let githubcopilotTOML = #"""
    id = "copilot"
    version = "2026.07.07.1"
    min_engine_version = 1
    updated_at = "2026-07-07T14:15:00Z"
    aliases = ["github-copilot", "ghcs"]

    [[rules]]
    id = "selection_blocker"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    all = [
      { any = [
        { contains = ["esc to cancel"] },
        { contains = ["esc cancel"] },
      ] },
      { any = [
        { contains = ["enter to select"] },
        { contains = ["enter to confirm"] },
        { contains = ["enter to submit"] },
        { contains = ["enter accept"] },
      ] },
    ]

    [[rules]]
    id = "working_cancel_hint"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    any = [
      { contains = ["esc to cancel"] },
      { contains = ["esc cancel"] },
      { contains = ["esc again to cancel"] },
      { contains = ["esc interrupt"] }
    ]
    """#

    static let kimiTOML = #"""
    id = "kimi"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["kimi-code", "kimi code"]

    [[rules]]
    id = "current_approval_panel"
    state = "blocked"
    priority = 400
    region = "whole_recent"
    visible_blocker = true
    contains = ["↵ confirm"]
    any = [
      { contains = ["run this command?"] },
      { contains = ["write this file?"] },
      { contains = ["apply these edits?"] },
      { contains = ["stop this task?"] },
      { contains = ["ready to build with this plan?"] },
      { line_regex = ['(?i)^\s*▶?\s*approve .*\?$'] },
    ]
    all = [
      { contains = [" choose"] },
      { any = [{ contains = ["approve"] }, { contains = ["reject"] }, { contains = ["revise"] }] },
    ]

    [[rules]]
    id = "question_panel"
    state = "blocked"
    priority = 390
    region = "whole_recent"
    visible_blocker = true
    contains = ["↑↓ select", "esc cancel"]
    line_regex = ['^\s*question\s*$', '^\s*\? ']
    any = [
      { contains = ["↵ choose"] },
      { contains = ["↵ toggle"] },
      { contains = ["↵ save"] },
    ]

    [[rules]]
    id = "legacy_approval_panel"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    contains = ["requesting approval", "reject"]
    any = [
      { contains = ["approve once"] },
      { contains = ["approve for this session"] },
    ]
    all = [
      { any = [{ contains = ["1/2/3/4 choose"] }, { contains = ["↵ confirm"] }] },
    ]

    [[rules]]
    id = "background_agent_status_working"
    state = "working"
    priority = 120
    region = "bottom_non_empty_lines(3)"
    visible_working = true
    line_regex = ['(?i)\bkimi[-\w.]*\s+thinking\b.*\[[1-9][0-9]*\s+agents?\s+running\]']

    [[rules]]
    id = "moon_spinner_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    line_regex = ['^\s*(🌕|🌖|🌗|🌘|🌑|🌒|🌓|🌔)\s*$']

    [[rules]]
    id = "braille_spinner_working"
    state = "working"
    priority = 90
    region = "whole_recent"
    visible_working = true
    line_regex = ['(?i)^\s*[\u2800-\u28FF]+\s*(thinking\.\.\.|working\.\.\.|using )']
    """#

    static let kiroTOML = #"""
    id = "kiro"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["kiro-cli"]

    [[rules]]
    id = "tool_approval"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    contains = ["requires approval"]
    any = [
      { contains = ["yes, single permission"] },
      { contains = ["trust, always allow"] },
      { contains = ["no (tab to edit)"] },
      { contains = ["esc to close"] },
    ]

    [[rules]]
    id = "subagent_approval"
    state = "blocked"
    priority = 290
    region = "whole_recent"
    visible_blocker = true
    contains = ["pending from subagents"]
    any = [
      { contains = ["tool approval"] },
      { contains = ["tool approvals"] },
    ]
    all = [
      { any = [{ contains = ["approve all pending"] }, { contains = ["configure individually"] }, { contains = ["exit (cancel subagents)"] }] },
    ]

    [[rules]]
    id = "kiro_working_marker"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["kiro is working"]

    [[rules]]
    id = "tool_spinner_working"
    state = "working"
    priority = 90
    region = "whole_recent"
    visible_working = true
    contains = ["esc to cancel"]
    line_regex = ['^\s*(◔|◑|◕|●)\s+\p{Alphabetic}']
    """#

    static let droidTOML = #"""
    id = "droid"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"

    [[rules]]
    id = "execute_selection_blocker"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    contains = ["enter to select", "esc to cancel"]
    any = [
      { contains = ["↑↓ to navigate"] },
      { contains = ["use ↑↓ to navigate"] },
    ]
    all = [
      { any = [{ contains = ["> yes, allow"] }, { contains = ["> no, cancel"] }] },
    ]

    [[rules]]
    id = "selection_menu_blocker"
    state = "blocked"
    priority = 290
    region = "bottom_non_empty_lines(8)"
    visible_blocker = true
    contains = ["enter select", "esc cancel"]
    any = [
      { contains = ["↑/↓ navigate"] },
      { contains = ["↑↓ navigate"] },
    ]

    [[rules]]
    id = "spinner_stop_working"
    state = "working"
    priority = 110
    region = "whole_recent"
    visible_working = true
    contains = ["esc to stop"]
    line_regex = ['^\s*[\u2800-\u28FF]']

    [[rules]]
    id = "stop_hint_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["esc to stop"]
    """#

    static let ampTOML = #"""
    id = "amp"
    version = "2026.07.09.1"
    min_engine_version = 2
    updated_at = "2026-07-09T00:00:00Z"
    aliases = ["amp-local"]

    [[rules]]
    id = "osc_title_plugin_confirmation_blocked"
    state = "blocked"
    priority = 1100
    region = "osc_title"
    visible_blocker = true
    contains = ["Plugin confirmation needed"]

    [[rules]]
    id = "osc_title_working"
    state = "working"
    priority = 1050
    region = "osc_title"
    visible_working = true
    regex = ['^[\x{2800}-\x{28FF}] ']

    [[rules]]
    id = "approval_footer"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["waiting for approval"] },
      { contains = ["invoke tool"] },
      { contains = ["run this command?"] },
      { contains = ["allow editing file:"] },
      { contains = ["allow creating file:"] },
      { contains = ["confirm tool call"] },
      { contains = ["approve"], any = [{ contains = ["allow all for this session"] }, { contains = ["allow all for every session"] }, { contains = ["allow file for every session"] }, { contains = ["deny with feedback"] }] },
    ]

    [[rules]]
    id = "status_footer_working"
    state = "working"
    priority = 200
    region = "bottom_non_empty_lines(5)"
    visible_working = true
    line_regex = ['(?i)^\s*╰\s+\S+\s+(thinking|streaming|running tools|waiting)\s+─']

    [[rules]]
    id = "esc_cancel_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["esc to cancel"]

    [[rules]]
    id = "osc_title_idle"
    state = "idle"
    priority = 50
    region = "osc_title"
    visible_idle = true
    contains = [" - amp - "]
    not = [
      { regex = ['^[\x{2800}-\x{28FF}] '] },
      { contains = ["Plugin confirmation needed"] },
    ]
    """#

    static let grokTOML = #"""
    id = "grok"
    version = "2026.07.16.2"
    min_engine_version = 3
    updated_at = "2026-07-16T00:00:00Z"
    aliases = ["grok-build"]

    # Evidence: Grok Build 0.2.101 source and live pane reads.
    #
    # Grok emits OSC 0 titles by default. Idle is "grok" or
    # "<session> - grok". During a turn, the configured title gains a braille
    # spinner and activity text. Permission prompts add "⚠ Action Required";
    # that prefix blinks while the terminal is unfocused, so visible blocker
    # rules outrank the generic non-idle title rule.
    #
    # Grok also emits OSC 9;4 progress on supported terminals. Herdr retains the
    # payload after "9;": "4;1;-1" while busy and "4;0;0" when idle.
    #
    # Working turns render one live status line directly above the prompt box:
    #   "⠧ Waiting on subagent… 2.8s   13s ⇣29.7k [stop]"
    #   "⠴ Explore /tmp/… + 1 more… 5.6s   19s ⇣29.7k [stop]"
    # with a braille spinner and a trailing [stop] chip, plus an Esc:cancel
    # footer hint. Permission prompts and ask-user-question dialogs replace the
    # spinner with "◆" and draw a "┃"-guttered option list:
    #   "┃  2 (○) Yes, proceed"
    #   "┃  z (○) Type your answer here"
    # with footer hints "1/3:select │ Ctrl+o:yolo │ Ctrl+c:cancel" (permission)
    # or "Esc:unselect │ Tab:scrollback │ Shift+x:dismiss" (question dialog).
    # Idle footers end with "Ctrl+.:shortcuts" and never contain "Esc:cancel".
    # The startup splash draws its logo with braille characters, so working
    # rules must anchor on the [stop] chip, not on a bare spinner glyph.

    [[rules]]
    id = "osc_title_blocked"
    state = "blocked"
    priority = 1300
    region = "osc_title"
    visible_blocker = true
    contains = ["Action Required"]

    [[rules]]
    id = "option_dialog_blocked"
    state = "blocked"
    priority = 1200
    region = "whole_recent"
    visible_blocker = true
    line_regex = ['^\s*┃\s+[0-9a-z]+\s+\([●○]\)\s']

    [[rules]]
    id = "permission_hints_blocked"
    state = "blocked"
    priority = 1190
    region = "bottom_non_empty_lines(2)"
    visible_blocker = true
    contains = [":select", "ctrl+o:yolo", "ctrl+c:cancel"]

    [[rules]]
    id = "question_dialog_hints_blocked"
    state = "blocked"
    priority = 1185
    region = "bottom_non_empty_lines(2)"
    visible_blocker = true
    contains = ["tab:scrollback", "shift+x:dismiss"]

    # Pre-0.2.x permission UI kept for older Grok Build releases.
    [[rules]]
    id = "permission_scope_selector"
    state = "blocked"
    priority = 1180
    region = "whole_recent"
    visible_blocker = true
    contains = ["yes, proceed", "no, reject"]
    any = [
      { contains = ["use ← → to choose permission whitelist scope"] },
      { contains = ["←/→:scope"] },
    ]

    # Grok clears its OSC busy signals while background work runs. The first
    # non-empty row is pinned application chrome, where this animated chip shows
    # the number of running background tasks and disappears when the count is zero.
    [[rules]]
    id = "background_work_chip_working"
    state = "working"
    priority = 1170
    region = "top_non_empty_lines(1)"
    visible_working = true
    line_regex = ['[⋅:⸬⁙.·]\s+[1-9][0-9]*\s+│']

    [[rules]]
    id = "osc_progress_working"
    state = "working"
    priority = 1150
    region = "osc_progress"
    visible_working = true
    regex = ['^4;1;-1$']

    [[rules]]
    id = "osc_title_idle"
    state = "idle"
    priority = 1100
    region = "osc_title"
    visible_idle = true
    regex = ['(?:^| - )grok$']
    not = [
      { regex = ['[\x{2800}-\x{28FF}]'] },
    ]

    # After known idle titles are excluded, any other non-empty Grok title is
    # active. OSC progress remains authoritative when a custom title omits the
    # spinner but the terminal supports progress reporting.
    [[rules]]
    id = "osc_title_working"
    state = "working"
    priority = 1000
    region = "osc_title"
    visible_working = true
    regex = ['\S']

    [[rules]]
    id = "osc_progress_idle"
    state = "idle"
    priority = 950
    region = "osc_progress"
    visible_idle = true
    regex = ['^4;0;0$']

    [[rules]]
    id = "spinner_status_working"
    state = "working"
    priority = 200
    region = "whole_recent"
    visible_working = true
    line_regex = ['^\s*[\x{2801}-\x{28FF}]\s.*\[stop\]\s*$']

    [[rules]]
    id = "esc_cancel_hints_working"
    state = "working"
    priority = 190
    region = "bottom_non_empty_lines(2)"
    visible_working = true
    contains = ["esc:cancel", "ctrl+.:shortcuts"]

    # Pre-0.2.x working chrome kept for older Grok Build releases.
    [[rules]]
    id = "waiting_tool_working"
    state = "working"
    priority = 120
    region = "whole_recent"
    visible_working = true
    any = [
      { all = [{ contains = ["ctrl+c:cancel", "ctrl+enter:interject"] }, { contains = ["waiting"] }] },
      { line_regex = ['^\s*[\x{2801}-\x{28FF}]\s+(Run|Read|Search|List)\b'] },
    ]

    [[rules]]
    id = "prompt_hints_idle"
    state = "idle"
    priority = 100
    region = "bottom_non_empty_lines(2)"
    visible_idle = true
    contains = ["ctrl+.:shortcuts"]
    not = [
      { contains = ["esc:cancel"] },
      { contains = ["ctrl+c:cancel"] },
    ]
    """#

    static let hermesTOML = #"""
    id = "hermes"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["hermes-agent"]

    [[rules]]
    id = "dangerous_command_approval"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["dangerous command"] },
      { contains = ["allow once", "allow for this session", "deny"] },
    ]
    all = [
      { any = [{ contains = ["enter to confirm"] }, { contains = ["↑/↓ to select"] }, { contains = ["show full command"] }] },
    ]

    [[rules]]
    id = "interrupt_status_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    any = [
      { contains = ["msg=interrupt"] },
      { contains = ["ctrl+c cancel"] },
    ]
    """#

    static let kiloTOML = #"""
    id = "kilo"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["kilo-code", "kilo code", "herdr:kilo"]

    [[rules]]
    id = "opencode_permission"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["△ Permission required"] },
      { contains = ["esc dismiss"], any = [{ contains = ["enter confirm"] }, { contains = ["enter submit"] }, { contains = ["enter toggle"] }], all = [{ any = [{ contains = ["↑↓ select"] }, { contains = ["⇆ tab"] }] }] },
    ]

    [[rules]]
    id = "esc_interrupt_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["esc interrupt"]
    """#

    static let qodercliTOML = #"""
    id = "qodercli"
    version = "2026.06.10.1"
    min_engine_version = 1
    updated_at = "2026-06-10T00:00:00Z"
    aliases = ["qoderclicn", "qoder", "qodercn"]

    [[rules]]
    id = "confirmation_or_input_blocker"
    state = "blocked"
    priority = 300
    region = "whole_recent"
    visible_blocker = true
    any = [
      { contains = ["waiting for user confirmation"], any = [{ contains = ["yes"] }, { contains = ["no"] }, { contains = ["allow"] }, { contains = ["reject"] }] },
      { contains = ["awaiting approval"], any = [{ contains = ["allow"] }, { contains = ["reject"] }] },
      { contains = ["permission required"] },
      { contains = ["allow once or always?"] },
      { contains = ["asking user"] },
      { contains = ["enter your response"] },
      { contains = ["review your answers:"] },
      { contains = ["shell awaiting input"] },
    ]

    [[rules]]
    id = "cancel_hint_working"
    state = "working"
    priority = 100
    region = "whole_recent"
    visible_working = true
    contains = ["(esc to cancel,"]

    [[rules]]
    id = "spinner_working"
    state = "working"
    priority = 90
    region = "whole_recent"
    visible_working = true
    line_regex = ['^\s*[\u2800-\u28FF]\s+.*\p{Alphabetic}']
    """#

    static let makiTOML = #"""
    id = "maki"
    version = "2026.07.09.2"
    min_engine_version = 1
    updated_at = "2026-07-09T00:00:00Z"

    # Maki renders a persistent one-line status bar on the bottom row. It starts
    # with the mode label "[BUILD]", "[PLAN]", or "[BASH]" when idle and gets a
    # leading braille spinner cell while the agent is streaming. Permission
    # requests and the plan-complete form replace the input box above the status
    # bar. Maki does not set OSC title or OSC 9;4 progress.

    [[rules]]
    id = "permission_prompt"
    state = "blocked"
    priority = 980
    region = "whole_recent"
    visible_blocker = true
    contains = ["permission required"]
    any = [
      { contains = ["y allow", "n deny"] },
      { contains = ["confirm allow"] },
      { contains = ["confirm deny"] },
      { contains = ["enter deny", "esc cancel"] },
    ]

    [[rules]]
    id = "plan_complete_form"
    state = "blocked"
    priority = 970
    region = "whole_recent"
    visible_blocker = true
    contains = ["plan complete", "enter confirm"]
    any = [
      { contains = ["space toggle parallel"] },
      { contains = ["edit plan"] },
    ]

    [[rules]]
    id = "status_bar_spinner_working"
    state = "working"
    priority = 900
    region = "bottom_non_empty_lines(1)"
    visible_working = true
    line_regex = ['^( [\x{2800}-\x{28FF}]){1,2} \[(BUILD|PLAN|BASH)\]']

    [[rules]]
    id = "status_bar_idle"
    state = "idle"
    priority = 850
    region = "bottom_non_empty_lines(1)"
    visible_idle = true
    line_regex = ['^ \[(BUILD|PLAN|BASH)\]']

    # On narrow panes the right side of the status bar overwrites the mode label,
    # so fall back to the prompt chevron above the input box border. The not-gates
    # keep this from matching the streaming placeholder or a status bar that still
    # shows the spinner.
    [[rules]]
    id = "prompt_box_idle"
    state = "idle"
    priority = 840
    region = "bottom_non_empty_lines(3)"
    visible_idle = true
    line_regex = ['^❯ ']
    not = [
      { contains = ["queue another prompt"] },
      { line_regex = ['^( [\x{2800}-\x{28FF}]){1,2} '] },
    ]
    """#
}

// swiftlint:enable line_length
