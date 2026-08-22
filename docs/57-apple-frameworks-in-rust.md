# 57 — Apple frameworks in Rust: the `slopdesk-apple-*` family

> Read `docs/55-ffi-boundary.md` first. That doc is about Rust that SWIFT calls. This one is about
> Apple frameworks that RUST calls, which is the opposite direction and a different safety story.

## 0. The ruling this doc records

The tree already ran the "port the decisions" program to its end. As of increment 83 there are
~225k lines of Rust against ~220k of Swift, 134 FFI modules, and the pure-logic seam is closed:
every classifier in the input path — the held-button balance, the scroll resampler, the swipe
recogniser, the raise policy, the coordinate mapping — is a Rust rule with a Swift face over it.

What is left in Swift below the view layer is not logic. It is EFFECT: `CGEvent.post`,
`SCStream`, `VTCompressionSession`, `AXUIElementPerformAction`, `IOPMAssertionCreate`. Roughly
12–14k lines of it, concentrated in two daemons that have no user interface at all
(`slopdesk-videohostd`, `slopdesk-hostd`).

**The ruling: that goes to Rust too, and Swift keeps the view layer and nothing else.** Which means
this repo now calls Apple frameworks from Rust, which means a family of crates that write `unsafe`,
which is a change to the invariant `CLAUDE.md` has carried since the Rust core landed. It was made
deliberately, and the rest of this doc is the terms.

## 1. Why `objc2` and not a hand-rolled `extern "C"` block

The alternative to a binding crate is declaring the symbols by hand — `extern "C" { fn CGEventPost(…) }`
plus `#[repr(C)]` structs for every type that crosses. That is the shape this repo already knows from
`slopdesk-posix`, and it is the wrong shape here for three reasons:

1. **The obligation is not local.** A hand-declared `CGEventPost` is only sound if the declaration
   matches the SDK's, and nothing in the crate can check that. `slopdesk-posix`'s safety comments can
   be written because a `read(2)` obligation is about the descriptor in front of you; a
   `_AXUIElementGetWindow` obligation is about whether a header you have not read agrees with a
   signature you typed. `CLAUDE.md`'s own test — "if the safety comment cannot be written without
   naming slopdesk, the boundary is in the wrong place" — fails, and the fix it prescribes is to move
   the operation, which is exactly what taking a binding crate does.
2. **Reference counting is where the leaks are.** Every Core Foundation and Objective-C object that
   crosses has a retain/release contract, and the create-rule vs get-rule distinction is per-function
   prose in Apple's headers. `objc2-core-foundation`'s `CFRetained<T>` encodes it in the type, so a
   leak becomes a compile error rather than a slow one.
3. **Most of the surface turns out to be SAFE.** Measured on `objc2-core-graphics` 0.3.2: `CGEvent.rs`
   exposes 31 safe functions against 7 `unsafe` ones, and the seven are precisely the raw-pointer
   ones (`keyboard_set_unicode_string`, the three `tap_create`s, `post_to_psn`). `CGEventSource.rs`
   and `CGRemoteOperation.rs` are 24 functions with **zero** `unsafe`. The whole injection path this
   repo needs — create a source, build a keyboard/mouse/scroll event, set fields and flags, warp,
   post — is safe Rust.

### The evaluation, since taking a dependency is a decision

| | |
| --- | --- |
| Version | `objc2` 0.6.4 (2026-06-24); framework crates 0.3.2 (2025-10-04) |
| Usage | 38.9M recent downloads for `objc2`; 19.8M `objc2-app-kit`, 18.5M `objc2-core-graphics`, 18.0M `objc2-io-surface` |
| Coverage | Every framework this tree needs has a generated crate: `screen-capture-kit`, `video-toolbox`, `core-media`, `core-video`, `io-surface`, `metal`, `core-graphics`, `app-kit`, `ui-kit`, plus `block2` and `dispatch2` |
| Provenance | The merge of the `objc`/`block` lineage the Rust-on-Apple ecosystem already stands on — `winit`, `wgpu` and `cacao` are downstream |
| MSRV | 1.71, explicitly **not** policy — may move in a patch release. Pin exactly. |

The caveat that matters: framework crates are **generated**, not hand-audited. A binding is only as
right as the SDK metadata it came from, which is why §3's bar asks for a leak test rather than
trusting `CFRetained` to be correct by construction.

### The one area `objc2` does not reach: IOKit power management

Measured, not assumed. `objc2-io-kit` 0.3.2's features are `AppleUSBDefinitions`,
`IOUSBHostFamilyDefinitions`, `IOUSBLib`, `USB`, `USBSpec`, `graphics`, `hid`, `hidsystem`, `usb`
and the plumbing ones — there is **no `IOPMLib`**, so `IOPMAssertionCreateWithName` and
`IOPMAssertionRelease` have no generated binding. The obvious substitute does not cover it either:
`io-kit-sys` 0.5.0 (2.9M recent downloads, updated 2025-10-31) has a `src/pwr_mgt/` module, but it
holds power-STATE constants (`kIOPMPowerOn`, `kIOPMPreventIdleSleep`, the assertion *dictionary
keys*) and declares neither assertion function.

So the only route for the two sleep assertions is a hand-declared `extern "C"` block, which is
precisely the shape §1 argues against, for a benefit of 154 Swift lines. **`slopdesk-apple-power` is
therefore deferred, not planned** — it lands when either a binding appears upstream or the surface
grows enough to pay for a build-time `bindgen` against `IOKit/pwr_mgt/IOPMLib.h`, which is the only
version of it where the declaration comes from the SDK header rather than from a signature someone
typed. `PreventSleepAssertion.swift` and `HostDisplayWake.swift` stay Swift until then, and that is
a recorded exception to §4 rather than an oversight.

## 2. What a `slopdesk-apple-*` crate is

**One framework area, one crate.** The isolation argument that gave the tree three unsafe crates is
the same one here: a reviewer should hold ONE question in mind. `slopdesk-apple-cgevent` argues about
event synthesis and nothing else; `slopdesk-apple-ax` argues about the accessibility tree.

**No logic.** Identical to `slopdesk-ffi`'s charter. If a decision is being made in one of these
crates, it belongs in the `forbid(unsafe_code)` crate being wrapped. These crates translate a
decision into an effect and translate an observation back into a value.

**No hand-written raw-pointer work.** A crate here may write `unsafe` to call an `unsafe` binding.
It may not write `ptr::read`, `transmute`, `from_raw`, `slice::from_raw_parts` or their kin. If a
framework call needs one, the obligation is a POSIX-shaped or FFI-shaped obligation and it belongs
in `slopdesk-posix` or `slopdesk-ffi`, where a reviewer is already holding that question.

**Every `unsafe` block names the FRAMEWORK rule it satisfies**, not a Rust rule. `// SAFETY: the
buffer outlives the call` is the wrong comment here — the binding already proved that. The right one
is `// SAFETY: kAXRaiseAction is a documented action on a window element; a stale element is a
no-op, not a fault.`

## 3. The bar, per crate

1. `#![deny(unsafe_op_in_unsafe_fn)]` and the workspace lint table otherwise unchanged.
2. A `# Safety` comment per `unsafe` block, in the form §2 describes.
3. A LEAK test: the crate's central object is created and dropped in a loop, and the test asserts the
   process's resident footprint does not climb. Generated bindings are the risk this covers.
4. Small enough to read in a sitting. If a wrapper crosses ~600 lines, the framework area was drawn
   too wide.
5. `cargo test` runs it on macOS; on any other host every module is `#[cfg(target_os = "macos")]` and
   the crate compiles to nothing.

### A macOS-only crate may enter `slopdesk-ffi`'s graph, by ONE route

`slopdesk-ffi` builds three slices, two of them iOS, so a macOS-only edge is a link error waiting to
happen — but the tree already carries one and enforces it. `slopdesk-git` vendors `libgit2`, is a
`[target.'cfg(target_os = "macos")'.dependencies]` edge, and its door is declared inside the
`MACOS-ONLY BEGIN/END` region of `slopdesk_ffi.h`. `build-ffi.sh` reads that region and requires the
symbol PRESENT on `aarch64-apple-darwin` and ABSENT on both iOS slices, so the three spellings of
the fact — the header guard, the `#[cfg]` in `src/lib.rs`, the target-gated dependency — cannot
drift apart without failing the build.

**That bijection is the only permitted route**, and a `slopdesk-apple-*` crate that Swift must call
takes it verbatim: all three spellings or none. A crate reached any other way is a phone archive
with AppKit in it.

## 4. The shape of the end state

Two daemons have no user interface and therefore no reason to be Swift:

- **`slopdesk-videohostd`** — capture, encode, inject, the AX raise chain, the virtual display.
- **`slopdesk-hostd`** — the PTY, the metadata probes, the repo watcher, the power assertion.

They become Rust binaries. That removes the handle problem before it starts: `InputInjector` is a
stateful object with a scroll timer inside it, and `slopdesk-ffi`'s ABI deliberately lets no
ownership cross. Rather than invent a handle protocol so Swift can own a Rust injector, the OWNER
moves and the ABI stays as it is.

What stays Swift: `SlopDeskMacUI`, `SlopDeskPhoneUI`, `SlopDeskSlate`, the view layers under
`SlopDeskClientCore`/`SlopDeskWorkspaceCore`, and the faces that already read Rust through
`CSlopDeskFFI`. That is `docs/56`'s split with one more line under it — layout diverges, capability
does not, and *effect* is nobody's layout.

## 5. The ledger

Ordered by how much Swift each removes against how much `unsafe` it costs. `cgevent` is first
because the spike proved it costs NONE: the whole injection path is safe `objc2` calls. The two
window-server rows cost three `unsafe` blocks each, and every one of the six names a framework rule —
an `extern` key constant, an element type C's `CFArrayRef` does not carry, an out-pointer enumerator.

| Crate | Wraps | Replaces | State |
| --- | --- | --- | --- |
| `slopdesk-apple-cgevent` | CoreGraphics events | `InputInjector`'s posting | **landed** (increment 84) |
| `slopdesk-apple-cgwindow` | CG window services | `HostFrontmostApp`'s decode, `WindowGeometryWatcher`'s window reads | **landed** (increment 85) |
| `slopdesk-apple-cgdisplay` | CG display services | every `CGDisplayBounds`/`CGGet*DisplayList` site | **landed** (increment 85) |
| `slopdesk-apple-ax` | `AXUIElement` | the raise chain, `WindowGeometryWatcher`, `WindowFeedAXSupport` | planned |
| `slopdesk-apple-cursor` | `NSCursor` + the offscreen `NSBitmapImageRep` render | `CursorSampler`'s two AppKit reads | **landed** (increment 89) — costs **two** `unsafe` blocks |
| `slopdesk-apple-app` | `NSRunningApplication` reads | `HostFrontmostApp`'s last line, `WindowFeedGlue`'s per-pid state, `InputInjector`'s activate | **landed** (increment 87) — costs **zero** `unsafe` |
| `slopdesk-apple-vt` | VideoToolbox + CoreMedia | `VideoEncoder`, `VideoDecoder` | planned |
| `slopdesk-apple-sck` | ScreenCaptureKit | `WindowCapturer` | planned |
| `slopdesk-apple-audio` | AudioToolbox | `AudioStreamEncoder`/`Decoder`, `AudioPlaybackEngine` | planned |
| `slopdesk-apple-power` | `IOKit.pwr_mgt` | `PreventSleepAssertion`, `HostDisplayWake` | **deferred** — §1 |

Each row lands on its own, with the Swift original deleted in the same change — `CLAUDE.md`'s
one-implementation rule does not soften because the other language is a framework.

### Four corrections this ledger earned by being wrong

**`ForegroundProcessProbes` was never an `slopdesk-apple-app` row.** It sat in that line because it
was read as "host code that resolves a process", and it contains no AppKit at all: `tcgetpgrp`,
`proc_pidpath`, `proc_listpids`, `proc_pidinfo` and `sysctl(KERN_PROCARGS2)`, which are syscalls and
therefore `rust/slopdesk-posix`'s — `proc.rs`, landed with increment 87. The rule the mistake
violated is §2's, not a scheduling one: this family wraps a FRAMEWORK AREA, and a Darwin syscall has
no framework to name in its safety comment. A row that names a Swift FILE rather than an API is a row
that has not been read yet.

**`HostMetadataProbe` was not one either, and it was the bigger half.** The same misreading put it
nowhere at all: it is `proc_listpids` over every live pid, `proc_pidinfo` for each one's `e_tdev` and
start second, `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the cwd, `ptsname` + `stat` for the pane's
device number, and a `Foundation.Process` running `lsof`. No framework, so no row here — the syscalls
are `rust/slopdesk-posix::proc` and `::pty` (increment 88) and the DECISIONS above them are
`rust/slopdesk-panecensus`, a `forbid(unsafe_code)` crate. What that split bought is the thing the
file's own header had conceded for years: it was compiled and code-reviewed ONLY, never unit-tested,
because every reading needs a live PTY and a real subprocess. The hostile-input parser rode along
under that exemption. It is now a function over a string with four tests.

**`CursorSampler` was a row and three quarters of it was not.** The ledger called it "`NSCursor`
reads", and the file is 389 lines of which about forty are that. The rest is four decisions —
when to re-read the shape, where the pointer sits in the captured window, which id a shape gets, and
what pixel size to render it at — plus a `dlsym` for the window server's private cursor SEED. So the
row split three ways rather than one, and each piece went where §2 sends it:

- the two AppKit reads are `slopdesk-apple-cursor`, this ledger's row;
- the four decisions are `slopdesk_video::cursor_sampling`, `forbid(unsafe_code)`, with eighteen
  tests that could not previously exist — the file that held them needed an AppKit run loop, so
  nothing in it ran headless;
- the seed is `slopdesk_posix::dynsym`, because resolving a symbol and calling it is a raw
  function-pointer transmute and §2 bars one from this family outright. The rule did not bend and
  the crate did not gain an exemption: the OPERATION moved to a crate that may already write it.

`slopdesk-ffi`'s `cursor_sampler` joins the three behind one handle — and it is the FIRST handle in
that header that two threads may call at once. Every other one is serialised by its Swift owner;
this one cannot be, because the 120 Hz position sample runs off the main thread precisely so a
main-thread window raise cannot freeze the pointer, while `AppKit` will only answer the shape ON the
main thread. So it carries its own locks, renders outside both of them, and says so in its own
doors. The header's convention note now names the exception rather than being quietly false.

**`NSWorkspace` left the row entirely**, and not because it was hard. Its `frontmostApplication` is
a per-process snapshot that freezes in a daemon pumping no run loop — the bug `slopdesk-apple-cgwindow`
exists to have fixed — so there is nothing to port, only something to keep deleted. Its
*notifications* are a different API and still Swift's: an observer with a run loop behind it is not an
effect on the system, it is a subscription, and §1's test for what belongs here is the former.
