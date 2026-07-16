# 20 — SlopDesk wire protocol (PATH 1 terminal + PATH 2 GUI video)

> **STATUS: CURRENT.** §1–8 spec the **PATH 1** terminal byte pipeline (TCP); §9 specs the
> independent **PATH 2** GUI video path (plain UDP). The two paths share nothing — different
> transport (UDP vs TCP), different message set, separate version constants, no shared
> `WireMessage` / `FrameDecoder` / `Channel`.
>
> Framing, codecs, channel mux and flow control are **native Swift** — the `SlopDeskProtocol`
> module (never panics / traps on untrusted input: a malformed frame throws and is dropped), with
> `SlopDeskTransport` driving the sockets. The codecs are the single source of truth for the wire,
> frozen bit-for-bit by the golden corpus (`golden/golden_vectors.json`). The wire format below is
> the contract both ends implement. Binding decisions it realizes: dual data/control channel +
> plain TCP + `TCP_NODELAY` + ET-style replay-buffer reconnect ([DECISIONS.md](DECISIONS.md),
> [17](17-native-feel-synthesis.md) §2, [18](18-risk-resolutions.md) H).

## 1. Channels (dual TCP)

A session uses **two** TCP connections, not one:

| `Channel` | Carries | Why separate |
|-----------|---------|--------------|
| `.data`   | `output`, `exit` (host→client); `input` (client→host) | The PTY byte hot path. |
| `.control`| `hello`/`resize`/`ack`/`bye` (client→host); `helloAck`/`title`/`bell` (host→client) | Lifecycle + sizing. |

**Rationale (Zellij lesson, [DECISIONS.md]):** a burst of PTY `output` on the data channel must
not delay a `resize`-ack or a disconnect intent. Putting control messages on their own TCP
connection keeps them head-of-line-independent from output bursts.

`TCP_NODELAY` is set on **both** sockets immediately after connect — in `SlopDeskTransport`, not
the protocol layer. (Nagle can add up to ~200 ms to single-keystroke writes.) Framing and decoder
are identical on both channels; `WireMessage.channel` is advisory metadata stating where each
message is expected to travel.

## 2. Framing

Every message on either channel is a single length-prefixed frame:

```
[ UInt32 big-endian: payloadLength ][ payload bytes ]
```

- `payloadLength` **excludes** the 4 prefix bytes — it counts only the payload.
- `payload = [ UInt8 messageType ][ message body... ]`.
- A `payloadLength` greater than **16 MiB** (`16 * 1024 * 1024`, `SlopDesk.maxFramePayloadLength`)
  is rejected with `SlopDeskError.frameTooLarge(_:)` — we never allocate or wait for an
  implausibly large frame.

The body uses **manual binary encoding**. The keystroke/output hot path must **not** use JSON or
`Codable`.

### Streaming decode (`FrameDecoder`)

TCP is a byte stream with no message boundaries: one read may deliver half a frame, three frames,
or a frame split across many reads. `FrameDecoder`:

1. Buffers raw bytes via `append(_:)`.
2. On `nextMessage()`, reads the 4-byte prefix (waiting if fewer than 4 bytes are buffered).
3. Validates the prefix against the 16 MiB cap (throws `frameTooLarge` otherwise).
4. Waits — returning `nil`, **not** an error — until the full payload has arrived.
5. Slices out and decodes exactly one frame, leaving any trailing bytes buffered for the
   next call.

A partial frame is never an error; only a body too short for its declared message type
(`truncated`), an unknown type byte (`unknownMessageType`), or invalid contents (`malformedBody`)
are.

## 3. Endianness

**All** multi-byte integers are big-endian ("network byte order") on the wire: `UInt32` length
prefix, `Int64` seq, `Int32` exit code, `UInt16` cols/rows/pixels, `UInt16` protocol version. The
protocol provides its own tiny big-endian read/write helpers (`BigEndian.swift`); no third-party
dependency.

UUIDs (`sessionID`) are sent as their **16 raw bytes** in canonical order (not a string).

## 4. Message table

`messageType` is the first payload byte. Bodies are listed after the type byte.

| Type | Name | Direction | Channel | Body |
|------|------|-----------|---------|------|
| 1  | `output`   | host → client | data    | `Int64 seq` (BE) + remaining bytes = PTY output payload |
| 2  | `exit`     | host → client | data    | `Int32 code` (BE) |
| 3  | `input`    | client → host | data    | remaining bytes = bytes to write to PTY stdin |
| 10 | `hello`    | client → host | control | `UInt16 protocolVersion` + 16-byte `sessionID` (all-zero = NEW) + `Int64 lastReceivedSeq` |
| 11 | `resize`   | client → host | control | `UInt16 cols` + `UInt16 rows` + `UInt16 pxWidth` + `UInt16 pxHeight` |
| 12 | `ack`      | client → host | control | `Int64 seq` (highest contiguous output seq durably received) |
| 13 | `bye`      | client → host | control | (empty) |
| 14 | `ping`     | client → host | control | `UInt64 timestampMS` (BE) — the client's monotonic clock, echoed verbatim in `pong` |
| 15 | `requestBlockOutput` | client → host | control | `UInt32 index` (BE) — the Block index whose captured output to fetch (→ `blockOutput`) |
| 16 | `metadataRequest` | client → host | control | `UInt32 requestID` (BE) + `UInt8 verb` + `UInt32 payloadLen` (BE) + `payload` bytes (opaque) — the host metadata RPC (E4) |
| 20 | `helloAck` | host → client | control | 16-byte `sessionID` + `Int64 resumeFromSeq` + `UInt8 returningClient` (0/1) |
| 21 | `title`    | host → client | control | remaining bytes = UTF-8 window/title string |
| 22 | `bell`     | host → client | control | (empty) |
| 23 | `commandStatus` | host → client | control | `UInt8 tag` (`0`=running, `1`=idle); `idle` body = `UInt8 hasExit` + `Int32 exitCode` (BE, 0 if absent) + `UInt32 durationMS` (BE) |
| 24 | `pong`     | host → client | control | `UInt64 timestampMS` (BE) — the client's `ping` timestamp echoed verbatim |
| 25 | `notification` | host → client | control | `UInt16 titleLen` (BE) + `title` UTF-8 + remaining bytes = `body` UTF-8 |
| 26 | `foregroundProcess` | host → client | control | remaining bytes = UTF-8 PTY foreground-process basename (coarse Claude-Code watch; `""` clears) |
| 27 | `claudeStatus` | host → client | control | `UInt8 state` + `UInt8 kind` + `UInt16 labelLen` (BE) + `label` UTF-8 (rich Claude-Code hook status) |
| 28 | `commandBlock` | host → client | control | `UInt32 index` + `UInt8 hasExit` + `Int32 exitCode` (BE, 0 if absent) + `UInt8 hasDuration` + `UInt32 durationMS` (BE, 0 if absent) + `UInt8 complete` + `UInt32 outputLen` (BE) + `UInt32 promptOrdinal` (BE; 1-based count of OSC-133 `A` prompt cycles at the block's start — counts EVERY cycle incl. blockless empty-Enter/Ctrl-C ones, matching libghostty's `.prompt` rows for `jump_to_prompt`; `0` = unknown) + `UInt16 cmdLen` (BE) + `commandText` UTF-8 (Warp-style Block metadata) |
| 29 | `blockOutput` | host → client | control | `UInt32 index` + `UInt32 outputLen` (BE) + `output` bytes (RAW VT, not UTF-8) — reply to `requestBlockOutput` |
| 30 | `metadataResponse` | host → client | control | `UInt32 requestID` (BE) + `UInt8 status` + `UInt32 payloadLen` (BE) + `payload` bytes (opaque) — reply to `metadataRequest` (E4) |
| 31 | `inputEcho` | host → client | control | `UInt8 enabled` (`1` = canonical echo on, `0` = no-echo password prompt) — PTY termios `ECHO` edge; drives AUTO Secure Keyboard Entry (E17/I22) |
| 32 | `progress` | host → client | control | `UInt8 state` (`0` clear / `1` in-progress / `2` error / `3` indeterminate) + `UInt8 percent` (`0`–`100`; meaningful for state `1`/`2`) — OSC 9;4 taskbar progress (E14/K1) |
| 33 | `cwd` | host → client | control | `path` UTF-8 (absolute; rest-of-frame, no length prefix — same shape as `title`) — HOST-derived working directory truth; feeds the tab's cwd line + new-tab/split cwd inheritance. Single-sourced through the same derivation as type 34 (`MuxChannelSession.deriveProjectKey`): emitted on ACCEPTED change edges only (warm-up-gated against pre-first-prompt plugin OSC-7 noise; at a 133;B/D prompt edge the `proc_pidinfo` probe beats a same-batch stale OSC-7 — this is also what covers OSC-7-less shells like Starship), synchronously at the latch (never behind the async type-34 resolve); the raw sniffed OSC-7 does NOT ride the output FIFO. Re-asserted on reattach; the client applies it ungated |
| 34 | `projectKey` | host → client | control | `path` UTF-8 (absolute; rest-of-frame, no length prefix — same shape as `title`/`cwd`) — HOST-computed By-Project sidebar key: the git worktree toplevel containing the pane's cwd (pure filesystem walk-up, no `git` subprocess), else the cwd itself. Emitted on change edges only (host dedupe anchors: cwd truth from the OSC-7 sniff or the 133;B/D prompt-edge `proc_pidinfo` probe); re-asserted on reattach alongside 23/26/27/31/32 (and a latched 33) so a reconnecting client renders the final sidebar sections immediately with zero client-side derivation |

`protocolVersion` is currently **1** (`SlopDesk.protocolVersion`). There is **no version
negotiation**: the host accepts **only** `protocolVersion == 1`. Any `hello` with a differing
`protocolVersion` is rejected outright with a generic `handshakeFailed` (`HostTransport`); the host
never offers or falls back to another version.

### Field notes

- **`output.seq`** is a **monotonic per-message index starting at 1** — *not* a byte offset. See §5.
- **`hello.sessionID`** all-zero (`WireMessage.newSessionID`) requests a brand-new session; a
  non-zero UUID requests resume of that session.
- **`resize`** pixel dimensions are `0` when unknown (cell-only resize); the host maps the fields
  to `TIOCSWINSZ`.
- **`helloAck.returningClient`** is decided **by the host** (see §5), not asserted by the client.
- **`title`** payload must be valid UTF-8; a non-UTF-8 body decodes to `SlopDeskError.malformedBody`.
- **`title` (21) and `bell` (22) are PRODUCED by the host** by a non-destructive OSC/BEL sniffer
  (`HostTitleBellSniffer` in `SlopDeskHost`, wired into `HostSession`'s output relay): as it relays
  the raw PTY stream it observes a copy of the bytes and emits:
  - **`title`** ← **OSC 0** (`ESC ] 0 ; <text> <term>`, icon + window) or **OSC 2**
    (`ESC ] 2 ; <text> <term>`, window), `<term>` = `BEL` (`0x07`) **or** `ST` (`ESC \`). **OSC 1**
    (icon-name only) is ignored — it never sets the window title. Identical consecutive titles are
    de-duped.
  - **`bell`** ← a **standalone** `BEL` outside any escape sequence. A `BEL` that *terminates* an
    OSC string is that OSC's terminator and fires `title` (if OSC 0/2), **never** `bell` — the
    state machine distinguishes the two structurally.

  The sniffer only observes (raw bytes reach the client unchanged — libghostty is the real
  terminal) and is **streaming-safe**: a byte-at-a-time state machine that holds partial state
  across read chunks, bounds the buffered OSC payload against an unterminated/hostile OSC, and
  re-syncs on a stray `ESC` without swallowing the next introducer. The client surfaces both as
  `SlopDeskClient.Event.title` / `.bell`. They ride the head-of-line-independent CONTROL channel
  and are **not** sequenced/replayed.

- **`foregroundProcess` (26) and `claudeStatus` (27) carry per-pane Claude-Code agent status**
  (host → client, CONTROL; W9, docs/41 §4 / docs/42). **Additive within wire version 1**: a peer
  that does not know them DROPS the frame (`unknownMessageType`) — validate-then-drop, never a trap.
  Pane identity rides the mux channel envelope, not either body.
  - **`foregroundProcess`** is the coarse path: the host watches the PTY master's foreground process
    group (`tcgetpgrp` → `proc_name`, W10) and emits the basename on an edge — `"claude"` means a
    `claude` is in the foreground; `""` (or any other name) clears it. The client derives a
    `ClaudeStatus` FLOOR (claude present → `.idle`).
  - **`claudeStatus`** is the rich hook path: the host folds Claude Code `Notification`/`Stop`/
    `SessionEnd` hooks (via `SlopDeskInspector.HookParser`) into `[UInt8 state][UInt8 kind][UInt16
    labelLen (BE)][label UTF-8]`. `state` = `ClaudeStatus.urgency` (`0` none / `1` idle / `2` done /
    `3` working / `4` needsPermission); `kind` = the notification class (`0` none / `1` permission /
    `2` waitingForInput / `3` other); `label` = the (often empty, length-prefixed) Stop/Notification
    message, capped at the UInt16 length field. The wire carries the RAW `state`/`kind` bytes —
    `SlopDeskProtocol` does not depend on `SlopDeskAgentDetect`; the client maps them back, and a
    decoder is forward-tolerant of an unknown future `state`/`kind` value (the consumer clamps it).
  - The decoder **validates the declared `labelLen` before reading** (a short body → `truncated`,
    never an over-read of a hostile datagram) and requires strict UTF-8 for the name/label (an
    invalid sequence → `malformedBody`). Both ride the head-of-line-independent CONTROL channel like
    `title`/`commandStatus` and are **not** sequenced/replayed.
  - **Host delivery (W10).** Both are emitted from `SlopDeskHost` and gated by two env flags (the
    repo idiom — check the exact comparison): **`SLOPDESK_AGENT_DETECT`** (DEFAULT-ON, only `"0"`
    disables) drives the foreground-process watch → type 26/27 (the PRIMARY, zero-config signal,
    Decision #5); **`SLOPDESK_AGENT_HOOKS`** (DEFAULT-OFF, only `"1"` enables) binds an opt-in
    `AF_UNIX` hook socket. When the socket is bound, every PTY exports **`SLOPDESK_SOCKET_PATH`** (the
    socket) + **`SLOPDESK_PANE_ID`** (the routing key) so an installed Claude hook
    (`slopdesk-hostd integration install claude`) POSTs `pane=<id>\n<json>` records the host folds
    into type 27 for the owning pane. The host **dedupes** both: type 26 only on a basename edge,
    type 27 only when the `(state, kind, label)` triple changes — an idle `claude` never spams
    identical frames.

- **`metadataRequest` (16) and `metadataResponse` (30) are the generic host-metadata RPC** (E4,
  CONTROL). ONE shared request/response pair backs every Details-Panel surface that reads host-side
  metadata — processes, listening ports, cwd, git status/diff, lazy directory listings, agent-session
  files — instead of adding ~8 frozen wire types. Structural twin of `requestBlockOutput` (15) →
  `blockOutput` (29). **Additive within wire version 1**: a peer that does not know either type DROPS
  the frame (`unknownMessageType`) — validate-then-drop, never a trap. Pane identity rides the mux
  channel envelope, not either body, so pane-scoped verbs need no pane field.
  - **`metadataRequest`** body = `[UInt32 BE requestID][UInt8 verb][UInt32 BE payloadLen][payload]`.
    `requestID` is a client-chosen monotonic `UInt32` correlating a reply to one of several in-flight
    requests; the host echoes it **verbatim** (stateless responder, like `pong`). `verb` is the raw
    `UInt8` of `MetadataVerb`: `1` processes, `2` ports, `3` cwd, `4` gitStatus (subsumes branch +
    remote + repo toplevel + ahead/behind + **stash depth** (`Int32` BE after `behind`, before the file
    count) + changed files), `5` gitDiff, `6` listDirectory, `7` listAgentSessions,
    `8` readAgentSession — all **read-only** — plus the two **side-effecting** verbs `9` openPath and
    `10` revealPath (E10), the **agent-hooks** verbs `11` installAgentHooks / `12` uninstallAgentHooks
    (side-effecting) / `13` agentHookStatus (a pure read returning a 2-byte flag payload) (E13), and
    `14` hostInfo (a **pure read** returning the host machine's own hostname). `payload` is the
    verb's length-prefixed argument — empty for the pane-scoped verbs (`processes`/`ports`/`cwd`/`gitStatus`)
    AND for the host-global verbs (`installAgentHooks`/`uninstallAgentHooks`/`agentHookStatus`/`hostInfo`),
    a UTF-8 path/id for the parameterized ones
    (`gitDiff`/`listDirectory`/`listAgentSessions`/`readAgentSession`), and a raw UTF-8 **absolute host
    path** for `openPath`/`revealPath`.
  - **`openPath` (9) / `revealPath` (10) are the ONLY side-effecting verbs** (E10 — the ⌘click /
    ⌘⇧click link actions; the file lives on the host Mac, not the client). The host opens the path in its
    default app / Finder (`NSWorkspace.open`) or reveals it in Finder
    (`NSWorkspace.activateFileViewerSelecting`) and replies with an **empty payload** + a status: `ok` on
    success, `notFound` if the path no longer exists, `error` for an empty/relative/un-openable path.
    Because **no host bytes ever cross the wire** (only the status byte), they are not an exfiltration
    vector and accept ANY absolute path **without cwd-subtree confinement** (unlike the read verbs below).
    The host routes 9/10 to a thin macOS shim (`HostPathActionPerformer`) BEFORE the read-only responder,
    which never performs a side effect; the iOS client routes open/reveal TO the host over this same wire.
  - **`installAgentHooks` (11) / `uninstallAgentHooks` (12) / `agentHookStatus` (13) are the agent-hooks
    verbs** (E13 — the Agents settings card). 11/12 are **side-effecting** like 9/10: the host writes (the
    hook script + a merge into `~/.claude/settings.json`) or strips exactly our entries via `AgentInstaller`
    and replies with an **empty payload** + a status (`ok` on a successful write, `error` if it threw).
    13 is a **pure read** that returns status `ok` + a **2-byte** payload
    `[UInt8 installed][UInt8 listenerActive]` — `installed` (`1`/`0`) is the `settings.json` install
    marker, and `listenerActive` (`1`/`0`) is the **LIVE bind state of the host's AF_UNIX hook
    listener** (bound only when hostd was *launched* with `SLOPDESK_AGENT_HOOKS=1`), so the client
    can show installed-but-inactive (hooks written but the daemon isn't listening → a hostd restart is
    required) instead of a false green "Installed". The client decodes the second byte tolerantly (a
    1-byte reply reads as `listenerActive = 0` — conservative, never a false green). It reads ONLY the
    marker + the in-process bind flag, NO host file contents cross the wire, so (unlike the
    read verbs below) it is not an exfiltration vector and needs no cwd confinement. All three carry an
    **empty request payload** and are **host-global** (install/uninstall act on the host's single
    `~/.claude/settings.json` regardless of which pane's channel carried the request). The host routes
    11/12/13 to a thin macOS shim (`HostAgentActionPerformer`) BEFORE the read-only responder; the iOS
    client routes install/uninstall/status TO the host over this same wire. **Claude Code only** (no
    codex/opencode install path is ever surfaced).
  - **`hostInfo` (14) is a pane-agnostic pure read** (MERIDIAN C2 host identity): the host answers
    status `ok` + its own hostname as raw UTF-8 (`ProcessInfo.hostName`, e.g. `mac-studio.local`;
    `error` when unresolvable/empty). Empty request payload, **no cwd confinement** (only the machine's
    name crosses the wire). The client chrome uses it so the titlebar monogram + label speak the host's
    NAME even when the user connected by IP; an old host answers `unsupportedVerb` and the client falls
    back to reverse-DNS, then the raw target host. Served by the read-only responder
    (`MetadataResponseBuilder` → `HostMetadataProbe.hostName()`).
  - **`metadataResponse`** body = `[UInt32 BE requestID][UInt8 status][UInt32 BE payloadLen][payload]`.
    The host **always replies** (so the client's pending-request registry never hangs — `status =
    error`/empty on any failure). `status` is the raw `UInt8` of `MetadataStatus`: `0` ok, `1`
    notFound, `2` error, `3` unsupportedVerb. `payload` is the verb-specific response — a per-verb
    `MetadataCodec` list encoding (`ProcessList`/`PortList`/`DirListing`/`GitStatus`/`AgentSessionList`,
    documented with the codecs) or raw opaque bytes for `cwd`/`gitDiff`/`readAgentSession`.
  - The `verb`/`status` bytes are carried RAW (forward-tolerant): an unknown future `verb` is answered
    `unsupportedVerb`, an unknown future `status` clamps to error client-side — neither traps. The
    decoder **validates the declared `payloadLen` before reading** (a short body → `truncated`, never
    an over-read of a hostile datagram); the `payload` is OPAQUE to this envelope (the per-verb
    `MetadataCodec` / typed client decoders validate the inner bytes, with strict UTF-8 on string
    fields). The **host also treats the request `payload` as untrusted**: for the **read verbs** (which
    stream host file CONTENTS back) path args are confined to the pane's cwd subtree (reject `..` escapes
    / absolute paths outside the repo root) and entry counts / byte sizes are capped before reading, so a
    hostile `listDirectory("/etc")` / `readAgentSession("../../secrets")` cannot exfiltrate arbitrary host
    files. The side-effecting `openPath`/`revealPath` (9/10) and the agent-hooks verbs (11/12/13) are
    exempt from cwd confinement — they return only a status byte (and, for `agentHookStatus`, the two
    flag bytes), so no host file contents cross the wire and there is nothing to exfiltrate — but still
    validate-then-drop (`openPath`/`revealPath`: empty/relative → `error`, missing → `notFound`;
    `install`/`uninstall`: a thrown disk write → `error`). All ride the
    head-of-line-independent CONTROL channel like `title`/`commandStatus` and are **not**
    sequenced/replayed.

- **`inputEcho` (31) is the secure-input echo signal** (host → client, CONTROL; E17/I22). The host
  watches the PTY master's termios `ECHO` line-discipline flag (`tcgetattr`) and emits a 1-byte
  `[UInt8 enabled]` body on a state EDGE — `enabled = 1` is canonical echo (the default), `enabled = 0`
  is a hidden-password prompt (`sudo`/`ssh`/`login`/`read -s`/`getpass` clear `ECHO` with `tcsetattr`).
  The macOS client engages `EnableSecureEventInput` while `enabled == 0`.
  - **Why a wire signal.** termios `ECHO` is a HOST-side line-discipline attribute — it is **not in the
    output byte stream** (unlike DECSET/DECRST/OSC-133, which the client parses), so the client cannot
    derive the no-echo state itself; the AUTO Secure-Keyboard-Entry path genuinely needs this host→client
    message. (The MANUAL Edit ▸ Secure Keyboard Entry path is client-only and works without the wire.)
  - **Additive within wire version 1**: a peer that does not know type 31 DROPS the frame
    (`unknownMessageType`) — validate-then-drop, never a trap. Host + client **redeploy together** (no
    version negotiation). Pane identity rides the mux channel envelope, not the body.
  - The decoder reads the flag as `byte != 0` (untrusted-bool rule — never assumes `{0,1}`) and a missing
    body decodes to `truncated` (never an over-read). The host **dedupes**: it is anchored at echo-on (the
    canonical default the client also assumes) and emits ONLY on a deviation from — and a restore to —
    that default, so the steady (echo-on) case adds nothing to the CONTROL stream. Host delivery is driven
    by the pure `EchoModeDetector` (the `ForegroundProcessDetector` pure-core / thin-`PTYEchoProbe`-shim
    split) from `MuxChannelSession`: opportunistically right after a client keystroke is written to the
    PTY (where `ECHO` flips fastest) plus the low-rate foreground-watch poll as a backstop. Rides the
    head-of-line-independent CONTROL channel and is **not** sequenced/replayed.

- **`progress` (32) is the OSC 9;4 taskbar-progress signal** (host → client, CONTROL; E14/K1). iTerm2 /
  ConEmu / winget / long builds emit `ESC ] 9 ; 4 ; <state> [ ; <pct> ] <terminator>` to drive a
  per-window progress bar. The host parses that subtype out of the OSC-9 stream with the pure
  `ProgressOSCParser` and forwards it as a 2-byte `[UInt8 state][UInt8 percent]` body so the client can
  light the per-pane rail-row spinner / determinate badge.
  - **Why a control message (not the VT stream).** The progress badge is APP CHROME on the rail row, not
    terminal content — the client renders it as a spinner/percent badge, never as bytes in the terminal
    grid. And it must NOT surface as a desktop `notification` (25): a `9;4;1;50` shown as an alert with
    body text `"4;1;50"` would flood the user. So the host strips the `9;4` subtype from the OSC-9
    notification path and emits `progress` instead; the **free-text OSC-9 notification path is unchanged
    / byte-identical** (only the previously-DROPPED `9;4` subtype now emits a message).
  - **State mapping + ceilings.** Only states `0`/`1`/`2`/`3` are carried. State `4` (paused/warning) is
    ignored. State `5` (OSC 9;4;5;`<exit>`[;watch], finished + exit) is NOT a new progress state — it
    maps onto the EXISTING `commandStatus(.idle(exitCode:))` path (OSC-133-D); the `watch` finish suffix
    is deferred to E20's watch command. The host CLAMPS `percent` to `0…100` and DROPS any malformed
    `9;4` (unknown state digit, non-integer percent, bad shape) — validate-then-drop, never trust.
  - **Forward-tolerant byte round-trip.** The decoder carries the raw `state` byte VERBATIM (it does NOT
    reject an unknown discriminant) so the codec stays a faithful 2-byte round-trip and the golden vector
    is stable; the CLIENT re-validates via `ProgressState(wire:)` and DROPS an unknown state. A missing
    body decodes to `truncated` (never an over-read).
  - **Additive within wire version 1**: a peer that does not know type 32 DROPS the frame
    (`unknownMessageType`) — validate-then-drop, never a trap. Host + client **redeploy together** (no
    version negotiation). Rides the head-of-line-independent CONTROL channel like the other inline
    signals; pane identity rides the mux channel envelope, not the body. Not sequenced/replayed.

The next free **client → host** CONTROL type byte is **17** (10–16 used). The next free
**host → client** CONTROL type byte is **35** (20–34 used). (Byte 28 was once reserved for a W14 OSC-8
hyperlink type, but W14 ships OSC-8 click-to-open via **libghostty's own hit-testing** —
`GHOSTTY_ACTION_OPEN_URL` / `GHOSTTY_ACTION_MOUSE_OVER_LINK` — so no wire change was needed; 28 was
later taken by the Warp-style `commandBlock`. See DECISIONS.md "W14 terminal parity".)

## 5. Seq / ack / replay semantics

The host assigns every `output` message a **monotonic `Int64` `seq` starting at 1** — a per-message
index, not a byte count. The replay buffer (implemented in `SlopDeskTransport`, WF-2) retains
un-acked `output` messages so a reconnect is lossless:

- The client sends `ack(seq)` carrying the **highest contiguous** seq it has durably received. The
  host may then release retained entries with `seq <= ack`.
- On reconnect the client sends `hello(lastReceivedSeq:)`. The host replays every retained `output`
  with `seq > lastReceivedSeq`, then resumes live streaming. The result is byte-exact resume
  **without tmux**.
- The host **decides `RETURNING_CLIENT`** (Eternal Terminal `Connection.cpp`): on a `hello` with a
  known non-zero `sessionID` it resumes + replays and answers `helloAck(returningClient: true)`; an
  all-zero or unknown id starts a fresh session (`returningClient: false`). `helloAck.resumeFromSeq`
  tells the client where replay began.

### Replay-buffer caps (WF-2, documented here for the contract)

- **64 MiB** retained-byte ceiling (`ReplayBuffer.maxBackupBytes`; ET `MAX_BACKUP_BYTES`).
- **4 MiB offline gate** (`ReplayBuffer.offlineGateBytes`): while the client is offline, once
  buffered bytes pass 4 MiB the host **pauses the PTY drain** (ET `SKIPPED`) instead of growing
  unbounded; below the gate it keeps buffering (`BUFFERED_ONLY`). A long background build must not
  overflow the buffer and silently lose output.
- Seq is **`Int64`** (ET proto2 used int32, which truncates on very long sessions).
- **No app-layer crypto.** Deployment assumes a trusted private network — typically a WireGuard mesh
  (e.g. NetBird/Tailscale) providing E2E encryption + node auth — so the buffer stores **raw bytes**.
  ET's `CryptoHandler` (libsodium secretbox + nonce reset) is deliberately omitted; do not
  reintroduce it ([18](18-risk-resolutions.md) H).

### Equivalence to Eternal Terminal

This design is **functionally equivalent to Eternal Terminal's byte-level `BackedWriter` sequence
number**, lifted from byte offsets to a per-message index. ET tags each chunk of PTY output with a
monotonically increasing sequence and replays the tail after the last client-acknowledged sequence
on reconnect (`recover(lastValidSeq)`); SlopDesk does the same at the granularity of one `output`
message. The reconnect handshake (`hello.lastReceivedSeq` → host replays `seq > lastReceivedSeq`)
mirrors ET's reconnect path, minus the crypto handler, over plain TCP on the trusted private network.

## 6. Errors (`SlopDeskError`)

| Case | Meaning |
|------|---------|
| `frameTooLarge(Int)` | Length prefix exceeded 16 MiB; associated value is the claimed length. |
| `truncated` | A complete frame's body was shorter than its message type requires (distinct from a partial TCP read, which is not an error). |
| `unknownMessageType(UInt8)` | First payload byte is not a recognized type. |
| `malformedBody(String)` | Right-length body with invalid contents (e.g. bad UTF-8 in `title`); reason string attached. |

## 7. Public API (`SlopDeskProtocol`)

The Swift `SlopDeskProtocol` module *is* the terminal codecs: the encode/decode and the streaming
`FrameDecoder` are native Swift, and these are the public types.

- `enum Channel { case data, control }`
- `enum WireMessage: Equatable, Sendable` — all cases above; `var messageType: UInt8`,
  `var channel: Channel`, `func encode() -> Data` (full frame, prefix + type + body),
  `static let newSessionID: UUID`.
- `struct FrameDecoder` — `init()`, `mutating func append(_ data: Data)`,
  `mutating func nextMessage() throws -> WireMessage?` (handles partial reads + multiple frames per
  append; **not** `Sendable`, lives inside one actor/task).
- `enum SlopDeskError: Error, Equatable, Sendable`.
- `enum SlopDesk` namespace — `static let protocolVersion: UInt16 = 1`,
  `static let maxFramePayloadLength = 16 * 1024 * 1024`.

`WireMessage`, `Channel`, and `SlopDeskError` are `Sendable`; `FrameDecoder` is a non-`Sendable`
value type by design (it carries the receive buffer for a single connection/channel).

## 8. Channel association & session handshake (WF-2, `SlopDeskTransport`)

> How the two physical TCP connections of one session are tied together and how the `hello`/`helloAck`
> handshake runs. Implemented in `SlopDeskTransport` (`HostTransport` / `ClientTransport` /
> `ChannelAssociation`). It does **not** change the framing (§2) or the message table (§4); the
> association preamble is raw bytes the transport peels off *before* the first frame.

### 8.1 Association preamble (per connection)

A session opens **two** TCP connections (§1). To bind them to one logical session, each connection
sends a tiny fixed preamble as its very first bytes, before any length-prefixed `WireMessage` frame:

```
CONTROL preamble:  [ UInt8 0x01 ]                              (1 byte)
DATA    preamble:  [ UInt8 0x02 ][ 16 raw sessionID bytes ]    (17 bytes)
```

The discriminator byte (`0x01` control / `0x02` data) lets the host route a freshly accepted
connection without parsing a frame. The DATA preamble additionally carries the authoritative
`sessionID` (the same 16 raw bytes UUID layout used everywhere in §3) so the host can attach the
data connection to the right session.

### 8.2 Connect ordering (deterministic — no race)

1. **Client** opens the **CONTROL** connection, writes the control preamble (`0x01`), then sends
   `hello(protocolVersion, sessionID, lastReceivedSeq)` (all-zero `sessionID` = NEW; a non-zero id =
   resume request).
2. **Host** reads the control preamble, reads `hello`, and **strictly checks** `protocolVersion == 1`
   (any other value → `handshakeFailed`, connection dropped; no negotiation, no downgrade). It then
   **decides** NEW vs RETURNING_CLIENT (it, not the client, is authoritative — see §5 and Eternal
   Terminal `Connection.cpp`). It replies `helloAck(authoritativeSessionID, resumeFromSeq,
   returningClient)` on CONTROL:
   - unknown / all-zero id → mint a fresh id, `resumeFromSeq = 0`, `returningClient = 0`;
   - known non-zero id → echo it, `resumeFromSeq = hello.lastReceivedSeq`, `returningClient = 1`.
3. **Client** reads `helloAck`, learns the authoritative `sessionID`, then opens the **DATA**
   connection and writes the data preamble (`0x02` + that `sessionID`).
4. **Host** reads the data preamble and associates the DATA connection with the session it
   minted/resumed in step 2.

Because the DATA connection only opens *after* the client has the authoritative id, the host can
always associate it — there is no ordering race to resolve.

### 8.3 Reconnect / replay

On a RETURNING_CLIENT (step 2, known id) the host, once the new DATA connection associates,
**replays** `output` with `seq > hello.lastReceivedSeq` from the session's `ReplayBuffer` **in order
on the new data channel before live output resumes**, then continues streaming. The first live
`output` after replay carries `highestSeq + 1`, so the client sees a contiguous, gap-free, dup-free
seq stream across the reconnect. Only `output` is sequenced/replayed; control messages are not.

The rebind is atomic on the host session actor: it swaps the data/control channels and closes the
old ones. A live `sendOutput` already suspended on the *old* data channel when the rebind runs has
its in-flight send cancelled by that close (the OS reports POSIX `ECANCELED` 89). This is **not** a
fatal fault and **not** byte loss — the bytes were retained in the `ReplayBuffer` before the send and
are only evicted by a client `ack`, so they are re-sent by the rebind's replay loop on the new
channel. The host therefore treats a dead-channel send (channel swapped out, or a typed
`notConnected` / `.cancelled`/`.failed` state) as "client offline → replay on next reconnect",
retaining the bytes rather than throwing. **Symmetrically on the client**, a DATA or CONTROL channel
that finishes — whether by error *or* a clean FIN/cancel (the reconnect-race half-close) — terminates
the merged `inbound` and surfaces a `.disconnected`, which drives the `ReconnectManager`: there is no
mid-session clean half-close the host intends, so a clean finish is always a disconnect that
reconnects (never a silent stall).

### 8.4 `SlopDeskTransport` public API (WF-2)

- `enum TransportParameters` — `static func makeTCP() -> NWParameters` (the single canonical params:
  `TCP_NODELAY` + keepalive, no app crypto, no interface pin).
- `protocol MessageChannel: Sendable` — `var channel`, `func send(_:) async throws`,
  `var inbound: AsyncThrowingStream<WireMessage, Error>`.
- `actor NWMessageChannel: MessageChannel` — one `NWConnection`, drives a `FrameDecoder`, surfaces
  `State`.
- `struct ReplayBuffer: Sendable` — pure logic: `append(bytes:) -> Int64`, `ack(upTo:)`,
  `messages(after:) -> [(seq, bytes)]`, `retainedBytes`, `isClientOnline`, `shouldPauseDrain` (4 MiB
  offline gate / 64 MiB cap; never drops un-acked data — backpressure via pause instead).
- `actor HostTransport` — `NWListener`; `start(port:)`, `boundPort`, `sessions_`
  (`AsyncStream<HostSessionTransport>`), `stop()`.
- `actor HostSessionTransport` — per-session `ReplayBuffer` owner; `sendOutput(_:)`, `sendControl(_:)`,
  `sendExit(code:)`, inbound `inboundInput`/`inboundResize`/`inboundAck`, and
  `drainPauses: AsyncStream<Bool>` (PTY-drain pause/resume).
- `actor ClientTransport` — `connect(host:port:resume:lastReceivedSeq:)`, merged `inbound`,
  `sendInput`/`sendResize`/`sendAck`/`sendBye`, `sessionID`/`resumeFromSeq`/`returningClient`.

---

# PATH 2 — GUI video transport (UDP)

> **STATUS: CURRENT.** The wire format, packetization, FEC and recovery logic are **native Swift**
> (the `SlopDeskVideoProtocol` codecs, with the FEC's GF(2⁸) NEON kernel in `CSlopDeskSIMD`);
> `SlopDeskVideoHost` (`NWVideoDatagramTransport`) and `SlopDeskVideoClient`
> (`NWVideoClientTransport`) capture/encode/decode/render and drive the sockets. This secondary GUI
> video path (doc 17 §3, doc 18 measured spike config) is **independent of PATH 1** — its own
> protocol over plain UDP, with NO TCP, no `WireMessage`, no `FrameDecoder`.

## 9. Path-2 overview

PATH 2 remotes one host GUI window: ScreenCaptureKit per-window capture (NV12) → VideoToolbox HEVC
encode → UDP datagrams (packetize + FEC) → VTDecompressionSession decode → Metal render, with a
client-side composited cursor and client→host CGEvent input injection. Everything is
**datagram-oriented** — no stream framing, no length prefix, no replay buffer. Loss is absorbed by
FEC and, when unrecoverable, by client→host recovery requests (LTR refresh → IDR).

`SlopDeskVideoProtocol.version` is a **`UInt16`, currently `1`**, separate from PATH 1's
`SlopDesk.protocolVersion`. There is **no negotiation**: the host accepts a `hello` only when
`protocolVersion == SlopDeskVideoProtocol.version` (strict, mirroring PATH 1 §4); any other value is
rejected. All multi-byte integers are **big-endian**, exactly as PATH 1 (§3); the sub-pixel
geometry/cursor/input fields are big-endian IEEE-754 `Float64`. Each codec serialises as
`[UInt8 messageType][body…]` and is decoded defensively — a short or inconsistent **single datagram**
throws `VideoProtocolError.truncated` / `.malformed(_)` and is dropped, never crashing the receiver.

## 9.1 Transport topology — two sockets, six logical channels

A session uses **two UDP sockets**, not one:

| Socket | Carries | Framing |
|--------|---------|---------|
| **media** | control, video, geometry, input, recovery | each datagram is prefixed with a **1-byte channel tag** (`VideoChannel.rawValue`) |
| **cursor** | cursor updates + cursor shapes | **bare bytes** (single-purpose socket, no tag) |

The cursor channel is split onto its own socket so pointer latency = RTT, fully decoupled from the
encode/decode pipeline and from video-burst head-of-line blocking (doc 17 §3.3) — the same "don't let
bulk traffic delay latency-critical control" rationale as PATH 1's dual TCP (§1).

`VideoChannel` (the 1-byte media-socket tag) — `enum VideoChannel: UInt8`:

| Tag | Channel | Direction | Payload (after the tag byte) |
|-----|---------|-----------|------------------------------|
| `0` | `control`  | both | `VideoControlMessage` (§9.2) |
| `1` | `video`    | host → client | one `FrameFragment` (§9.3) |
| `2` | `geometry` | host → client | `WindowGeometryMessage` (§9.5) |
| `3` | `cursor`   | host → client | *(logical id; physically carried on the dedicated cursor socket, untagged — §9.6)* |
| `4` | `input`    | client → host | `InputEvent` (§9.7) |
| `5` | `recovery` | client → host | `RecoveryMessage` (§9.8) |

> The `cursor` tag value (`3`) is reserved for completeness/symmetry; cursor datagrams physically
> travel on the dedicated cursor socket as bare bytes, so they carry no leading channel tag.
> Client→host recovery messages (§9.8) ride their OWN media-socket channel (`5`), **never** the
> `input` channel: a `RecoveryMessage`'s leading type byte (1/2/3) overlaps an `InputEvent`'s
> (mouseMove/Down/Up), so multiplexing them onto `input` would have the host mis-decode a recovery
> request as a phantom mouse event. The dedicated tag removes that ambiguity (no discriminator byte).

The enum is defined identically (byte-for-byte raw values) in both `SlopDeskVideoHost` and
`SlopDeskVideoClient`; the client cannot depend on the macOS-only host module, so it carries its own
copy. *(Candidate to hoist into `SlopDeskVideoProtocol` so one definition is shared.)*

## 9.2 Session bring-up — `VideoControlMessage` (control channel)

PATH 2 has no TCP handshake; a tiny control exchange runs over the UDP **control** channel before any
media flows. `[UInt8 type][body]`, big-endian:

| Type | Name | Direction | Body |
|------|------|-----------|------|
| `1` | `hello`    | client → host | `UInt16 protocolVersion` + `UInt32 requestedWindowID` + `Float64 viewportW` + `Float64 viewportH` |
| `2` | `helloAck` | host → client | `UInt8 accepted(0/1)` + `UInt32 streamID` + `UInt16 captureWidth` + `UInt16 captureHeight` + `Float64 boundsX` + `boundsY` + `boundsW` + `boundsH` |
| `3` | `bye`      | either | *(empty)* |
| `24` | `helloDisplay` | client → host | `UInt16 protocolVersion` + `UInt32 requestedDisplayID` + `Float64 viewportW` + `Float64 viewportH` |

- `hello` announces the client, the host `CGWindowID` it wants to remote, and the client viewport
  size so the host can size capture/encode to the client surface.
- **`helloDisplay` (24, the full-desktop pane — 2026-07-14 pivot)** is the display sibling of
  `hello`: it names a host `CGDirectDisplayID` (`0` = the main display) instead of a window, and the
  host answers with the SAME `helloAck` shape — `bounds*` carry the DISPLAY's CG bounds and
  `captureWidth/Height` its point size, so everything downstream (decode, aspect-fit, the
  normalized input mapping) is target-agnostic. A display session never resizes the host
  (`resizeRequest` is rejected; the client letterboxes), gets no geometry datagrams (the bounds are
  fixed), and injects input with NO AX raise (whole-desktop input lands wherever a local user's
  would). An old host drops the unknown type → the client's hello retry gives up like any downed
  host.
- `helloAck` confirms (or rejects via `accepted = 0`) and reports the **host-decided** capture
  dimensions plus the window's current **CG top-left bounds** — the client's input-mapping origin
  until the geometry channel updates it. ("Negotiated" elsewhere in the code/comments means this
  single host-decides-and-reports step — the host sizes capture to the client viewport and reports it
  back — **not** a two-way negotiation; the protocol version itself is strictly non-negotiated, per
  §9 / §4.)
- The host starts capture/encode **only on an accepted `hello`**; a duplicate `hello` is re-acked
  idempotently. Either side sends `bye` for a clean teardown.
- **Session-liveness closure (2026-07-03, the reconnect-wedge fix — behavior only, no wire change):**
  (1) the client **re-sends the `hello` on an exponential backoff (0.5 s → 5 s cap) while
  unanswered**, so a lost hello/ack — or a host that is still restarting — can no longer wedge a pane
  in "connecting" forever; (2) the host daemon **sends `bye` (×2) on every live lane at graceful
  shutdown**; (3) a restarted host that receives an **unbound-lane datagram proving the sender still
  believes a session exists** (input / recovery / control `keepalive`/`resizeRequest`/`focusWindow`)
  **answers `bye` on the arrival flow** (rate-limited, one per second per channelID;
  hello/discovery/stray-`bye`/undecodable payloads are never answered — validate-then-drop, no
  reflection). On any received `bye` the client tears down and **rebuilds the whole pipeline** (fresh
  channelID lane + hello + decoder/pacer/renderer), so a videohostd restart self-heals within one
  keepalive interval (≤ ~5 s) instead of freezing the pane with dead input.
- **Host→client heartbeat + stall scrim (2026-07-03, the residual of the above — behavior only, no
  wire change):** while a session streams, the host sends a zero-body **`keepalive` (6) host→client
  every 1 s** (`KeepaliveTiming.hostHeartbeatInterval`; type 6 was already documented wire-safe in
  both directions — an old client's FSM drops it inertly). The client stamps the arrival of every
  decodable control message and every video fragment, and a ~1 s monitor evaluates `StreamStallPolicy`
  (threshold 3 s = tolerates two lost heartbeats): **no frame AND no control for ≥ 3 s while streaming
  ⇒ the pane overlays a "Reconnecting…" scrim** over the frozen last frame. The heartbeat — not frame
  arrival — is the liveness signal, so a healthily-idle window (idle-skip suppresses frames by design)
  never false-stalls. The scrim is **sticky** through the self-heal rebuild (bye → fresh lane/hello)
  and clears only when traffic actually resumes. A stopped/bye'd host session sends no heartbeat (it
  must go silent so the monitor sees the truth).
- Beyond the handshake the control channel also carries additive host→client info messages, each an
  unknown type an old peer simply drops: `resizeAck` (5), `streamCadence` (10), `scrollOffset` (13),
  `contentMask` (14), and **`displayMax` (15)** = `UInt16 maxWidthPt` + `UInt16 maxHeightPt`, the max
  POINT size the captured window can reach (the bounds of its display, or the parked VD). The host
  sends it once at capture start, paired with its resize-to-display-origin step, so the client's
  "Resize…" popover can cap its width/height fields at a size the remote can actually adopt.
- **Live stream settings (25, client → host, 2026-07-16):** `streamSettings` = `UInt8 fpsCap` +
  `UInt32 bitrateCeilingBps` — the user's per-session encode fps CAP and bitrate CEILING. `0` on
  either axis means AUTO (clear that override); non-zero values are clamped on the HOST at apply
  time (fps 5…120, bitrate 500 kbps…200 Mbps — the decoder rejects only a malformed length). A
  later message REPLACES the earlier one wholesale. The fps cap composes with the FPS governor
  (`min(governed, cap)`) and actuates the governed-fps path (capture cadence gate + VT
  `ExpectedFrameRate` + a `streamCadence` announce so the client pacer rebases); the bitrate
  ceiling layers UNDER the resolution-derived policy ceiling in the ABR controller (the current
  target clamps down immediately; climbs never exceed it). Per-session HOST state: it dies with a
  session re-mint, so the client re-sends its last-requested values after every accepted
  (re-)hello. Inert to an old host (unknown type → dropped).
- **Session-LESS discovery (no capture mint; the request bootstraps its reply flow at the mux, is
  never answered with an unbound-lane `bye`, and its lane is retired after the reply):**
  `listWindows` (7, zero body) → `windowList` (8) powers the remote-window picker AND the client's
  `WindowRebind` open-time/reconnect revalidation. The reply enumerates ALL streamable windows —
  on-screen first, then titled minimized / other-Space ones (the mint path rescues those via AX
  un-minimize), so absence in the reply really does mean "gone from the host";
  `listSystemDialogs` (11, zero body) → `systemDialogList` (12) powers the system-popup panes;
  `listDisplays` (22, zero body) → `displayList` (23, `UInt16 count` + per record `UInt32
  displayID` + `UInt16 wPt` + `UInt16 hPt` + `UInt8 isMain`) enumerates the online displays for the
  full-desktop pane (the client defaults to the main display via `requestedDisplayID 0`, so this
  pair is informational/multi-display only). Exact record layouts live in the
  `VideoControlCodec.swift` header table (golden-pinned).
- **Host-window FEED (2026-07-11; the dedicated rail UI was retired by the 2026-07-14 full-desktop
  pivot — the feed remains LOAD-BEARING for Open Quickly's Host rows + the app-launch layout
  auto-switch):** `windowFeedSubscribe` (16, client → host,
  `UInt32 knownGeneration`, 0 = have nothing) is the ONE feed message — sent every ~2 s while
  Open Quickly is visible it is simultaneously the poll, the (Phase-2)
  subscription renewal, and the loss-healing resync anchor. The host answers with either
  **`windowFeedCurrent` (18, `UInt32 generation`)** — "you're current", so a quiet desktop costs
  5 bytes each way per renewal — or a **`windowFeedSnapshot` (17)** chunk sequence: `UInt32
  generation` + `UInt8 chunkIndex` + `UInt8 chunkCount` + `UInt16 recordCount` + records of `UInt32
  windowID` + `UInt16 wPt` + `UInt16 hPt` + `UInt8 flags` (bit0 onScreen, bit1 minimized, bit2
  appHidden, bit3 frontmostApp, bit4 focusedWindow) + `UInt8 displayIndex` + lp `bundleID` + lp
  `appName` + lp `title`. Always FULL snapshots (never deltas — idempotent, latest-wins on a lossy
  lane), byte-budgeted by the host so each chunk fits one datagram
  (`VideoControlMessage.feedRecordBytesPerChunk`, titles capped at 120 UTF-8 bytes), dup-sent ×2
  ~25 ms apart (the `bye`/`streamCadence` loss pattern). The client assembles per generation (all
  chunks must agree on `chunkCount`), applies the latest fully-assembled generation, and heals any
  loss at the next renewal. All three are inert to an old peer (unknown type → dropped).
- **App icons + blobs (client-dormant since the rail's retirement — the wire stays pinned):**
  `appIconRequest` (19, client → host, `UInt16 sizePx` +
  lp `bundleID`) is session-LESS like the feed subscribe (bootstraps, bye-exempt, lane retired per
  answer). The host answers with **`blobChunk` (20)** — the ONE shared binary-blob reply: `UInt8
  blobKind` + `UInt64 blobID` + `UInt16 metaA` + `UInt16 metaB` + `UInt8 chunkIndex` + `UInt8
  chunkCount` + `UInt16 byteCount` + bytes (≤ `VideoControlMessage.blobBytesPerChunk` per chunk).
  Kind 0 = app icon (PNG, `blobID` = FNV-1a64(bundleID), `metaA` = pxEdge, assembled cap 32 KB);
  kind 1 = window preview (JPEG, `blobID` = windowID, `metaA`/`metaB` = pxW/pxH, cap 48 KB — Phase
  4). The client's shared `BlobAssembler` reassembles per (kind, blobID), caps hostile
  accumulation, and validates image magic before any cache sees bytes; a request retransmit
  re-sends every chunk from the host's LRU'd encoded cache (whole-blob re-request — no per-chunk
  NACK machinery). Both inert to an old peer.
- **Window-preview PEEK (client-dormant since the rail's retirement):** `windowPreviewRequest` (21, client → host, `UInt32
  windowID` + `UInt16 maxWidthPx`) — session-LESS like `appIconRequest`. Answered with `blobChunk`
  kind 1 (JPEG). The host hard-throttles (single-flight per window, captures reused ≤ 1 s, ≤ 2
  fresh captures/s globally, chunks paced ~1 datagram/ms) because `SCScreenshotManager` shares
  WindowServer/GPU with the live encoders; a throttled request is answered with SILENCE (the
  client's peek is fully-formed-only — nothing appears). Inert to an old peer.

## 9.3 Video frame datagrams — `FrameFragment` (video channel)

An encoded HEVC frame (AVCC: length-prefixed NAL units, with the IDR carrying inline VPS/SPS/PPS — the
client self-configures its `CMVideoFormatDescription` from those parameter sets, no out-of-band
parameter exchange) is fragmented into datagrams ≤ **1200 bytes** (`VideoPacketizer.maxDatagramSize`,
doc 17 §3.6 — under the runtime MTU including WireGuard-mesh overhead).

**Fragment header — fixed 15 bytes, big-endian:**

```
off 0: UInt32 streamSeq    — monotonic per-datagram sequence (loss / ordering)
off 4: UInt32 frameID      — groups all fragments of one encoded frame
off 8: UInt16 fragIndex    — 0-based fragment index within the frame
off10: UInt16 fragCount    — total fragments in the frame (data + parity)
off12: UInt8  flags        — bit0 keyframe(IDR) | bit1 parity(FEC) | bit2 crisp(Session B)
off13: UInt16 payloadLen   — payload byte count that follows
off15: [payloadLen] bytes  — fragment payload (AVCC bytes, or FEC parity)
```

`streamSeq` is a monotonic per-**datagram** index (every emitted datagram, data and parity alike,
increments it) — the loss/ordering signal, analogous to PATH 1's per-message `output.seq` but at
datagram granularity. `frameID` is a monotonic per-**frame** index. `flags` bits: `keyframe` (fresh
decode anchor / IDR), `parity` (this fragment is FEC parity, not original data), `crisp` (the frame
came from the on-demand all-intra "crisp" Session-B encoder).

## 9.4 Forward error correction (FEC)

To absorb single-packet loss without a round trip, the packetizer appends **XOR parity** fragments
per frame (`XORParityFEC`, default `groupSize = 5` ⇒ ~20% parity, the Sunshine/doc-17 target). Each
group of up to 5 data fragments yields one parity fragment = the byte-wise XOR of the group, where
each member is **length-prefixed (`UInt32` BE)** before XOR so recovery reproduces the exact original
length even when group members differ in size. Parity fragments carry the `parity` flag and share the
frame's `frameID`/`fragCount`.

Recovery fills exactly **one** missing data fragment per group (`parity XOR survivors`, then strip the
length prefix); **two or more** losses in a group are unrecoverable and left as a hole, which the
client escalates via §9.8 recovery requests. The `FECScheme` protocol lets a Reed-Solomon codec
replace XOR later without touching the wire header.

## 9.5 Window geometry — `WindowGeometryMessage` (geometry channel)

Host → client window move/resize/title so the client view repositions before the next frame
(doc 17 §3.8). `[UInt8 type][body]`, big-endian; coordinates are host CG-space **points**:

| Type | Name | Body |
|------|------|------|
| `1` | `move`   | `Float64 x` + `Float64 y` (new top-left origin) |
| `2` | `resize` | `Float64 width` + `Float64 height` |
| `3` | `bounds` | `Float64 x` + `y` + `width` + `height` (move+resize in one) |
| `4` | `title`  | remaining bytes = UTF-8 title (non-UTF-8 → `.malformed`) |

## 9.6 Cursor side-channel (dedicated cursor socket)

The host strips the cursor from the captured video (`showsCursor = false`) and streams it out-of-band
so it composites client-side at RTT latency (doc 17 §3.3). Both messages travel on the dedicated
cursor socket as **bare bytes**, told apart by their leading type byte (`CursorChannelMessage` peeks
the first byte to route):

**`CursorUpdate` (type `1`) — hot, position-only, fixed 36 bytes (< 64-byte budget), ~120 Hz:**

```
off 0: UInt8   type (=1)
off 1: UInt16  shapeID      — references a shape bitmap the client has cached
off 3: UInt8   visible (0/1)
off 4: Float64 x            — host-window-space point
off12: Float64 y
off20: Float64 hotspotX
off28: Float64 hotspotY
```

**`CursorShapeMessage` (type `2`) — rare bitmap, shipped once per new `shapeID`:**

```
off 0: UInt8   type (=2)
off 1: UInt16  shapeID
off 3: UInt16  width        — points (informational; the PNG is self-describing)
off 5: UInt16  height
off 7: Float64 hotspotX
off15: Float64 hotspotY
off23: UInt32  bitmapLength
off27: [bitmapLength] bytes — PNG-encoded cursor image
```

A single cursor PNG fits comfortably in one 1200-byte datagram, so the shape channel needs no
fragmentation. The client caches each shape by `shapeID` and composites it at
`position * videoScale − hotspot`, where `videoScale = layerSize.width / decodedSize.width`.

**`SwipeNavStatusMessage` (type `3`) — rare status push, fixed 5 bytes:**

```
off 0: UInt8   type (=3)
off 1: UInt8   eligible   (0/1) — a qualifying swipe would be translated to ⌘[/⌘] right now
off 2: UInt8   slowTier   (0/1) — the host's SLOPDESK_SWIPE_NAV_SLOW operating point
off 3: UInt16  fireTravel — points, the host's clamped SLOPDESK_SWIPE_NAV_TRAVEL
```

Sent by the host on every frontmost-app **activation** plus a ~2 s heartbeat (`SwipeNavStatusKicker`
fan-out; a window session resolves eligibility against its own target app instead of the frontmost).
The client's swipe-peel feedback mirror (doc 05 §8) is gated + threshold-tuned by the latest push;
until one arrives it stays NOT eligible, so an older host simply never shows the overlay. Pure
fire-and-forget — a lost datagram self-heals on the next beat. Golden vector: `swipeNavStatus`.

**Client → host prime (mux only).** On the shared-flow mux the cursor socket is host→client except
for the lane's flow **prime**: a channelID-framed datagram (`[UInt32 BE channelID][payload…]`, no
channel tag; payload content is ignored — the reference client sends one `0x00` byte) whose only
purpose is teaching the host which remote flow carries this lane's cursor replies. Because no other
client→host traffic exists on the socket, a lost stamp never self-heals the way the media flow does
(re-stamped by every routed inbound datagram) — so the client sends the prime at lane registration,
**with every `hello`/`helloDisplay` (including retries)**, and **piggybacked on each `keepalive`
tick**: a host daemon restart or NAT rebind then restores cursor delivery within one keepalive
interval instead of freezing the pointer shape for the lane's lifetime.

## 9.7 Input events — `InputEvent` (input channel, client → host)

Client→host input (doc 17 §3.9 / doc 05). Pointer positions are in **normalised window space (0..1)**
— the client never sends raw pixels, removing all pixel-vs-point ambiguity; the host maps normalised →
host-window-point via `CoordinateMapping`. Every event carries a `UInt32 tag` = the value the host
stamps on `eventSourceUserData`, so it filters its own self-injected events out of the cursor /
geometry watchers and avoids feedback loops (doc 18 §A). `[UInt8 type][body]`, big-endian:

| Type | Name | Body (after type byte) |
|------|------|------------------------|
| `1` | `mouseMove` | `UInt32 tag` + `Float64 nx` + `ny` |
| `2` | `mouseDown` | `UInt32 tag` + `UInt8 button` + `UInt8 clickCount` + `UInt8 modifiers` + `Float64 nx` + `ny` |
| `3` | `mouseUp`   | *(same layout as `mouseDown`)* |
| `4` | `scroll`    | `UInt32 tag` + `Float64 dx` + `dy` + `Float64 nx` + `ny` |
| `5` | `key`       | `UInt32 tag` + `UInt16 keyCode` + `UInt8 down(0/1)` + `UInt8 modifiers` |
| `6` | `text`      | `UInt32 tag` + remaining bytes = UTF-8 text |

`button`: `0` left / `1` right / `2` other. `modifiers` bitmask: `shift 1<<0`, `control 1<<1`,
`option 1<<2`, `command 1<<3`, `capsLock 1<<4`, `function 1<<5`. `key` is for navigation / shortcuts
by host virtual keycode; `text` is the robust layout-independent Unicode-insertion path (doc 05 §3) —
the host attaches the unicode string to the key-**down** only.

## 9.8 Loss recovery — `RecoveryMessage` (client → host)

When the client detects an unrecoverable fragment loss (a frame hole FEC could not fill), it asks the
host to recover **without** the bandwidth/latency spike of a forced keyframe. Sent on the dedicated
**`recovery` channel (tag `5`)** of the media socket — never `input` (§9.1). `[UInt8 type][body]`,
big-endian:

| Type | Name | Body |
|------|------|------|
| `1` | `ack`               | `UInt32 streamSeq` (highest contiguous datagram seq durably received — bounds the host's LTR-pin window; DOUBLES as the LTR/keyframe ack, carrying the decoded frame's `frameID` in that arm) |
| `2` | `requestLTRRefresh` | `UInt32 fromFrameID` + `UInt32 toFrameID` (the lost frame range) + `UInt32 lastDecodedFrameID` (`0xFFFFFFFF` = nothing decoded yet) |
| `3` | `requestIDR`        | `UInt32 lastDecodedFrameID` (`0xFFFFFFFF` = nothing decoded yet — keys the host's delivery-keyed recovery-IDR cooldown) |
| `4` | `requestCursorShape` | `UInt16 shapeID` — re-request a cursor SHAPE bitmap the client is missing (its one-shot shipment was lost / over-MTU); the host re-emits it on the cursor socket, the cache re-insert is idempotent |
| `5` | `networkStats`      | 11 × `UInt32`: `framesReceived` + `fecRecovered` + `unrecovered` + `latestHostSendTs` + `clientHoldMs` + `owdJitterMicros` + `owdTrendMilli` + `owdTrendFlags` + `pacerLateFrames` + `pacerPresentGaps` + `pacerDepth` — the periodic (~50 ms) client→host telemetry window; every field is RELATIVE (windowed counters / host-stamp echo / client-local deltas), so the host derives RTT in its OWN clock, clock-skew-free |
| `6` | `requestFragments`  | `UInt32 frameID` + `UInt16 count` + count × `UInt16 fragIndex` — NACK / selective ARQ (`SLOPDESK_NACK=1`, capped at 64 indices): the host re-sends exactly those data fragments from its send-history ring; a ring miss is a benign no-op (the Dropped→LTR-refresh fallback still fires) |

Recovery **prefers an LTR refresh** (`requestLTRRefresh`): the client names the lost frame range; the
host invalidates the referenced long-term-reference frame and encodes the next frame against an older
still-valid LTR (`kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh`). The invalidation
direction is client→host (doc 17 §3.6). The client's `RecoveryPolicy` escalates to `requestIDR` if no
decodable frame arrives within ~**2 RTT** of the LTR-refresh request (`idrTimeoutRTTMultiple`, default
`2.0`; the escalation is driven off the client's loss-detection path against the smoothed RTT
estimate).

**Host handling (`RecoveryDatagramRouter` → `WindowCapturer.requestKeyframe()`):** the host routes a
`recovery` datagram to recovery handling (not the input injector). Today both `requestLTRRefresh` and
`requestIDR` map to a **forced IDR on the next captured frame** — a keyframe is always a correct, if
heavier, refresh; the dedicated LTR-refresh encode is a future optimisation. An `ack` advances no
window yet (no retransmit buffer) and is recorded for diagnostics. This re-anchors a loss-recovering
client immediately rather than waiting for the ~1 s heartbeat IDR.

## 9.9 Errors (`VideoProtocolError`)

| Case | Meaning |
|------|---------|
| `truncated` | A datagram ended before a fixed-size field could be read. |
| `malformed(String)` | A field held an out-of-range value (unknown message type, unknown channel/cursor/button tag, non-UTF-8 title/text); reason string attached. |

A corrupt single datagram is dropped (the error is caught at the receive boundary), never fatal — UDP
loss is the normal case PATH 2 is built to tolerate.
