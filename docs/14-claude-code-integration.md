# 14 — Claude Code integration (+ Warp, herdr)

> Output of the research workflow (13 agents + adversarial verify). Use-case: running/controlling **Claude Code** (Anthropic CLI agent) over the terminal path (libghostty renderer). Full sources: [research/claude-code-warp-herdr-corpus.json](research/claude-code-warp-herdr-corpus.json).
>
> *As-of: Claude Code v2.1.x (2026-06). Claims tied to a version + undocumented flags → verify on the target CC version.*

## TL;DR
- **Hosting Claude Code:** native binary needing a real PTY + alt-screen. **Enable fullscreen** (`CLAUDE_CODE_NO_FLICKER=1`). PTY bridge forwards control sequences + kitty keyboard + SGR mouse + OSC 8/52/777 + bracketed paste **untouched**; set `COLORTERM=truecolor` + `TERM=xterm-ghostty`. ⚠️ Custom TERM → `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` mandatory (DEC 2026 bug). Image paste via OSC 5522 **does not work yet** (Ghostty parse-only) → don't ship it, document the limitation.
- **External input box (Warp-style) — DECIDED: A+B1:** (A) shell input box + block mode (`COMMAND_FINISHED` callback + self-sniffing `ESC[?1049h/l` to hide/show the box); (B1) Claude Code keeps its TUI + an overlay compose-box that writes bytes into the PTY (Warp Ctrl-G style). **Do NOT build B2 (SDK pane)** — structured view uses the read-only inspector [16]. See §"External input box".
- **Warp:** external input box = **client-side GUI editor, nothing sent to the PTY until Enter**; hides/shows on **DECSET 1049 (alt-screen)** which Warp parses itself in the VT stream (NOT raw-mode/termios). Block boundary: **`GHOSTTY_ACTION_COMMAND_FINISHED`** callback (exit_code+duration) — **no OSC 133** (Warp doesn't use it either; injecting it breaks Warp). ✅ **Input editor IS FEASIBLE on our stack.** Don't copy: Warp's GPU renderer / cloud orchestration.
- **herdr** = [github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) — Rust "agent multiplexer", 3.6k★, AGPL+commercial, NDJSON-over-Unix-socket, native Claude Code support. → **Be a FIRST-CLASS CLIENT** of herdr/orchestrators (speak NDJSON, avoid AGPL by not embedding the binary); **do NOT build our own orchestration product**. Our value = PTY transport + libghostty rendering + mobile client.

## Decisions made (+ open questions resolved)

**Decision 1 — `TERM = xterm-ghostty`** (native). Gets kitty keyboard (Shift+Enter, Cmd+C, modifier combos) + DEC 2026 sync auto-detect. ⚠️ **Accepted risk: paste bug #54700** (xterm-ghostty terminfo may mangle multi-line paste, newline→Enter; "not planned"). **Mitigation:** track #54700; consider client-side bracketed-paste wrapping + let the user toggle back to `xterm-256color`. (Inside **tmux**, `CLAUDE_CODE_FORCE_SYNC_OUTPUT` is ineffective → run CC directly in the PTY, no tmux nesting unless required.)

**Decision 2 — Auth = Subscription OAuth + `claude setup-token`** (1-year token for the headless host daemon). Interactive sessions do **NOT** consume Agent SDK credit → daily coding uncapped. ⚠️ **Refinement ([15](15-prior-art-happy-happier.md)):** safest is to **reuse `~/.claude/.credentials.json`** (have `claude` already logged in) instead of running PKCE ourselves — the `user:inference` scope (happy) is NOT confirmed to grant Pro/Max quota vs. API-billed only. Set `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK) when spawning headless so the session resumes from a terminal. ⚠️ If we later build an **SDK-driven agent pane (P1)** on OAuth → `claude -p`/SDK **consumes Agent SDK credit** (from 2026-06-15) **and** `--bare` cannot be used (bare requires an API key). → SDK pane on OAuth: drop `--bare`, or use a dedicated API key just for that pane.

**libghostty open questions — RESOLVED (read the source):**
- **Alt-screen (1049)**: ✅ works through the external backend (same VT parser) → fullscreen CC OK.
- **Parsed stream vs pixels**: API is **OPAQUE** — no parsed stream/grid; only **action callbacks** (COMMAND_FINISHED/PWD/TITLE/PROGRESS) + `read_text` → **block/status UI via callbacks**, no raw OSC parsing.
- **Kitty keyboard**: ✅ Ghostty encodes it via `ghostty_surface_key()` → route every key through it (NOT the Lakr233 bypass path). Consistent with `xterm-ghostty`.
- **TCP-split OSC**: ✅ only buffering needed (VT parser is stateful), no loss-recovery.
- Details + remaining spikes: [12 open-questions](12-coding-profile.md), `research/resolve-open-questions-corpus.json`.

## External input box (Warp-style) — design for our stack

> Source: `research/warp-input-box-corpus.json`. **How Warp does it in 2026:** input box = a GUI editor inside the Warp process, keys do NOT reach the PTY until Enter; hide/show follows the `TerminalInputState` state machine (AltScreen / InputEditor / LongRunningCommand) **driven by DECSET 1049/47** that Warp parses itself — NOT raw-mode/termios detection.

**A. Shell commands → native input box + block mode — FEASIBLE (~2–4 weeks).**
- SwiftUI input box pinned to the bottom; Enter → write the whole line to the PTY master; output renders in the ghostty surface above.
- Block boundary: **`GHOSTTY_ACTION_COMMAND_FINISHED`** (exit_code+duration) from `action_cb` — **no OSC 133 needed**.
- ⚠️ **MANDATORY: sniff the byte stream BEFORE feeding ghostty** — scan ~6 fixed sequences `ESC[?1049h/l`, `ESC[?1047h/l`, `ESC[?47h/l`. On `h` → `altScreenActive=true`, hide the input box, forward keys raw (vim/btop/htop owns the screen); on `l` → flip back. Exactly Warp's mechanism; small fixed-length parser, no full VT parse (~1–2 weeks after A). Why sniff ourselves: **the libghostty surface is OPAQUE, no alt-screen action** (`GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN` only exists in `libghostty-vt`, unreachable through the surface).
- Hard parts: hiding shell echo so it doesn't overwrite the input box (shell integration / echo management); multi-line + history.

**B. Claude Code → external input box: two routes (a DECISION was needed).**
> Running `claude` inside Warp → still **Claude Code's own TUI**; Warp only wraps a footer + a Ctrl-G overlay that **writes bytes straight into the PTY** (DelayedEnter ~50ms). **The native input box + tool-call cards exist ONLY for Warp's own agent (Oz), NOT for the CC CLI.** CC has 2 modes: classic (inline, no 1049) and **fullscreen (alt-screen, opt-in via `/tui fullscreen`/`CLAUDE_CODE_NO_FLICKER=1`)**.
- **B1 — overlay compose-box (Warp Ctrl-G style):** keep CC's TUI, add a native overlay, submit = PTY write that fakes typing. **Cheap** but **fragile** (must hit the moment CC is at its prompt; conflicts with Shift+Tab/focus like Warp bugs #9179/#9365). No native cards.
- **B2 — SDK pane (Oz style, "true Warp-style"):** don't run the TUI; drive CC via `claude -p --output-format stream-json --include-partial-messages`, parse NDJSON (`assistant`/`text_delta`, `tool_use`, `tool_result`, `result`) → native tool-call cards + a real input box. **Expensive (~4–8 weeks — writing a CC frontend).** ⚠️ Billing: SDK metered separately (Agent SDK credit) on subscriptions; verify headless OAuth runs on the remote host before committing.

**✅ DECIDED: A + B1** (shell input box + overlay compose-box for CC, keeping the TUI); the structured view is the read-only inspector [16] (does not drive the agent), so the SDK pane (B2) is not built. B2 kept only as context.

**Implementing B1 (avoid Warp-style bugs):**
- Native overlay compose-box; submit = write bytes into the PTY + **DelayedEnter** (text first, `\r` after ~50ms).
- **Gate availability on agent state:** detect `claude` is running (command name) + use **CC lifecycle hooks** (OSC 777 / `terminalSequence`) to know when CC is at prompt/idle → enable the overlay only then (avoid injecting mid-render/mid-tool).
- **Don't swallow keys CC needs:** especially **Shift+Tab** (CC switches modes — Warp bug #9179) and focus/Esc. The overlay captures keys only while focused; yields to the TUI otherwise.
- No native tool-call cards (cards were the SDK pane's job — dropped); the overlay just pre-composes text into the TUI. Structured view → read-only inspector [16].
- ⚠️ **Duplicate-prompt dedup (MANDATORY, lesson from Happy/Happier [15](15-prior-art-happy-happier.md)):** B1 exposes BOTH the compose-box AND the PTY feeding prompts → the prompt enters the transcript twice. Keep a **dedup ring buffer (text + timestamp)**.
- ⚠️ **stdin `O_NONBLOCK` (Happy #301):** `setBlocking(true)` to clear the O_NONBLOCK libuv leaves behind, before spawning — else the TUI echoes garbled / cursor doubles.

**Test to run (not a decision):** has CC fullscreen become default on the target version → `script -q /dev/null claude 2>&1 | xxd | grep "1049"` (`\x1b[?1049h` = on the alt-screen). Determines whether the alt-screen parser catches interactive CC.

---

## Integrating Claude Code + Warp + HERDR into the remote-coding tool (libghostty terminal path)

Based on the adversarially verified corpus; **refuted**/**uncertain** claims flagged at each load-bearing spot.

---

### 1. Claude Code integration: TUI requirements (+ why NOT the SDK pane route)

> **Decision: run the real TUI, do NOT drive via the Agent SDK (B2 dropped).** The SDK tier analysis below is context only.

#### 1.1. What Claude Code is (terminal-wise)
Claude Code is a **native binary** (x64/ARM64, installed to `~/.local/bin/claude`), NOT a Node.js TUI wrapper — npm is only a distribution channel ([code.claude.com/docs/en/setup](https://code.claude.com/docs/en/setup)). Needs a **real PTY** on Unix (reads terminal dimensions, emits escape sequences, uses alt-screen). Works over the terminal path *if* the transport is faithful to PTY signals (SIGWINCH/`TIOCSWINSZ`) and doesn't strip escape sequences.

**Two render modes:**
- **Inline-scrollback (default)**: appends to the host terminal's scrollback. Has the SIGWINCH bug — every resize writes a new frame without erasing the old, flooding scrollback ([#49086](https://github.com/anthropics/claude-code/issues/49086), [#20094](https://github.com/anthropics/claude-code/issues/20094)).
- **Fullscreen alt-screen (opt-in)**: `CLAUDE_CODE_NO_FLICKER=1` or `/tui fullscreen` (needs v2.1.89+) — alternate screen buffer like vim, flat memory, fewer bytes/frame, adds mouse ([code.claude.com/docs/en/fullscreen](https://code.claude.com/docs/en/fullscreen)).

> **For a remote PTY at any non-trivial latency, fullscreen is the only correct mode** (isolates redraws, fewer bytes/frame). Enable by default.

#### 1.2. TUI requirements — MUST support (in priority order)

| # | Requirement | Why / source |
|---|---------|----------------|
| 1 | **Propagate `COLORTERM=truecolor` into the PTY env** | UI (spinner, permission borders, diff bg, statusline) is hardcoded 24-bit ANSI. Remote shells usually don't advertise COLORTERM → washed-out colors ([terminal-config](https://code.claude.com/docs/en/terminal-config), [#35806](https://github.com/anthropics/claude-code/issues/35806)) |
| 2 | **Set `TERM=xterm-ghostty`** | libghostty's native TERM; enables kitty keyboard for the client. ⚠️ See DEC 2026 caveat below |
| 3 | **Forward kitty keyboard protocol reports untouched** | Shift+Enter, Option+Enter, modifier combos depend on it. Ctrl+J always inserts a newline in every terminal ([interactive-mode](https://code.claude.com/docs/en/interactive-mode)) |
| 4 | **Enable fullscreen by default** (`CLAUDE_CODE_NO_FLICKER=1`) | As above |
| 5 | **Forward SGR mouse tracking reports** | Fullscreen requests mouse; click-to-position, click-expand tool results, drag-select → OSC 52 copy |
| 6 | **Pass OSC 52 + OSC 8 untouched** through the TCP byte stream | Clipboard copy + clickable hyperlinks. Do NOT rewrite/strip ([#21586](https://github.com/anthropics/claude-code/issues/21586), [fullscreen](https://code.claude.com/docs/en/fullscreen)) |
| 7 | **Forward SIGWINCH + update the PTY ioctl, debounce ~50ms** | Reduces redraw floods over the network |
| 8 | **Forward Ctrl+C / Ctrl+D / Esc / double-Esc WITHOUT translation** | CC-specific behavior (Esc = stop turn, double-Esc = rewind menu), not POSIX defaults ([interactive-mode](https://code.claude.com/docs/en/interactive-mode)) |
| 9 | **Bracketed paste** (mode 2004) wrappers `ESC[200~`/`ESC[201~` | Pastes >10,000 chars collapse into `[Pasted text]`; `-p` mode caps stdin at 10MB ([headless](https://code.claude.com/docs/en/headless)) |

#### 1.3. Two load-bearing caveats (verified — read before shipping)

- **⚠️ DEC 2026 synchronized output with `xterm-ghostty` — CONFIRMED problem.** Since v2.1.110, CC switched from dynamic capability detection to a **hardcoded TERM allowlist**: it sends DEC 2026 only when TERM is *exactly* `xterm-ghostty` or `xterm-kitty` ([#49584](https://github.com/anthropics/claude-code/issues/49584), [#55613](https://github.com/anthropics/claude-code/issues/55613)). The `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` workaround shipped v2.1.129 but **the root cause (allowlist instead of DECRQM) remains unfixed** as of v2.1.159. → **Custom TERM ⇒ you MUST set `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1`.** Keeping exactly `xterm-ghostty` works natively, but watch the terminfo paste-tokenization bug ([#54700](https://github.com/anthropics/claude-code/issues/54700)) — if it manifests, expose a toggle to `xterm-256color` (disables DEC 2026 but avoids the paste bug).

- **❌ Image paste via OSC 5522 — REFUTED, do NOT ship.** Corpus said "Ghostty PR in progress"; WRONG both ways: Ghostty PR #10560 was **MERGED 2026-02-16 (shipped in 1.3.0)** but is **parse-only, does NOT implement the behavior** ([PR #10560](https://github.com/ghostty-org/ghostty/pull/10560), [1.3.0 notes](https://ghostty.org/docs/install/release-notes/1-3-0)). The accepted implementation is [issue #10549](https://github.com/ghostty-org/ghostty/issues/10549) ("we can figure out how to impl this later") — **no PR yet**. CC issue #42712 could NOT be verified (GitHub: ISSUE NOT FOUND). → **Ghostty silently parses and ignores OSC 5522.** Document as a known limitation; interim workaround: macOS native Ctrl+V (not Cmd+V), or Kitty (full support).

#### 1.4. Going deeper via the Agent SDK (just-run-TUI vs SDK-driven) — analysis only; **SUPERSEDED by the A+B1 decision (B2/SDK pane dropped)**

Three integration tiers:
- **TUI tier (PTY passthrough)** — full interactive experience, but pushing ANSI pixels over the network is latency-sensitive. [#20286](https://github.com/anthropics/claude-code/issues/20286): at ~500ms RTT a permission dialog arrived 30+ min late (VS Code-specific serialization; raw PTY lacks that bug, but the React renderer re-renders per token → many small writes → typing latency).
- **Headless tier (`claude -p`)** — non-interactive, `--output-format stream-json` emits NDJSON (text_delta, tool use, system/init), `--json-schema`, `--continue`/`--resume SESSION_ID`. ⚠️ `--bare` = `settingSources:[]` = **DISABLES** skills/commands/CLAUDE.md/hooks → **don't use it if you need feature parity** (the default loads everything) ([headless](https://code.claude.com/docs/en/headless)).
- **Agent SDK tier** (`@anthropic-ai/claude-agent-sdk` / `claude-agent-sdk`) — `query()` async generator yields typed messages; PreToolUse/PostToolUse hooks in-process; subagent definitions; MCP attachment; session resumption. The TS SDK **bundles the native binary as an optional dep** — no separate install needed ([agent-sdk/overview](https://code.claude.com/docs/en/agent-sdk/overview)).

> **Hybrid architecture recommendation:** keep the raw PTY path for the full TUI; **add an SDK-driven agent pane** (native SwiftUI) for structured interaction. SDK output is **JSON over stdout — far more tolerant of network buffering than raw ANSI**. Map: tool invocations → UI cards, text_delta → streaming pane, permission approval → native buttons, session cost/model → status bar.
>
> ⚠️ **CORRECTION (feature parity — `research/sdk-feature-parity-corpus.json`):** **do NOT use `--bare`** for the SDK pane if you want skills/custom commands! `--bare` = `settingSources: []` = **disables all** `.claude/` config (skills, commands, CLAUDE.md, hooks, subagents). By default (omitting `settingSources`) the SDK **loads EVERYTHING** (`["user","project","local"]`, matching the CLI) → **skills + custom slash commands work IMMEDIATELY**. Only requirement: **`cwd` at the project root**. See §"Skills/slash in the SDK".

> **⚠️ Billing — CONFIRMED:** from **2026-06-15**, `claude -p` and the Agent SDK on **subscription plans** draw from a separate "monthly Agent SDK credit" ($20 Pro / $100 Max-5x / $200 Max-20x). **API-key auth (`ANTHROPIC_API_KEY`) is NOT affected** — pay-as-you-go ([support 15036540](https://support.claude.com/en/articles/15036540)). → API-key auth = no issue; OAuth/subscription = warn the user.

---

### 2. Warp terminal: what to learn — must-have vs nice-to-have vs don't copy

#### 2.1. Core insight
Warp's block model's power **comes entirely from shell-integration signals, NOT the renderer**. Warp is not a PTY-passthrough emulator: it owns the input editor (buffers keystrokes client-side, writes to the PTY only on Enter), and groups output into typed blocks via **injected shell hooks** (precmd/preexec) emitting JSON metadata inside an escape sequence ([how-warp-works](https://www.warp.dev/blog/how-warp-works), [block-model blog](https://www.warp.dev/blog/block-model-behind-warps-agentic-development-environment)).

> **⚠️ Protocol correction (CONFIRMED):** Warp uses **DCS** (`\eP$f{JSON}\x9c`) as its primary protocol on **macOS/Linux**, NOT OSC 133. On **Windows** it uses a **custom OSC** because ConPTY swallows DCS ([building-warp-on-windows](https://www.warp.dev/blog/building-warp-on-windows)). **Warp does NOT consume OSC 133** — injecting OSC 133 markers *breaks* Warp's rendering ([Warp #6718](https://github.com/warpdotdev/warp/issues/6718)). Warp went open-source (2026-04-28, client AGPL v3 + UI crates MIT) but **the Rust terminal-emulation source is not in the public tree yet** — protocol only verifiable from docs/blog, not source.

Key point: you do **not** use Warp's proprietary DCS protocol. You use **OSC 133** (open standard: A=prompt start, B=command start, C=output begins, D=command finished + exit code) which iTerm2/Ghostty/Kitty/WezTerm/Windows Terminal all implement. **Ghostty (libghostty) already implements OSC 133** for bash/zsh/fish/elvish/nushell. Open issue asking CC to emit OSC 133 ([#22528](https://github.com/anthropics/claude-code/issues/22528)) — **but CC does NOT emit OSC 133 today** (claims_to_verify; open issues #1465, #32635). So block detection applies to **shell commands** around/outside CC, not inside a CC session.

#### 2.2. Transferability classification

**MUST-HAVE:**
1. **OSC 133 shell-integration injection on the remote host** — the PTY runs over plain TCP on the trusted private network (direct P2P), escape sequences flow intact, **no side channel or remote-server binary needed** (unlike Warp SSH). Enabling primitive for block grouping, exit-code coloring, prompt-jump.
2. **CC lifecycle hooks in the style of `claude-code-warp`** — a shell-script hook for 6 events (SessionStart, Stop, Notification, PermissionRequest, UserPromptSubmit, PostToolUse), emitting OSC 777 → drives a "running / needs permission / done" status pane. ⚠️ **CONFIRMED but partially outdated:** the `\033]777;notify;warp://cli-agent;<JSON>\007` format is correct for CC **< 2.1.141**; from **CC ≥ 2.1.141** the plugin switched to a `terminalSequence` JSON field on stdout (the Stop hook validator rejects unknown fields), bypassing `/dev/tty`. **Handle BOTH paths** ([warpdotdev/claude-code-warp](https://github.com/warpdotdev/claude-code-warp), `emit-terminal-sequence.sh`).
3. **Bidirectional PTY fidelity including control sequences** (Ctrl+C/Z/D, arbitrary byte writes). Warp's #1 Terminal-Bench (52%, a self-reported **marketing claim**) shows this is the most important capability for agentic-coding correctness; a PTY that drops/delays control sequences breaks CC mid-task ([full-terminal-use](https://docs.warp.dev/agent-platform/capabilities/full-terminal-use/)).

**NICE-TO-HAVE (later):**
4. **Block-based UI** (height-indexed SumTree, GridStorage for active + FlatStorage for scrollback) — requires parsing OSC 133 in the client renderer. Good for navigation + AI context framing, but **not required** to run CC.
5. **MCP auto-discovery from `~/.claude.json` / `.mcp.json`** — Warp reads CC's own config files; users who configured them get the integration free ([MCP docs](https://docs.warp.dev/agent-platform/capabilities/mcp/)). Trivial UX, no protocol work.
6. **Rich-content blocks coexisting with terminal blocks** in the same BlockList (zero-height hidden blocks for collapsing) — fits the SDK structured event stream.

**DO NOT COPY:**
7. **Warp's input editor** (buffered keystrokes, multi-cursor) — incompatible with libghostty's external-backend model (renders the VT stream as-is). CC's TUI input is sufficient.
8. **Warp's GPU renderer / custom UI framework** — you already have libghostty Metal rendering.
9. **Oz cloud-agent orchestration + Warp Drive cloud sync** — proprietary, out of scope for a P2P tool.

---

### 3. What HERDR is + the multi-agent orchestration landscape

#### 3.1. HERDR — CONFIRMED, exact identity
[github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) (author Oğulcan Çelik). "Agent multiplexer that lives in your terminal" — a **Rust terminal multiplexer with agent awareness**, single binary. **3.6k stars, v0.6.6 (2026-05-31)** — CONFIRMED via live fetch. **Dual-licensed AGPL-3.0-or-later + commercial** (`hey@herdr.dev`) — CONFIRMED via LICENSE/Cargo.toml/nix ([herdr LICENSE](https://github.com/ogulcancelik/herdr/blob/main/LICENSE)). macOS/Linux, **no Windows** (Unix sockets).

Not a CC plugin/framework. Architecture: a **background server managing workspaces/tabs/panes, each backed by a real vt100 PTY**; a thin client connects locally or over SSH. State tracking uses 3 signals: **process detection + socket API reports + screen heuristics**. Natively integrates Claude Code (hook-based), Codex, OpenCode, Hermes, Pi, Qoder. Socket API = **NDJSON over a Unix domain socket, no auth** — an agent can create/destroy panes, read output, send keystrokes, report state (blocked/working/done/idle), wait on other agents, spawn helpers. `HERDR_ENV=1` tells the agent it's inside herdr; `SKILL.md` teaches CC to self-orchestrate.

> **⚠️ License note:** AGPL copyleft applies to the herdr *software*, NOT the *protocol*. A self-written Swift client that only **speaks the NDJSON protocol** does NOT distribute herdr code → not AGPL-bound (protocols aren't copyrightable). AGPL triggers only if you: (a) ship the herdr binary, (b) link the herdr library, (c) use herdr's Rust source. The commercial license (price unpublished) resolves all three.

> **Identity correction:** "Herd" ([joinherd.ai](https://joinherd.ai/)) and "AgentHerder" ([agentherder.com](https://agentherder.com/)) are **DIFFERENT projects**, not herdr. "herdctl" ([edspencer.net](https://edspencer.net/2026/1/29/herdctl-orchestration-claude-code)) is another MIT tool, Node.js, Docker-based, built on the Agent SDK.

#### 3.2. Landscape (universal pattern: git-worktree isolation per agent + task queue + human review gate)

- **Claude Code Agent Teams** (native, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, v2.1.32+): a lead session spawns N teammates (each a full session with its own context), a shared file-locked task list + mailbox. **⚠️ Split-pane mode CONFIRMED to NOT support Ghostty** (only tmux or iTerm2) ([agent-teams docs](https://code.claude.com/docs/en/agent-teams), [#24189](https://github.com/anthropics/claude-code/issues/24189) open). Blocker is on Ghostty's side (no stable CLI/IPC); [#26572](https://github.com/anthropics/claude-code/issues/26572) proposes a `CustomPaneBackend` protocol (JSON-RPC 2.0/NDJSON) that would unblock it — no Anthropic response yet.
- **Claude Squad** (smtg-ai, 7.7k★, Go, AGPL): tmux + worktree per agent, TUI dashboard.
- **Conductor** (conductor.build, macOS GUI, free BYOK): worktree per agent, diff-first review, no tmux.
- **Uzi** (devflowinc, Go, MIT): CLI `uzi prompt --agents claude:2,codex:1`, has `broadcast` + `checkpoint` for sweep workloads.
- **Claude Code Agent Farm** (Dicklesworthstone, Python): 20-50 agents via tmux panes, file-lock coordination (shared tree, no worktrees).
- **Vibe Kanban** (Apache-2.0, community-maintained after Bloop shut down early 2026): Kanban-card-per-worktree.

#### 3.3. Should the tool host/manage a herd of agents? — **YES, but only as the transport+rendering layer; do NOT build an orchestration product.**

Your tool is uniquely positioned to **natively host a herd of CC agents** — the PTY transport already provides the core primitive every other tool builds on. Opportunities, by value:
1. **Git worktree per agent** — every serious tool uses it. Host supports create/list/switch worktree (trivial shell) + exposes each worktree as a PTY session in the UI.
2. **Agent supervisor pane** (sidebar with blocked/working/done state) — the common herdr/Claude Squad/Conductor pattern. State detection uses 3 signals like herdr: process detection + CC hooks (Stop/TeammateIdle/TaskCompleted) + screen heuristics.
3. **HERDR compatibility** — speak the NDJSON socket protocol natively, so the macOS/iPad client renders herdr's workspace/tab/pane model with ghostty surfaces. Become a **first-class client** instead of a plain SSH terminal.
4. **Fill Agent Teams' Ghostty gap** — since Anthropic doesn't support Ghostty split panes, parse tmux pane-creation commands and translate into your multi-PTY model; or implement `CustomPaneBackend` (#26572) if it lands.
5. **Do NOT build:** a full git-worktree UI, a Kanban board, a multi-model routing layer — that's the product layer of herdr/Conductor/Claude Squad. **Your value = PTY transport + rendering quality (libghostty) + mobile client.** Be the *best PTY host* for those tools, don't replicate them.

---

### 4. ROADMAP RECOMMENDATIONS

#### Now (P0 — so Claude Code runs smoothly over the network PTY)
Sufficient conditions for the CC TUI to work correctly — do these first:
1. Set PTY env: `COLORTERM=truecolor`, `TERM=xterm-ghostty`. Custom TERM → `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` **mandatory** (DEC 2026 fix, CONFIRMED).
2. Enable fullscreen by default: `CLAUDE_CODE_NO_FLICKER=1`.
3. PTY bridge **bidirectional fidelity**: forward control sequences (Ctrl+C/D, Esc, double-Esc), kitty keyboard, SGR mouse, bracketed paste, OSC 8/52/777 **untouched**. Do NOT strip/rewrite.
4. SIGWINCH forwarding + ioctl update, **debounce ~50ms**.
5. Document the limitation: **image paste over a remote PTY is broken** (OSC 5522 not implemented in Ghostty — "PR in progress" REFUTED); workaround: macOS Ctrl+V.

#### Next (P1 — Warp-style external input box, DECIDED A+B1)
6a. **A — shell input box + block mode:** SwiftUI input box pinned to the bottom; Enter→PTY; block boundary via `GHOSTTY_ACTION_COMMAND_FINISHED`; an **`ESC[?1049h/l` sniffer** on the feed stream to hide/show the box (~2–4 weeks + 1–2 weeks for the sniffer). See §"External input box".
6b. **B1 — overlay compose-box for CC:** keep the TUI, overlay writes to the PTY + DelayedEnter, gated by lifecycle hooks, avoid swallowing Shift+Tab/focus.
6c. **OSC 133** (optional, richer metadata) + lifecycle hooks → status pane.
> **B2 (native SDK-driven agent pane) — NOT doing it.** The TUI keeps 100% of features natively; structured view = read-only inspector [16].
7. **OSC 133 shell-integration** injection on the remote host (libghostty already parses it) → block model for shell commands around CC: prompt-jump, exit-code coloring, per-block copy. CC **does not emit OSC 133 internally** so block grouping applies outside its session.
8. **CC lifecycle hooks** (claude-code-warp style, handling both the OSC 777 `/dev/tty` and the `terminalSequence` stdout path) → status pane.

#### Later (P2 — multi-agent / orchestration)
9. **Agent supervisor sidebar** + git-worktree-per-agent PTY sessions.
10. **HERDR socket-protocol client** (NDJSON, self-written — avoid AGPL by not embedding the binary/linking the library).
11. Fill Agent Teams' **Ghostty split-pane gap** (parse tmux commands or implement CustomPaneBackend if #26572 lands).

#### Fit into the hybrid terminal+GUI architecture
- **Terminal path (PTY over plain TCP / libghostty)**: P0 + P1.7/P1.8 — the backbone. The block model + OSC 133 live in the client-side VT parser of libghostty's external backend.
- **GUI path (ScreenCaptureKit + VideoToolbox)**: orthogonal (GUI windows); doesn't touch the PTY layer.
- **The SDK pane (P1.6)** is a *third tier*: not PTY, not video — native SwiftUI consuming a JSON stream. Where Warp's "rich-content blocks" map, and where the multi-agent supervisor (P2) displays state.

> ℹ️ **The 4 open questions above are RESOLVED** (later turn) — see [12 open-questions](12-coding-profile.md): alt-screen ✅ works; parsed stream **opaque** (use action callbacks); kitty keyboard ✅ via `ghostty_surface_key`; TCP only needs buffering.

## Skills / slash commands — run natively in the TUI

> ℹ️ **B2 was dropped** → we do NOT drive CC via the SDK. The TUI **is** the real Claude Code, so **skills + custom slash commands + every feature run 100% natively**, nothing extra needed. The SDK-parity analysis below is reference only (if reconsidered later).

> Source: `research/sdk-feature-parity-corpus.json`. Does a structured-event UI (SDK) support skills + custom slash commands like the TUI?

**YES — and nearly for free.** ⚠️ **Correction:** the SDK **loads `.claude/` config by DEFAULT** (omitting `settingSources` = `["user","project","local"]`, matching the CLI). **It is `--bare`/`settingSources:[]` that DISABLES everything** — don't use it. Only condition: **`cwd` at the project root** (via the host process, not the iOS sandbox).

| Feature | SDK | How |
|---------|-----|------|
| Skills (`.claude/skills`, model-invoked) | ✅ default | `skills:'all'` (enabled by default). ⚠️ `allowed-tools` in SKILL.md is **ignored** in the SDK → use `allowedTools` on `query()` |
| Custom slash (`.claude/commands/*.md`) | ✅ default | send `/cmd args` as the prompt; `$ARGUMENTS`/`$1`, `!\`bash\``, `@file` all expand |
| CLAUDE.md, subagents, MCP, hooks, plugins | ✅ default/config | automatic with default settingSources; or programmatic |
| `/compact`, `/clear` | ✅ | send as a prompt (streaming, CC v2.1.117+) |
| Autocomplete for commands/skills | ✅ | read `slash_commands`/`skills`/`plugins` from the `system/init` message → native palette |
| `@`-file-mentions | ❌ tui-only | SDK doesn't expand them → **native file picker** injects content into the prompt |
| `/model` `/config` `/agents` `/permissions` `/diff` `/memory` `/resume`(picker) | ❌ tui-only | **build native equivalents** (~15–20 controls: model picker, permissions toggle, usage card, diff viewer, CLAUDE.md editor...) |
| Agent teams, `/rewind` checkpoint | ❌ no SDK path | replace with programmatic subagents / session branching (`fork_session`) |

**Conclusion:** **core agent capabilities (skills, custom commands, subagents, MCP, hooks, CLAUDE.md) reach parity for FREE** in a structured UI; extra cost = ~15–20 native UI pieces for **management chrome** (not agent capability); real losses = agent teams + `/rewind` + visual grids. → **A structured iOS UI (B2) is feasible for skills + custom commands** — reinforcing the structured choice for iOS ([12 Phase 3](12-coding-profile.md)). **Desktop raw-PTY keeps 100% of features** (it *is* the TUI).
