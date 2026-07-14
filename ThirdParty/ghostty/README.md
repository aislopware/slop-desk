# libghostty — SlopDesk's terminal renderer

SlopDesk renders the terminal with **libghostty** (see
[`docs/DECISIONS.md`](../../docs/DECISIONS.md) → *Terminal renderer*).
The terminal path streams raw VT bytes from the host PTY to the client; libghostty parses
+ GPU-renders them in a Metal view. This directory is the build infra + Swift binding for
that renderer.

> **Why here and not in `Sources/`:** the binding links a Zig-built XCFramework, and that
> link must never enter the default `swift build` graph — otherwise the headless core suite
> could not build without the framework. So the binding + C module map live under
> `ThirdParty/ghostty/integration/` as **source files wired into no `Package.swift` target**;
> the macOS/iOS GUI app target adds them to its own build. A plain `swift build` / `swift test`
> never sees them → the core stays green with zero conditional-compilation hacks.

---

## Pins + the SLIM delta (2026-07-11)

| Pin | Value | Source of truth |
|-----|-------|-----------------|
| **Upstream** | `ghostty-org/ghostty` @ **`v1.3.1`** | canonical tag (2026-03-13); the reproducible base |
| **Slopdesk delta** | ONE consolidated patch, 17 files, +1155/−341 | `slopdesk-libghostty-on-v1.3.1.patch` |
| Slim SHA (local) | `5c78c84…` (branch `slim` in `.work/ghostty-src`) | v1.3.1 + the slim delta (not on any remote) |
| **Zig** | `0.15.2` | the source's `build.zig.zon` `minimum_zig_version` (0.16 not adoptable — see below) |
| Zig SHA-256 | `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b` | `zig-aarch64-macos-0.15.2.tar.xz` |

**2026-07-11 — SLIMMED the delta: tmux control-mode + iOS sync-search DROPPED.** The
patch-audit round confirmed SlopDesk references **zero** `ghostty_surface_tmux_*` /
`ghostty_surface_search_*` / `ghostty_surface_selection_bounds` symbols (SlopDesk *is*
the tmux replacement), so the fork's tmux viewer (~10k patch lines incl. the DCS/ST
parser rewrite in `dcs.zig`/`parse_table.zig` and a per-keystroke mutex round-trip in
`queueWrite`) was cut. What the consolidated patch now carries — the COMPLETE list:

- **External-IO backend**: `src/termio/External.zig` (~470 LOC), the `external` arm in
  `src/termio/backend.zig`, `src/termio.zig` export, the `embedded.zig` glue
  (`ghostty_surface_write_output`, `ghostty_surface_draw_now`, `getTermioBackend`/
  `usesExternalBackend`, `backend_type`/`write_callback`/`resize_callback` surface-config
  fields) + the matching `include/ghostty.h` declarations, and `Surface.zig`'s
  backend-selection block in `init()` (+ the `.external` arm in `childExitedAbnormally`).
- **Termio torn-read fix**: `self.size = size` moved INSIDE `renderer_state.mutex` in
  `Termio.resize` — with the external backend, `processOutput` runs on the embedder's
  feed thread and reads `size` under that mutex.
- **updateFrame serialization** (the ex-patch-0001, race-fixed): `Surface.draw()` calls
  `renderer.updateFrame()` synchronously (iOS-Simulator wakeup-pump bug + crisp macOS
  resize reflow), and the NEW `update_mutex` in `src/renderer/generic.zig` serializes
  every `updateFrame` entry — closing the main-thread-draw vs renderer-thread data race
  the 2026-07-11 audit found (`terminal_state` periodic reset, highlight rebuilds, and
  `dirty=false` all mutate outside `state.mutex`/`draw_mutex`). The round-4 audit
  extended it to every "must be called on the render thread" mutator of
  updateFrame-visible state: `changeConfig` (frees `config.links`' arena + swaps
  `font_shaper` → was a UAF window), `setFontGrid` (its `markDirty` could be swallowed
  by updateFrame's dirty reset → garbage glyphs), `setScreenSize`, `setFocus`, and the
  two search-match swaps in `renderer/Thread.zig` `drainMailbox` (upstream takes NO
  lock there). Lock order: `update_mutex → state.mutex → draw_mutex` (update_mutex
  always outermost; no guarded path holds the other two when acquiring it).
- **iOS embedding fixes**: `ghostty_config_load_file_len`/`ghostty_config_load_string`
  (iOS has no default config paths) + `NoHomeDir` tolerance in `Config.zig`, the
  `Metal.zig` teardown UAF fix (clear display callback + `removeFromSuperlayer` in
  `deinit`/`loopExit` — the upstream-#13021 class), the `main_c.zig` iOS panic handler,
  and lib-mode logging in `global.zig`.
- **Unicode 17 width tables** (`src/simd/codepoint_width.*`) and two defensive
  `unreachable`→graceful-return fixes in `src/terminal/search/` (upstream's own search
  engine; ReleaseFast `unreachable` is UB).
- **Programmatic selection + viewport readback (2026-07-14, the copy-mode ceiling lift)**:
  `ghostty_surface_set_selection` / `ghostty_surface_clear_selection` /
  `ghostty_surface_viewport_info` (+ `ghostty_viewport_info_s`) in `embedded.zig` +
  `include/ghostty.h`. Resolves the same tagged points as `read_text`, drives
  `Screen.select` under `renderer_state.mutex`, bypasses copy-on-select (yank copies
  explicitly), wakes the renderer like `select_all`'s `queueRender`. Lets the client's
  keyboard copy-mode START a char/line/block selection from a vi cursor (DECISIONS.md
  2026-07-14).

**What was dropped** (present in the pre-2026-07-11 fat delta; recoverable from git
history of this file + the old patch): the tmux control-mode viewer
(`src/terminal/tmux/*`, `stream_handler.zig` observer plumbing, `apprt` tmux
actions/messages, `Surface.zig` pane bindings, 14 `ghostty_surface_tmux_*` C APIs), the
iOS sync-search C API, `ghostty_surface_selection_bounds`, and the unconditional
DCS/ST/`parse_table` rewrite (upstream FSM behavior is restored). The `queueWriteLocked`
patch (ex-0002) is gone WITH its trigger: upstream `queueWrite` never touches
`renderer_state.mutex`, so the recursive-lock hazard no longer exists.

Historical provenance: the external backend originated in
`daiimus/ghostty:ios-external-backend` @ `21c71734` (v1.3.0-based, frozen since
2026-03-10); the original ~470-LOC backend delta stays recorded in
[`External.zig.patch`](External.zig.patch). The pre-slim consolidated fork delta
(32 files, +9469/−793 incl. tmux) is in git history at tag-time `a499d3d1^`.

Reproducible recipe: `git clone --branch v1.3.1` upstream + apply
`slopdesk-libghostty-on-v1.3.1.patch`; `build-libghostty.sh` automates it (its §2
sentinel = `External.zig` present + `update_mutex` in `generic.zig`).

`brew`'s `zig 0.16.0` cannot build this source (see below). The build script ignores brew
and downloads the pinned **0.15.2** into the gitignored `.toolchain/`, used via a
build-local `PATH`.

---

## Upstream watch (audited 2026-07-11)

**v1.3.1 is STILL the latest upstream release tag** (only the mutable `tip` nightly exists past
it; `1.3.2`/`1.4.0` milestones are open but unshipped). Upstream `main` is ~1.4k commits ahead
with material terminal-core work — **all unreleased**, so the pin stands. Re-audit when a new
tag lands. What's waiting on `main` (motivates a prompt rebase when tagged):

- **VT throughput**: PR #13220 (~1.5–6×) + #13226 (~1.2–3.4×; ASCII ~128→~725 MB/s) — directly
  helps us, our client pushes remote-PTY bytes through `ghostty_surface_write_output`.
- **Scrollback page compression**: PR #13264 (70–90% resident-memory savings) + the #13282
  `page_serial` generation-marker correctness fix (search-after-erase panics).
- (PR #13209's pty-read pipelining does NOT apply to us — the external backend bypasses termio reads.)

Rebase exposure is small: `include/ghostty.h` on `main` renames `ghostty_app_key_is_binding` →
`ghostty_config_key_is_binding`, drops `translated` from the trigger union (we use neither), and
makes `ghostty_surface_free_text` take `(surface, text*)` — our binding already passes `(s, &text)`.
New `GHOSTTY_API` visibility macro is harmless for static linking (`GHOSTTY_STATIC`).

- **External-IO backend stays fork-only.** Upstream PR #10484 (Manual termio backend, ~our
  approach) was closed unmerged with zero review; no tracking issue exists. Official iOS support
  ships an embedded UIView platform but its termio is `exec`-only — the fork delta remains required.
- **daiimus fork is frozen** at `21c71734` (2026-03-10, zero commits since). Its tmux
  delta was DROPPED from our tree 2026-07-11 (see "Pins + the SLIM delta") — we now carry
  only External.zig + the embedded glue + slopdesk fixes, so the next upstream rebase is
  ~2k patch lines instead of ~12.5k.
- **Known live bug upstream+forks**: iOS Metal-teardown use-after-free on `ghostty_surface_free`
  (issue #13021, closed without a merged fix; `Metal.zig` at HEAD has no `loopExit`/`threadExit`).
  Affects any Metal-embedding iOS app freeing a surface during renderer teardown — re-check before
  shipping the iOS client.

## Build outcome (honest status)

**The build WORKS on this macOS 26.5 / Xcode 26.5 / arm64 host** and produces a universal
`libghostty.xcframework` (macos-arm64 + ios-arm64 + ios-arm64-simulator), all external-IO
symbols verified. The Zig-0.15.2 ↔ macOS-26-SDK *link* wall is resolved by the **xcrun SDK
shim** (caveat #1 in the script header): the build-local `xcrun` answers `macosx
--show-sdk-path` with an old SDK (≤ 15.x) so Zig's native macOS link step succeeds, while
iOS/sim queries pass through to the real 26.5 SDK. The shim is **build-time only** — zero
effect on the shipped binary or runtime. `build-libghostty.sh` preflights it with a libSystem
link smoke test.

### Why Zig stays 0.15.2 (and is NOT bumped to 0.16.0)

Zig **0.16.0** (2026-04-13) *is* the first Zig that links the macOS 26 SDK natively (it
carries the `aarch64-macos`↔`arm64e-macos` TBD-matching fix), so on paper it could drop the
SDK shim. We deliberately **do not** adopt it: **ghostty does not compile under Zig 0.16.0**,
and neither does upstream ghostty itself (HEAD still pins `minimum_zig_version = "0.15.2"`).
The 0.15→0.16 boundary is a large, multi-class breaking change across the ~462-file source:

- `std.ArrayList` → **unmanaged-by-default** (managed `.init(alloc)`/`.append(item)`
  deprecated) → ~68 files;
- the **"Writergate"** I/O rewrite (`std.io.Reader`/`Writer`, `.writer()`/`.reader()`,
  `fixedBufferStream`, `getStdOut`) with new buffer semantics → ~40 files;
- `format`-method signature changes (`{}` → `{f}`);
- `std.process.EnvMap` → `std.process.Environ.Map` (17 files);
- plus the `requireZig` exact-minor gate.

Upstream hasn't done that port; doing it downstream — on top of the external-backend fork
delta — would yield a fragile, divergent fork whose subtle I/O-buffering behaviour can only
be validated by full ghostty test + HW runs. Since the shim is invisible at runtime, **0.15.2
+ shim is the correct pin**. **Re-evaluate when upstream bumps its own `minimum_zig_version`
to 0.16+** — then bump `ZIG_VERSION`/`ZIG_SHA256`, drop the shim, and re-verify the header.
(Checked 2026-07-11: upstream HEAD still pins `0.15.2`; the 0.16 migration is tracked in
upstream issue #12726 — Linux builds, macOS is blocked on Arocc/`translate-c` ARM/NEON.)

---

## How to build

```bash
# macOS arm64 native slice (fast first cut — the default):
ThirdParty/ghostty/build-libghostty.sh

# macOS universal + iOS arm64 device + iOS arm64 simulator slices:
XCFRAMEWORK_TARGET=universal ThirdParty/ghostty/build-libghostty.sh

# cap the actual `zig build` wall clock (seconds):
ZIG_BUILD_TIMEOUT_SECS=1800 ThirdParty/ghostty/build-libghostty.sh
```

The script is idempotent (re-runnable with no manual cleanup):

1. Downloads pinned Zig → `.toolchain/` (gitignored), **verifying SHA-256**.
2. Clones upstream @ `v1.3.1` → `.work/ghostty-src` (gitignored) and applies the slim
   delta patch; fast-fails if the external-IO symbols are not in the source header.
3. `zig build -Demit-xcframework=true -Dxcframework-target=<native|universal>
   -Doptimize=ReleaseFast` with the build-local Zig. First run also fetches ~15 Zig
   package deps into `.work/zig-global-cache` (network required).
4. Copies the produced `GhosttyKit.xcframework` → `libghostty.xcframework`
   (gitignored — large/derived).
5. `nm`-verifies the slice exposes `ghostty_surface_write_output`, then prints
   `OK: <path>` (or a precise failure).

**Gitignored** (derived/large; reproducible from the pins above):
`.toolchain/`, `.work/`, `libghostty.xcframework/`, `GhosttyKit.xcframework/`.
**Committed**: this README, `build-libghostty.sh`,
`slopdesk-libghostty-on-v1.3.1.patch` (the consolidated slim delta),
`External.zig.patch` (historical provenance),
`integration/CGhostty/{module.modulemap,ghostty.h}`,
`integration/GhosttySurface/*.swift`.

---

## Symbols exposed (external-IO C API)

Confirmed against the pinned `include/ghostty.h` (1369 lines), vendored verbatim at
[`integration/CGhostty/ghostty.h`](integration/CGhostty/ghostty.h). **The actual fork
names differ from the loose names in the original spec** — the binding uses the real ones:

| Role | Real C symbol (header line) | Spec called it |
|------|-----------------------------|----------------|
| Select external backend | `config.backend_type = GHOSTTY_BACKEND_EXTERNAL` (466 / 424) | `use_custom_io = true` |
| **Data IN** (host → render) | `ghostty_surface_write_output(s, ptr, len)` (1185) | `ghostty_surface_feed_data` |
| **Data OUT** (keys → host) | `config.write_callback` field, set at `ghostty_surface_new` (467 / 429) | `ghostty_surface_set_write_callback` |
| Resize | `ghostty_surface_set_size(s, wpx, hpx)` (1174, **pixels**) + `config.resize_callback` (468) | resize |
| Keys | `ghostty_surface_key(s, ghostty_input_key_s)` (1180) | `ghostty_surface_key` |
| Text / IME | `ghostty_surface_text(s, ptr, len)` (1184) | `ghostty_surface_text` |
| Render | `ghostty_surface_refresh` (1167) / `ghostty_surface_draw` (1168) | — |
| Recover Swift `self` | `ghostty_surface_userdata(s)` (1161) ← `config.userdata` (456) | — |
| Lifecycle | `ghostty_surface_new` (1158) / `_free` (1160); app via `ghostty_app_new` (1141) | — |

The C glue: `ghostty_surface_write_output` calls `surface.core_surface.io.processOutput(bytes)`
(`src/apprt/embedded.zig`), i.e. it pushes bytes through the same stream processor a
PTY would — full VT fidelity, no second parser.

---

## External-IO data flow

```
        host PTY (SlopDeskHost)                          GUI app (WF-8) — main thread
        ────────────────────                          ────────────────────────────
  PTY output ──► WireMessage.output ──► TCP ──► SlopDeskClient
                                                    │  (bg receive loop)
                                                    │  await MainActor.run { … }
                                                    ▼
                                          GhosttySurface.feed(Data)
                                                    │  ghostty_surface_write_output(s, ptr, len)
                                                    │  + ghostty_surface_refresh + _draw   (Metal frame)
                                                    ▼
                                              pixels on screen

  keystroke ──► GhosttySurface.key(ghostty_input_key_s)   (ghostty_surface_key — kitty/DECCKM encode)
                                                    │  Ghostty encodes bytes, fires C write_callback
                                                    ▼  (synchronous, main thread)
                                          GhosttySurface.onWrite(Data)
                                                    │
  host PTY stdin ◄── WireMessage.input ◄── TCP ◄── SlopDeskClient.send(input)

  resize ──► GhosttySurface.setSize(cols,rows)  (ghostty_surface_set_size — pixels)
                                                    │  + onResize(cols,rows)
  host TIOCSWINSZ ◄── WireMessage.resize ◄── TCP ◄── SlopDeskClient
```

- **Keys go through `ghostty_surface_key`** so Ghostty does the kitty/DECCKM
  encoding (DECISIONS: route every key there; the Lakr233 VT100 bypass is *wrong*
  for a remote PTY in kitty/DECCKM mode). Committed text / IME / paste →
  `ghostty_surface_text`.
- The host receives **cols/rows** for `TIOCSWINSZ`, never pixels — pixels are a
  client-side concern of the Metal surface.

### Threading contract (doc 18 §C — SOLVED-by-source)

`ghostty_surface_write_output` / `_refresh` / `_draw` are **main-thread-only**. The
fork's own doc comment on `ghostty_surface_write_output` confirms it is "NOT safe to
call concurrently on the same surface … typically the embedder calls this from a
single I/O thread per surface." Swift's `@MainActor` does **not** propagate across
the C boundary, so `GhosttySurface` is declared `@MainActor` to force every call
site onto main:

- TCP receive loop (bg thread) → `await MainActor.run { surface.feed(d) }`.
- The C `write_callback` fires **synchronously on main** from Ghostty's key encoder
  → `onWrite` runs on main.
- A `CVDisplayLink`/`CADisplayLink` tick (bg) → `DispatchQueue.main.async` before
  touching the surface.
- **Hazard:** do not `await` *between* `write_output → refresh → draw` (actor-
  suspension escape). The binding keeps that trio synchronous inside `feed`.

---

## How the GUI app links it

In the WF-8 GUI app's build settings / SwiftPM-via-Xcode target:

1. **Build** the framework: `ThirdParty/ghostty/build-libghostty.sh` →
   `ThirdParty/ghostty/libghostty.xcframework`.
2. **Embed & link** `libghostty.xcframework` in the app target.
3. **Add the C module**: point `SWIFT_INCLUDE_PATHS` /
   `-Xcc -fmodule-map-file=` at
   `ThirdParty/ghostty/integration/CGhostty/module.modulemap` so `import CGhostty`
   resolves (the `link "ghostty"` directive ties it to the framework's binary).
4. **Compile** `ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift`
   as a member of the app target (it `import`s `SlopDeskTerminal`, `SlopDeskProtocol`,
   `CGhostty`). It conforms to `SlopDeskTerminal.TerminalSurface`, so the rest of the
   client (`SlopDeskClient`) drives it through the existing seam with no libghostty
   knowledge.

The headless core never participates in any of the above.
