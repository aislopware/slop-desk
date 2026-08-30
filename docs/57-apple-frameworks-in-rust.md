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
| Version | pinned `=0.6.3` for `objc2`, `=0.3.2` for every framework crate — the exact pins the MSRV row below asks for, and what every `slopdesk-apple-*` manifest carries |
| Usage | 38.9M recent downloads for `objc2`; 19.8M `objc2-app-kit`, 18.5M `objc2-core-graphics`, 18.0M `objc2-io-surface` |
| Coverage | Every framework this tree needs has a generated crate: `screen-capture-kit`, `video-toolbox`, `core-media`, `core-video`, `io-surface`, `metal`, `core-graphics`, `app-kit`, `ui-kit`, plus `block2` and `dispatch2` |
| Provenance | The merge of the `objc`/`block` lineage the Rust-on-Apple ecosystem already stands on — `winit`, `wgpu` and `cacao` are downstream |
| MSRV | 1.71, explicitly **not** policy — may move in a patch release. Pin exactly. |

The caveat that matters: framework crates are **generated**, not hand-audited. A binding is only as
right as the SDK metadata it came from, which is why §3's bar asks for a leak test rather than
trusting `CFRetained` to be correct by construction.

### The area that was deferred, and the measurement that ended it

IOKit power management used to be the one hole in this family, on a measured claim: that
`objc2-io-kit` 0.3.2 shipped no `IOPMLib`, so the two sleep assertions could only be reached through
a hand-declared `extern "C"` block — precisely the shape §1 argues against. The deferral named its
own end condition: *"it lands when a binding appears upstream."*

**The claim was wrong, and re-measuring is what found it.** `objc2-io-kit` 0.3.2 has a `pwr_mgt`
feature, on by DEFAULT, and it generates `IOPMAssertionCreateWithName`, `IOPMAssertionRelease` and
`IOPMAssertionID` from the SDK header. The original reading listed the crate's USB, HID and graphics
features and stopped before the one it was looking for. Nothing upstream changed; the audit did.

So `slopdesk-apple-power` exists, and it is worth naming what the deferral bought anyway: the crate
declares `default-features = false` and asks for `pwr_mgt` alone, because `objc2-io-kit`'s default
set drags in USB, HID and the IOKit plug-in machinery — a framework area far wider than §2 lets one
crate cover. `PreventSleepAssertion.swift` and `PreventSleepPolicy.swift` are DELETED, and
`PreventSleepDriver.swift` and `HostDisplayWake.swift` shrank to what a face is: a lock over a
handle, twice.

The transferable rule: a deferral resting on a measurement is only as good as the measurement, and
the crate index moves. Re-run the check before treating one as settled — this one bought a standing
"that is a recorded exception to §4" for a feature flag that was there the whole time.

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

**With ONE admission: `CFRetained::from_raw`, at most once per crate.** Core Foundation's Copy/Create
rule says a function whose name contains `Copy` or `Create` hands back a +1 retain, and some of them
deliver it through an out-parameter rather than as a return value — `objc2` generates those as a raw
`NonNull<*const CFType>` and offers nothing owned, because the ownership is stated by Apple's naming
convention and not by the C signature. Taking that retain is a FRAMEWORK obligation in the exact
sense the paragraph above is built on: documented, and checked by reading the callee's name. What
keeps this from being a hole is the COUNT. One site per crate means the crate has exactly one place
where a Copy-rule pointer becomes an owned value and every typed reader is a caller of that helper;
a second one fails `apple-family` with the same message a `transmute` gets. See the fifth correction
in §5 for the reading that earned this.

**And its Get-rule twin: `CFRetained::retain`, at most once per crate.** The other half of the same
convention. A function whose name contains neither `Copy` nor `Create` hands back a BORROWED +0
reference valid only for the call, and the place that matters is a callback: `objc2` generates
`VTCompressionOutputHandler`'s sample buffer as a bare `*mut CMSampleBuffer` because that is what
the C block signature says, and a sink that outlives the block needs a reference of its own.
`CFRetained::retain` is Apple's documented way to take one. Same shape as the Copy-rule admission
and same defence: a framework obligation, checked by reading the callee's name, counted at ONE site
per crate so the question "is this borrowed pointer still the framework's" is answered where the
framework hands it across rather than wherever someone found a pointer. Counted by the qualified
path only — `value.retain()` on a live typed reference asserts nothing and is not this admission.
The two counts are independent: a crate that owns a session AND reads its callback's samples
genuinely carries both, and one does not consume the other.

**One admission, TWO spellings.** `objc2` gives an Objective-C object `Retained::retain` and a Core
Foundation type `CFRetained::retain`, and they satisfy one rule: `ScreenCaptureKit` hands its
completion handler a borrowed `SCShareableContent` for exactly the reason `VideoToolbox` hands its
output handler a borrowed `CMSampleBuffer`. So the two spellings share ONE budget rather than each
getting their own, and the gate adds them. This is written down because it was not: the gate matched
only the CF spelling, and `slopdesk-apple-sck` spent the admission at two `Retained::retain` sites
with the gate reading green. Its one site is now `own::borrowed`, the helper the paragraph below
already asks for.

**Both admissions may be spent on a GENERIC HELPER, and that is the reading, not a loophole.**
`slopdesk-apple-vt` grew a second framework area — compression takes one Create-rule out-parameter
and one Get-rule callback pointer, decompression takes four and one — and written inline that would
have been ten sites and a §2 violation for a crate that had done nothing wrong. Written as one
`created<T>` and one `borrowed<T>` in its own module it is two, which is what the paragraphs above
already ASK for in their own words: "the crate has exactly one place where a Copy-rule pointer
becomes an owned value and every typed reader is a caller of that helper". The per-site alternative
is strictly worse for a reviewer — it makes the same argument ten times, each of which must be
re-derived from the callee's name. Here the argument is made once, in the helper's `# Safety` note,
and each call site's remaining job is the one thing a reader can actually check on the line in front
of them: *does this function's name contain `Copy` or `Create`?* The cap is unchanged and
`apple-family` still counts two qualified paths; what moved is where the crate spends them.

**And TWO crates are exempt from the raw-pointer ban, because their frameworks hand out MEMORY
rather than objects.** `slopdesk-apple-audio` and `slopdesk-apple-vt` may write
`slice::from_raw_parts`, `.read()`, `.add()` and their kin; every other crate in the family may not.
They are a NAMED LIST in `crate_policy.rs`, each with its own site cap, and a third does not join by
resembling them — it joins by a change to this paragraph.

The reason is a difference in what the framework gives you, not in what the crate wants. Everywhere
else in this family the thing crossing is an OBJECT — a `CGEvent`, an `AXUIElement`, a
`CMSampleBuffer` — and `objc2` has a type for it, so the two CF admissions above are the whole gap
between what the C signature says and what Apple's convention means. Core Audio has no object.
`AudioBufferList` is a C flexible-array member: a header with a count and a trailing array the
caller both allocates and sizes, which is a shape Rust has no type for at all.
`AudioConverterFillComplexBuffer` fills one through a callback, `CMSampleBuffer`'s
`audio_buffer_list_with_retained_block_buffer` writes into one the caller supplied, and what comes
back is `mData: *mut c_void` with a byte length beside it. There is no reading of that as a `&[f32]`
which does not go through `slice::from_raw_parts`.

Three routes were checked before widening the rule, and each fails on its own terms:

- **Move the obligation to `slopdesk-ffi`, as §2 says to.** `slopdesk-ffi` already depends on the
  `apple-*` crates, so `apple-audio → ffi` is a dependency CYCLE. The rule's own escape hatch does
  not exist here.
- **Use AVFAudio's object wrappers instead.** `AVAudioPCMBuffer::floatChannelData` is
  `*mut NonNull<c_float>` and `AVAudioSourceNodeRenderBlock` hands over `*mut AudioBufferList`. The
  higher-level framework does not hide the flexible-array member; it hands over the same pointer
  with an extra allocation in front of it.
- **Give up and keep the encode in Swift.** That is the thing this whole family exists to stop, and
  it costs about 640 lines of Swift making the same pointer arguments with no `# Safety` note, no
  leak test and no gate counting the sites.

`slopdesk-apple-vt` is the second, over TWO framework areas, and it is worth saying why it was
refused for years before it was granted. HEVC parameter sets — the VPS, SPS and PPS a decoder must have before it can
decode anything — live in the FORMAT DESCRIPTION rather than inline in the sample, and
`CMVideoFormatDescriptionGetHEVCParameterSetAtIndex` is the only way to reach them. It reports a
pointer. There is no `…CopyParameterSet…` anywhere in CoreMedia, so the same "no reading of this
that does not go through `slice::from_raw_parts`" that Core Audio has is true here, for one call.

The other area is a LOCKED pixel buffer. `CVPixelBufferGetBaseAddressOfPlane` answers where a plane
starts and `…GetBytesPerRowOfPlane` how far apart its rows are, and what those two describe IS a
mapping — there is no plane object to hold instead, and the pair is only meaningful while the lock
guard is alive. Encoding reads one; the loopback harness writes a synthetic picture into one and
reads the decoded one back, which is why the crate answers both a shared and an exclusive view.

The three-route test above is what refused it. Route one — move the obligation to `slopdesk-ffi` —
did NOT fail for this crate: the encoder driver lived there, `slopdesk-ffi`'s whole remit is that
question, and the crate answered parameter sets as `(NonNull<u8>, usize)` VALUES so the slice was
made on the other side of the boundary. The planes were the same arrangement one module over —
`slopdesk-ffi::pixel_plane` existed for no reason but "this crate may write `unsafe` and apple-vt
may not". An exemption while its own escape hatch is open would be the door this section is written
to prevent, so `docs/61` §2 recorded it as a debt with a trigger rather than granting it early.

The trigger fired when `Sources/SlopDeskVideoHost` was deleted. With no Swift calling the encoder,
the `extern "C"` doors went with it, and a shim crate stopped being the natural home for a driver
whose only caller is a Rust daemon — one that is `forbid(unsafe_code)` like every crate outside these
two families, and so cannot make the slice itself. At that point route one no longer exists and the
site has to be at the framework, which is here. What landed is narrower than the debt anticipated:
`EncodedSample` now answers only COPIES, `FrameworkBytes` is gone, `Locked` answers a plane as a
slice rather than a base address, and no framework pointer leaves that crate at all — so the driver
needed no exemption of its own, and the whole spend is three reads: `copy_parameter_sets_into` and
the two plane views.

So each exemption is real, and what keeps it from being a door is that it is a RATCHET rather than a
category. `apple-family` counts the raw-pointer sites in each listed crate against ITS OWN fixed
number and fails BOTH ways: above it, because a crate that grew a site did so in a commit that should
have said what the site is for; at zero, because an exemption nothing spends should be deleted rather
than left lying around for the next crate to notice. A listed crate that no longer exists fails too,
since a ratchet naming a folded-away crate reads for years like a checked claim. The counting pattern
is deliberately WIDER than the ban's — it adds `.read(`, `.write(`, `.add(` and `.offset(` — since a
ratchet that missed `pointer.read()` would let an exempt crate grow sites the count never saw. Caps
are per crate rather than shared, or the tighter one would be protected by the looser. Everything
else in §2 still binds both: the `deny(unsafe_op_in_unsafe_fn)`, the `# Safety` note naming the
AudioToolbox or CoreMedia rule per block, the leak test, and the ban on logic.

**Every `unsafe` block names the FRAMEWORK rule it satisfies**, not a Rust rule. `// SAFETY: the
buffer outlives the call` is the wrong comment here — the binding already proved that. The right one
is `// SAFETY: kAXRaiseAction is a documented action on a window element; a stale element is a
no-op, not a fault.`

## 3. The bar, per crate

1. `#![deny(unsafe_op_in_unsafe_fn)]` and the workspace lint table otherwise unchanged.
2. A `# Safety` comment per `unsafe` block, in the form §2 describes.
3. A LEAK test: the crate's central object is created and dropped in a loop, and the test asserts the
   process's resident footprint does not climb. Generated bindings are the risk this covers.
4. Small enough to read in a sitting. If a wrapper crosses ~600 lines of CODE, the framework area
   was drawn too wide. **Code**, counting neither blank lines nor comments and stopping at the first
   `#[cfg(test)]`, and the distinction is not a loophole — these crates run about half prose, because
   every `unsafe` block owes a `# Safety` note naming a framework rule and every door owes the reason
   it answers nothing rather than failing. A bar that counted those would be a bar on writing them
   down, and one that counted the leak test §3.3 demands would be a bar on writing that.

   **Where the bar and the rule above it collide, the rule wins — and the crate is BOOKED.** `ax`
   was the first: the accessibility client API genuinely is that wide, and splitting it would draw
   two crates across one framework area. Four more rows have landed on the same side since — `vt`,
   `sck`, `audio`, `cgvirtualdisplay` — so it is a pattern rather than one crate's excuse, and a
   pattern with no instrument is drift. `rules::crate_policy::apple_family` now counts every crate in
   the family and holds each booked one to the width it MEASURED, so an excused crate cannot also
   grow unremarked, and one that comes back under the bar loses its booking. The per-crate numbers
   live in that rule's `WIDE` table with the reason each area is indivisible; a census here would be
   a second place for them to be wrong.

   The other thing an over-bar count can mean is portable RULES that belong one crate down, the way
   `vt`'s Swift original was mostly rules before they moved. That is the question to answer BEFORE
   booking one: a module that names no framework at all is a move, not an excuse.
5. `cargo test` runs it on macOS; on any other host every module is `#[cfg(target_os = "macos")]` and
   the crate compiles to nothing.

### A macOS-only crate may enter `slopdesk-ffi`'s graph, by ONE route

`slopdesk-ffi` builds three slices, two of them iOS, so a macOS-only edge is a link error waiting to
happen — but the tree already carries one and enforces it. `slopdesk-git` vendors `libgit2`, is a
`[target.'cfg(target_os = "macos")'.dependencies]` edge, and its door is declared inside the
`MACOS-ONLY BEGIN/END` region of `slopdesk_ffi.h`. `slopdesk-gate ffi` reads that region and requires the
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
`vt` is the first row whose Swift original was mostly RULES rather than calls, and it is split
accordingly — see the sixth correction. `sck` is the first that cost NEITHER §2 admission and still
called a framework all the way through: `objc2-core-media` already returns `CFRetained` from every
accessor it needs, so the ownership question was answered by the binding rather than by us.

| Crate | Wraps | Replaces | State |
| --- | --- | --- | --- |
| `slopdesk-apple-cgevent` | CoreGraphics events | `InputInjector`'s posting | **landed** (increment 84) |
| `slopdesk-apple-cgwindow` | CG window services | `HostFrontmostApp`'s decode, `WindowGeometryWatcher`'s window reads | **landed** (increment 85) |
| `slopdesk-apple-cgdisplay` | CG display services | every `CGDisplayBounds`/`CGGet*DisplayList` site | **landed** (increment 85) |
| `slopdesk-apple-ax` | `AXUIElement` | the raise chain, `WindowPlacement`, `WindowGeometryWatcher`'s resize, `WindowFeedAXSupport`'s probe, `HostNavHistory` | **landed** (increments 90-91) — costs the §2 admission |
| `slopdesk-apple-cursor` | `NSCursor` + the offscreen `NSBitmapImageRep` render | `CursorSampler`'s two AppKit reads | **landed** (increment 89) — costs **two** `unsafe` blocks |
| `slopdesk-apple-app` | `NSRunningApplication` reads, and `NSWorkspace`'s two EFFECT verbs | `HostFrontmostApp`'s last line, `WindowFeedGlue`'s per-pid state, `InputInjector`'s activate, `HostPathActionPerformer`'s open/reveal | **landed** (increment 87; `NSWorkspace` in stage E) — costs **zero** `unsafe` |
| `slopdesk-apple-vt` | VideoToolbox + CoreMedia | `VideoEncoder` **(done)**, `VideoDecoder` **(done)**, `DevicePanelSampleBuffer` + both `*VideoFormat` **(done)** | **landed** (increments 92, 93; the device panels 2026-08-29) — costs both §2 admissions, the shim's third convention, and the family's only iOS edge. The panels cost NO further admission: `FormatDescription::from_parameter_sets` generalised the decoder's own builder over a codec and a length prefix, and `SampleBuffer::into_raw` hands the finished buffer to Swift at +1 without a matching `from_raw` — ownership goes OUT there, and the one place it comes back (the leak test's reclaim) goes through `owned::created` like every other typed reader |
| `slopdesk-apple-sck` | ScreenCaptureKit | `WindowCapturer`'s stream **(done)** | **landed** (increment 94) — costs **neither** §2 admission |
| `slopdesk-apple-audio` | AudioToolbox | `AudioStreamEncoder`/`Decoder` | **done** — the §2 exemption above; `AudioPlaybackEngine` went to `slopdesk-audio-out` (cpal) instead |
| `slopdesk-apple-power` | `IOKit.pwr_mgt` | `PreventSleepAssertion`, `PreventSleepPolicy`, `HostDisplayWake`'s seams | **landed** — costs **one** `unsafe` block; the deferral was a mis-read feature list, see §1 |

| `slopdesk-apple-pasteboard` | `NSPasteboard` **and** `UIPasteboard` (+ each framework's image transcode) | `SystemPasteboard`, `PasteboardClip` — the whole `SlopDeskPasteboard` target, both arms | **landed** (stage E for `AppKit`, extended to `UIKit` when the client end crossed) — costs **one** `unsafe` block on the `AppKit` half, a per-accessor `#[expect]` on the `UIKit` half where `objc2` generates every non-atomic property `unsafe`, and **neither** §2 admission. The family's SECOND two-framework crate, and for `slopdesk-apple-vt`'s reason: §2's unit is the framework AREA, and a pasteboard asked the same six questions in two spellings is one area. `appkit.rs` and `uikit.rs`, selected by `cfg`; `apple_floors.rs` carries a row per FILE, because one crate holding two frameworks still owes one floor each |
| `slopdesk-apple-fsevents` | `FSEvents` | `RepoStatusWatcher`'s stream | **landed** (stage E) — costs **zero** `unsafe` blocks and **neither** admission; see the no-context-pointer note below |
| `slopdesk-apple-nsapp` | `NSApplication` | the video host `main`'s `setActivationPolicy(.accessory)`, and its `NSApplication.run()`-vs-`dispatchMain()` block | **landed** (stage F) — costs **zero** `unsafe` blocks and **neither** admission. A separate crate from `slopdesk-apple-app` because §2's unit is a framework AREA and these are two: that one resolves OTHER processes, this one is what THIS process is — its window-server connection, its activation policy, its run loop. It keeps the Swift's TWO loops rather than unifying them: `dispatch_main()` is the proven default and `NSApplication.run()` is the arm a registered `CGVirtualDisplay` needs for its `CFRunLoop`, and the superset costing the default path nothing is a claim nobody has measured |
| `slopdesk-apple-nsevent` | `NSEvent.mouseLocation` | `CursorSampler`'s pointer read — the third of its three AppKit reads, and the one the ledger had left unattributed | **landed** — costs **zero** `unsafe` blocks and **neither** admission: `objc2-app-kit` generates the class method SAFE, nothing in and a `CGPoint` out. A separate crate from `slopdesk-apple-cursor` on the same §2 ruling that crate's own `primary_height` note made: `NSCursor` is the cursor's IMAGE and `NSEvent` is the input hardware's STATE, two areas that happen to be read by one sampler. It is `NSEvent` rather than `slopdesk-apple-cgevent`'s `CGEventGetLocation` for the COORDINATE SPACE — the CG answer is top-left-origin global points and would need flipping back through the primary display's height, which is the exact y-flip `slopdesk-apple-cgdisplay`'s header exists to avoid, while `mouseLocation` already answers the bottom-left-origin space `cursor_sampling::window_position` documents as its input. The generated signature carries NO `MainThreadMarker`, because the call is a window-server query rather than view state, and that is what lets the 120 Hz sampling thread ask directly instead of hopping |
| `slopdesk-apple-machine` | `NSHost` | `HostWorkspaceStore.hostDisplayName`'s first rung | **landed** (stage F) — costs **zero** `unsafe` blocks and **neither** admission; the ledger's `SCDynamicStoreCopyComputedName` was where the name LIVES, not what the Swift called. The class is deprecated, so the crate carries the family's first `#[expect(deprecated, reason = …)]`, at the one call and not crate-wide: `Network` replaces the four RESOLVING names this crate deliberately does not expose, and answers nothing at all for the label |

Each row lands on its own, with the Swift original deleted in the same change — `CLAUDE.md`'s
one-implementation rule does not soften because the other language is a framework.

**The two stage-E rows were the ONE exception, and both are now closed.** hostd was a Swift process
until stage F's cutover, so `SystemPasteboard` and `RepoStatusWatcher` ran beside their crates for
one stage; deleting them would have taken the host down. What held the line meanwhile was
`one-rust-home-per-apple-area` in `rules/apple_floors.rs` — the Rust side had exactly one caller per
framework area, so the drift this family exists to prevent could not start on the Rust side while
the Swift waited. Stage F deleted `RepoStatusWatcher`; the pasteboard's exception outlived it by the
CLIENT half, which was not hostd's to delete, and closed when that half crossed too. Nothing in
`Sources/` names a pasteboard flavour or a clip UTI now — `one-pasteboard-clip` bans all four
spellings outright, with no exempt file, which is the shape a closed exception has.

**`slopdesk-apple-machine` is under that same carve-out, mid-stage-F rather than before it.**
`HostWorkspaceStore.hostDisplayName()` still exists and still runs, because the Swift hostd it lives
in is not deleted until the cutover at the end of the stage; it goes with `Sources/SlopDeskHost`, in
that change and not in this one. The floor row is what holds the line meanwhile, exactly as it does
for the two above.

**`slopdesk-apple-fsevents` spends no admission because it passes no context pointer.** The Swift
round-trips an `Unmanaged<EventBox>` through `FSEventStreamContext.info`, which in Rust is
`Box::into_raw` plus a raw-pointer dereference in the callback — §2's ban, squarely. The crate
instead passes a NULL context and keys the callback off the `FSEventStreamRef` ADDRESS, held as a
`usize` in a process-wide map, so "never dereferenced" is a promise the type system keeps. The
borrowed `FSEventStreamRef` §5 of `docs/60` predicted would cost a `CFRetained::retain` is therefore
never retained at all: it is a map key. `FSEventStreamRef` is not a CF object in the first place —
it has its own `FSEventStreamRetain`/`Release` pair, not `CFRetain` — so the Get-rule admission was
never the right instrument for it.

### Six corrections this ledger earned by being wrong

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
row split FOUR ways rather than one, and each piece went where §2 sends it:

- the two `NSCursor` reads are `slopdesk-apple-cursor`, this ledger's row;
- the POINTER read — a third AppKit call, and the one the sentence above missed for two increments —
  is `slopdesk-apple-nsevent`, its own row. It is a separate crate on §2's framework-AREA unit, the
  same ruling `slopdesk-apple-cursor`'s `primary_height` note had already made about `NSScreen`:
  what the cursor LOOKS like and where the pointer IS are two areas one sampler happens to read;
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

**§2's raw-pointer ban was one clause too wide, and `slopdesk-apple-ax` is where it showed.** The
ban listed `from_raw` beside `transmute`, and the two are not the same kind of thing.
`AXUIElementCopyAttributeValue` is a Copy-rule function that returns its +1 retain through an
out-parameter, so `objc2` generates the parameter as a raw `NonNull<*const CFType>` — measured, not
assumed: the binding's own `# Safety` note says only "`value` must be a valid pointer", and there is
no owned-return variant anywhere in the generated module. Every typed read in this crate goes
through that one call, so the ban as written had exactly two escapes, and both were worse than the
thing they avoided: file an accessibility read in `slopdesk-posix` under "a syscall with no safe
wrapper", or leave the whole AX row in Swift.

So the rule narrowed rather than bent. §2 now admits `CFRetained::from_raw` and nothing else, at one
site per crate, and `apple-family` counts the sites rather than pattern-matching them away — the
admission is recognised by the QUALIFIED path, so `Box::from_raw` and `CString::from_raw`, which
reconstruct a value this crate itself made, are still the Rust obligation the family does not carry.
In `slopdesk-apple-ax` that site is `attribute::copy`, and the crate's other readers — position,
size, minimized, the window list — are its callers.

The rest of the AX row split the way the cursor row did, and for the same reason: the private
`_AXUIElementGetWindow` has no binding at all, so resolving and calling it is a function-pointer
transmute that §2 still bars outright. It went to `slopdesk_posix::dynsym`, which had to learn a
second framework image to hold it — CoreGraphics does not export that symbol, HIServices does, and
asking the wrong one answers null rather than failing, so a single shared handle would have made the
door permanently dead. A test pins that. The DECISIONS above the reads — the probe budget, the
window ledger, the phantom filter, and the rule that the private window id wins outright while the
frame is consulted only when the symbol resolved nothing for any candidate — are
`slopdesk_video::ax_probe`, `forbid(unsafe_code)`, with eighteen tests. Every one of those arms was
previously unreachable: the Swift they came from needed an Accessibility grant to run a line of it,
and `WindowFeedAXSupport.swift`'s header said so.

`HostNavHistory` followed one increment later and split the same three ways, which is what turned
the shape above from a fix into a pattern. The crate gained an untyped `Element` and one bounded
depth-first `walk` — the mechanical part, which belongs beside the IPC because every node it touches
is a round trip, so the bound and the traversal have to be the same loop. It takes its two bounds as
plain numbers rather than a policy type, and that is what keeps the policy one crate over:
`slopdesk_video::nav_history` owns which node counts, how deep to look, when a cached pair may still
be believed, and how two half-answers fold. Thirteen tests, against a file whose own header had
conceded that no unit test could reach it.

One detail is worth recording because it is the kind a port loses. Both readings are two-attribute
matches — a role and then an identifier, a key-equivalent character and then its modifiers — and the
Swift read the second only when the first had already matched. Passing both as VALUES would have
made that eager and doubled the round trips of an 800-node walk to learn nothing, so the second
attribute crosses as a closure and the policy crate decides whether to call it. Laziness here is not
an optimisation applied to a rule; it is part of the rule, and it lives with it.

**The `vt` row is two thirds decisions, and reading it that way is what found a silent bug.**
`VideoEncoder.swift` was 1500 lines, and the ledger row named the file. Roughly 350 of those lines
are VideoToolbox calls; the rest are a dozen environment parses, three clamps, a rate-limit
calculation and a seven-field rate-control state machine with three concurrent writers. None of it
had ever run in a test, and the file's own header said why: `VTCompressionSessionCreate` hangs
without a window server and a Screen-Recording grant, so a constructor nobody could call held rules
nobody could reach. The row therefore lands as three pieces, not one — `slopdesk-apple-vt` for the
calls, `slopdesk_video::encoder_config` and `::encoder_state` for the rules, and the shim for the
join. That is the same split the `HostNavHistory` row settled into one increment earlier; what is
new is the RATIO, and it is the reason a row that names a Swift file rather than an API has to be
read before it is scheduled.

Two measurements paid for themselves before a line of the crate was written. The property keys were
read from the framework's own `extern` statics rather than transcribed as string literals, and
`kVTEncodeFrameOptionKey_ForceKeyFrame` turns out to be the string `EncoderForceKeyframe`. Every
other key in the surface — twenty-odd of them — is spelled exactly like the tail of its own
constant, so a literal would have looked right to any reviewer, applied without error, encoded
successfully, and quietly shipped every forced IDR as a delta frame: no recovery keyframe, no crisp
static refresh, no heartbeat, and nothing anywhere reporting a fault. `kVTQPModulationLevel_Disable`
is `0` rather than the `-1` its name suggests, which is the same class of thing one step less
dangerous.

The row also cost the Get-rule admission in §2, and the placement of the other three obligations is
what kept it to one. The session's Create-rule out-parameter uses the existing `CFRetained::from_raw`
site. The encoded payload avoids `slice::from_raw_parts` ENTIRELY by asking
`CMBlockBufferCopyDataBytes` to copy into a `Vec` the crate allocated and resized first — the same
"writes through a slot the caller owns" shape `slopdesk-apple-ax` uses for `AXValueGetValue`, and it
costs nothing, because appending the parameter sets before the payload turns the Swift's two copies
per keyframe into one. The HEVC parameter sets have no copy-out variant in the SDK at all, so they
are answered as `(NonNull<u8>, usize)` VALUES and the one slice is made in `slopdesk-ffi`, whose
entire `unsafe` remit is that question. Only the output block's `*mut CMSampleBuffer` had nowhere
else to go, and that is the admission.

**The join is the one door in the header that calls back, and that is a third `slopdesk-ffi`
convention.** Every other door in `slopdesk_ffi.h` answers when asked. A compression session does
not: the frame arrives on a VideoToolbox thread whenever the hardware is done with it, so
`slopdesk_video_encoder_new` takes a `@convention(c)` function and a context, and the module states
the four terms it is sound under — the bytes are borrowed for the duration of the call, so the caller
copies; the callback runs on a framework thread and never reentrantly; the function is registered
once at `_new` and never changed; the context outlives the handle, which is why Swift retains the box
and releases it only after `_free` has drained. The convention is confined to `encoder.rs` by name,
not by habit, and widening it is a design change.

**The port came out with FEWER copies than the Swift it replaced, which was not the goal.** Swift
paid one copy for a delta frame and two for a keyframe, because it built the parameter-set prefix and
then appended the payload. Rust asks the block buffer whether the payload is one contiguous run
first, and an ordinary delta frame is: it is handed to Swift exactly where the encoder left it, zero
Rust-side copies, and Swift's `Data(bytes:count:)` is the only one in the system. A keyframe still
costs one — parameter sets then payload, into a scratch `Vec` that is reused for the life of the
session rather than reallocated per frame.

**Two things were deleted rather than ported, and one of them was a bug.** The drop-relief integrator
folded its counter only inside the default regime's `else` arm, so under const-QP the count
accumulated for the process lifetime and nothing ever drained it — in the mode most likely to produce
drops, the number a person would read to diagnose them was the one number that could not be trusted.
Rust folds unconditionally, and the accessor that proves it is public because a test needed it. The
LTR capability probe went for the other reason: see `docs/DECISIONS.md`.

**The link line grew, and the reason is worth knowing before the next row.** `objc2-video-toolbox`
carries `#[link(name = "VideoToolbox", kind = "framework")]`, and that attribute does not survive
`xcodebuild -create-xcframework` — it lives in the rlib's metadata, and what ships is a plain static
archive. Three frameworks therefore had to be named in `Package.swift`'s `ffiCLibraries`, where
AppKit already sits for the analogous reason. VideoToolbox and CoreMedia because C FUNCTIONS never
resolve through the Objective-C runtime; CoreVideo for the three `kCVImageBuffer*_ITU_R_709_2`
colour tags, which are `extern` constants. Until this row they were implicit — `VideoEncoder.swift`
imported VideoToolbox itself, and the import was the link. **Every future row that calls a C function
or reads an `extern` constant will hit this, and it presents as a wall of undefined symbols at the
final link, long after the crate and `just ffi` are both green.**

**The decoder closes the row, and it is where the family first reached iOS.** Every other crate in
this family is macOS-gated in `slopdesk-ffi`'s manifest, most because the API does not exist on a
phone at all. VideoToolbox is the exception: iOS has it, and the two halves have opposite audiences
— only the host COMPRESSES, every client DECOMPRESSES. So the crate gates its own compression half
with `#[cfg(target_os = "macos")]` and its Cargo edge widened to `cfg(any(macos, ios))`, which makes
`decoder.rs` the only ungated `slopdesk-apple-*` door in the header and puts its declarations
OUTSIDE the `MACOS-ONLY` region. What keeps the internal gate honest is the check that was already
there: `slopdesk-gate ffi` requires the ENCODER's symbols present on the macOS slice and absent on the
other two, so a `#[cfg]` that quietly stopped matching fails a gate rather than merely bloating a
phone.

**The callback's ownership term is INVERTED from the encoder's, and that is not a style choice.**
The encoder lends `(ptr, len)` for the duration of the call and requires the caller to copy. The
decoder hands the `CVImageBufferRef` over at **+1**, and Swift's `takeRetainedValue()` is the
release the contract requires. The reason is the consumer: the decoded buffer goes to a display-link
pacer that holds it until the next vsync, which is always after the callback returns. A borrow would
be a use-after-free on the first frame; a copy would be a full NV12 frame memcpy sixty times a
second to avoid one retain. Two doors on the same convention with opposite ownership is exactly the
kind of thing a header has to SAY rather than leave to symmetry, so both terms are written out where
the doors are declared.

**Reading this half found the same thing reading the encoder did: the file was mostly rules.**
`VideoDecoder.swift` was 380 lines with three test seams in it — a `cachedParameterSetsForTesting`
getter and a `seedCachedParameterSetsForTesting` setter existed purely so a test could model a
configured decoder without creating a session that would hang. Those seams are gone, because in
`slopdesk_video::decoder_state` the state IS a value and a test builds one by calling the
constructor. Two of the decisions it holds are load-bearing in a way their Swift spelling did not
show: the parameter-set cache must be CLEARED by a hard failure, or a fixed-capture-size stream's
byte-identical recovery IDR answers "reuse" and freezes the pane permanently with nothing reporting
it; and the decode-wall average's first sample must SEED the average whole, or the stats HUD shows a
warmup ramp no decode ever took. Both now have a named test each and a content ban in
`hevc-decode-is-rusts`.

**Three doors were deleted by this row, not ported.** `slopdesk_hevc_types`,
`slopdesk_hevc_nal_type` and `slopdesk_hevc_parameter_sets` existed so `HEVCParameterSets.swift`
could be a face over `slopdesk_video::hevc_parameter_sets`. With the decoder in Rust the only caller
of that face was the decoder, so the face went and the doors went with it — the crate module they
wrapped is unchanged and keeps its own tests, and the shim now calls it directly. This is the second
time in two increments that collapsing a Swift face into Rust orphaned the doors that face existed
to call, and both times `ffi-doors-are-opened` is what said so.

**The `sck` row was the biggest file and the smallest port, and both halves of that are the point.**
`WindowCapturer.swift` was 2 350 lines. About 250 of them called ScreenCaptureKit; the rest is the
frame-decision pipeline — the backlog pacer, the encode-load governor, the adaptive quantiser
measurement, the scroll reprojection, the static-IDR timer, the cadence gate — which is about
SlopDesk and not about the framework, and which stayed. What moved is the stream (the filter, the
configuration, the lifecycle, the per-sample status read) and the rules that fed it. Those rules were
the reason the row was worth doing at all: the delivery ceiling, the surface depth, the crisp quiet
window, the poll tick, the mode selector and the in-place-resize gate had all been split out BY HAND
into `static func resolve*` helpers whose only purpose was to be testable, because the type around
them cannot be instantiated without a window server and a Screen-Recording grant. In
`slopdesk_video::capture_config` that is not a workaround, it is where they live, and the pin that
keeps a child window from softening the whole pane — the one piece that had never been extracted —
came with them.

**Neither §2 admission was spent, and the reason generalises.** `objc2-core-media` 0.3.2 returns
`CFRetained` from `image_buffer()`, `sample_attachments_array()` and their neighbours, so there is
no `CFRetained::from_raw` and no `CFRetained::retain` anywhere in the crate. What `unsafe` remains is
the framework's own contract — `objc2-screen-capture-kit` generates almost everything `unsafe`
because ScreenCaptureKit's header states no nullability and no thread affinity — plus one `extern`
static and one `cast_unchecked` naming the element type C's `CFArrayRef` cannot carry. The lesson
for the rows still open is to check what the bindings already return before budgeting an admission
for it.

**Every entry point BLOCKS, and the caller's actor is what pays for that.** The framework's whole
lifecycle is completion handlers. A door that took a callback per lifecycle step would push a state
machine across the boundary for no gain, so each one waits on its handler behind a `Mutex` +
`Condvar` with a ten-second ceiling and answers a status. That makes the Swift side's job explicit
rather than incidental: `WindowCapturer` owns a `controlQueue` and every door call is `await`ed
through it, because the session that asks is an actor and an actor that blocks stops serving every
other message. The three DELIVERY callbacks are the encoder's convention verbatim, on the queues the
caller named — and the frame queue being the caller's is load-bearing, since sharing it with the
static-IDR timer IS the discipline that lets both touch one cached frame with no lock.

**`ScreenCaptureKit` had to be named in `Package.swift`, for the AppKit reason.** The crate reads
`SCStreamFrameInfoStatus` to tell a frame carrying new pixels from the framework's idle-skip, and an
`extern` constant is a symbol the linker must resolve — unlike a class, which `objc2` looks up
through the runtime. It was implicit until this row, because `WindowCapturer.swift` used to
`import ScreenCaptureKit` itself. The failure it prevents is one undefined symbol at the final link
of every macOS product, long after both the crate and `just ffi` are green.

**The ban this row earned had to be NARROWER than the two before it.** Nothing else in Swift touches
VideoToolbox, so `hevc-encode-is-rusts` could sweep the whole framework. Here the window feed still
enumerates through `SCShareableContent`, `SCWindow` and `SCDisplay` — a read of what exists, not a
capture — so `capture-is-rusts` bans the STREAM vocabulary and nothing else. It once exempted two
files by name; both are gone. The preview glue, which asked `SCScreenshotManager` for one still, was
deleted with its target (`docs/61` §1), and the glass-to-glass measurement harness
`slopdesk-framewatch` — exempted on the reading that porting it would mean measuring the port with
the port — is `rust/slopdesk-instruments`' `slopdesk-framewatch` bin (`docs/61` §1 row 6). That
reading assumed the port would be a second capture; it drives THIS crate's `CaptureStream`, the same
one the daemon drives, so the instrument measures the shipping path instead of a Swift twin of it.
The lifecycle method names are deliberately absent from the ban as well: `startCapture` and
`stopCapture` are also two effect cases in `VideoSessionLogic`'s state machine, which is Swift's and
staying.
