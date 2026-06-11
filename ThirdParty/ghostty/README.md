# libghostty — Aislopdesk's ONLY terminal renderer

Aislopdesk renders the terminal with **libghostty and nothing else**: no SwiftTerm, no
fallback path (see [`docs/DECISIONS.md`](../../docs/DECISIONS.md) → *Terminal
renderer*). PATH 1 streams raw VT bytes from the host PTY to the client; libghostty
parses + GPU-renders them in a Metal view. This directory is the build infra +
Swift binding for that renderer.

> **Why this is here and not in `Sources/`:** the libghostty binding links a
> Zig-built XCFramework. That link must never be in the default `swift build`
> graph, or the headless core (187 tests) would refuse to build without the
> framework. So the binding + C module map live under
> `ThirdParty/ghostty/integration/` as **source files wired into no `Package.swift`
> target**. The macOS/iOS GUI app target (WF-8) adds them to its own build. A plain
> `swift build` / `swift test` never sees them → the core stays green with zero
> conditional-compilation hacks.

---

## Chosen fork + pins

| Pin | Value | Source of truth |
|-----|-------|-----------------|
| **Upstream** | `ghostty-org/ghostty` @ **`v1.3.1`** | canonical tag (2026-03-13); the reproducible base |
| Fork delta | `daiimus/ghostty:ios-external-backend` (= v1.3.0 + external backend) | `patches/aislopdesk-libghostty-on-v1.3.1.patch` |
| Merge SHA (local) | `c38ee78…` | local merge of v1.3.1 + fork delta + 0001/0002 (not on any remote) |
| **Zig** | `0.15.2` | the source's `build.zig.zon` `minimum_zig_version` (0.16 not adoptable — see below) |
| Zig SHA-256 | `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b` | `zig-aarch64-macos-0.15.2.tar.xz` |

**2026-06-06 update — bumped ghostty 1.3.0 → 1.3.1.** The source is now canonical
upstream **`v1.3.1`** with the daiimus external-backend fork delta merged on top
(External.zig + the tmux control-mode viewer + search + the embedded C glue), plus the
two aislopdesk patches. The merge took ONE conflict (Surface.zig `io_backend` init block —
resolved by keeping the fork's `uses_external` branching and porting v1.3.1's
`working-directory` `.value()` change). The v1.3.1 embedded ABI change `read_clipboard_cb`
`void → bool` was absorbed in the integration (`CGhostty/ghostty.h` + the Swift callback
now returns `true` since we complete the request synchronously). The reproducible recipe
is `git clone --branch v1.3.1` upstream + apply `patches/aislopdesk-libghostty-on-v1.3.1.patch`
(+ 0001/0002); `build-libghostty.sh` does this automatically.

### Why this fork, directly (approach **(b)**)

The spec allowed two routes: (a) pin **upstream** ghostty + author our own
`External.zig` patch, or (b) pin a **daiimus** SHA that already carries the
external-IO API. We chose **(b)** because it most reliably yields the symbols:

- The external-IO C API (`ghostty_surface_write_output`, the `write_callback` /
  `resize_callback` config fields, `GHOSTTY_BACKEND_EXTERNAL`) **does not exist in
  upstream Ghostty** ([doc 17 §2.2], verified against the header). It exists only on
  the forks.
- `daiimus/ghostty:ios-external-backend` ships a complete `src/termio/External.zig`
  (~470 LOC: `init`/`deinit`/`threadEnter`/`resize`/`queueWrite` + write/resize
  callbacks + unit tests) plus the C glue in `src/apprt/embedded.zig` — strictly more
  complete than `wiedymi/ghostty:custom-io` (which lacks the resize callback and is
  frozen). It is proven in a shipping iOS app (Geistty).
- Authoring our own patch against a moving upstream SHA adds rebase risk for **zero
  benefit** over pinning a branch that already builds. We still record the source
  delta in [`External.zig.patch`](External.zig.patch) so a future upstream rebase
  (per DECISIONS) has the exact change in hand. `build-libghostty.sh` does **not**
  apply it — the pinned branch already contains it.

`brew`'s `zig 0.16.0` cannot build this source (see "Why Zig stays 0.15.2" below). The
build script ignores brew and downloads the pinned **0.15.2** into the gitignored
`.toolchain/`, used via a build-local `PATH`.

---

## Build outcome (honest status)

**The build WORKS on this macOS 26.5 / Xcode 26.5 / arm64 host** and produces a
universal `libghostty.xcframework` (macos-arm64 + ios-arm64 + ios-arm64-simulator),
all external-IO symbols verified. The earlier Zig-0.15.2 ↔ macOS-26-SDK *link* wall
is resolved by the **xcrun SDK shim** (caveat #1 in the script header): the build-local
`xcrun` answers the `macosx --show-sdk-path` query with an old SDK (≤ 15.x) so Zig's
native macOS link step succeeds, while iOS/sim queries pass through to the real 26.5
SDK. The shim is **build-time only** — it has zero effect on the shipped binary or on
runtime. `build-libghostty.sh` preflights it with a libSystem link smoke test.

### Why Zig stays 0.15.2 (and is NOT bumped to 0.16.0)

Zig **0.16.0** (2026-04-13) *is* the first Zig that links the macOS 26 SDK natively (it
carries the `aarch64-macos`↔`arm64e-macos` TBD-matching fix), so on paper it could
remove the SDK shim. We deliberately **do not** adopt it, because **ghostty does not
compile under Zig 0.16.0** — and neither does upstream ghostty itself (its HEAD still
pins `minimum_zig_version = "0.15.2"`). The 0.15→0.16 boundary is a large, multi-class
breaking change across the ~462-file ghostty source:

- `std.ArrayList` flipped to **unmanaged-by-default** (managed `.init(alloc)`/`.append(item)`
  deprecated) → ~68 files,
- the **"Writergate"** I/O rewrite (`std.io.Reader`/`Writer`, `.writer()`/`.reader()`,
  `fixedBufferStream`, `getStdOut`) with new buffer semantics → ~40 files,
- `format`-method signature changes (`{}` → `{f}` for format-method types),
- `std.process.EnvMap` → `std.process.Environ.Map` (17 files),
- plus the `requireZig` exact-minor gate.

Porting all of that is a project upstream hasn't undertaken; doing it downstream — on
top of also carrying the external-backend fork delta — would yield a fragile, divergent
fork whose subtle I/O-buffering behaviour can only be validated by full ghostty test +
HW runs. Since the shim is invisible at runtime, **0.15.2 + shim is the correct pin**.
**Re-evaluate when upstream ghostty bumps its own `minimum_zig_version` to 0.16+** — then
bump `ZIG_VERSION`/`ZIG_SHA256` here, drop the shim, and re-verify the header.

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
2. Clones the pinned fork SHA → `.work/ghostty-src` (gitignored); fast-fails if the
   external-IO symbols are not in the source header (wrong SHA).
3. `zig build -Demit-xcframework=true -Dxcframework-target=<native|universal>
   -Doptimize=ReleaseFast` with the build-local Zig. First run also fetches ~15 Zig
   package deps into `.work/zig-global-cache` (network required).
4. Copies the produced `GhosttyKit.xcframework` → `libghostty.xcframework`
   (gitignored — large/derived).
5. `nm`-verifies the slice exposes `ghostty_surface_write_output`, then prints
   `OK: <path>` (or a precise failure).

**Gitignored** (derived/large; reproducible from the pins above):
`.toolchain/`, `.work/`, `libghostty.xcframework/`, `GhosttyKit.xcframework/`.
**Committed**: this README, `build-libghostty.sh`, `External.zig.patch`,
`integration/CGhostty/{module.modulemap,ghostty.h}`,
`integration/GhosttySurface/GhosttySurface.swift`.

---

## Symbols exposed (external-IO C API)

Confirmed against the pinned `include/ghostty.h` (1369 lines), vendored verbatim at
[`integration/CGhostty/ghostty.h`](integration/CGhostty/ghostty.h). **Note the
ACTUAL fork names differ from the loose names in the WF-5 spec** — the binding uses
the real ones:

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
        host PTY (AislopdeskHost)                          GUI app (WF-8) — main thread
        ────────────────────                          ────────────────────────────
  PTY output ──► WireMessage.output ──► TCP ──► AislopdeskClient
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
  host PTY stdin ◄── WireMessage.input ◄── TCP ◄── AislopdeskClient.send(input)

  resize ──► GhosttySurface.setSize(cols,rows)  (ghostty_surface_set_size — pixels)
                                                    │  + onResize(cols,rows)
  host TIOCSWINSZ ◄── WireMessage.resize ◄── TCP ◄── AislopdeskClient
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
   as a member of the app target (it `import`s `AislopdeskTerminal`, `AislopdeskProtocol`,
   `CGhostty`). It conforms to `AislopdeskTerminal.TerminalSurface`, so the rest of the
   client (`AislopdeskClient`) drives it through the existing seam with no libghostty
   knowledge.

The headless core never participates in any of the above.
