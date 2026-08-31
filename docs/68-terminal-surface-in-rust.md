# 68 — The terminal surface becomes ours

The client stops embedding a terminal *application* and starts driving a terminal *engine*. libghostty's
surface API — which owns its own Metal renderer, its own IO thread and its own grid layout — is
replaced by `libghostty-vt`, the renderer-agnostic half, through the MIT Rust bindings. The pixels
become this repo's, and with them the one thing an opaque surface can never give up: **layout**.

Read `docs/20-wire-protocol.md` (unchanged by this document — see §7), `docs/55-ffi-boundary.md` for
the artifact rule, `docs/57-apple-frameworks-in-rust.md` §2 for what `slopdesk-apple-*` may do, and
`ThirdParty/ghostty/README.md` for the fork this deletes.

## 1. What this supersedes

`DECISIONS.md:7` fixes "Renderer = **libghostty** (full surface) … No fallback paths to maintain",
`docs/17:40` picks the external-IO surface as the way to get it, and
`Sources/SlopDeskWorkspaceCore/Terminal/TerminalRendererSeam.swift:56` restates it at the seam. That
ruling stands for the *engine* and is strengthened here: ghostty still parses every byte. What it no
longer covers is the *renderer*, because the renderer is what has to go for the product to reach the
surface it wants.

`docs/17:59` is the one nearby ruling that could be misread as reversed, and is not. It rejects a
**second** VT parser — a shadow framebuffer beside libghostty's, kept for latency prediction, whose
cost was desync between two parsers. Nothing here adds a parser: `libghostty-vt` *replaces* the
fork's, one engine before and one after, and no prediction is built on it.

Two memory rulings are folded in and neither is reversed:

- **"Underline by the cell's ANSI colour", rejected because "no C ABI exposes cell colour."** The
  technical half was falsified 2026-08-28 and is now falsified in the tree: `libghostty-vt`'s
  `style.rs` carries `Style { fg_color, bg_color, underline_color, … }` with
  `StyleColor::{None, Palette, Rgb}`. Whether the design still wants it is a separate question this
  document does not answer.
- **"Zig 0.16, rejected — pinned 0.15.2."** That rejection was about porting *our fork* to 0.16: a
  462-file breaking migration (`std.ArrayList` unmanaged, Writergate, `EnvMap`) that upstream itself
  has not done on macOS (upstream issue #12726). It is untouched. This document deletes the thing
  that needs 0.15.2 rather than porting it, and Zig 0.16.0 is already the machine's `zig`.

## 2. Why the surface API cannot reach the product

The goal is a block-based, editor-like terminal. The discriminating fact is not performance and not
feature coverage — it is **who owns layout**.

An overlay over an opaque surface can do **decoration**, and this tree already does:
`DecorationPromptFlash` paints row-anchored rects from `PromptJumpFlashGeometry` over the
`IOSurfaceLayer` libghostty installs. That is the ceiling of the technique — a flash, a highlight, an
underline.

Blocks are **layout**, not decoration: collapsing a command's output, padding between blocks, rows of
differing height, a native action bar between two blocks, a sticky header. The surface's grid layout
is a function of terminal state the embedder does not own, and `ghostty_surface_draw` composites the
whole grid into one layer. There is no seam to insert a view into, at any price.

With `libghostty-vt` the client holds the grid and draws it, so a block is an ordinary AppKit/UIKit
layout problem. That is the whole argument; everything below is cost.

## 3. Verifications taken before anything was deleted

**V1 — the iOS slices build. PASS, and this was the gate on the entire design.** Today's fork ships
macos-arm64 + ios-arm64 + ios-arm64-simulator out of `build-libghostty.sh` (641 lines, an `xcrun` SDK
shim, a pinned toolchain download). The question was whether `libghostty-vt-sys` cross-builds, or
whether that recipe has to be written again.

```
cargo build --target aarch64-apple-ios       → Finished in 3m 55s
cargo build --target aarch64-apple-ios-sim   → Finished in 56s
lipo -info …/ghostty-install/lib/libghostty-vt.a
    → architecture: arm64
otool -l  …/libghostty-vt.a
    → LC_BUILD_VERSION  platform 2 (iOS)  minos 13.0
```

`build.rs` drives Zig itself, emits `cargo:rustc-link-lib=static=ghostty-vt`, and brings `libsimdutf.a`
and `libhighway.a` with it. **No build recipe is ours to write.** The 641-line script, the SDK shim
and the `.toolchain/` download all go.

**V2 — the build must not touch the network.** `libghostty-vt-sys/build.rs` clones ghostty at a pinned
commit at compile time, which is incompatible with the content-stamped gates (`slopdesk-gate ffi`) and
with a reproducible release. The escape hatch is authoritative and short-circuits the fetch:

```rust
if env::var_os("GHOSTTY_SOURCE_DIR").is_some() { build_vendored(link_mode); return; }
```

So the fetch becomes ours: one `just` recipe pins the ghostty commit, fetches once into a gitignored
cache, and exports `GHOSTTY_SOURCE_DIR` + `GHOSTTY_ZIG_SYSTEM_DIR`. Same shape as today's
`.work/ghostty-src`, roughly thirty lines instead of six hundred.

`build.rs` also returns early under `CARGO_CFG_MIRI`, so `just check`'s Miri gate keeps working
without a native library.

**V3 — baselines, measured before the old renderer is deletable. PARTIAL, and the shortfall is
ruled on.** A measured regression is the only veto (`CLAUDE.md`). Parse throughput is measurable on
both engines and is in §6; the live fork's **key→render-feed latency is pinned in §6.3** by a gate
that re-runs unchanged on the new renderer. Draw cadence is **not** baselined — §6.3 says what
blocked it and why resurrecting the fork later is the wrong answer. The demolition proceeds on that
reading.

## 4. What ships free, and what is ours

Verified against `Uzaaft/libghostty-rs` @ `a0b5a46`, MIT, pinning ghostty `22d13172`.

| | |
| --- | --- |
| **Dissolves** | `ghostty_app_new/tick/free`, `ghostty_init`, the `surface_new/free` lifecycle, `write_callback`/`resize_callback` and the whole `ghosttyOnMainActor` thread-hop, the `External.zig` backend (a fork-only patch upstream closed unmerged), the 2 347-line consolidated patch, `build-libghostty.sh`, the xcframework recipe, the `.toolchain/` download, the `xcrun` SDK shim, and upstream bug #13021 (iOS Metal-teardown UAF) — a renderer bug we stop having |
| **vt already has** | parse + grid + scrollback · per-cell `Style`/`sgr` · **selection, richer than what we call today** · `RenderState` with per-row damage bits · cursor visible/blinking/visual-style/password/colour/viewport · `colors()` · `KeyEncoder`/`MouseEncoder` · `osc.rs` (OSC 22 pointer, OSC 52 clipboard) · bracketed `paste.rs` · `focus.rs` · kitty graphics state · `unicode.rs` widths · `compress()` (upstream PR #13264's 70–90 % scrollback savings, which our v1.3.1 pin cannot reach) · `continuation_*` session serialisation |
| **Ours to build** | the glyph renderer (§5) · grid search (§5.2) · the config/keybind layer that `ghostty_config_*` and `ghostty_surface_binding_action` used to answer |

**Selection is a gain, not a gap.** The six selection doors we call today (`set`/`has`/`clear`/
`read_selection`, `read_text`, `selection_s`) map onto a richer model: `Gesture` for click-drag,
`select_word`, `select_line`, `select_output`, `select_word_between`, rectangle selection, `adjust`,
and `format_selection` with `unwrap`/`trim`. `SelectLineOptions::with_semantic_prompt_boundary` is
OSC 133-aware — the same boundary `rust/slopdesk-terminal/src/blocks.rs` derives by re-parsing.

## 5. The build list

### 5.1 The glyph renderer

The dominant item, and the only one whose absence is load-bearing: `libghostty-vt` "leaves
pixel-pushing to the host application."

1. Core Text font stack and fallback chain
2. shaping and ligatures — vt gives cell widths through `unicode.rs`; shaping stays Core Text's
3. glyph atlas and the Metal pipeline under one `NSView`/`UIView`
4. damage-driven redraw — **cheaper than it looks**: `RenderState::dirty()` and per-row `dirty()`
   already hand over exactly which rows changed
5. cursor: block / bar / underline, blink, hollow when unfocused
6. underline variants and underline colour
7. selection highlight
8. **marked-text (preedit) drawing in the grid.** `NSTextInputClient`/`UITextInput` come free with
   AppKit/UIKit — that is the argument that decided the framework — but drawing marked text in a
   terminal grid is renderer work, and Telex is the reason it is on the critical path
9. scrollbar geometry, replacing `ghostty_surface_viewport_info` and the `SCROLLBAR` action
10. padding, content scale, resize → cols·rows, which `rust/slopdesk-terminal/src/geometry.rs`
    already computes

Kitty-graphics *rendering* is **out of the bar**: `TerminalConfigBuilder` enables no image token
today, so nothing regresses by not drawing them. vt keeps the state if that changes.

The renderer's home is Rust. `rust/slopdesk-apple-text` already declares itself "the whole of the Core
Text area slopdesk touches" and is in the `slopdesk-apple-*` family, so shaping extends an audited
crate rather than opening a new `unsafe` boundary — no fourth hand-written-`unsafe` crate is proposed
and none is needed.

### 5.2 Search

vt exposes no search. The parity cost is smaller than that sounds, because the expensive half is
already ours: `TerminalFindBarModel.swift` records that libghostty's in-surface search is "a LITERAL
substring matcher with NO regex engine", so regex mode is driven entirely from
`slopdesk_workspace::find_bar`'s match positions and never arms `search:`. What has to be written is
the literal matcher over the grid — the case libghostty was covering.

### 5.3 Blocks

The data layer exists and is already Warp-shaped. `rust/slopdesk-terminal/src/blocks.rs` (890 lines):
the host segments the byte stream and pushes **metadata only** — index, command text, exit code,
duration, output length — while captured output stays on the host until something asks for it, behind
a request registry, a 64-entry ring and a coalescing rule. Today that model drives only
`MacCommandNavigator` / `PhoneCommandNavigator`: a list you jump through.

What is missing is exactly one layer — rendering — plus:

- a virtualised block list with variable heights and collapse state
- an **alt-screen escape hatch**: vim and htop need the flat grid, so the renderer alternates block
  layout (main screen, OSC 133 boundaries) with plain grid layout (alt screen).
  `rust/slopdesk-terminal/src/tracker.rs` already discriminates the two, byte-at-a-time, across chunk
  boundaries

### 5.4 The editor-like prompt

Also an upgrade rather than greenfield. `rust/slopdesk-terminal/src/inputbox.rs` already models two
affordances — `ShellCommand` at a prompt (whole line on Enter, OSC 133 block boundary) and
`TuiCompose` under a fullscreen TUI (write on submit, dedup the PTY's echo via `InputDedupRing`). The
Warp-class prompt is `ShellCommand` grown up: multi-line editing, syntax highlighting, history and
completion, over a state machine that already knows when it is at a prompt and which echoed bytes to
swallow.

## 6. Measured

`libghostty-vt` parse throughput, release, this Mac Studio, 256 MiB per shape through `vt_write`
(warmed, single-threaded, no renderer attached):

| shape | throughput |
| --- | --- |
| ASCII lines, 80×24 | 427.9 MB/s |
| ASCII lines, 200×50 | 494.8 MB/s |
| SGR-heavy build log, 200×50 | 108.8 MB/s |
| full-screen TUI repaint, 200×50 | 128.5 MB/s |
| CJK + Vietnamese diacritics + emoji, 200×50 | 231.2 MB/s |

Two things to read carefully. **This is not a comparison** — measuring the fork the same way needs a
live surface and a renderer, so the before/after pair belongs to the demolition pass, not here. What
it does settle is that the pinned commit carries the parser upstream landed after our v1.3.1 tag
(PRs #13220 / #13226, which `ThirdParty/ghostty/README.md` lists as unreachable from the pin): 495 MB/s
on ASCII is the post-rewrite parser, not the one the fork compiles.

The SGR row is the one that matters for this product — a colourised agent log is what the panes
actually carry — and 108.8 MB/s is far above any rate a remote PTY can deliver over the mesh. Parsing
is not where the budget goes; drawing is, which is why §5.1 is the risk and this table is not.

### 6.1 Which platform the veto is measured on

**macOS.** The before-numbers are taken on the deployed macOS client, and a regression there is the
veto. iOS ships without a before-number, and that is a decision rather than a gap: the probe is
portable (§6.2) but a simulator number measures the host's GPU, not the phone's, and the fork will
be gone before a device run can be repeated. Two things make the asymmetry acceptable — the two
`renderTick` paths in `GhosttyTerminalView.swift` (macOS at 1115, iOS at 3705) present through the
same gated-`presentTicks` design, so a macOS regression and an iOS one have the same shape; and
upstream bug #13021, the iOS Metal-teardown use-after-free the fork carries, is a defect the
demolition removes rather than risks.

### 6.2 The harness

The table above came from a scratch crate against `libghostty-vt` alone. It is reproduced here rather
than left on disk, because the same five shapes are what the after-numbers must be taken over, and a
number nobody can re-run is not a baseline. `Cargo.toml` is one dependency —
`libghostty-vt = { git = "https://github.com/Uzaaft/libghostty-rs", rev = "a0b5a46" }` — built
`--release`.

```rust
use std::time::Instant;

use libghostty_vt::Terminal;

/// Feed `payload` repeatedly until `total` bytes have gone through, and report MB/s.
fn bench(name: &str, cols: u16, rows: u16, payload: &[u8], total: usize) {
    let mut term = Terminal::new(cols, rows).expect("terminal");
    let reps = total / payload.len();

    // Warm the parser and the page allocator before the timed run.
    for _ in 0..(reps / 20).max(1) {
        term.vt_write(payload);
    }

    let started = Instant::now();
    for _ in 0..reps {
        term.vt_write(payload);
    }
    let elapsed = started.elapsed();

    let mb = (reps * payload.len()) as f64 / (1024.0 * 1024.0);
    println!(
        "{name:<28} {:>8.1} MB/s   ({mb:.0} MiB in {:.2}s)",
        mb / elapsed.as_secs_f64(),
        elapsed.as_secs_f64()
    );
}

fn main() {
    const TOTAL: usize = 256 * 1024 * 1024;

    // Plain ASCII lines — `cat` of a large log, the commonest remote-PTY shape.
    let ascii: Vec<u8> = (0..64)
        .flat_map(|_| {
            let mut line = b"the quick brown fox jumps over the lazy dog 0123456789".to_vec();
            line.push(b'\n');
            line
        })
        .collect();

    // SGR-heavy output — a colourised build log, which is what an agent pane actually carries.
    let sgr: Vec<u8> = (0..64)
        .flat_map(|i| {
            format!("\x1b[38;5;{}m▎\x1b[0m compiling \x1b[1mcrate-{i}\x1b[0m v0.1.0\r\n", i % 256)
                .into_bytes()
        })
        .collect();

    // A full-screen TUI repaint: absolute cursor moves plus erases, the alt-screen shape.
    let tui: Vec<u8> = (0..48)
        .flat_map(|row| format!("\x1b[{row};1H\x1b[K row {row} of a redrawn frame").into_bytes())
        .collect();

    // Wide/CJK plus combining marks — the grapheme path, and Telex's own alphabet.
    let unicode: Vec<u8> = (0..64)
        .flat_map(|_| "日本語テキスト tiếng Việt có dấu 🎉 combining\r\n".as_bytes().to_vec())
        .collect();

    bench("ascii lines 80x24", 80, 24, &ascii, TOTAL);
    bench("ascii lines 200x50", 200, 50, &ascii, TOTAL);
    bench("sgr build log 200x50", 200, 50, &sgr, TOTAL);
    bench("tui repaint 200x50", 200, 50, &tui, TOTAL);
    bench("unicode/cjk 200x50", 200, 50, &unicode, TOTAL);
}
```

### 6.3 The live-app baseline, and the one number it does not have

Taken 2026-08-31 on the deployed macOS client with the fork still rendering, through
`slopdesk-guigate macos --connect` — which builds the app, starts a real `slopdesk-hostd`, dials it,
and types a COMPUTED marker so an echo of the literal keystrokes cannot satisfy it:

```
client↔host session ESTABLISHED on :47420
OUT-path PROVEN: keystrokes → host PTY → shell EXECUTED (computed 42 → SLOPDESK_OUT_…_42_END)
echo latency (n=1): median 1.4 ms, p95 1.4 ms   (key→render-feed, loopback)
```

`.work/macos-verify/macos-shot.png` is the picture the gate's own PASS criterion asks for: libghostty
painting a live remote shell — prompt, ANSI colour, the sidebar's session rows. **That is the number
the after-side must beat, and the gate that produces it is not ours to write** — the same invocation
re-runs on the new renderer unchanged, which is why it is the baseline rather than a bespoke probe.

Read what it measures precisely: **key→render-feed**, not glass-to-glass. It ends where the bytes are
handed to the surface, so it prices the wire and the PTY round trip and *excludes* draw. That makes it
the right veto for §5.1 in one direction only — a renderer that regresses drawing will not show up
here — and §5.1 is exactly where the risk was already located.

**The cadence and scroll histograms are deliberately not in this document.** `slopdesk-framewatch`
was built and its capture path verified (`--list` enumerates on-screen windows, so SCK and the
Screen-Recording grant are live), but a frame-cadence p99 needs the app held open under a sustained
workload, and `--connect` tears it down after its assertions. Both gaps were reached on a box under
load average 33 — a cadence percentile measured there prices contention, not the renderer, which is
the same failure mode `perf-tests-load-flaky` records.

So the veto is asymmetric, and stated rather than hidden: **key→render-feed is pinned and binding;
draw cadence is not baselined.** The fork is recoverable — it is in git history — but recovering it is
not `git show`: it is an old-tree checkout that must build and run, which means the 0.15.2 toolchain
download, the `xcrun` SDK shim, an Xcode that has since moved and a cold `.build`. Hours, and not
certain. If §5.1 lands and drawing feels worse, the honest move is to measure the NEW renderer's
cadence on a quiet box against the 60 Hz ceiling directly, not to resurrect the fork.

## 7. What this does NOT touch

- **The wire.** Blocks already ship as metadata push plus on-demand output fetch. No new verb, no
  golden re-pin. `docs/20` is unchanged and `golden/golden_vectors.json` is not regenerated.
- **Security.** No pairing, no tokens; the WireGuard mesh is still the boundary.
- **The framework ruling.** AppKit/UIKit for the view layer, chosen 2026-08-31 and not reopened here.
  GPUI is not in this tree and does not enter it.

## 8. Risks

- **`libghostty-vt` is alpha with no API-stability promise**, pinned to a main-branch commit rather
  than a tag. Betting the client's primary surface on it is a larger exposure than a like-for-like
  swap would be. The mitigation is that vt is the half upstream built for embedders, and that we pin
  the commit ourselves (§3, V2) so churn arrives when we choose it.
- **Concurrency changes owner.** `terminal.rs:511` — "the caller must serialize it with writes,
  rendering, searches". libghostty ran its own IO and renderer threads; afterwards that is ours.
  `superd` still owns `read` on every PTY master, so the discipline is unchanged in kind.
- **Perf is a veto, not a worry.** Throughput, input latency and scroll all get numbers before and
  after, per §3.

## 9. Blast radius

390 files name ghostty; **42 are real coupling** — a `ghostty_*` symbol, `import CGhostty`, or the
renderer wiring. The rest is prose. The coupled set is `ThirdParty/ghostty/` (the fork, the 5 039-line
`GhosttySurface`/`GhosttyTerminalView` embedder, `CGhostty/ghostty.h` and its modulemap), the two app
specs and their `AppMain.swift`, `Sources/SlopDeskTerminal/`, the `Sources/SlopDeskWorkspaceCore/Terminal/`
policy files, `rust/slopdesk-devtools/src/ops/renderer.rs` (`slopdesk-ops enable-renderer`) with its
`stamp.rs` and `release/pack.rs` edges, and the `pointer`/`surface`/`wrap_map` modules that name
libghostty tokens.

Per `CLAUDE.md`, this lands as ONE pass — the fork and the embedder go first, the tree is red in the
middle, and it is green once at the end.
