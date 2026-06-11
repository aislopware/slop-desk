# 15 — Prior art: Happy & Happier (mobile/desktop for Claude Code)

> Read the actual source of `slopus/happy` + `happier-dev/happier` (cloned and verified). These are the 2 **shipping** mobile/desktop apps for Claude Code — direct prior art. Source: `research/happy-happier-corpus.json`.

## Core finding (changes how to think about this)

**Both relay STRUCTURED events to mobile, NOT raw TUI.**
- **Local mode:** spawn `claude` with `stdio: inherit` → the full TUI appears in the **host's terminal**, NO byte stream goes down to mobile. fd 3 (the 4th pipe) = a side-channel capturing thinking-state.
- **Mobile/remote:** uses the **official `@anthropic-ai/claude-agent-sdk`** (`query()`) → the SDK spawns `claude --output-format stream-json` itself; mobile receives **NDJSON events** (assistant/text_delta, tool_use, tool_result, result) + reads the **JSONL transcript** Claude writes to disk. Renders a **native UI (cards)**, NOT a terminal.
- → **They concluded mobile needs a native UI, not a raw ANSI terminal.** That is the **SDK pane** approach — which we are **NOT doing** (best-only). Our structured view = the **read-only inspector [16]** (reads the JSONL transcript, does not drive the agent).

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

> ℹ️ The items below are **observations from prior art**. Final decisions (auth, transport, control-plane, dedup) = single source in [DECISIONS.md](DECISIONS.md) + [14](14-claude-code-integration.md)/[13](13-netbird-transport.md).

1. **SessionStart hook to obtain the session UUID + transcript path — use `--plugin-dir`, NOT `--settings`.** Happier's production-hardened lesson: PATH wrappers (cmux...) silently swallow `--settings` (last-write-wins). Parse **both** `session_id`/`sessionId` + `transcript_path`/`transcriptPath` (the schema has changed across versions). Needed even though we relay the PTY — to map resume/handoff (file-watching JSONL races when multiple processes share a project dir).
2. **Keep the 2 credential layers separate:** transport auth (NetBird keypair / setup-token) is independent of Claude auth. **The safest Claude auth: reuse `~/.claude/.credentials.json`** (have `claude` logged in already) instead of running PKCE ourselves — because happy's `user:inference` scope is NOT yet confirmed to grant Pro/Max quota vs API-billed only (⚠️ relevant to the auth decision in [14](14-claude-code-integration.md)).
3. **Replay-safe session resume:** dedupe by uuid (happy's `sessionScanner`) + a server-side monotonic `seq` → after a NetBird reconnect you know which messages were missed.
4. **Keypair challenge→token auth** (no password/email) for machine registration — fits a setup-token flow.
5. **Push notifications + presence suppression** ("Claude ready", suppressed while actively viewing). **Use APNs/FCM directly from the host** (not Expo Push — privacy). → needs a **lightweight control plane** (see below).
6. **tmux as the persistence layer** for headless sessions (happier's `startHappyHeadlessInTmux`) → the libghostty client attaches/detaches, surviving disconnects.
7. **E2E-encrypt the app layer** for all metadata/transcripts if a history/signaling server is added later (NetBird covers the byte path, but for storage wrap the key per-session).

## Pitfalls they hit — we avoid

1. **stdin `O_NONBLOCK`** (happy #301): must `setBlocking(true)` to clear the O_NONBLOCK left behind by libuv, otherwise the TUI echoes garbled / the cursor doubles. **We will hit exactly this** when inheriting/relaying the PTY.
2. **`CLAUDE_CODE_ENTRYPOINT`:** the headless SDK sets `sdk-cli`/`sdk-ts` → the `claude --resume` picker filters those out. Set `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK) when spawning so the session remains resumable from a terminal.
3. **⚠️ Duplicate prompt forwarding:** when **BOTH the compose box (B1) AND the PTY** feed prompts → they land in the JSONL twice. **We expose both simultaneously (per decision B1!) → a dedup ring buffer (text+timestamp) is MANDATORY.** Noted for B1.
4. **`--settings` is non-composable** + **hook schema drift** → `--plugin-dir` + defensive parsing (covered above).
5. **Orphan sidechain buffering** when the `Task` tool spawns a subagent (subagent messages arrive before the parent) — invisible in PTY mode, but if we layer structured events onto iOS we must handle it.

## What we do DIFFERENTLY / BETTER
1. **Full TUI fidelity via libghostty** — they do NOT stream the TUI to mobile; we relay the raw PTY (`TERM=xterm-ghostty`) preserving colors/cursor/compose-box. A fundamental difference.
2. **P2P, no relay SPOF** — happy/happier die if their relay goes down; NetBird P2P removes the relay from the byte path (near-zero latency, one fewer trust boundary).
3. **A single PTY codepath** instead of 2 launchers (local TUI + remote SDK).

## ⚠️ 3 points to weigh (honest; may adjust the architecture)

1. **iOS: raw TUI vs a structured-event layer.** Both happy and happier concluded that **mobile needs a native UI, not raw ANSI** (pinch-zooming a terminal on a small screen is bad). → **Consider layering structured events on top of the PTY for iOS** (parse additional events from the byte stream libghostty already has — incremental); we use the **read-only inspector [16]** for the structured view (read-only, doesn't drive) + **keep the libghostty TUI as primary** (full fidelity) on both desktop and iOS. (Do NOT build an SDK-driven pane.)
2. **A lightweight control plane is still needed despite P2P.** NetBird covers the byte path, BUT **push notifications** ("Claude needs input" while the app is backgrounded) + **"host offline → queue the prompt"** need a control plane. Don't fantasize that P2P removes 100% of servers — it only removes the relay from the *byte path*. (The NetBird management server + APNs/FCM directly from the host may be enough.)
3. **OAuth scope uncertainty** (lesson 2 above) — affects the auth decision in doc 14.
