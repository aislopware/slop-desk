# libghostty — Rwork's ONLY terminal renderer

Rwork renders the terminal with **libghostty and nothing else**: no SwiftTerm, no
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
| Fork | `daiimus/ghostty` | DECISIONS: "own minimal patch ref daiimus External.zig" |
| Branch | `ios-external-backend` | the branch carrying the external-IO C API |
| **SHA** | `21c717340b62349d67124446c2447bf38796540b` | hard-pinned in `build-libghostty.sh` |
| **Zig** | `0.15.2` | the fork's `build.zig.zon` `minimum_zig_version` |
| Zig SHA-256 | `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b` | `zig-aarch64-macos-0.15.2.tar.xz` |

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

`brew`'s `zig 0.16.0` is **too new** for this fork (Zig breaks between minors). The
build script ignores brew and downloads the pinned **0.15.2** into the gitignored
`.toolchain/`, used via a build-local `PATH`.

---

## Build outcome / known blocker (honest status — WF-5)

**The build infra is complete and correct, but the actual compile is currently
BLOCKED on this machine by a Zig ↔ macOS-SDK incompatibility — not a script, pin,
or binding bug.** The build script downloaded + SHA-verified Zig 0.15.2, pinned the
fork source, confirmed the external-IO symbols in the source header, and fetched the
Zig deps; it then failed at the **link** step.

The pincer (both characterized empirically):

1. **Zig 0.15.2 (the pinned, fork-required version) cannot link against the macOS
   26.5 SDK** present on this host. Even a trivial `zig run` of an empty program
   fails with `undefined symbol: __availability_version_check`, `_abort`, `_bzero`,
   `_fork`, … — Zig 0.15.2 predates macOS 26 and doesn't know its `libSystem`
   availability-runtime layout. `--sysroot`/`-lc` do not help; the symbols *are*
   present in `MacOSX.sdk/usr/lib/libSystem.tbd`, but 0.15.2's bundled libc stubs +
   linker can't resolve them against this SDK.
2. **Zig 0.16.0 (the only Zig that links the macOS 26.5 SDK here — verified: a
   trivial program links fine) is rejected by the fork's `build.zig`** on two
   independent counts: a hard version gate
   (`requireZig` → `@compileError("Your Zig version v0.16.0 does not meet the
   required build version of v0.15.2")`) AND a `std` API break
   (`std.process.EnvMap` was removed/renamed after 0.15.2, so `src/build/Config.zig`
   no longer compiles).

So there is **no satisfying toolchain on a macOS-26.5-only host**. This was
anticipated in [`docs/19`] (brew 0.16.0 "too new for the fork"); the inverse — 0.15.2
"too old for the macOS 26.5 SDK" — closes the gap.

**To actually produce the xcframework, build on one of:**
- a macOS host with an **older SDK (≤ 15.x / Sequoia)** that Zig 0.15.2 supports
  (e.g. an Xcode 16 Command Line Tools install, or a CI runner image), **or**
- a future Zig that supports **both** the macOS 26.x SDK and the fork's `build.zig`
  (then bump the `ZIG_*` pins here and re-verify the header), **or**
- bump the **fork pin** to a daiimus/own SHA whose `build.zig` accepts a
  macOS-26-capable Zig — **no such SHA is known to exist today**; this option is
  hypothetical and would require first producing (or finding) such a branch and then
  re-confirming the external-IO symbols after the bump.

`build-libghostty.sh` now **preflights** this exact condition (a libSystem link
smoke test) and fails fast with the actionable message above, instead of burning the
full dep-fetch + compile before hitting the link error.

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
        host PTY (RworkHost)                          GUI app (WF-8) — main thread
        ────────────────────                          ────────────────────────────
  PTY output ──► WireMessage.output ──► TCP ──► RworkClient
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
  host PTY stdin ◄── WireMessage.input ◄── TCP ◄── RworkClient.send(input)

  resize ──► GhosttySurface.setSize(cols,rows)  (ghostty_surface_set_size — pixels)
                                                    │  + onResize(cols,rows)
  host TIOCSWINSZ ◄── WireMessage.resize ◄── TCP ◄── RworkClient
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
   as a member of the app target (it `import`s `RworkTerminal`, `RworkProtocol`,
   `CGhostty`). It conforms to `RworkTerminal.TerminalSurface`, so the rest of the
   client (`RworkClient`) drives it through the existing seam with no libghostty
   knowledge.

The headless core never participates in any of the above.
