# 15 — Prior art: Happy & Happier (mobile/desktop for Claude Code)

> Verified against cloned source of `slopus/happy` + `happier-dev/happier` — the 2 **shipping** mobile/desktop apps for Claude Code. Source: `research/happy-happier-corpus.json`.

## Core finding (changes how to think about this)

**Both relay STRUCTURED events to mobile, NOT raw TUI.**
- **Local mode:** spawn `claude` with `stdio: inherit` → full TUI in the **host's terminal**; NO byte stream to mobile. fd 3 (4th pipe) = side-channel for thinking-state.
- **Mobile/remote:** the **official `@anthropic-ai/claude-agent-sdk`** (`query()`) spawns `claude --output-format stream-json`; mobile receives **NDJSON events** (assistant/text_delta, tool_use, tool_result, result) + reads the **JSONL transcript** Claude writes to disk. Renders a **native UI (cards)**, NOT a terminal.
- → They concluded **mobile needs a native UI, not a raw ANSI terminal** — the **SDK pane** approach. Our structured view is the **read-only inspector [16]** instead (reads the JSONL transcript, does not drive the agent).

## How they hook into Claude Code (summary)

| | slopus/happy | happier-dev/happier |
|--|--------------|---------------------|
| Local hook | `claude` + stdio inherit (TUI on host) + fd3 thinking | identical |
| Remote/mobile hook | `@anthropic-ai/claude-agent-sdk` → stream-json | SDK + `--print` fallback; **ACP** for codex/gemini/opencode/qwen/copilot/cursor |
| Hook injection | `--settings` (SessionStart) + `--mcp-config` | **`--plugin-dir` (additive)** — avoids PATH wrappers swallowing `--settings` |
| Hook payload parsing | snake_case (+ partial camel) | snake_case **+** camelCase (defends against schema drift) |
| Permissions from mobile | MCP/RPC | dedicated `PermissionRequest` hook |
| Transport | Socket.IO/WSS relay (`cluster-fluster.com`), **mandatory, no P2P** | Socket.IO relay (`api.happier.dev`), self-host Docker, Tailscale Serve |
| Encryption | **E2E** NaCl secretbox / AES-256-GCM dataKey | **E2E** X25519+XSalsa20-Poly1305 zero-knowledge |
| Relay auth | NaCl keypair challenge → JWT (no password) | keypair + OAuth/OIDC/mTLS enterprise |
| Claude auth | PKCE OAuth scope `user:inference` (reuses subscription) | reuses `~/.claude/.credentials.json` per-profile |
| Client | Expo/RN + **Tauri** (+ Electron `codium`) | Expo/RN + Tauri |

## Lessons WORTH borrowing for our tool

> ℹ️ Observations from prior art. Final decisions (auth, transport, control-plane, dedup) = single source in [DECISIONS.md](DECISIONS.md) + [14](14-claude-code-integration.md)/[13](13-network-transport.md).

1. **SessionStart hook to get the session UUID + transcript path — use `--plugin-dir`, NOT `--settings`.** Happier's hardened lesson: PATH wrappers (cmux...) silently swallow `--settings` (last-write-wins). Parse **both** `session_id`/`sessionId` + `transcript_path`/`transcriptPath` (schema changed across versions). Needed even though we relay the PTY — to map resume/handoff (file-watching JSONL races when multiple processes share a project dir).
2. **Keep the 2 credential layers separate:** network/transport auth (WireGuard mesh node auth, or setup-token) is independent of Claude auth. **Safest Claude auth: reuse `~/.claude/.credentials.json`** (have `claude` logged in) instead of running PKCE — happy's `user:inference` scope is NOT confirmed to grant Pro/Max quota vs API-billed only (⚠️ affects the auth decision in [14](14-claude-code-integration.md)).
3. **Replay-safe session resume:** dedupe by uuid (happy's `sessionScanner`) + server-side monotonic `seq` → after reconnect you know which messages were missed.
4. **Keypair challenge→token auth** (no password/email) for machine registration — fits a setup-token flow.
5. **Push notifications + presence suppression** ("Claude ready", suppressed while actively viewing). **Use APNs/FCM directly from the host** (not Expo Push — privacy). → needs a **lightweight control plane** (see below).
6. **tmux as the persistence layer** for headless sessions (happier's `startHappyHeadlessInTmux`). Our equivalent: host-side sessions survive disconnects via the seq-numbered replay buffer, so the libghostty client detaches/reattaches byte-exact.
7. **E2E-encrypt the app layer** for stored metadata/transcripts if a history/signaling server is added later (mesh encrypts the byte path in transit; wrap the key per-session for at-rest storage).

## Pitfalls they hit — we avoid

1. **stdin `O_NONBLOCK`** (happy #301): must `setBlocking(true)` to clear the O_NONBLOCK libuv leaves, else TUI echoes garbled / cursor doubles. **We hit exactly this** relaying the PTY.
2. **`CLAUDE_CODE_ENTRYPOINT`:** the headless SDK sets `sdk-cli`/`sdk-ts` → `claude --resume` picker filters those out. Set `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK) when spawning so the session stays resumable from a terminal.
3. **⚠️ Duplicate prompt forwarding:** when **BOTH the compose box (B1) AND the PTY** feed prompts → they land in JSONL twice. **We expose both simultaneously (decision B1) → a dedup ring buffer (text+timestamp) is MANDATORY.** Noted for B1.
4. **`--settings` is non-composable** + **hook schema drift** → `--plugin-dir` + defensive parsing (above).
5. **Orphan sidechain buffering** when the `Task` tool spawns a subagent (subagent messages arrive before the parent) — invisible in PTY mode, but must be handled if we layer structured events onto iOS.

## What we do DIFFERENTLY / BETTER
1. **Full TUI fidelity via libghostty** — they do NOT stream the TUI; we relay the raw PTY (`TERM=xterm-ghostty`) preserving colors/cursor/compose-box. A fundamental difference.
2. **No relay SPOF** — happy/happier die if their relay goes down. SlopDesk connects directly over a trusted private network (WireGuard mesh, e.g. NetBird/Tailscale), so no relay sits in the byte path: near-zero latency, one fewer trust boundary.
3. **A single PTY codepath** instead of 2 launchers (local TUI + remote SDK).

## ⚠️ 3 points to weigh (honest; may adjust the architecture)

1. **iOS: raw TUI vs a structured-event layer.** happy/happier concluded mobile needs a native UI, not raw ANSI (pinch-zooming a terminal on a small screen is bad). → We keep the **libghostty TUI as primary** (full fidelity) on desktop and iOS, plus the **read-only inspector [16]** for the structured view (reads JSONL, never drives). Do NOT build an SDK-driven pane.
2. **A lightweight control plane is still needed despite direct connectivity.** The mesh covers the byte path, BUT **push notifications** ("Claude needs input" while backgrounded) + **"host offline → queue the prompt"** need a control plane. Direct/P2P only removes the relay from the *byte path*, not every server. (The mesh's own management plane + APNs/FCM from the host may suffice.)
3. **OAuth scope uncertainty** (lesson 2) — affects the auth decision in doc 14.
