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
| `scripts/check-android.sh` | ONLY gate on the Android panel's SOCKETS — needs a device in state `device`, an `adb` and a `scrcpy-server` jar (both vendored — `make provision`); sets `SLOPDESK_ANDROID_HW=1`, without which every case in `AndroidBridgeHardwareTests` is a no-op and a clean checkout stays green. Everything PURE about the panel (stream reassembly, control encoding, layout, scroll machine, logcat parse, bridge framing) is already in `make test-touched`; this proves the scrcpy v4.1 handshake and the bridge's line-JSON-then-bytes framing against real `adb`. Dialect + traps: `docs/48-android-panel.md` |
| `scripts/check-macos.sh`, `check-video.sh` | GUI proof; needs unlocked Aqua + Screen Recording TCC (not over SSH). `check-video.sh --second-client` = ONLY gate with two `SCStream`s + two `VTCompressionSession`s on one capture target (unit tests may not build any of the four). Client B gets the TERMINAL autoconnect only, so it must learn the pane from the document; asserts A's decode counter still climbs after B joins (fan-out, not takeover); screenshots each instance raised by PID — a name-matched raise photographs one client twice |
| `scripts/check-multiclient.sh` | Workspace-document / intent / projection changes — two app instances on one hostd, real menu gesture on one, `slopdesk --socket` reads the other's projection; needs **Accessibility** TCC. Step 7b asserts PTY fan-out unconditionally — every pane in the final layout must take a second subscriber |
| `scripts/soak-fanout-laggard.sh` | Fan-out / subscriber-set / out-FIFO / queue-gate / ReplayBuffer-retention changes — real hostd + clients + PTY, laggard frozen with `SIGSTOP`. Asserts retention loses nothing, eviction takes the LAGGARD not the session, the fast member is never head-of-lined, a pane shrunk back to one member still backpressures the PTY. ~80 s, no GUI/TCC. Default `SLOPDESK_SUB_LAG_BYTES` = 4 MiB for speed; `33554432` soaks the shipped value |

| `make lint-rust` / `make hook-test` | ONLY gate on `rust/slopdesk-hook` (the Claude Code hook relay). `swift build`/`swift test` never compile it, so a Swift-only run is blind to it. clippy runs `all`+`pedantic`+`nursery`+`cargo` plus a curated `restriction` slice, every group DENY, with `-D warnings` on top; the crate is `unsafe_code = "forbid"`. ⚠️ `cargo fmt` needs **nightly** (`rust/rustfmt.toml` enables unstable options) — the build and tests are stable-only. The relay's framing is a wire contract with `AgentHookRecord.split`, so `cargo test` is its golden pin and prek gates it on any `rust/**.rs|toml` change |

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

**Not a fourth path (2):** the Claude Code hook relay is a SEPARATE PROCESS (`~/.claude/hooks/slopdesk-agent`, built from `rust/slopdesk-hook`) that speaks one line-framed record over AF_UNIX to `AgentHookListener` — no FFI, no `SlopDeskProtocol`, no wire version. It is same-machine by construction (the hook runs inside the host's own PTY). ⚠️ It must stay SYNCHRONOUS (ordering is meaning) and must keep BOTH `PreToolUse` and `PostToolUse` — see the CLAUDE.md invariant. `swift build` does not produce it; `make build` stages it beside the host binary, which is where `AgentInstaller.bundledBinaryPath` looks.

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
| `SLOPDESK_ADB_BIN` / `_ANDROID_EMULATOR_BIN` / `_ANDROID_SERVER_JAR` / `_ANDROID_EMULATOR_ARGS` | Android panel tool overrides. No `adb` ⇒ the tab is `unavailable`; a missing `emulator` or jar is NOT (a plugged-in phone still lists, and a host with no jar still boots AVDs — it just cannot mirror). `adb` and the jar are vendored (below); the **emulator is deliberately not** — it comes from `sdkmanager` and is useless without gigabyte system images behind a licence accept. Detail: `docs/48-android-panel.md` |
| `SLOPDESK_ANDROID_HW` | `=1` arms `AndroidBridgeHardwareTests` (needs a booted device). Set by `scripts/check-android.sh`; off ⇒ every case is a no-op |
| `SLOPDESK_CODE_SERVER_BIN` | Code panel binary override, and the escape hatch that outranks the pin (bisecting a candidate build). Unset ⇒ the ``HostServiceProcess.searchDirectories`` walk described under **Vendored runtime deps** below |
| `SLOPDESK_BUILD_HASH` | Read at RUNTIME by `slopdesk version` (`CLIVersion.swift`) — appends a short build hash in parentheses. Absent in a plain `swift build`, so the parenthetical simply vanishes |
| `SLOPDESK_VERSION` / `_BUILD_NUMBER` / `_SIGN_IDENTITY` / `_NOTARY_PROFILE` / `_SKIP_NOTARIZE` | `scripts/package-release.sh` only — never read by shipped code. `_VERSION` is required and must match the `CLIVersion.version` constant or the script refuses to package. `_SKIP_NOTARIZE=1` is a pipeline dry-run: the output is signed but will NOT pass Gatekeeper elsewhere. Detail: `docs/49-release-pipeline.md` |

Deleted deliberately — do not reintroduce: `SLOPDESK_WORKSPACE_DOC`, `SLOPDESK_PANE_FANOUT` (multi-client sync is unconditional; a host that refuses `channelClass 1` gives a client a blank window with no error).

## Vendored runtime deps

The right panel's surfaces stand on programs this repo does not build. They are **pinned by URL + SHA-256 in `ThirdParty/tools/tools.lock`** and provisioned by `ThirdParty/tools/provision.sh` (`make provision`, `make provision-check`) into `ThirdParty/tools/.prefix/bin` (gitignored, ~730 MB). Same bargain as `ThirdParty/ghostty/`: the recipe is committed, the artifact is not.

**Why.** Homebrew's `code-server` formula froze at 4.112 and was deprecated, and nothing in the repo recorded — or could enforce — the version the panel was written against. The panel sat on Code 1.112 for months, below the 1.121 floor where the built-in mermaid preview landed, and no gate could see it.

| Dep | Surface | Pinned | Note |
|---|---|---|---|
| `code-server` | code panel (verb 18) | 4.131.0 | floor is **4.121** — Code 1.121 is where `mermaid-markdown-features` became built-in |
| `baguette` | simulator panel (verb 21) | 0.1.88 | executable is `Baguette`, sibling to the `.bundle` it loads assets from; the `bin/` symlink was checked to still resolve it |
| `adb` | Android panel (verb 22) | 37.0.1 | Google's versioned zip; its `repository2-3.xml` SHA-1 was cross-checked against our SHA-256 |
| `scrcpy-server` | Android panel | 4.1 | **committed** at `ThirdParty/tools/vendor/scrcpy-server` (716 KB, not an executable — the device's `app_process` runs it). `provision.sh` verifies those bytes, never downloads them |

**Search order** (`HostServiceProcess.searchDirectories`, mirrored by `AndroidToolchain.locateSDKTool`): `SLOPDESK_*_BIN` override → **vendored prefix** → `PATH` → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin`. The prefix outranking `PATH` is deliberate and is the whole point: a stale Homebrew copy silently winning is the failure this layer ends. `VendoredTools` finds the prefix by walking up from the running binary looking for `tools.lock`, so a hostd copied out of the checkout correctly resolves nothing and falls through.

**hostd never provisions.** Nothing on the runtime path downloads, extracts or writes — it stats. A coding host must not reach the network because someone opened a panel.

**Not vendorable, and not attempted:** iOS simulator runtimes and `simctl` (inside Xcode, Apple's licence — `baguette` is the vendorable half), and the Android emulator with its system images (`sdkmanager`, licence-gated, gigabytes per API level — `adb` is the vendorable half). Both keep their existing host-discovery path and report unavailable when the host has none.

**Bumping a pin has a tail.** For `code-server` specifically: re-measure `CodeSidebarWebView.clippedTitleBarHeight` against the new workbench (the title bar the client clips off — 35px on Code 1.112, 30px on 1.131; it is inline geometry, not a greppable CSS constant, so measure `getBoundingClientRect()` on `#workbench.parts.titlebar`), re-check `CodeServerManager.seededUserSettings` against the new settings schema (only registered keys may be seeded, and the shipped extension set moves between releases), and run `scripts/measure-code-server-start.sh` — the daemon prewarms this child at boot (docs/DECISIONS 2026-08-07), so a spawn→listen regression lands on every hostd restart, not just on panel opens.

## Wire golden vectors — the long version

Manual binary encode (no JSON/Codable on the hot path); multi-byte ints big-endian; UUIDs 16 raw bytes. After wire changes run `bash scripts/golden-check.sh`, then update `docs/20-wire-protocol.md`.

**Never** `>`-redirect the generator over `golden/golden_vectors.json` — it emits a subset (13 frozen keys are XCTest-only). Generate with **no** `SLOPDESK_*` env set. An intended format change is a surgical hand-merge, not a regeneration.
