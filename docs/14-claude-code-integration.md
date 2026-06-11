# 14 — Claude Code integration (+ Warp, herdr)

> Output of the research workflow (13 agents + adversarial verify). Use-case: running/controlling **Claude Code** (Anthropic CLI agent) through the remote-coding tool (libghostty/NetBird terminal path). Full sources: [research/claude-code-warp-herdr-corpus.json](research/claude-code-warp-herdr-corpus.json).
>
> *As-of: Claude Code v2.1.x (2026-06). Claims tied to a version + undocumented flags → verify on the target CC version.*

## TL;DR
- **Hosting Claude Code:** it is a native binary that needs a real PTY + alt-screen. **Enable fullscreen mode** (`CLAUDE_CODE_NO_FLICKER=1`) for the remote PTY. The PTY bridge must forward control sequences + kitty keyboard + SGR mouse + OSC 8/52/777 + bracketed paste **untouched**; set `COLORTERM=truecolor` + `TERM=xterm-ghostty`. ⚠️ If you emit a custom TERM → `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` is mandatory (DEC 2026 bug). Image paste via OSC 5522 **does not work yet** (Ghostty is parse-only) → do not ship it, document the limitation.
- **External input box (Warp-style) — DECIDED: A+B1:** (A) shell input box + block mode (`COMMAND_FINISHED` callback + self-sniffing `ESC[?1049h/l` to hide/show the box); (B1) Claude Code keeps its TUI + an overlay compose-box that writes bytes into the PTY (Warp's Ctrl-G style). **Do NOT build B2 (SDK pane)** — structured view uses the read-only inspector [16]. See §"External input box".
- **Warp:** the external input box = **a client-side GUI editor, nothing is sent to the PTY until Enter**; it hides/shows based on **DECSET 1049 (alt-screen)** which Warp parses itself in the VT stream (NOT raw-mode/termios). Block boundary: we use the **`GHOSTTY_ACTION_COMMAND_FINISHED`** callback (has exit_code+duration) — **no OSC 133 needed** (Warp doesn't use OSC 133 either; injecting it even breaks Warp). ✅ **The input editor IS FEASIBLE on our stack** (see §"External input box" below). Don't copy: Warp's GPU renderer / cloud orchestration.
- **herdr** = [github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) — a Rust "agent multiplexer", 3.6k★, AGPL+commercial, NDJSON-over-Unix-socket, native Claude Code support. → **Our tool should be a FIRST-CLASS CLIENT** of herdr/orchestrators (speak the NDJSON protocol, avoid AGPL by not embedding the binary), **do NOT build our own orchestration product**. Our value = PTY transport + libghostty rendering + mobile client.

## Decisions made (+ open questions resolved)

**Decision 1 — `TERM = xterm-ghostty`** (native). Gets kitty keyboard (Shift+Enter, Cmd+C, modifier combos) + DEC 2026 sync auto-detect. ⚠️ **Accepted risk: paste bug #54700** (the xterm-ghostty terminfo may mangle multi-line paste, newline→Enter; bug is "not planned"). **Mitigation:** track #54700; consider client-side paste handling (proper bracketed-paste wrapping) + let the user toggle back to `xterm-256color` if it bites. (If CC runs inside **tmux**, `CLAUDE_CODE_FORCE_SYNC_OUTPUT` is ineffective — architectural decision: run CC directly in the PTY, no tmux nesting unless required.)

**Decision 2 — Auth = Subscription OAuth + `claude setup-token`** (1-year token for the headless host daemon). Interactive sessions do **NOT** consume Agent SDK credit → daily coding is not capped. ⚠️ **Refinement from prior art ([15](15-prior-art-happy-happier.md)):** the safest approach is to **reuse `~/.claude/.credentials.json`** (have `claude` logged in already) instead of running PKCE ourselves — because the `user:inference` scope (used by happy) is NOT confirmed to grant Pro/Max quota vs. API-billed only. Set `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK) when spawning headless so the session can still be resumed from a terminal. ⚠️ **Interaction note:** if we later build an **SDK-driven agent pane (P1)** on OAuth → `claude -p`/SDK **consumes Agent SDK credit** (from 2026-06-15) **and** `--bare` cannot be used (bare requires an API key). → SDK pane on OAuth: drop `--bare`, or use a dedicated API key just for that pane.

**libghostty open questions — RESOLVED (read the source):**
- **Alt-screen (1049)**: ✅ works correctly through the external backend (same VT parser) → fullscreen Claude Code OK.
- **Parsed stream vs pixels**: the API is **OPAQUE** — no parsed stream/grid; there are **action callbacks** (COMMAND_FINISHED/PWD/TITLE/PROGRESS) + `read_text` → **block/status UI via callbacks**, no raw OSC parsing.
- **Kitty keyboard**: ✅ Ghostty encodes it itself via `ghostty_surface_key()` → route every key through it (do NOT use the Lakr233 bypass path). Consistent with the `xterm-ghostty` choice.
- **TCP-split OSC**: ✅ only buffering needed (the VT parser is stateful), no loss-recovery.
- Details + remaining spikes: [12 open-questions](12-coding-profile.md), `research/resolve-open-questions-corpus.json`.

## External input box (Warp-style) — design for our stack

> Source: `research/warp-input-box-corpus.json` (reading Warp's AGPL source). **How Warp actually does it in 2026:** the input box = a GUI editor inside the Warp process, keys do NOT reach the PTY until Enter; hide/show follows the `TerminalInputState` state machine (AltScreen / InputEditor / LongRunningCommand) **driven by DECSET 1049/47** that Warp parses itself — NOT raw-mode/termios detection.

**A. Shell commands → native input box + block mode — FEASIBLE (~2–4 weeks).**
- SwiftUI input box pinned to the bottom; Enter → write the whole line to the PTY master; output still renders in the ghostty surface above.
- Block boundary: use **`GHOSTTY_ACTION_COMMAND_FINISHED`** (exit_code+duration) from `action_cb` — **no OSC 133 needed**.
- ⚠️ **MANDATORY: sniff the byte stream BEFORE feeding ghostty** — scan for ~6 fixed sequences `ESC[?1049h/l`, `ESC[?1047h/l`, `ESC[?47h/l`. On `h` → `altScreenActive=true`, hide the input box, forward keys raw (vim/btop/htop owns the screen); on `l` → flip back. This is **exactly** Warp's mechanism; it's a small fixed-length parser, no full VT parse needed (~1–2 weeks after A). Why we must sniff ourselves: **the libghostty surface is OPAQUE, there is no alt-screen action** (`GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN` only exists in the `libghostty-vt` sub-lib, not reachable through the surface).
- Hard parts: hiding shell echo so it doesn't overwrite the input box (shell integration / echo management); multi-line + history.

**B. Claude Code → external input box: two routes (this is where a DECISION was needed).**
> The truth: running `claude` inside Warp → it is still **Claude Code's own TUI**; Warp only wraps a footer + a Ctrl-G overlay that **writes bytes straight into the PTY** (DelayedEnter ~50ms). **The native input box + tool-call cards exist ONLY for Warp's own agent (Oz), NOT for the Claude Code CLI.** CC has 2 modes: classic (inline, no 1049) and **fullscreen (alt-screen, opt-in via `/tui fullscreen`/`CLAUDE_CODE_NO_FLICKER=1`)**.
- **B1 — overlay compose-box (Warp Ctrl-G style):** keep CC's TUI, add a native overlay, submit = a PTY write that fakes typing. **Cheap** but **fragile** (must hit the moment CC is at its prompt; conflicts with Shift+Tab/focus like Warp bugs #9179/#9365). No native cards.
- **B2 — SDK pane (Oz style, "true Warp-style"):** do NOT run the TUI; drive CC via `claude -p --output-format stream-json --include-partial-messages`, parse NDJSON (`assistant`/`text_delta`, `tool_use`, `tool_result`, `result`) → native tool-call cards + a real input box. **Expensive (~4–8 weeks — writing a Claude Code frontend)** but this is what a real native input-box + cards means. ⚠️ Billing: the SDK is metered separately (Agent SDK credit) on subscriptions; verify headless OAuth runs on the remote host before committing.

**✅ DECIDED: A + B1** (shell input box + overlay compose-box for Claude Code, keeping the TUI). **Do NOT build B2 (SDK pane)** (best-only; structured view = read-only inspector [16], not driving the agent). The B2 section below is kept only as context.

**Implementing B1 (notes to avoid Warp-style bugs):**
- Native overlay compose-box; submit = write bytes into the PTY + **DelayedEnter** (text first, `\r` after ~50ms).
- **Gate availability on agent state:** detect that `claude` is running (command name) + use **Claude Code lifecycle hooks** (OSC 777 / `terminalSequence` — already covered in this doc) to know when CC is at prompt/idle → only enable the overlay then (avoid injecting while CC is mid-render/running a tool).
- **Don't swallow keys CC needs:** especially **Shift+Tab** (CC uses it to switch modes — Warp bug #9179) and focus/Esc. The overlay only captures keys while it has focus; yields back to the TUI otherwise.
- No native tool-call cards (cards were the SDK pane's job — dropped); the overlay is just a pre-compose layer that pours text into the TUI. Structured view → read-only inspector [16].
- ⚠️ **Duplicate-prompt dedup (MANDATORY, lesson from Happy/Happier [15](15-prior-art-happy-happier.md)):** B1 exposes BOTH the compose-box AND the PTY feeding prompts → the prompt enters the transcript twice. Keep a **dedup ring buffer (text + timestamp)**.
- ⚠️ **stdin `O_NONBLOCK` (Happy #301):** `setBlocking(true)` to clear the O_NONBLOCK libuv leaves behind, before spawning — otherwise the TUI echoes garbled / the cursor doubles.

**Test to run (not a decision):** has CC fullscreen become the default on the target version → `script -q /dev/null claude 2>&1 | xxd | grep "1049"` (seeing `\x1b[?1049h` = it is on the alt-screen). This determines whether the alt-screen parser will catch interactive CC.

---

## Integrating Claude Code + Warp + HERDR into the remote-coding tool (libghostty/NetBird)

The analysis below is based on the adversarially verified corpus; **refuted**/**uncertain** claims are flagged at each load-bearing spot.

---

### 1. Claude Code integration: TUI requirements (+ why NOT the SDK pane route)

> **Decision: run the real TUI, do NOT drive via the Agent SDK (B2 dropped).** The SDK tier analysis below remains as context only.

#### 1.1. What Claude Code is (terminal-wise)
Claude Code is a **native binary** (x64/ARM64, installed to `~/.local/bin/claude`), NOT a Node.js TUI wrapper — npm is only a distribution channel ([code.claude.com/docs/en/setup](https://code.claude.com/docs/en/setup)). It needs a **real PTY** on Unix (reads terminal dimensions, emits escape sequences, uses the alt-screen). That's good news for your architecture: a raw byte stream over NetBird works *if* the transport layer is faithful to PTY signals (SIGWINCH/`TIOCSWINSZ`) and doesn't strip escape sequences.

There are **two render modes**:
- **Inline-scrollback (default)**: appends to the host terminal's scrollback. This mode has the well-known SIGWINCH bug — every resize writes a new frame without erasing the old one, flooding the scrollback ([issue #49086](https://github.com/anthropics/claude-code/issues/49086), [#20094](https://github.com/anthropics/claude-code/issues/20094)).
- **Fullscreen alt-screen (opt-in)**: `CLAUDE_CODE_NO_FLICKER=1` or `/tui fullscreen` (needs v2.1.89+) — uses the alternate screen buffer like vim, flat memory, fewer bytes/frame, adds mouse support ([code.claude.com/docs/en/fullscreen](https://code.claude.com/docs/en/fullscreen)).

> **For a remote PTY at any non-trivial latency, fullscreen mode is the only correct mode.** It isolates redraws to the alt-screen and reduces bytes/frame — directly helping over WireGuard. Enable it by default.

#### 1.2. TUI requirements — MUST support (in priority order)

| # | Requirement | Why / source |
|---|---------|----------------|
| 1 | **Propagate `COLORTERM=truecolor` into the PTY env** | UI elements (spinner, permission borders, diff bg, statusline) are hardcoded 24-bit ANSI. Remote shells usually don't advertise COLORTERM → washed-out colors ([terminal-config](https://code.claude.com/docs/en/terminal-config), [#35806](https://github.com/anthropics/claude-code/issues/35806)) |
| 2 | **Set `TERM=xterm-ghostty`** | This is libghostty's native TERM; enables the kitty keyboard protocol for the client. ⚠️ See the DEC 2026 caveat below |
| 3 | **Forward kitty keyboard protocol reports untouched** | Shift+Enter, Option+Enter, modifier combos depend on it. Ctrl+J always inserts a newline in every terminal ([interactive-mode](https://code.claude.com/docs/en/interactive-mode)) |
| 4 | **Enable fullscreen mode by default** (`CLAUDE_CODE_NO_FLICKER=1`) | As above |
| 5 | **Forward SGR mouse tracking reports** | Fullscreen mode requests mouse; click-to-position, click-expand tool results, drag-select → OSC 52 copy |
| 6 | **Pass OSC 52 + OSC 8 untouched** through the TCP byte stream | Clipboard copy + clickable hyperlinks. Do NOT rewrite/strip ([#21586](https://github.com/anthropics/claude-code/issues/21586), [fullscreen](https://code.claude.com/docs/en/fullscreen)) |
| 7 | **Forward SIGWINCH + update the PTY ioctl, debounce ~50ms** | Reduces redraw floods over WireGuard |
| 8 | **Forward Ctrl+C / Ctrl+D / Esc / double-Esc WITHOUT translation** | They have Claude Code-specific behavior (Esc = stop turn, double-Esc = rewind menu), not POSIX defaults ([interactive-mode](https://code.claude.com/docs/en/interactive-mode)) |
| 9 | **Bracketed paste** (mode 2004) wrappers `ESC[200~`/`ESC[201~` | Pastes >10,000 characters collapse into a `[Pasted text]` placeholder; `-p` mode caps stdin at 10MB ([headless](https://code.claude.com/docs/en/headless)) |

#### 1.3. Two load-bearing caveats (verified — read carefully before shipping)

- **⚠️ DEC 2026 synchronized output with `xterm-ghostty` — CONFIRMED to be a problem.** Since v2.1.110, Claude Code switched from dynamic capability detection to a **hardcoded TERM allowlist**: it only sends DEC 2026 when TERM is *exactly* `xterm-ghostty` or `xterm-kitty` ([#49584](https://github.com/anthropics/claude-code/issues/49584), [#55613](https://github.com/anthropics/claude-code/issues/55613)). The `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` workaround shipped in v2.1.129 but **the root cause (allowlist instead of DECRQM) remains unfixed** as of v2.1.159. → **If your client emits a new/custom TERM value, you MUST set `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1`.** If you keep exactly `xterm-ghostty` it works natively, but watch the `xterm-ghostty` terminfo paste-tokenization bug ([#54700](https://github.com/anthropics/claude-code/issues/54700)) — if it manifests, expose a toggle back to `xterm-256color` (which disables DEC 2026 but avoids the paste bug).

- **❌ Image paste via OSC 5522 — REFUTED, do NOT ship.** The original corpus said "Ghostty PR in progress"; the adversarial verdict shows this is WRONG in both directions: Ghostty PR #10560 was **MERGED 2026-02-16 (shipped in 1.3.0)** but is **parse-only, it does NOT implement the behavior** ([PR #10560](https://github.com/ghostty-org/ghostty/pull/10560), [1.3.0 release notes](https://ghostty.org/docs/install/release-notes/1-3-0)). The actually accepted implementation is [issue #10549](https://github.com/ghostty-org/ghostty/issues/10549) with the comment "we can figure out how to impl this later" — **no PR yet**. Claude Code issue #42712 could NOT be verified (GitHub returns ISSUE NOT FOUND). → **Don't ship an image-paste feature relying on Ghostty's OSC 5522 semantics: Ghostty will silently parse and ignore it.** Document it as a known limitation; interim workaround: macOS native Ctrl+V (not Cmd+V), or Kitty (full support).

#### 1.4. Should we go deeper via the Agent SDK? — **YES, for a separate dedicated pane.** (just-run-TUI vs SDK-driven)

Three integration tiers:
- **TUI tier (PTY passthrough)** — the full interactive experience, but pushing ANSI pixels over the network is latency-sensitive. Issue [#20286](https://github.com/anthropics/claude-code/issues/20286) shows that at ~500ms RTT a permission dialog arrived 30+ minutes late (that's a VS Code-specific serialization issue; your raw PTY doesn't have that bug, but the React renderer still re-renders per token → many small writes → typing latency).
- **Headless tier (`claude -p`)** — non-interactive, `--output-format stream-json` emits NDJSON events (text_delta, tool use, system/init), `--json-schema`, `--continue`/`--resume SESSION_ID`. ⚠️ `--bare` = `settingSources:[]` = **DISABLES** skills/commands/CLAUDE.md/hooks → **don't use it if you need feature parity** (the default already loads everything) ([headless](https://code.claude.com/docs/en/headless)).
- **Agent SDK tier** (`@anthropic-ai/claude-agent-sdk` / `claude-agent-sdk`) — `query()` async generator yields typed messages; PreToolUse/PostToolUse hooks in-process; subagent definitions; MCP attachment; session resumption. The TS SDK **bundles the native binary as an optional dep** — no separate Claude Code install needed ([agent-sdk/overview](https://code.claude.com/docs/en/agent-sdk/overview)).

> **Hybrid architecture recommendation:** keep the raw PTY path for users who want the full TUI; **add an SDK-driven agent pane** (native SwiftUI) for structured interaction. SDK output is **JSON over stdout — far more tolerant of network buffering than raw ANSI**. Map: tool invocations → UI cards, text_delta → streaming pane, permission approval → native buttons, session cost/model → status bar.
>
> ⚠️ **Important CORRECTION (feature parity — `research/sdk-feature-parity-corpus.json`):** **do NOT use `--bare`** for the SDK pane if you want to keep skills/custom commands! `--bare` = `settingSources: []` = **disables all** `.claude/` config (skills, commands, CLAUDE.md, hooks, subagents). By default (omitting `settingSources`) the SDK **loads EVERYTHING** (`["user","project","local"]`, matching the CLI) → **skills + custom slash commands work IMMEDIATELY by default**. The only requirement: **`cwd` points at the project root**. See §"Skills/slash in the SDK" below.

> **⚠️ Billing — CONFIRMED:** from **2026-06-15**, `claude -p` and the Agent SDK on **subscription plans** draw from a separate "monthly Agent SDK credit" ($20 Pro / $100 Max-5x / $200 Max-20x). **API-key auth (`ANTHROPIC_API_KEY`) is NOT affected** — pay-as-you-go as before ([support article 15036540](https://support.claude.com/en/articles/15036540)). → If the tool uses API-key auth there's no issue; if OAuth/subscription, warn the user.

---

### 2. Warp terminal: what to learn — must-have vs nice-to-have vs don't copy

#### 2.1. Core insight
The power of Warp's block model **comes entirely from shell-integration signals, NOT from the renderer**. Warp is not a PTY-passthrough emulator: it owns the input editor (buffers keystrokes on the client, only writes to the PTY on Enter), and groups output into typed blocks via **injected shell hooks** (precmd/preexec) emitting JSON metadata inside an escape sequence ([how-warp-works](https://www.warp.dev/blog/how-warp-works), [block-model blog](https://www.warp.dev/blog/block-model-behind-warps-agentic-development-environment)).

> **⚠️ Protocol correction (CONFIRMED):** Warp uses **DCS** (Device Control String, `\eP$f{JSON}\x9c`) as its primary protocol on **macOS/Linux**, NOT OSC 133. On **Windows** it switched to a **custom OSC** because ConPTY swallows DCS ([building-warp-on-windows](https://www.warp.dev/blog/building-warp-on-windows)). Importantly: **Warp does NOT consume OSC 133** — injecting OSC 133 markers even *breaks* Warp's rendering ([Warp #6718](https://github.com/warpdotdev/warp/issues/6718)). Warp went open-source (2026-04-28, client AGPL v3 + UI crates MIT) but **the Rust terminal-emulation source is not in the public tree yet** — the protocol is only verifiable from docs/blog, not source.

The key point for you: you do **not** use Warp's proprietary DCS protocol. You use **OSC 133** (the open standard: A=prompt start, B=command start, C=output begins, D=command finished + exit code) which iTerm2/Ghostty/Kitty/WezTerm/Windows Terminal all implement. **Ghostty (libghostty) already implements OSC 133** for bash/zsh/fish/elvish/nushell. There is an open issue asking Claude Code to emit OSC 133 ([#22528](https://github.com/anthropics/claude-code/issues/22528)) — **but Claude Code does NOT emit OSC 133 today** (claims_to_verify records this; several open issues: #1465, #32635). Meaning block detection will apply to **shell commands** around/outside Claude Code, not inside a Claude Code session.

#### 2.2. Transferability classification

**MUST-HAVE:**
1. **OSC 133 shell-integration injection on the remote host** — because the PTY runs over NetBird TCP (direct P2P), escape sequences flow intact, **no side channel or remote-server binary needed** (totally unlike Warp SSH). This is the enabling primitive for block grouping, exit-code coloring, prompt-jump.
2. **Claude Code lifecycle hooks in the style of `claude-code-warp`** — pattern: a shell-script hook for 6 events (SessionStart, Stop, Notification, PermissionRequest, UserPromptSubmit, PostToolUse), emitting OSC 777 → drives a "agent running / needs permission / done" status pane. ⚠️ **CONFIRMED but partially outdated:** the `\033]777;notify;warp://cli-agent;<JSON>\007` format is correct for CC **< 2.1.141**; from **CC ≥ 2.1.141** the plugin switched to a `terminalSequence` JSON field on stdout (because the Stop hook validator rejects unknown fields), bypassing `/dev/tty`. **The implementation must handle BOTH paths** ([warpdotdev/claude-code-warp](https://github.com/warpdotdev/claude-code-warp), `emit-terminal-sequence.sh`).
3. **Bidirectional PTY fidelity including control sequences** (Ctrl+C/Z/D, arbitrary byte writes). Warp's #1 Terminal-Bench (52%, a self-reported claim — flagged as a **marketing claim**) demonstrates this is the most important capability for agentic-coding correctness; a PTY that drops/delays control sequences will break Claude Code mid-task ([full-terminal-use](https://docs.warp.dev/agent-platform/capabilities/full-terminal-use/)).

**NICE-TO-HAVE (later):**
4. **Block-based UI** (height-indexed SumTree, GridStorage for active + FlatStorage for scrollback) — requires parsing OSC 133 in the client renderer. Useful for navigation + AI context framing, but **not required** to run Claude Code.
5. **MCP auto-discovery from `~/.claude.json` / `.mcp.json`** — Warp reads Claude Code's own config files, users who already configured them get the integration free ([MCP docs](https://docs.warp.dev/agent-platform/capabilities/mcp/)). Trivial UX, no protocol work.
6. **Rich-content blocks coexisting with terminal blocks** in the same BlockList (zero-height hidden blocks for collapsing) — an elegant pattern, fits the SDK structured event stream.

**DO NOT COPY:**
7. **Warp's input editor** (buffered keystrokes, multi-cursor) — incompatible with libghostty's external-backend model (renders the VT stream as-is). Claude Code's TUI input is sufficient.
8. **Warp's GPU renderer / custom UI framework** — you already have libghostty Metal rendering.
9. **Oz cloud-agent orchestration + Warp Drive cloud sync** — proprietary, out of scope for a P2P tool.

---

### 3. What HERDR is + the multi-agent orchestration landscape

#### 3.1. HERDR — CONFIRMED, exact identity
[github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) (author Oğulcan Çelik). "Agent multiplexer that lives in your terminal" — a **Rust terminal multiplexer with agent awareness**, single binary. **3.6k stars, v0.6.6 (2026-05-31)** — both numbers CONFIRMED via live fetch. **Dual-licensed AGPL-3.0-or-later + commercial** (`hey@herdr.dev`) — CONFIRMED via the LICENSE file/Cargo.toml/nix ([herdr LICENSE](https://github.com/ogulcancelik/herdr/blob/main/LICENSE)). Runs on macOS/Linux, **no Windows** (depends on Unix sockets).

It is NOT a Claude Code plugin/framework. Architecture: a **background server managing workspaces/tabs/panes, each backed by a real vt100 PTY**; a thin client connects locally or over SSH. State tracking uses 3 signals: **process detection + socket API reports + screen heuristics**. Natively integrates Claude Code (hook-based), Codex, OpenCode, Hermes, Pi, Qoder. The socket API = **NDJSON over a Unix domain socket, no auth** — an agent can create/destroy panes, read output, send keystrokes, report state (blocked/working/done/idle), wait on other agents, spawn helpers. `HERDR_ENV=1` tells the agent it's running inside herdr; `SKILL.md` teaches Claude Code to self-orchestrate.

> **⚠️ Load-bearing license note:** the AGPL copyleft applies to the herdr *software*, NOT the *protocol*. A self-written Swift client that only **speaks the NDJSON protocol** does NOT distribute herdr code → not automatically AGPL-bound (protocols aren't copyrightable). AGPL only triggers if you: (a) ship the herdr binary in the product, (b) link the herdr library, (c) use herdr's Rust source. The commercial license (price unpublished) resolves all three.

> **Identity correction:** "Herd" ([joinherd.ai](https://joinherd.ai/)) and "AgentHerder" ([agentherder.com](https://agentherder.com/)) are **DIFFERENT projects**, don't confuse them with herdr. "herdctl" ([edspencer.net](https://edspencer.net/2026/1/29/herdctl-orchestration-claude-code)) is another MIT tool, Node.js, Docker-based, built on the Agent SDK.

#### 3.2. Landscape (universal pattern: git-worktree isolation per agent + task queue + human review gate)

- **Claude Code Agent Teams** (native, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, v2.1.32+): a lead session spawns N teammates (each a full session with its own context), a shared file-locked task list + mailbox. **⚠️ Split-pane mode CONFIRMED to NOT support Ghostty** (only tmux or iTerm2) ([agent-teams docs](https://code.claude.com/docs/en/agent-teams), [#24189](https://github.com/anthropics/claude-code/issues/24189) still open). The blocker is on Ghostty's side (no stable CLI/IPC); [#26572](https://github.com/anthropics/claude-code/issues/26572) proposes a `CustomPaneBackend` protocol (JSON-RPC 2.0/NDJSON) that would unblock it — no Anthropic response yet.
- **Claude Squad** (smtg-ai, 7.7k★, Go, AGPL): tmux + worktree per agent, TUI dashboard.
- **Conductor** (conductor.build, macOS GUI, free BYOK): worktree per agent, diff-first review, no tmux needed.
- **Uzi** (devflowinc, Go, MIT): CLI `uzi prompt --agents claude:2,codex:1`, has `broadcast` + `checkpoint` for sweep workloads.
- **Claude Code Agent Farm** (Dicklesworthstone, Python): 20-50 agents via tmux panes, file-lock coordination (shared tree, no worktrees).
- **Vibe Kanban** (Apache-2.0, community-maintained after Bloop shut down in early 2026): Kanban-card-per-worktree.

#### 3.3. Should the tool host/manage a herd of agents? — **YES, but only as the transport+rendering layer; do NOT build an orchestration product.**

Your tool is uniquely positioned to **natively host a herd of Claude Code agents**, because PTY-over-NetBird already provides the core primitive every other tool builds on. Concrete opportunities, in order of value:
1. **Git worktree per agent** — every serious tool uses it. Host supports create/list/switch worktree (trivial shell) + exposes each worktree as a PTY session in the UI.
2. **Agent supervisor pane** (sidebar with blocked/working/done state) — the common pattern of herdr/Claude Squad/Conductor. State detection uses 3 signals like herdr: process detection + Claude Code hooks (Stop/TeammateIdle/TaskCompleted) + screen heuristics.
3. **HERDR compatibility** — speak the NDJSON socket protocol natively, so the macOS/iPad client renders herdr's workspace/tab/pane model with ghostty surfaces. You become a **first-class client** instead of a plain SSH terminal.
4. **Fill Agent Teams' Ghostty gap** — since Anthropic doesn't support Ghostty split panes, you can parse tmux pane-creation commands and translate them into your multi-PTY model; or implement `CustomPaneBackend` (#26572) if it lands.
5. **Do NOT build:** a full git-worktree UI, a Kanban board, a multi-model routing layer. That is the product layer of herdr/Conductor/Claude Squad. **Your value = PTY transport + rendering quality (libghostty) + mobile client.** Be the *best PTY host* for those orchestration tools, don't replicate them.

---

### 4. ROADMAP RECOMMENDATIONS

#### Now (P0 — so Claude Code runs smoothly over the network PTY)
These are the sufficient conditions for the Claude Code TUI to work correctly — do them before anything else:
1. Set env in the PTY: `COLORTERM=truecolor`, `TERM=xterm-ghostty`. If emitting a custom TERM → `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` is **mandatory** (DEC 2026 fix, CONFIRMED).
2. Enable fullscreen by default: `CLAUDE_CODE_NO_FLICKER=1`.
3. PTY bridge **bidirectional fidelity**: forward control sequences (Ctrl+C/D, Esc, double-Esc), kitty keyboard reports, SGR mouse, bracketed paste, OSC 8/52/777 **untouched**. Do NOT strip/rewrite.
4. SIGWINCH forwarding + ioctl update, **debounce ~50ms**.
5. Document the limitation: **image paste over a remote PTY is broken** (OSC 5522 not implemented in Ghostty — the "PR in progress" claim was REFUTED); workaround: macOS Ctrl+V.

#### Next (P1 — Warp-style external input box, DECIDED A+B1)
6a. **A — shell input box + block mode:** SwiftUI input box pinned to the bottom; Enter→PTY; block boundary via `GHOSTTY_ACTION_COMMAND_FINISHED`; an **`ESC[?1049h/l` sniffer** on the feed stream to hide/show the box (~2–4 weeks + 1–2 weeks for the sniffer). See §"External input box".
6b. **B1 — overlay compose-box for Claude Code:** keep the TUI, overlay writes to the PTY + DelayedEnter, gated by lifecycle hooks, avoid swallowing Shift+Tab/focus.
6c. **OSC 133** (optional, richer metadata) + lifecycle hooks → status pane.
> **B2 (native SDK-driven agent pane) — NOT doing it.** The TUI keeps 100% of features natively; structured view = read-only inspector [16] (read-only, not an interactive SDK pane).
7. **OSC 133 shell-integration** injection on the remote host (libghostty already parses it) → block model for shell commands around Claude Code: prompt-jump, exit-code coloring, per-block copy. Note that Claude Code **does not emit OSC 133 internally** so block grouping applies outside its session.
8. **Claude Code lifecycle hooks** (claude-code-warp style, handling both the OSC 777 `/dev/tty` and the `terminalSequence` stdout path) → status pane.

#### Later (P2 — multi-agent / orchestration)
9. **Agent supervisor sidebar** + git-worktree-per-agent PTY sessions.
10. **HERDR socket-protocol client** (NDJSON, self-written — avoid AGPL by not embedding the binary/linking the library).
11. Fill Agent Teams' **Ghostty split-pane gap** (parse tmux commands or implement CustomPaneBackend if #26572 lands).

#### Fit into the hybrid terminal+GUI architecture
- **Terminal path (PTY/NetBird/libghostty)**: P0 + P1.7/P1.8 — the backbone. The block model + OSC 133 live in the client-side VT parser of libghostty's external backend.
- **GUI path (ScreenCaptureKit + VideoToolbox)**: orthogonal, used for GUI windows; doesn't touch the PTY layer.
- **The SDK pane (P1.6)** is a *third tier* next to the two paths above: not PTY, not video — native SwiftUI consuming a JSON stream. This is exactly where Warp's "rich-content blocks" map to, and where the multi-agent supervisor (P2) displays state.

> ℹ️ **The 4 open questions above are RESOLVED** (in a later turn) — see [12 open-questions](12-coding-profile.md): alt-screen ✅ works; parsed stream is **opaque** (use action callbacks); kitty keyboard ✅ via `ghostty_surface_key`; TCP only needs buffering.

## Skills / slash commands — run natively in the TUI

> ℹ️ **B2 was dropped** → we do NOT drive Claude Code via the SDK. The TUI **is** the real Claude Code, so **skills + custom slash commands + every feature run 100% natively**, nothing extra needed. The SDK-parity analysis below is kept for reference only (in case it's reconsidered later).

> Source: `research/sdk-feature-parity-corpus.json`. Answers the question: does a structured-event UI (SDK) support skills + custom slash commands like the TUI does?

**YES — and nearly for free.** ⚠️ **Correction to the old assumption:** the SDK **loads `.claude/` config by DEFAULT** (omitting `settingSources` = `["user","project","local"]`, matching the CLI). **It is `--bare`/`settingSources:[]` that DISABLES everything** — don't use it. The only condition: **`cwd` points at the project root** (via the host process, not the iOS sandbox).

| Feature | SDK | How |
|---------|-----|------|
| Skills (`.claude/skills`, model-invoked) | ✅ default | `skills:'all'` (enabled by default). ⚠️ `allowed-tools` in SKILL.md is **ignored** in the SDK → use `allowedTools` on `query()` |
| Custom slash (`.claude/commands/*.md`) | ✅ default | send `/cmd args` as the prompt; `$ARGUMENTS`/`$1`, `!\`bash\``, `@file` all expand |
| CLAUDE.md, subagents, MCP, hooks, plugins | ✅ default/config | automatic with default settingSources; or programmatic |
| `/compact`, `/clear` | ✅ | send as a prompt (streaming, CC v2.1.117+) |
| Autocomplete for commands/skills | ✅ | read `slash_commands`/`skills`/`plugins` from the `system/init` message → native palette |
| `@`-file-mentions | ❌ tui-only | the SDK doesn't expand them → **native file picker** injects content into the prompt |
| `/model` `/config` `/agents` `/permissions` `/diff` `/memory` `/resume`(picker) | ❌ tui-only | **build native equivalents** (~15–20 controls: model picker, permissions toggle, usage card, diff viewer, CLAUDE.md editor...) |
| Agent teams, `/rewind` checkpoint | ❌ no SDK path | replace with programmatic subagents / session branching (`fork_session`) |

**Conclusion:** **the core agent capabilities (skills, custom commands, subagents, MCP, hooks, CLAUDE.md) reach parity for FREE** in a structured UI; the extra cost = ~15–20 native UI pieces for **management chrome** (not agent capability); the real losses = agent teams + `/rewind` + visual grids. → **A structured iOS UI (B2) is feasible for skills + custom commands** — reinforcing the structured choice for iOS ([12 Phase 3](12-coding-profile.md)). **Desktop raw-PTY keeps 100% of features** (because it *is* the TUI).
