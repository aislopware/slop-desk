# 16 — Read-only Structured Inspector (companion to the TUI)

> Direction: **Main = libghostty TUI** (full fidelity, all interaction through the TUI) + a **READ-ONLY inspector alongside it** (desktop + iOS) for viewing things that are hard to read in scrollback: subagent content, full tool calls, CoT, todos, workflows. Source: `research/readonly-inspector-corpus.json`.
>
> *As-of: Claude Code v2.1.x (2026-06). Claims tied to versions + undocumented flags → verify on the target CC version.*

## Why this direction wins (differentiator)

- **Read-only = avoids the ENTIRE cost of an SDK-driven interactive pane:** no reimplementing slash/model/permissions (the TUI handles all input), no duplicate prompts, no worrying about `--bare`/`settingSources` (we **observe** the transcript, we don't **drive** the agent). No input path from inspector → claude → absolutely safe.
- **Same session as the TUI** (not a second SDK session). It reads the transcript of the very `claude` process that is running.
- **Better than Happy/Happier:** they only have structured (losing TUI fidelity); we have the **full TUI + inspector** = best of both.

## Data source: tail the JSONL transcript (+ supplementary hooks)

`claude` writes append-only JSONL at `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` (override via `CLAUDE_CONFIG_DIR`). **Take the path from the `transcript_path` field in the hook payload** (`SessionStart`) — do not reconstruct it yourself.

| Component | In the JSONL? | Notes |
|------------|--------------|---------|
| Full **tool_use input** | ✅ | assistant `message.content[]` block `{type:tool_use,id,name,input}` |
| Full **tool_result output** | ✅ | user line `{type:tool_result,tool_use_id,content,is_error}` + top-level `toolUseResult` (full file/diff) |
| **Todos/Tasks** | ✅ (via tool calls) | `TaskCreate/TaskUpdate/TaskList` (new, default v2.1.142+) / `TodoWrite` (old) — **accumulate from the tool-call sequence**, not a dedicated record |
| **Subagent (Task/sidechain)** | ✅ **SEPARATE file** | `~/.claude/projects/<project>/<sessionId>/subagents/agent-<hash>.jsonl` + meta `agent-<hash>.meta.json` (`{agentType,description,toolUseId}`); each line has `isSidechain:true` + `agentId` |
| **CoT/thinking** | ⚠️ mostly EMPTY on Opus 4.x | the `{type:thinking,thinking:"",signature}` block is always structurally present but the text is empty by default — see below |

> ⚠️ **CORRECTION (refuted):** native `claude` does **NOT** write a top-level `parent_tool_use_id`; subagent turns are **NOT** interleaved into the main session file. → tailing only the main file = **losing all subagents**. Must additionally watch the `subagents/` directory (FSEvents), index by `agentId`, and use the **`SubagentStop.agent_transcript_path`** hook as the signal. (Path from Happier source + observed locally — **NOT official**, verify on the target CC version.)

> ⚠️ **CoT/thinking — the heaviest caveat:** on **Claude 4 (Opus 4.5/4.7/4.8 = our stack)** the `thinking` field is **EMPTY** by default (`display:"omitted"` for Opus 4.7+; `showThinkingSummaries` is not wired to `thinking.display`). Workaround: the **undocumented** flag `claude --thinking-display summarized` → populates the text (may break on updates). `redacted_thinking` (encrypted) is Claude 3.7 only, not Claude 4. → The inspector must be defensive: `thinking===""` + a `signature` present → render the placeholder "Thinking (not persisted)". **This is a load-bearing decision (see the end).**

## "Workflow" = Dynamic Workflows (new feature)

CC ≥ **v2.1.154** (released 2026-05-28, **research preview**). It is a **JS orchestration script** Claude writes itself, running in a runtime **separate** from the conversation, spawning ≤16 concurrent / 1000 total agents, intermediate results in **script variables** (outside the context). Triggers: the keyword `workflow`, `/effort ultracode`, `/deep-research`. Saved in `.claude/workflows/`. UI: `/workflows`. Disable: `CLAUDE_CODE_DISABLE_WORKFLOWS=1`.
- **Observing:** there is NO dedicated JSONL event, NO WorkflowStart/Stop hook. Indirect via **SubagentStart/Stop hooks** + sidechain files. ⚠️ **Gap:** the main JSONL is **sparse/silent** throughout a long workflow run (results live in script vars) → the inspector must show "workflow running" (via Subagent hooks) instead of appearing hung.

## Hooks — a supplementary push channel (not a JSONL replacement)
- `SessionStart` → `transcript_path` + `session_id` + `model`.
- `PostToolUse` → full `tool_name`+`tool_input`+`tool_result`+`duration_ms` (sub-second, **earlier than the JSONL flush** → instant cards).
- `SubagentStop` → `agent_id`+`agent_type`+**`agent_transcript_path`**+`last_assistant_message`.
- Hooks do **not** carry thinking. Use type `http` (POST to a listener) / async `command` — no polling.

## Design for our stack

**Data flow:** host spawns `claude` (PTY) + registers a `SessionStart` hook (POST to a local listener) → the inspector daemon opens `transcript_path`, FSEvents-watches it + watches `subagents/` → parses into typed events → a **SECOND NWConnection** (length-prefixed JSON frames) multiplexed over the same NetBird tunnel beside the PTY byte stream → a client-side Swift actor keeps an ordered store → SwiftUI read-only views. (Optional: PostToolUse/SubagentStop HTTP hooks for low-latency push, backfilled by JSONL later.)

**Views:** tool-call card (input+output+diff+duration, joined via `tool_use_id`) · subagent tree (collapsible, attached via `agentId`, sorted by timestamp **within a level**) · thinking block (empty-aware) · todos/workflow panel · message timeline.

**Sync/dedup:** a `processedMessageKeys` Set (keyed by `uuid` / `sidechain:<id>:<uuid>` / ...); files are append-only → re-read the tail (cap ~1MB), `JSON.parse` each line inside try/catch (a line may be mid-write); `.passthrough()` to tolerate unknown fields (the schema is only stable at the discriminated-union level); skip internal types (`file-history-snapshot`,`queue-operation`,`rate_limit_event`); reconnect = the host assigns a monotonic `seq`, the client sends `lastSeq` → replay.

**Platform fit:** desktop = split view (TUI left, inspector right) · iOS = tab/bottom-sheet (timeline → drill-down), fully read-only.

## Effort & pitfalls
**v1 effort ~5–7 weeks:** host tailer+hook listener+framing (~2–3w) · SwiftUI views (~2–3w) · subagent tree (+~1w).
**Pitfalls:** (1) transcript lags the TUI (JSONL flushes per turn) → use the PostToolUse hook for instant cards; (2) large outputs → truncate ~50KB + "show more"; (3) async sidechain ordering → sort-within-level; (4) silent workflows → detect via hooks; (5) SessionStart racing file creation → retry opening the file.

## Phasing
- **P1 (MVP, 80% of the value):** tail the main session JSONL + SessionStart hook; tool-call cards + timeline + todos.
- **P2:** subagent tree (watch `subagents/`, SubagentStop hook).
- **P3:** workflow panel + agent teams inbox (experimental, defer).
- **CoT:** placeholder-only in every phase (settled — there is no "CoT text" phase).

## Settled decisions
1. **CoT/thinking = PLACEHOLDER ONLY** ✅ — render "Thinking (not persisted)" + a signature fingerprint when `thinking===""`. Do **NOT** pursue the undocumented `--thinking-display summarized` flag (fragile). → drop the P4 "CoT text" phase; if Anthropic later persists thinking by default it will display naturally (the render slot already exists).
2. **Transport = length-prefixed NWConnection** (a second one, multiplexed over the NetBird tunnel) — consistent with the PTY path. WebSocket only if a high event rate causes problems (measure later).
3. **Workflow panel / Agent Teams = defer** (research preview / experimental off-by-default).

## Confidence (honest)
- ✅ High: JSONL is the right source; tool input/output/todos are complete; hooks supplement it; `agent_transcript_path` is real; Workflow = Dynamic Workflows v2.1.154+.
- ⚠️ Uncertain (load-bearing): thinking empty on Claude 4 (model+flag dependent; the corpus has conflicting verdicts); subagent/team paths from Happier source + observation, **not official** → verify on the target CC version; schema only stable at the union level → `.passthrough()`.
- ❌ Refuted: top-level `parent_tool_use_id` (must use the separate `subagents/` files).
