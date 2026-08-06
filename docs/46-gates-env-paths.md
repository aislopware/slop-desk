# 46 — Gates, env flags, three paths

Full detail split out of `CLAUDE.md` to keep that file small. `CLAUDE.md` carries the one-line rules; this file carries the *why* and the exact conditions. Read the relevant row before choosing a gate, touching a transport, or adding a `SLOPDESK_*` flag.

## Gates — which one reaches which path

Clean checkout builds headless with no prerequisite: `swift build`/`swift test` never see libghostty / VideoToolbox / ScreenCaptureKit; libghostty only in Xcode app targets (`TerminalSurface` seam), built via `ThirdParty/ghostty/build-libghostty.sh` (Zig; never blocks headless core).

| Gate | When / what it uniquely covers |
|------|-------------------------------|
| `scripts/test-touched.sh` (`make test-touched`) | **Default inner-loop gate after Swift edits** — incremental build + only the test targets whose dependency closure reaches the changed files (~10-50s vs ~100s full `swift test --parallel`). Diffs against the last full-green tree, so scope grows until a full run resets it; Package.swift/golden/unattributable paths escalate to full; a partial green never warms the pre-push cache. Full suite (`make test`) before push / after big cross-cutting changes |
| `.build/release/slopdesk-loopback-validate` (`--smoke`/`--frames N`) | FEC / packetizer / reassembler changes — real VT encode→decode, no GUI |
| `scripts/check-ios.sh` | `#if os(iOS)` / UIKit changes — type-checks the iOS slice (`swift build` skips iOS); runs zero tests |
| `scripts/check-ios-tests.sh` | ONLY executor of iOS tests (host-less bundle, booted simulator, iOS triple). `swift test` compiles the **macOS** side of every `#if os(iOS)` fork — an iOS default asserted there is asserted about the wrong branch |
| `scripts/check-launch-restore.sh` | ONLY gate on the shipping launch path (`workspace.json` restore → offer → `connectIfSavedTarget()`). Every other GUI gate sets `SLOPDESK_AUTOCONNECT_*` → `hasAutomationEnvironment()` true → automation branch (persistence nil, layout replaced by one synthetic pane). Run after `WorkspaceStore` restore/autosave, `connectIfSavedTarget()`, or `runArmedLaunchAdoptIfPossible` changes |
| `scripts/herdr-sync.sh` | `SlopDeskAgentDetect` engine/manifest changes, or herdr upstream sync — builds the real herdr binary, diffs both engines on ~10k screens (`scripts/herdr-differential.py`); pin = `scripts/herdr.pin` |
| `scripts/check-android.sh` | ONLY gate on the Android panel's SOCKETS — needs a device in state `device`, an `adb` and a `scrcpy-server` jar (`brew install scrcpy`); sets `SLOPDESK_ANDROID_HW=1`, without which every case in `AndroidBridgeHardwareTests` is a no-op and a clean checkout stays green. Everything PURE about the panel (stream reassembly, control encoding, layout, scroll machine, logcat parse, bridge framing) is already in `make test-touched`; this proves the scrcpy v4.1 handshake and the bridge's line-JSON-then-bytes framing against real `adb`. Dialect + traps: `docs/48-android-panel.md` |
| `scripts/check-macos.sh`, `check-video.sh` | GUI proof; needs unlocked Aqua + Screen Recording TCC (not over SSH). `check-video.sh --second-client` = ONLY gate with two `SCStream`s + two `VTCompressionSession`s on one capture target (unit tests may not build any of the four). Client B gets the TERMINAL autoconnect only, so it must learn the pane from the document; asserts A's decode counter still climbs after B joins (fan-out, not takeover); screenshots each instance raised by PID — a name-matched raise photographs one client twice |
| `scripts/check-multiclient.sh` | Workspace-document / intent / projection changes — two app instances on one hostd, real menu gesture on one, `slopdesk --socket` reads the other's projection; needs **Accessibility** TCC. Step 7b asserts PTY fan-out unconditionally — every pane in the final layout must take a second subscriber |
| `scripts/soak-fanout-laggard.sh` | Fan-out / subscriber-set / out-FIFO / queue-gate / ReplayBuffer-retention changes — real hostd + clients + PTY, laggard frozen with `SIGSTOP`. Asserts retention loses nothing, eviction takes the LAGGARD not the session, the fast member is never head-of-lined, a pane shrunk back to one member still backpressures the PTY. ~80 s, no GUI/TCC. Default `SLOPDESK_SUB_LAG_BYTES` = 4 MiB for speed; `33554432` soaks the shipped value |

Ratchets inside `make lint`: `check-ds-leaks.sh` (Slate tokens live in `Sources/SlopDeskClientUI/DesignSystem/SlateDesign.swift`), `check-menu-shortcutless.sh` (no `.keyboardShortcut` in `WorkspaceCommands.swift`).

SIMD detail: the frame hash is scalar Swift, **not** NEON — only the GF(2⁸) multiply kernel in `Sources/CSlopDeskSIMD` has a NEON path, and `GF256NeonDifferentialTests` is what pins it equivalent to the scalar fallback.

Hang-safety detail: video unit tests stay pure `SlopDeskVideoProtocol` + controllers — no `SCStream`, `VTCompressionSession`, `VTDecompressionSession` or Metal device. Security detail: there is no app-layer crypto/auth; the replay buffer holds raw bytes and the WireGuard mesh is the boundary.

## Three paths (do not merge)

Separate transport, message set, version (`1` only — no negotiation).

| Path | Notes that bite |
|------|-----------------|
| Terminal (TCP) | Dual `.data` + `.control`; `TCP_NODELAY` on **both**. ReplayBuffer 256 MiB cap, 64 MiB offline gate **pauses PTY drain**; queue gate 64 KiB attached (latency) ↔ 64 MiB detached (budget — agent keeps running while away). Real smoke: `SubprocessE2ETests` (in-memory loopback misses open-order races). |
| GUI video (UDP) | Media socket (1-byte channel tags; recovery has its own tag) + dedicated cursor socket. FEC via `FECScheme` (RS GF(2⁸)). |
| Inspector (TCP) | Read-only; client→host is only `subscribe(fromSeq:)`. |

**Not a fourth path:** the Simulators panel speaks a FOREIGN wire (`baguette serve` — HTTP + one websocket, H.264 down / JSON up) to a third-party process, sharing no socket, message set or codec with the three above; `SlopDeskProtocol` never sees a byte of it. Only discovery (metadata verb 21) rides a SlopDesk wire, and it carries an address, not frames. Dialect, traps and fixtures: **`docs/47-simulator-panel.md`** — read it before touching anything under `Sources/SlopDeskClientUI/Simulator`. Gate: `make test-touched` (the whole panel is unit-testable — both runtime seams are injectable, so no test opens a socket or builds a display layer).

**Nor is the Android panel:** a SECOND foreign wire — the host's own bridge relaying `scrcpy-server` v4.1 (H.264 down / touch and key messages up, on ONE full-duplex TCP connection). The relay is not optional: `adb forward` binds 127.0.0.1 only, so a mesh client cannot reach the device socket without it (`adb -a server -H 0.0.0.0` was rejected — machine-wide, and it hands every peer a device shell). Only discovery (metadata verb 22) rides a SlopDesk wire. Dialect, measurements and traps: **`docs/48-android-panel.md`** — read it before touching anything under `Sources/SlopDeskClientUI/Android` or `Sources/SlopDeskHost/Android`. Gates: `make test-touched` for everything pure, `scripts/check-android.sh` for the sockets.

## Env (`SLOPDESK_*`)

Not exhaustive — grep `SLOPDESK_`. **Default idiom:** `!= "0"` → default-ON; `== "1"` → default-OFF; check the call site.

| Flag | Notes |
|------|--------|
| `SLOPDESK_FEC_M` / `_FEC_K` | Set **identically** host + client |
| `SLOPDESK_VIDEO_DEBUG` | Video stderr |
| `SLOPDESK_DISPLAY_CAPTURE` | `window` / `display` / `include` |
| `SLOPDESK_PACER` | default present-on-arrival; `=deadline` for smoothness pacer |
| `SLOPDESK_AUDIO` | host app-audio stream gate (default-ON); `_CODEC=pcm` bypasses AAC-ELD |
| `SLOPDESK_SUB_LAG_BYTES` | laggard-eviction threshold, default **32 MiB** — deliberately BELOW the 64 MiB offline gate. TUNING, not a toggle. A lone subscriber is never evicted because eviction needs two or more members |
| `SLOPDESK_WORKSPACE_STATE_DIR` | relocates `workspace-state.json`. EVERY `HostServer` builds a `HostWorkspaceStore` — a test that calls `start()` must set this or inject `workspaceStore:`, or it reads/overwrites the developer's real workspace |
| `SLOPDESK_ADB_BIN` / `_ANDROID_EMULATOR_BIN` / `_ANDROID_SERVER_JAR` / `_ANDROID_EMULATOR_ARGS` | Android panel tool overrides. No `adb` ⇒ the tab is `unavailable`; a missing `emulator` or jar is NOT (a plugged-in phone still lists, and a host with no jar still boots AVDs — it just cannot mirror). The jar is NEVER in this repo and the host never downloads one — `brew install scrcpy`. Detail: `docs/48-android-panel.md` |
| `SLOPDESK_ANDROID_HW` | `=1` arms `AndroidBridgeHardwareTests` (needs a booted device). Set by `scripts/check-android.sh`; off ⇒ every case is a no-op |
| `SLOPDESK_CODE_SERVER_BIN` | Code panel binary override. Unset ⇒ `PATH` walk, then `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` (`HostServiceProcess.fallbackBinDirectories` — hostd is `nohup`'d, so its `PATH` is not a login shell's). **Install code-server ≥ 4.121 by hand, NOT with Homebrew**: the formula froze at 4.112 and is deprecated, and the built-in mermaid preview arrived in Code 1.121 (`mermaid-markdown-features`). Standalone: untar `code-server-<v>-macos-arm64.tar.gz` into `~/.local/lib/code-server-<v>` and symlink `~/.local/bin/code-server`; a leftover Homebrew copy must be `brew unlink code-server`'d or it wins the `PATH` walk. A version bump also means re-measuring `CodeSidebarWebView.clippedTitleBarHeight` (the web title bar the client clips off — 35px on Code 1.112, 30px on 1.131) |

Deleted deliberately — do not reintroduce: `SLOPDESK_WORKSPACE_DOC`, `SLOPDESK_PANE_FANOUT` (multi-client sync is unconditional; a host that refuses `channelClass 1` gives a client a blank window with no error).

## Wire golden vectors — the long version

Manual binary encode (no JSON/Codable on the hot path); multi-byte ints big-endian; UUIDs 16 raw bytes. After wire changes run `bash scripts/golden-check.sh`, then update `docs/20-wire-protocol.md`.

**Never** `>`-redirect the generator over `golden/golden_vectors.json` — it emits a subset (13 frozen keys are XCTest-only). Generate with **no** `SLOPDESK_*` env set. An intended format change is a surgical hand-merge, not a regeneration.
