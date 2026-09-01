// slopdesk_ffi_macos.h — the doors that cause an EFFECT — macOS only
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_MACOS_H
#define SLOPDESK_FFI_MACOS_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- The doors that cause an EFFECT — MACOS ONLY --------------------------------
//
// Everything between the MACOS-ONLY markers is declared on macOS and NOWHERE else,
// and the markers are read by `scripts/build-ffi.sh`: it requires these symbols on
// the macOS slice and requires them ABSENT from the two iOS slices, so the guard
// here and the `cfg(target_os = "macos")` in `src/lib.rs` cannot drift apart.
//
// Three things live here. Behind `slopdesk_git_status` is a vendored `libgit2`: only
// hostd asks — a client on either platform RECEIVES the git status as a metadata
// reply and never computes it — so compiling that library into the phone slices
// would cost every phone build and every phone archive for a door nothing on the
// phone can reach. Behind the `slopdesk_injector_*` doors is CoreGraphics event
// synthesis and the accessibility tree, and behind the `slopdesk_cgwindow_*` /
// `slopdesk_cgdisplay_*` ones is
// the WindowServer's read side; iOS has neither at all, so an ungated declaration
// there would not merely cost bytes — it would fail to link.
//
// MACOS-ONLY BEGIN
#if TARGET_OS_OSX

// ---- Remote input injection ------------------------------------------------------
//
// ONE handle for one session's injected input: the raise chain, the scroll resampler,
// the swipe-back translation, and every event that reaches the window server. What was
// `InputInjector.swift` — 735 lines that owned no rule, only two DispatchQueues, a
// DispatchSourceTimer and three NSLocks. The rules were already Rust and the effects
// were already doors; this is what was left, and eight doors went away with the file.
//
// THREADING: this and the cursor sampler are the two handles in this header that more
// than one thread may call. The session injects and raises, the geometry watcher updates
// the bounds, teardown reads the balance, and the handle's OWN two threads call back
// into it. It carries its own locks, so no caller needs one.

typedef struct SlopDeskInjector SlopDeskInjector;

// The environment keys this handle reads, NUL-joined, in the order slopdesk_injector_new
// expects their values. TWO gate families and one name in neither, as one list because
// the caller resolves them all through the same overlay-aware lookup (EnvConfig.string,
// docs/58) in the same breath. SLOPDESK_INPUT_TRACE is deliberately NOT here: the
// session's own gate table already resolves it, and it crosses as the bool below.

// The resampler's output rate, or 0 for the direct-post path. Needed BEFORE any injector
// exists — the scroll coalescer's default follows it, because the resampler already caps
// the post rate and stacking the summing gate under it double-quantizes the stream. An
// unreadable list answers the default rather than off.

// Builds one session's injector and starts whichever threads it needs. Never null.
//
// `pid` is 0 for a DISPLAY-scoped session (the full-desktop pane), which raises nothing:
// whole-desktop input goes to whatever is frontmost, exactly like a local user's.
//
// `held` SEEDS the balance and is what a stale injector's slopdesk_injector_balance
// answered — the same record the per-event fold already crosses as (docs/55 §4b). A
// transparent reconnect rebuilds the injector while the user may still be PHYSICALLY
// holding a drag or Command; seeding empty would classify the eventual release as an
// orphan, suppress it, and strand the host mid-drag.

// Stops both threads and releases the handle. Null is inert. This JOINS rather than
// cancels: a pump still holding the shared state when the box went away would be reading
// freed memory, so the wait is the safety property. Bounded — the only thing either
// thread blocks on is the channel this closes.

// Re-points the coordinate mapping at the window's current frame, as the geometry watcher
// sees it move.

// Requests the raise chain for the first event of an interaction, and returns IMMEDIATELY.
// The chain is 6-10 synchronous AX round-trips against a backgrounded target — measured at
// 1-7 seconds — which is why it never runs on the caller's thread; on the main actor it
// starved the main-only cursor-shape refresh for whole seconds. A display-scoped session
// has nothing to raise and this is a no-op.

// Posts one remote input event. `text` carries the text arm's bytes and is ignored by
// every other arm — the split SlopDeskInputEvent already uses, because a string has no
// home in a flat record and the caller is holding the datagram it came out of. false
// means the record described no event this build answers to.

// The held-button/held-modifier ledger, as a snapshot. The session reads this off the
// STALE injector at teardown and threads it into the replacement's seed. A record rather
// than a handle, per docs/55 §4b: the balance is twelve bits, and a handle for it would be
// an allocation to leak.

// ---- The WindowServer's read side ------------------------------------------------
//
// `rust/slopdesk-apple-cgwindow` asks CGWindowList and decodes the answer;
// `rust/slopdesk-apple-cgdisplay` asks Quartz which displays exist. Four Swift call
// sites each hand-decoded the same CFDictionary before these, and they disagreed
// about what a missing field means — one defaulted kCGWindowLayer to Int.min,
// another to -1. The crate behind these DROPS an incomplete record, once.
//
// Every rect is CG global points, TOP-LEFT origin — the space kCGWindowBounds, the
// Accessibility API and CGEvent mouse positions share. NSScreen.frame is not that
// space, and reading one through AppKit would need a y-flip nobody remembers.

// The frontmost app's pid, or 0 when nothing normal-level is on screen (login/lock
// screen, bare desktop, display asleep).
//
// 0 rather than a flag because 0 is not a pid a window can have, and every caller
// already fails CLOSED on it. Read from the window list and NEVER from NSWorkspace:
// that snapshot freezes at first access in a daemon that pumps no AppKit run loop,
// which is the bug this door exists to have fixed.

// One window's current bounds. `expected_pid` of 0 accepts any owner; anything else
// requires that owner, because CGWindowIDs are per-boot and REUSABLE — a stale id
// must never let the parked-window restore move an unrelated app's window. false
// leaves *out untouched.

// Every on-screen window strictly IN FRONT of `window_id`, front-to-back, as
// SlopDeskWindowRecord — declared with the deciders that consume it, above. The answer
// is the count NEEDED (§4), so a caller that lent too little is told what to lend. A
// window_id of 0 names nothing and answers 0.

typedef struct {
  SlopDeskVideoRect bounds; // CG global points, top-left origin
  uint32_t display_id;      // the CGDirectDisplayID SCShareableContent keys on
} SlopDeskCGDisplay;

// Every display, and how many there are. `online_only` asks for displays that EXIST
// — mirrored and sleeping ones included — rather than only the drawable ones: a
// window on a sleeping display is not stranded, and the restore must not move it.
// The answer is the count NEEDED (§4).

// The display under a point. false — the point is off every display — leaves *out
// untouched.

// One display's bounds, by id, for the callers that already hold one from
// SCShareableContent or from the virtual display they created. An id naming no
// display answers a zero rect, which is CoreGraphics's own answer.

// The bundle identifier of a pid, or 0 (§4's None) when it names no application — it
// exited, it is not an app bundle, or it has no Info.plist. Every caller reads that as
// "not eligible" and fails CLOSED. Pair it with slopdesk_cgwindow_frontmost_pid above;
// together they are the whole frontmost read, with no AppKit on the Swift side.

// Whether that app is HIDDEN (⌘H, or hidden by another app becoming active). A pid
// naming no application answers false — the window feed reads hidden as a reason to
// SUPPRESS a row, and a window belonging to nothing is not a window a person hid.

// ---- Keeping the Mac's SCREEN awake ---------------------------------------------------
//
// One handle pairing the fold that decides whether anyone is watching with the single
// IOPMAssertion it drives, answering the state that fold reached. The pairing is inside
// the handle on purpose — the Swift version kept the count and the assertion apart and
// made every caller hold a lock across both, and the failure that slips through is one
// thread applying a verdict computed against a count another thread has already changed,
// which leaves an assertion held over an empty set. That does not self-heal; it keeps the
// screen lit until the daemon dies.
//
// Handle convention as everywhere: exactly one free per new, no two calls on one handle
// at once. Freeing RELEASES a still-held assertion, which is the teardown guarantee.
//
// Its SYSTEM twin — the agent-working assertion, once `SlopDeskPreventSleep` — has no door
// here any more. The two were never one door with a flag: an agent working through the
// night must not let the MACHINE sleep, a client watching the desktop must not let the
// SCREEN go dark, and an agent working with nobody watching should still let the screen go
// dark. But the system one was only ever hostd's, and it crossed here because hostd was
// Swift. `rust/slopdesk-hostd::sleep` owns the set and the assertion outright now and buys
// the same property with ownership instead of a lock (docs/60 F.9). The display one stays
// because its caller is still Swift, and it is refcounted by session rather than keyed by
// pane.

typedef struct SlopDeskDisplayWake SlopDeskDisplayWake;



// One more streaming desktop session; answers whether the display assertion is held.

// One session ended. An UNBALANCED release clamps at zero rather than underflowing —
// a count that wrapped would hold the screen awake with no live session to release it.

// There is no `_is_held` twin here, and its absence is the rule rather than an omission: both doors
// above already answer the state they reached, and `HostDisplayWake` reads neither. An unread door
// is a claim about the far side that nothing checks, which `ffi-doors-are-opened` fails.

// ---- The accessibility tree ---------------------------------------------------------

// Four Swift files opened by writing the same six lines — application element,
// messaging timeout, kAXWindows, walk it calling a private symbol, compare against a
// CGWindowID. That preamble is written once now, behind these doors; what each file
// actually wanted is below. The AXObserver stays Swift: a subscription with a run loop
// behind it is not an effect on the system (docs/57 §1).

// Whether this process holds the Accessibility grant. Never cache it — the grant is
// live TCC state a person can give or take away while the process runs.
bool slopdesk_ax_is_trusted(void);

// Asks for the grant with the system prompt, and answers whether it is ALREADY held.
// macOS shows the prompt at most once per app per install; after that this is a silent
// read, which is why the caller's own UI carries the "open System Settings" path.
bool slopdesk_ax_prompt_for_trust(void);

// What a successful park answers.
typedef struct {
  SlopDeskVideoRect original;  // the PRE-move global frame, for putting it back later
  double achieved_width;       // the size the window ACTUALLY took, which may be clamped
  double achieved_height;
} SlopDeskAxPark;

// Moves the window fully onto display_id, shrinking it DOWN first if it does not fit.
// Size before position, and the order is load-bearing: an app asked to cross displays
// before it is asked to shrink clamps the shrink against the display it is LEAVING.
//
// false on every failure — window not found, pre-move frame unreadable, position write
// refused, or the app clamped the shrink so the window still overhangs. On the last two
// the window is rolled BACK to where it started, so a 1x fallback captures it cleanly in
// place rather than over-cropping a half-moved one. `out` is written only on true.

// Puts the window back at `frame` — the inverse of a park, ORIGIN before size, so it
// crosses back to the roomier display before it is asked to grow.

#define SLOPDESK_AX_DEMINIATURIZE_FAILED        0
#define SLOPDESK_AX_DEMINIATURIZE_NOT_MINIMIZED 1
#define SLOPDESK_AX_DEMINIATURIZE_RESTORING     2

// Un-minimizes the window so the WindowServer paints it again — a minimized window is
// never rendered, so capturing one streams nothing. Read-then-write: a window that is
// not minimized is left completely untouched.

// Resizes the window and answers the size it ACTUALLY took, which is the source of truth
// for the encoder reconfigure — the window may clamp to its own min/max.
//
// `displays` is every display's bounds, used for ONE thing: re-anchoring the window at
// its display's top-left BEFORE the size write. macOS clamps a size-set to keep the
// window on screen from its CURRENT position, so a window parked mid-screen cannot grow
// to fill the display until it has been moved to the origin first. Lend nothing to skip
// the re-anchor. out_width/out_height are written only on true.

// The budgeted minimized probe (docs/45 Phase 5): which off-screen windows are minimized
// rather than on another Space, and which have any AX evidence of being real windows at
// all — the feed's junk filter for the phantom entries CGWindowList reports.
typedef struct SlopDeskAxProbe SlopDeskAxProbe;


typedef struct {
  uint32_t window_id;
  int32_t pid;  // the owning process
} SlopDeskAxOffScreen;

typedef struct {
  uint32_t window_id;
  bool ax_listed;  // false = a phantom the WindowServer lists and no person can look at
  bool minimized;  // as opposed to sitting on another Space
} SlopDeskAxVerdict;

// Classifies every off-screen window, sweeping at most a few applications on the way.
// `now` is the CALLER's clock so a whole tick shares one instant.
//
// The sweep is budgeted because it is the only thing in the feed that can BLOCK: a hung
// app costs its whole messaging timeout, so an unbounded tick is one beachballing app
// away from stalling the feed. Windows whose pid was not swept this tick answer from the
// last sweep; windows never swept at all answer false/false rather than a guess.
//
// Reports the count it NEEDS. A retry re-classifies from the ledger and sweeps nothing
// new — this tick's pids are already stamped — so it is cheap and stable.

// ---- The swipe-nav history gate (doc 20 §9.6) ---------------------------------------

// Whether the frontmost browser can go back and forward, so the chip never promises a
// navigation the chord cannot perform. Two readings, tried in this order:
//
//   1. the toolbar buttons with AXIdentifier BackButton/ForwardButton — what the person
//      SEES grey out, so it cannot be stale;
//   2. the menu items whose key equivalent is bare-Cmd [ or ] — locale-independent and
//      semantically exact, and Chromium keeps them live without any menu opening.
//
// A handle rather than a function because a cold scan is 25-180 ms of blocking IPC and a
// cached re-read is ~0.05 ms, while the poll runs at 4 Hz. One handle per reader; no two
// calls on it may overlap.
typedef struct SlopDeskNavHistory SlopDeskNavHistory;


typedef struct {
  bool can_go_back;     // whether Cmd-[ would navigate
  bool can_go_forward;  // whether Cmd-] would navigate
} SlopDeskNavFlags;

// Reads pid's availability into `out`; answers whether it is KNOWN. false leaves `out`
// untouched and is the FAIL-OPEN answer: the client falls back to its pre-gate behaviour
// rather than darking a chip nobody can vouch for.
//
// `rescan_unknown` is the slow heartbeat's permission to retry a pid whose last scan
// found no pair — without it a browser with no windows would cost a full walk 4x a
// second forever. `verify_window` is that same beat's permission to spend one extra
// round trip confirming a TOOLBAR pair still belongs to the focused window, since that
// state is per-window and a stale pair reads successfully rather than failing.
//
// Blocks on out-of-process IPC, bounded by a per-message cap and a scan deadline. Call
// it OFF the main thread.

// ---- The cursor side-channel's host end --------------------------------------------

// THE ONE HANDLE THAT MAY BE CALLED FROM TWO THREADS. The convention at the top of
// this header says no two calls on one handle may overlap; this handle is the
// exception, and it is written for it. The 120 Hz position sample runs off the main
// thread so that a main-thread window raise cannot freeze the pointer, while the
// shape read is main-thread-only because AppKit says so — so two threads is the
// design rather than a caller's mistake, and the handle carries its own locks.
//
// Everything the old Swift sampler decided is behind these doors: when to re-read
// the shape (the window server's cursor seed), where the pointer sits in the
// captured window, which id a shape gets, and what pixel size it renders at. The
// caller keeps the timer, the one off-main mouse query, and the two sockets.
typedef struct SlopDeskCursorSampler SlopDeskCursorSampler;

// Builds a sampler for a window at these CG top-left bounds. Never NULL.

// Retargets the sampler; call from the geometry watcher on any thread.

// Counts one tick and answers whether it should go to the main thread for a fresh
// shape. Reads the cursor seed itself — there is nothing to pass in. Sampling thread.

// The encoded CursorUpdate for a mouse at these GLOBAL COCOA points (bottom-left
// origin — the space the off-main window-server query answers in). Sampling thread.
//
// 0 until the first refresh has primed the shape id and screen height: an update sent
// before that would name a shape the client has never been given. The answer is a
// fixed 36 bytes, so size the buffer once and never retry.

// Reads the displayed cursor and caches what the position path needs. MAIN THREAD
// ONLY; a call from anywhere else answers 0 and touches nothing.
//
// Answers the length of a NEWLY MINTED shape message, parked for _answer, or 0 when
// the shape was one already shipped — the common case by far. Parked rather than
// returned because the length is what the render ladder decides, so a retry with a
// bigger buffer would re-run the whole render.
//
// primary_height is the main display's height in points, for the Cocoa-to-CG flip. It
// is passed in because NSScreen is a different framework area than the one crate this
// door reads its cursor from (docs/57 §2).

// Copies out the shape message the last _refresh minted.

// An already-shipped shape message by id, for a client that lost the one-shot
// shipment. 0 for an id never minted — re-reading the cursor would answer whatever is
// displayed NOW rather than the shape asked for. Any thread.

// Whether a refresh changed the shape id since this was last asked, and CLEARS the
// flag. Taken rather than read so the caller emits exactly one extra position update
// per change — the client switches its pointer on the next update carrying the new id.

// ---- The capture stream -------------------------------------------------------------
//
// ScreenCaptureKit: asking the window server for a window's or a display's pixels, and
// nothing about what to do with them. The frame-decision pipeline the deliveries feed —
// the backlog pacer, the adaptive-QP measurement, the scroll reprojection, the static-IDR
// timer — is the caller's and stays there.
//
// THE ONE DOOR THAT CALLS BACK, now that the HEVC encoder's has gone. Every other entry
// point in this header answers when asked; this one hands frames over when
// ScreenCaptureKit says so, on a thread ScreenCaptureKit chose. That is a THIRD convention
// beside the (out, cap) -> needed one at the top of this header and the handle one below
// it, and it exists for the same reason the encoder's did: a delivered frame must reach
// the encoder before the next one arrives 16 ms later, and both existing conventions
// require the caller to ask. Polling would be latency added on purpose to preserve a rule
// about shapes.
//
// Its terms:
//   * Every pointer the callback is handed is borrowed for the duration of the call.
//     COPY WHAT YOU KEEP.
//   * It runs on a framework thread, never reentrantly into the handle.
//   * It is registered once, at _start, and never changed.
//   * The context must outlive the handle. Free the handle first.
//
// THE QUEUES ARE THE CALLER'S, and that is load-bearing. The frame queue must be the same
// serial queue the caller's static-IDR timer runs on — that sharing IS the discipline
// that lets the capture callback and the timer touch one cached frame with no lock. The
// audio queue is a second one so a slow synchronous encode cannot delay a 10 ms buffer.
//
// The window is named by CGWindowID, never by an SCWindow pointer: the mint flow moves a
// window onto the virtual display AFTER the object a caller enumerated was made, so that
// object's frame is the pre-move one and a display-local crop computed from it is wrong.
// The far side re-resolves by id, which makes that the only path rather than a correction
// inside one.
typedef struct SlopDeskCapture SlopDeskCapture;

// Which content filter to build. A capture region overrides this — a region spans the
// window AND the dialog it put up, and DISPLAY_INCLUDING is the only mode that
// composites both.
#define SLOPDESK_CAPTURE_MODE_WINDOW 0
#define SLOPDESK_CAPTURE_MODE_DISPLAY_EXCLUDING 1
#define SLOPDESK_CAPTURE_MODE_DISPLAY_INCLUDING 2

// A frame carrying NEW pixels. image_buffer is a CVImageBufferRef borrowed for the call
// ONLY — the surface behind it goes back to the framework's pool when this returns, so
// anything kept must be copied or retained. The presentation time arrives as its two
// CMTime fields rather than as a struct: no caller of this reads the flags or the epoch.
typedef void (*SlopDeskCaptureFrameFn)(void *context, const void *image_buffer,
                                       int64_t value, int32_t timescale);

// An audio buffer, as a CMSampleBufferRef borrowed for the call only.
typedef void (*SlopDeskCaptureAudioFn)(void *context, const void *sample_buffer);

// The stream stopped ITSELF — the shared window closed, the display was unplugged, the
// Screen-Recording grant was revoked, the window server reset. NEVER called for a
// deliberate slopdesk_capture_stop.
typedef void (*SlopDeskCaptureStoppedFn)(void *context);

// Everything _start needs, as one record rather than fifteen arguments: the fields are
// read together, several are meaningless without their neighbour, and a mis-ordered
// argument list of same-typed scalars is the failure this shape cannot have.
typedef struct {
  double capture_scale;  // window points x this = the output buffer's pixels
  double region_x;       // the four region_* are read only when has_region is true,
  double region_y;       // and are in the region display's LOCAL points
  double region_width;
  double region_height;
  uint32_t window_id;   // 0 selects the whole display named below
  uint32_t display_id;  // the display to capture, or the region's display
  int32_t mode;         // one of the SLOPDESK_CAPTURE_MODE_* above
  int32_t pixel_width;
  int32_t pixel_height;
  int32_t fps;                 // the ENCODE rate; the delivery ceiling is resolved from it
  int32_t audio_sample_rate;   // 0 for no audio tap at all
  int32_t audio_channel_count; // read only when the sample rate is non-zero
  bool full_range;             // the full-range NV12 variant rather than the video-range one
  bool has_region;
} SlopDeskCaptureDesc;

// Brings a capture stream up. NULL when it could not start, with status_out — when
// non-NULL — carrying either a ScreenCaptureKit error code or one of the far side's own
// sentinels: -1 no answer inside the wait limit, -2 nothing shareable (no grant, no
// window server), -3 nothing matching the id, -4 not reconfigurable.
//
// BLOCKS on the framework, and needs a window server plus a Screen-Recording grant.

// Stops the capture and waits for the framework to confirm; 0 is success. Separate from
// _free because a caller stops on its teardown path and frees when the last reference
// goes, and those are not the same moment.

// Releases the handle. Does NOT stop the stream — call _stop first.

// Re-origins a display-anchored crop after the window moved, in GLOBAL points. 1 when the
// move was under half a point and not worth a reconfigure, 0 when the live stream took the
// new crop, negative otherwise. Force a keyframe after a 0: the crop jump lands mid-GOP as
// a whole-frame delta, and an anchor right after it is what keeps a late-joining client
// from decoding half of each.

// Resizes a display-anchored capture in place, keeping the crop's origin; 0 is success.
// -4 for a stream this is not allowed on — the caller restart-fallbacks. On a framework
// refusal the stream keeps running at the OLD size rather than dying.

// Whether the crop is anchored to a DISPLAY rather than to the window's backing store,
// and whether it is a poller-owned union region — an in-place resize must not touch one.

// The capture rules, with no stream in the room. _hz is the same resolution _start
// applies, exposed because the caller's cadence gate takes its tolerance from it, so the
// two cannot disagree. Seconds, not milliseconds, wherever a duration is answered.
//
// The surface queue depth is NOT here. It is resolved inside _start and written straight
// onto the SCStreamConfiguration; no caller compares against it the way the cadence gate
// compares against _hz, so a second way to ask would be a face with no reader.

// Which filter to build, as one of the SLOPDESK_CAPTURE_MODE_* above. The request arrives
// as TEXT from the caller rather than being read on the far side, because the caller
// resolves it through a settings overlay in front of the environment — a graphical setting
// can force the capture filter, and an empty overlay reads exactly like a bare lookup.

// ---- The AAC-ELD audio encoder ---------------------------------------------------
//
// The other half of the decoder above, and macOS-only for the same reason the HEVC
// encoder is: only the HOST encodes. iOS HAS AudioToolbox, so an ungated declaration
// would LINK and merely bloat every client slice with a host-only codec — which is
// worse than a link error, because nothing would fail.
//
// _push_sample_buffer takes the CMSampleBufferRef ScreenCaptureKit handed its callback
// and does everything downstream of it: the channel fold to stereo, the 480-frame
// block accumulation, and the encode. It calls `sink` once per COMPLETED wire payload,
// which is zero, one or two per buffer — the arity is why this door is a callback and
// the decoder's is an (out, cap) pair. The span handed to `sink` is alive only for that
// call; copy it or send it, do not retain it.

typedef struct SlopDeskAudioEncoder SlopDeskAudioEncoder;

typedef void (*SlopDeskAudioPayloadFn)(void *context, const uint8_t *bytes, size_t len);

typedef struct {
  uint8_t  format;       /* a SLOPDESK_AUDIO_FORMAT_* code */
  uint32_t sample_rate;
  uint8_t  channels;
  size_t   cookie_len;   /* fetch the bytes with _cookie */
} SlopDeskAudioEncoderConfig;

// The two knobs _new takes, resolved from this process's environment rather than the caller's.
//
// _wire_format answers a SLOPDESK_AUDIO_FORMAT_* code: SLOPDESK_AUDIO_CODEC=pcm selects the
// codec-free s16le arm and ANYTHING else — unset, misspelt, differently cased — is AAC-ELD, because
// silently dropping to raw PCM is sixteen times the bitrate on a link sized for the other number.
// _bitrate_bps answers SLOPDESK_AUDIO_BITRATE clamped into the band, and is never 0: text that is
// not a number answers the default, not the floor.


// The wire config, when there is one. false means "do not send a config packet yet": the PCM arm
// answers from the first call, the AAC arm only once its converter has built. A NULL `out` is a
// presence probe and answers true without writing.
// The magic cookie the client decoder is initialised from, under §4's size-then-fetch convention.
// Empty for the PCM arm — there is no codec to describe.
// Whether the converter REFUSED to build: a permanently silent lane, not a transient.
// Drops the sub-block remainder AND the codec's carried state — the enable transition.


// ---- The HiDPI virtual display ------------------------------------------------------
//
// The four private `CGVirtualDisplay*` classes, reached by NAME through the Objective-C
// runtime — they are Objective-C classes in the PUBLIC CoreGraphics framework, so the
// availability probe and the class lookup are ONE operation and there is no linkage
// attribute to keep. `Sources/CSlopDeskVirtualDisplay` was the shim that used to declare
// them; it is deleted, and there is now no C under `Sources/` at all.
//
// The geometry laws these drive — `slopdesk_vd_geometry` and its neighbours — are pure and
// cross-platform, so they stay OUTSIDE this block, above.
//
// `_create` returns 0 on any failure, including a machine where the classes are absent.
// Every door but `_free` takes `const`: the interior is locked, and the framework delivers
// the terminate callback on its own serial queue. `_FREE IS THE ONE CALL THAT MAY NOT
// OVERLAP ANYTHING` — it is a BARRIER, executing the registration drop synchronously on
// that delivery queue, so it cannot return while a handler is still inside the caller's
// function pointer. Clearing or replacing the callback is NOT a barrier, so the owner must
// keep every context box alive until `_free` has returned.
typedef struct SlopDeskVirtualDisplay SlopDeskVirtualDisplay;
typedef void (*SlopDeskVirtualDisplayTerminatedFn)(void *context);

// Whether this machine's CoreGraphics actually publishes the four classes. Answered by the
// runtime lookup itself, so a false here is the same fact `_create` would return 0 for.

// Points and scale, not pixels: the caller asks for the layout it wants and the scale it
// wants it backed at. `max_horizontal_pixels` is the chip's own limit
// (`slopdesk_vd_chip_pixel_limit`), and `name` is `(ptr, len)` UTF-8 as everywhere else.

// A NULL callback disarms. The context is opaque and never freed here — see the barrier
// note above for the one moment at which the caller may release it.

// ---- Installing the `slopdesk` command -----------------------------------------------
//
// In the region, and not because of a framework: iOS has no `PATH` and no place to put a
// command, so the question does not arise on the phone at all.
//
// The smallest split that could work. `Bundle.main` is the only thing on either side of
// this boundary that knows where this app's own executable lives, so the shell resolves
// the source and lends it; where the link goes, whether one is already there, whose file
// it is, and the `symlink` itself are all behind the door. Both runs are `(ptr, len)`
// UTF-8 as everywhere else, and an empty one links nothing.
//
// Idempotent — called on every launch. Three of the four verdicts are not "it worked":
// OCCUPIED means a regular file somebody else owns is at the destination and was left
// exactly where it was, which is the one refusal that is a decision rather than a failure.
#define SLOPDESK_CLI_LINK_ALREADY  0u
#define SLOPDESK_CLI_LINK_MADE     1u
#define SLOPDESK_CLI_LINK_OCCUPIED 2u
#define SLOPDESK_CLI_LINK_FAILED   3u

uint8_t slopdesk_cli_link(const uint8_t *home, size_t home_len,
                          const uint8_t *source, size_t source_len);

#endif /* TARGET_OS_OSX */
// MACOS-ONLY END

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_MACOS_H */
