//! The host synthesises, decodes and decides nothing of its own.
//!
//! Ported from the deleted `check-supervisor.sh`. Three ports out of Swift and into the `objc2`
//! family `docs/57` opens the unsafe gate for, and each is pinned the same way: the crate exists,
//! no Swift does the work beside it, and the Rust that replaced the Swift still ASKS it.
//!
//! ## The shape changed with `docs/61`, and the doc header says so because the change was large
//! Each of these rules used to have a fourth arm: the macOS-only BIJECTION, spelled in all three of
//! its places — the `cfg`, the header's `MACOS-ONLY` region, the Cargo edge. That arm named C doors
//! (`slopdesk_injector_inject`, `slopdesk_cgwindow_frontmost_pid`, `slopdesk_cgdisplay_list`, the
//! three portable capture deciders) whose ONLY caller was the Swift video host, and `docs/61`
//! deletes both sides at once. Seventeen claims went with them rather than being re-aimed — two,
//! seven and eight, in the three rules below — because a claim that keeps a dead door alive makes
//! its deletion read as a regression. Each rule carries the accounting for its own share under
//! "What was DROPPED".
//!
//! What replaced them is a check the door-shaped claims could not make. A bijection claim asks
//! "is this declaration on the right side of a line"; it never asked whether anyone still CALLS the
//! thing. `rust/slopdesk-videohostd` links these crates as ordinary Rust dependencies now, so the
//! question that matters is whether it still asks them — a daemon that inlines an answer keeps
//! every suite green until the two copies drift. That is a [`Claim::MentionsUnder`] per rule.
//!
//! Every ban here reads [`View::Code`], and that is load-bearing rather than tidy. The files still
//! NAME these calls in prose, and should: the comments carry the hardware measurements that decided
//! the tablet path and the suppression interval, why the feed uses `CGWindowList` over
//! `SCShareableContent`, and why the probe walks displays out of process. A gate that could not
//! tell a call from a sentence about one would force that knowledge out of the file to stay green.
//! Four live client files argue in prose about `CGEventSource` latching modifiers, and the
//! now-tree-wide injection ban would delete those paragraphs if it read them.

use crate::claim::{Claim, RUST, SWIFT, View, check_all};
use crate::report::Report;
use crate::text::matches_line;
use crate::tree::Tree;

/// The Rust daemon that replaced the Swift GUI video host.
///
/// A DIRECTORY rather than a file: `docs/61` split what the Swift host held across a dozen modules,
/// and which one holds a given ask is the daemon's business. What is not is that it ASKS.
const DAEMON: &str = "rust/slopdesk-videohostd";
/// Every extension a private Objective-C class could be named in under `Sources`.
///
/// Wider than [`SWIFT`] on purpose: the shape this bans is not "Swift calls the class" but "the
/// clang-module shim comes back", and a shim is an `.h` that declares the interface plus a `.m`
/// that forces the link. Banning only `.swift` would leave the two files that made it reachable.
const SOURCES: &[&str] = &["swift", "m", "h"];

/// The host synthesises no event of its own
///
/// Every injected `CGEvent` is built and posted by `rust/slopdesk-apple-cgevent`, the first crate
/// of the `objc2` family, and the orchestration above it — the bounds, the balance, the resampler,
/// the raise chain — is `rust/slopdesk-videohostd/src/injector.rs`. The Swift `InputInjector` that
/// used to own the handle is gone with `docs/61`, and so is the shim module that used to hold the
/// orchestration behind a C door: the daemon that installs the injector is the crate that writes
/// it.
///
/// The line matters because the two languages fail differently here. Swift's `Int32(_:)` TRAPS on a
/// value off the wire; Rust's clamp saturates. Swift's `CGEvent` construction was nine call sites
/// that each had to remember the click-state rule, the untagged-keyboard rule and the suppression
/// interval; Rust's is one. A `CGEvent` built in Swift would not be a duplicate implementation in
/// the abstract — it would be the specific bug each of those rules was written to close.
///
/// ## The ban went from ONE FILE to the whole tree
/// It used to name the ARC owner, because that was the file somebody would reach for to add "just
/// one" direct post to. With the owner deleted there is no such file, and a per-file ban would have
/// nothing to check — so the ban is now tree-wide over `Sources` and `Tests`, which is what it
/// should always have been. A `CGEvent` posted from the client, from a device panel or from a test
/// helper is the same bug in a target nobody was watching.
///
/// The prose is deliberately untouched by this: [`View::Code`] drops whole-line comments, and four
/// live client files argue in PROSE about the shared `CGEventSource(.hidSystemState)` latching
/// modifiers and about `CGEvent(.cghidEventTap)` keystrokes reaching a secure field. Those
/// paragraphs are the measurements that decided the modifier protocol, and a gate that could not
/// tell a call from a sentence about one would force them out of the files that need them.
///
/// ## The narrowing check moved languages, and could not go tree-wide
/// `clampToInt32` is NOT banned across Swift, and the reason is a fact about the tree rather than a
/// principle: `SlopDeskDevicePanels` declares its own twice, for the Android and shared panel
/// geometries, and a ban wide enough to catch a revival would fire on the tree it ships with. The
/// check re-aimed onto the DAEMON instead, in Rust spelling, where the narrowing would actually
/// come back — and the Swift half is covered anyway, because
/// [`crate::rules::deleted_video_swift`] bans declaring an `InputInjector` in any Swift target.
///
/// ## What was DROPPED, and where the protection went
/// Two claims are gone. The header claim pinned `slopdesk_injector_inject` inside the MACOS-ONLY
/// region, and the manifest claim pinned the `slopdesk-apple-cgevent` edge as target-gated. Both
/// protected the same thing — a CoreGraphics door reachable from an iOS slice fails at LINK, far
/// from here — and both named a door whose only caller was the deleted Swift. `docs/61` deletes
/// those exports, so re-aiming either would have pinned a symbol on its way out: a claim that keeps
/// a dead door alive is worse than no claim, because it makes the deletion look like a regression.
/// The protection did not evaporate — it moved DOWN a level. The daemon links
/// `slopdesk-apple-cgevent` as an ordinary Rust dependency with no C door in between, and
/// `slopdesk-gate ffi` still checks the Cargo edge of every door the library does export. The
/// `Exists` claim MOVED with the orchestration: `docs/61` deleted the shim module too, once the
/// settings faces that called its gate-key doors went with the Swift host, so the claim now names
/// the daemon's own module.
///
/// BREAK-TEST: added `CGEvent(mouseEventSource:` to a live client file ⇒ FAIL "builds a `CGEvent`
/// itself". Separately added `fn clamp_to_i32` under the daemon ⇒ FAIL "keeps its own narrowing".
/// Separately deleted the Rust crate ⇒ FAIL "has no Rust behind it". Separately dropped the
/// daemon's `injector_gates` ask ⇒ FAIL "stopped asking". All four restored from /tmp; PASS.
#[must_use]
pub fn the_host_synthesises_no_event(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Exists {
            path: "rust/slopdesk-apple-cgevent/src/inject.rs",
            message: "the injector has no Rust behind it — the host synthesises no event of its own \
                      (docs/57 §5, docs/56 increment 84)",
        },
        Claim::Exists {
            path: "rust/slopdesk-videohostd/src/injector.rs",
            message: "the injector has no implementation behind it — the bounds, the balance, the resampler \
                      and the raise chain live in ONE module of the daemon that installs it, with no C door \
                      in between (docs/57 §5, docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"CGEvent\(|\.setIntegerValueField|\.post\(tap:|\.postToPid\(|CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition|CGEventSource\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "Swift builds a CGEvent itself in {files} — synthesis, field-setting, the warp and the \
                      post are slopdesk-apple-cgevent's, orchestrated once in the injector module, and a \
                      second copy anywhere is where the click-state rule and the untagged-keyboard rule \
                      drift apart. No Swift target injects any more (docs/57 §5, docs/61)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"fn clamp_to_i32|fn scaled_scroll_delta",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon keeps its own narrowing in {files} — clamp_to_i32 and the scroll resampler \
                      are slopdesk_video's, and a second copy on a path that parses hostile datagrams is \
                      the trapping conversion coming back under a new name (docs/57 §5)",
        },
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["slopdesk_video::injector_gates"],
            message: "the daemon stopped asking {entry} — which keys the injector gates, and at what \
                      resample rate, is resolved once from the overlay and read the same way by the \
                      settings face; a daemon that resolved it itself would answer the same question twice \
                      with nothing comparing the two (docs/61 §3)",
        },
    ])
}

/// The host decodes no window record of its own
///
/// `CGWindowListCopyWindowInfo` answers a `CFArray` of `CFDictionary`, and reading one is a decode:
/// eight optional fields, each of which can be absent or of the wrong type. Four Swift call sites
/// wrote that decode independently and DISAGREED about what absence means — one defaulted
/// `kCGWindowLayer` to `Int.min`, another to `-1`, a third dropped the record, and the fourth read
/// a missing owner pid as `-1` and went on to compare it. `rust/slopdesk-apple-cgwindow` decodes
/// once and drops an incomplete record, which is the only one of the four answers that cannot elect
/// a frontmost app or move a window on a malformed record.
///
/// The display half is the same shape: three call sites ran the same two-call enumeration by hand,
/// two sizing from a counting call and one hard-coding sixteen — a silent truncation at seventeen
/// displays, which is absurd until it is a mirrored wall.
///
/// The frozen frontmost is a third failure with the same cause. `NSWorkspace.frontmostApplication`
/// in a daemon that pumps no `AppKit` run loop populates on first access and then never updates, so
/// the read answers the launching app for the process's whole life. `HostFrontmostApp` elects from
/// the window list instead, and nothing in the host may go back.
///
/// ## The last exemption is gone, and the ban is now TOTAL
/// The feed enumeration used to be the ONE file allowed its own record build: it needed three
/// `AppKit` reads per pid that no CoreGraphics door could answer, so the Swift glue was named here
/// rather than left to a grep that happens to miss it. `docs/61` moved the feed into
/// `rust/slopdesk-videohostd`, where the three reads are the `slopdesk-apple-*` family's, and the
/// exemption went with the file it named. Removing it is the point rather than housekeeping: an
/// exemption that outlives its file is a hole any new file can be named into, and the four-way
/// decode drift this rule exists for is exactly what walks through such a hole.
///
/// ## What was DROPPED, and where the protection went
/// Seven claims are gone: the two `Exists` on the shim's `cgwindow` and `cgdisplay` modules, the
/// two header claims gating `slopdesk_cgwindow_frontmost_pid` and `slopdesk_cgdisplay_list`, and
/// the three manifest claims gating the `cgwindow`, `cgdisplay` and `sck` edges. Every one of them
/// named a door or an edge that existed ONLY for the deleted Swift host, and `docs/61` deletes them
/// in the same change. Re-aiming any of them would have pinned a symbol on its way out and made the
/// deletion read as a regression.
///
/// What they protected survives in a stronger form. Their subject was "the `WindowServer` decode
/// happens once"; the daemon now reaches `slopdesk-apple-cgwindow` and `slopdesk-apple-cgdisplay`
/// as ordinary Rust dependencies, with no C door in between to gate — so the claim that it still
/// does is a `MentionsUnder` over the daemon, which is a check the door-shaped claims could never
/// make. The bijection they guarded is `slopdesk-gate ffi`'s for the doors that remain, and the
/// `Exists` claims on the two apple crates are untouched: those are the homes.
///
/// BREAK-TEST: added `CGWindowListCopyWindowInfo` to a live client file ⇒ FAIL "decode a window
/// record themselves". Separately added `NSWorkspace.shared.frontmostApplication` to one ⇒ FAIL
/// "read a frozen frontmost". Separately deleted the cgwindow crate ⇒ FAIL "has no Rust behind it".
/// Separately dropped the daemon's `slopdesk_apple_cgwindow` calls ⇒ FAIL "stopped asking". All
/// four restored from /tmp; PASS.
#[must_use]
pub fn the_host_decodes_no_window_record(tree: &Tree) -> Report {
    /// The crates this port stands on. The shim's two modules are NOT here — see the note above.
    const REQUIRED: &[&str] = &[
        "rust/slopdesk-apple-cgwindow/src/list.rs",
        "rust/slopdesk-apple-cgdisplay/src/displays.rs",
    ];

    let mut report = Report::new();
    for required in REQUIRED {
        report.absorb(check_all(tree, &[Claim::Exists {
            path: required,
            message: "the host has no Rust behind its window reads — the WindowServer decode lives in one \
                      place (docs/57 §5, docs/56 increment 85)",
        }]));
    }
    report.absorb(check_all(
        tree,
        &[
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: "CGWindowListCopyWindowInfo|CGGetActiveDisplayList|CGGetOnlineDisplayList|CGGetDisplaysWithPoint",
                all: &[],
                unless: &[],
                view: View::Code,
                // No exemption, and that is the change docs/61 bought: the feed glue that held the
                // only one was deleted with its target, so the ban is total.
                exempt: &[],
                message: "these decode a window record themselves: {files} — the CGWindowList and \
                          display-list reads are slopdesk-apple-cgwindow's and \
                          slopdesk-apple-cgdisplay's, asked from rust/slopdesk-videohostd, and a second \
                          decode is where 'a missing field means Int.min' comes back (docs/57 §5, \
                          docs/61 §3)",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"NSWorkspace\.shared\.frontmostApplication|NSWorkspace\.shared\.menuBarOwningApplication",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "these read a frozen frontmost: {files} — NSWorkspace's snapshot populates \
                          on first access and then never updates in a daemon that pumps no AppKit \
                          run loop, so the read answers the launching app for the process's whole \
                          life. HostFrontmostApp elects from the window list (docs/57 §5)",
            },
            Claim::MentionsUnder {
                root: DAEMON,
                names: &["slopdesk_apple_cgwindow", "slopdesk_apple_cgdisplay"],
                message: "the daemon stopped calling {entry} — the window and display reads it makes on \
                          every geometry poll, every park and every mint go through the one crate that \
                          decodes a record; a daemon that stopped asking either is one that started \
                          reading CoreGraphics some other way (docs/57 §5, docs/61 §3)",
            },
        ],
    ));
    report
}

/// The host decides no capture region of its own
///
/// DIALOG-EXPAND's math — the union with an attached panel, the individual content rects, the
/// per-edge hysteresis gate, the expand/contract/hold verdict — and the resize path's display pick
/// were `CaptureRegionMath` and `WindowDisplayResolver`, two Swift enums whose every operation was
/// `CGRect` algebra. `golden/golden_vectors.json` pinned 23 of their outputs as raw `f64` bit
/// patterns and, for a long time, NOTHING replayed them: the generator's own comment claimed a Rust
/// `slopdesk_core` crate and a `golden_parity` test validated them, and neither had ever existed.
///
/// They live in `slopdesk_video::capture_region` and `::window_list` now, over a `CGRect` algebra
/// read off CoreGraphics by probe — an edge touch intersects at the seam, a NaN coordinate resolves
/// to the other rect, an empty rect still contributes its corner to a union — and the 23 vectors
/// are replayed by the Rust integration suite, which `golden-check.sh` independently requires to
/// exist.
///
/// ## What was DROPPED, and where the protection went
/// The doors were PORTABLE, and that arm used to be the MIRROR of the two rules above rather than a
/// copy of them: these decide rather than read, so a declaration inside the MACOS-ONLY region would
/// drop them from the iOS slices for no reason and hide that they are pure. Eight claims stated it
/// — two `Exists` on the shim's `capture_region` and `window_list` modules, and a
/// `Matches`/`LacksWithin` pair per decider — and all eight are gone, because all eight named C
/// doors whose only caller was the deleted Swift host. `docs/61` deletes them in this same change,
/// so keeping any of the eight would pin a symbol on its way out.
///
/// The MIRROR argument itself is not lost, only relocated: the deciders are pure Rust functions the
/// daemon calls in-process now, so "do not gate a pure decider behind macOS" is not a property
/// anyone can get wrong any more — there is no gate to put them behind. What CAN still go wrong is
/// a second copy of the algebra, and that is what survives: the `Exists` floor on the rules module,
/// the tree-wide Swift ban, and a new `MentionsUnder` proving the daemon still ASKS. The 23 golden
/// vectors are replayed by the Rust integration suite either way, which `golden-check.sh`
/// independently requires to exist.
///
/// BREAK-TEST: reintroduced `enum CaptureRegionMath` in a live client file ⇒ FAIL "decide a capture
/// region themselves". Separately deleted `rust/slopdesk-video/src/capture_region.rs` ⇒ FAIL "has
/// no Rust behind its capture region". Separately dropped the daemon's `capture_region` ask ⇒ FAIL
/// "stopped asking". All three restored from /tmp; PASS.
#[must_use]
pub fn the_host_decides_no_capture_region(tree: &Tree) -> Report {
    /// The rules the 23 golden vectors are replayed against. The shim's two modules are NOT here —
    /// see the note above.
    const REQUIRED: &[&str] = &[
        "rust/slopdesk-video/src/capture_region.rs",
        "rust/slopdesk-video/src/window_list.rs",
    ];

    let mut report = Report::new();
    for required in REQUIRED {
        report.absorb(check_all(tree, &[Claim::Exists {
            path: required,
            message: "the host has no Rust behind its capture region — the 23 golden-pinned union and \
                      retarget vectors are replayed against it (docs/56 increment 86)",
        }]));
    }
    report.absorb(check_all(
        tree,
        &[
            Claim::NoneUnder {
                roots: &["Sources", "Tests"],
                extensions: SWIFT,
                pattern: r"enum CaptureRegionMath|enum WindowDisplayResolver|CaptureRegionMath\.|WindowDisplayResolver\.",
                all: &[],
                unless: &[],
                view: View::Code,
                exempt: &[],
                message: "these decide a capture region themselves: {files} — the union, the content \
                          rects, the hysteresis gate and the display pick are \
                          slopdesk_video::capture_region's and ::window_list's, and a second copy is a \
                          predicate that drifts one ulp under a green suite (docs/56 increment 86)",
            },
            Claim::MentionsUnder {
                root: DAEMON,
                names: &[
                    "slopdesk_video::capture_region",
                    "slopdesk_video::window_list",
                ],
                message: "the daemon stopped asking {entry} — the union with an attached panel, the \
                          per-edge hysteresis gate and the display pick are golden-pinned as raw f64 bit \
                          patterns, and a daemon that answers any of them itself is the 23 vectors going \
                          unreplayed on the one path that uses them (docs/56 increment 86, docs/61 §3)",
            },
        ],
    ));
    report
}

/// The frameworks the hostd port moved, and the ONE directory each is allowed to be named in.
///
/// A pair per framework: the Rust file that wraps it, and the token no Rust outside
/// `rust/slopdesk-apple-*` may spell. The token is the framework's own entry point rather than a
/// crate name, because what this pins is not "the wrapper is depended on" — a Cargo edge already
/// says that — but "the CALL happens in one place".
///
/// Three rows arrived with stage E and the fourth with stage F. The list is keyed on the FRAMEWORK
/// rather than on the stage for exactly that reason: a stage is when a row landed, and what the
/// rule asserts is a property that does not expire when the next one starts.
const AREA_FLOORS: &[(&str, &str)] = &[
    ("rust/slopdesk-apple-fsevents/src/watch.rs", r"FSEventStream[A-Z]"),
    (
        "rust/slopdesk-apple-pasteboard/src/board.rs",
        r"NSPasteboard(Type)?::|NSPasteboard\b",
    ),
    ("rust/slopdesk-apple-app/src/lib.rs", r"NSWorkspace::"),
    ("rust/slopdesk-apple-machine/src/lib.rs", r"NSHost\b"),
    (
        "rust/slopdesk-apple-cgvirtualdisplay/src/classes.rs",
        r"CGVirtualDisplay(Descriptor|Settings|Mode)?\b",
    ),
];

/// The clang-module shim that used to make the private classes reachable.
///
/// TWO files rather than one because a shim is a pair: the header that class-dumped the four
/// interfaces, and the `.m` that forced them to link. Naming both is what makes "the shim is gone"
/// checkable — the header alone could come back under a different name, and the `.m` alone links
/// nothing, so either one restored is the target coming back.
///
/// When this was written, the Swift `VirtualDisplay` was deliberately NOT in this list, because it
/// still existed and still owned the handle's lifetime and the trampoline — only the private
/// classes had left it. `docs/61` then deleted the whole target, and the handle's lifetime is
/// `rust/slopdesk-videohostd/src/vdisplay.rs`'s. The list did not grow a row for it, and that is
/// the right answer twice over: [`crate::rules::deleted_video_swift`] bans the DIRECTORY it lived
/// in, which no filename dodge can satisfy, and what this constant is for is narrower — a SHIM is a
/// pair of files, and naming both is what makes "the shim is gone" checkable.
const DELETED_VIRTUAL_DISPLAY_SHIM: &[&str] = &[
    "Sources/CSlopDeskVirtualDisplay/include/CGVirtualDisplayPrivate.h",
    "Sources/CSlopDeskVirtualDisplay/shim.m",
];

/// The host reaches `FSEvents`, the pasteboard, Launch Services and `NSHost` from ONE crate each
///
/// `docs/60` §7 says stage E adds a row here per new crate, the way `slopdesk-apple-power` did. It
/// is a different SHAPE from the three rules above and deliberately so: those pin that the Swift
/// stopped doing the work, and under `docs/60` §5's carve-out no Swift is deleted before stage F —
/// hostd is a Swift process until the cutover, and `RepoStatusWatcher`, `HostClipboardPerformer`
/// and `HostPathActionPerformer` are still running. Asserting they had stopped would be false.
///
/// What IS true today, and is the property the family exists for, is that the RUST side has one
/// home per framework. `docs/57` §2 gives a crate one framework area; the failure that rule guards
/// against is a second Rust file reaching the same API directly, which is how the four-way
/// `CGWindowList` decode drift above happened in the first place. So the ban runs over `rust/`,
/// exempts the `slopdesk-apple-*` family itself, and fires on a call outside it.
///
/// The reads are [`View::Code`] for the reason the file header gives: `crate::clipsync` and
/// `crate::pathaction` argue in PROSE about `NSPasteboard`'s permission model and `NSWorkspace`'s
/// snapshot freeze, and a gate that could not tell a call from a sentence about one would push
/// those arguments out of the files that need them.
///
/// The `CGVirtualDisplay` row is the one that carries a SWIFT side too, and for a reason the others
/// do not have. Those four frameworks are reached from Swift processes that still exist, so their
/// Swift was never deleted — but the four private `CGVirtualDisplay*` classes were not linked at
/// all: they were reached through a clang-module shim, a class-dumped header plus a `.m` that
/// forced the link. `objc2::runtime::AnyClass::get` answers an `Option`, which is the existence
/// GATE and the lookup in one call, so the shim had nothing left to do and the whole target went.
/// That makes two claims checkable here that the other rows cannot make: the shim's two files are
/// GONE, and no source under `Sources` names one of the four classes.
///
/// That deletion also fixed a live bug, which is the argument for keeping it deleted rather than
/// dormant: the class-dumped header declared `CGVirtualDisplayMode`'s width and height
/// `NSUInteger`, and the running class's own method signature says `unsigned int`. The shim passed
/// 64 bits into a 32-bit parameter in silence for as long as it existed; `objc2` verifies the
/// encoding on every send and refused on the first try.
///
/// BREAK-TEST: added `let board = NSPasteboard::generalPasteboard();` to
/// `rust/slopdesk-hostserver/src/clipsync.rs` ⇒ FAIL "reaches `NSPasteboard` directly". Separately
/// added `NSHost::currentHost()` to `rust/slopdesk-hostd/src/workspacestore.rs` ⇒ FAIL, naming
/// `slopdesk-apple-machine` as the home. Separately deleted
/// `rust/slopdesk-apple-fsevents/src/watch.rs` ⇒ FAIL "has no Rust behind it". Separately added
/// `let cls: AnyClass = CGVirtualDisplayDescriptor;` to `rust/slopdesk-videohostd/src/vdisplay.rs`
/// ⇒ FAIL, naming the cgvirtualdisplay crate as the home. Separately restored a one-line
/// `Sources/CSlopDeskVirtualDisplay/shim.m` ⇒ FAIL "the private-class shim is back". Separately
/// added `let d = CGVirtualDisplayDescriptor()` to a live Swift target — the handle's own file is
/// `rust/slopdesk-videohostd/src/vdisplay.rs` now, so the Swift ban has no host file left to fire
/// on and the seed goes wherever the class could next be named ⇒ FAIL "names a private
/// `CGVirtualDisplay` class". All six restored from /tmp; PASS.
#[must_use]
pub fn each_apple_area_has_one_rust_home(tree: &Tree) -> Report {
    let mut report = Report::new();
    for (home, _call) in AREA_FLOORS {
        report.fail_if(
            !tree.has(home),
            format!(
                "{home} is gone — a framework the hostd port moved has no Rust behind it (docs/60 stages E \
                 and F, docs/57 §2)",
            ),
        );
    }
    for gone in DELETED_VIRTUAL_DISPLAY_SHIM {
        report.absorb(check_all(tree, &[Claim::Absent {
            path: gone,
            message: "the private-class shim is back — the four CGVirtualDisplay* classes are reached by \
                      runtime lookup from rust/slopdesk-apple-cgvirtualdisplay, which needs no class-dumped \
                      header and no .m to force the link; the header it replaced also had the wrong integer \
                      width on CGVirtualDisplayMode (docs/57 §2, docs/60 §7)",
        }]));
    }
    report.absorb(check_all(tree, &[Claim::NoneUnder {
        roots: &["Sources"],
        extensions: SOURCES,
        pattern: r"CGVirtualDisplay(Descriptor|Settings|Mode)?\b",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "these name a private CGVirtualDisplay class: {files} — the classes are resolved once, by \
                  name, in rust/slopdesk-apple-cgvirtualdisplay/src/classes.rs, and a Swift or Objective-C \
                  spelling of one is the class-dumped shim coming back (docs/57 §2, docs/60 §7)",
    }]));

    let mut read_any = false;
    for (path, file) in tree.under("rust") {
        let Some(text) = path.to_str() else { continue };
        // The family itself is the home, and THIS crate is a gate: every rule table below names
        // these tokens as PATTERNS, in code rather than in prose, so a ban that read them would be
        // the one file it can never let pass.
        if path.extension().and_then(std::ffi::OsStr::to_str) != Some("rs")
            || text.starts_with("rust/slopdesk-apple-")
            || text.starts_with("rust/slopdesk-invariants/")
        {
            continue;
        }
        read_any = true;
        for (home, call) in AREA_FLOORS {
            report.fail_if(
                matches_line(file.code(), call),
                format!(
                    "{text} reaches /{call}/ directly — every Apple framework area has ONE Rust home and \
                     this one's is {home}; a second caller is how the four-way CGWindowList decode drift \
                     happened (docs/57 §2, docs/60 stages E and F)",
                ),
            );
        }
    }
    report.fail_if(
        !read_any,
        "no Rust outside the slopdesk-apple-* family was read — this ban would pass for the wrong reason",
    );
    report
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The crates all three rules stand on, plus the daemon that has to be ASKING them.
    ///
    /// The daemon half is not decoration. Every rule here now carries a [`Claim::MentionsUnder`],
    /// which refuses to pass on an EMPTY directory — so a fixture that seeded only the crates would
    /// go red for a reason no test was asking about, and the tempting repair is to weaken the
    /// claim. Seeding the asks is what keeps the "no vacuous pass" guard from reading as a bug.
    fn floors(fixture: &Fixture) {
        for path in [
            "rust/slopdesk-apple-cgevent/src/inject.rs",
            "rust/slopdesk-videohostd/src/injector.rs",
            "rust/slopdesk-apple-cgwindow/src/list.rs",
            "rust/slopdesk-apple-cgdisplay/src/displays.rs",
            "rust/slopdesk-video/src/capture_region.rs",
            "rust/slopdesk-video/src/window_list.rs",
        ] {
            fixture.write(path, "pub fn f() {}\n");
        }
        fixture
            .write(
                "rust/slopdesk-videohostd/src/main.rs",
                "use slopdesk_video::injector_gates::InjectorGates;\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/windowgeometry.rs",
                "use slopdesk_video::capture_region::WindowSnapshot;\nuse \
                 slopdesk_video::window_list::display_for_window_frame;\nfn poll(id: u32) {\n    let _ = \
                 slopdesk_apple_cgwindow::bounds_of(id, None);\n    let _ = \
                 slopdesk_apple_cgdisplay::under(point);\n}\n",
            );
    }

    /// A `CGEvent` built in a LIVE Swift target, which is the drift the old per-file ban could not
    /// see. The host file it named is deleted, so the only way this comes back is somewhere nobody
    /// was watching — the client, a device panel, a test helper.
    #[test]
    fn swift_that_builds_an_event_is_red() {
        let fixture = Fixture::new("apple-inject");
        floors(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/VideoClientSessionLogic.swift",
            "// The suppression interval is why the host calls CGEvent(mouseEventSource:) once.\nlet plan = \
             1\n",
        );
        // The prose still names the call, and must — the measurements that decided the modifier
        // protocol live there. A gate that read comments would force them out of the file.
        assert!(super::the_host_synthesises_no_event(&fixture.tree()).is_clean());

        for call in [
            "let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown)\n",
            "event.setIntegerValueField(.mouseEventClickState, value: 2)\n",
            "event.post(tap: .cghidEventTap)\n",
            "CGWarpMouseCursorPosition(point)\n",
            "let src = CGEventSource(stateID: .hidSystemState)\n",
        ] {
            let fixture = Fixture::new("apple-inject-revived");
            floors(&fixture);
            fixture.write("Sources/SlopDeskVideoClient/InputRelay.swift", call);
            let report = super::the_host_synthesises_no_event(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("InputRelay")),
                "{call:?} was not caught: {report:?}"
            );
        }
    }

    /// The narrowing, re-aimed to the daemon. It cannot be banned across Swift:
    /// `SlopDeskDevicePanels` declares its own `clampToInt32` twice, for the Android and shared
    /// panel geometries, so a tree-wide ban would fire on the tree it ships with.
    #[test]
    fn a_daemon_that_keeps_its_own_narrowing_is_red() {
        for line in [
            "fn clamp_to_i32(v: f64) -> i32 { 0 }\n",
            "fn scaled_scroll_delta(v: f64) -> i32 { 0 }\n",
        ] {
            let fixture = Fixture::new("apple-narrowing");
            floors(&fixture);
            fixture.append("rust/slopdesk-videohostd/src/main.rs", line);
            let report = super::the_host_synthesises_no_event(&fixture.tree());
            assert!(
                report.violations().iter().any(|v| v.contains("own narrowing")),
                "{line:?} was not caught: {report:?}"
            );
        }
    }

    /// A window decode in a live target. There is no exemption left to hide behind: the feed glue
    /// that held the only one was deleted with its target, so the ban is total.
    #[test]
    fn a_second_window_decode_is_red() {
        let fixture = Fixture::new("apple-window");
        floors(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/WindowGeometryRelay.swift",
            "// The feed needs three AppKit reads per pid that no door can answer.\nlet ordinary = 1\n",
        );
        assert!(super::the_host_decodes_no_window_record(&fixture.tree()).is_clean());

        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Video/WindowGeometryRelay.swift",
            "let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)\n",
        );
        let found = super::the_host_decodes_no_window_record(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("WindowGeometryRelay")),
            "{found:?}"
        );
    }

    #[test]
    fn a_frozen_frontmost_read_is_red() {
        // Its own fixture: the daemon's snapshot never updates, so the read answers the launching
        // app for the process's whole life.
        let fixture = Fixture::new("apple-frontmost");
        floors(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/FrontmostRelay.swift",
            "let app = NSWorkspace.shared.frontmostApplication\n",
        );
        assert!(!super::the_host_decodes_no_window_record(&fixture.tree()).is_clean());
    }

    /// The drift the door-shaped claims never could see: the daemon stops asking, inlines the
    /// answer, and every suite stays green because the two copies agree until one is edited.
    #[test]
    fn a_daemon_that_stopped_asking_is_red() {
        for (name, ask) in [
            ("cgwindow", "slopdesk_apple_cgwindow"),
            ("cgdisplay", "slopdesk_apple_cgdisplay"),
            ("region", "slopdesk_video::capture_region"),
            ("list", "slopdesk_video::window_list"),
            ("gates", "slopdesk_video::injector_gates"),
        ] {
            let fixture = Fixture::new(&format!("apple-stopped-asking-{name}"));
            floors(&fixture);
            for path in [
                "rust/slopdesk-videohostd/src/main.rs",
                "rust/slopdesk-videohostd/src/windowgeometry.rs",
            ] {
                let text = fixture.tree().read(path).unwrap_or_default();
                let kept = text
                    .lines()
                    .filter(|line| !line.contains(ask))
                    .collect::<Vec<_>>()
                    .join("\n");
                fixture.write(path, &format!("{kept}\n"));
            }
            let reports = [
                super::the_host_synthesises_no_event(&fixture.tree()),
                super::the_host_decodes_no_window_record(&fixture.tree()),
                super::the_host_decides_no_capture_region(&fixture.tree()),
            ];
            assert!(
                reports
                    .iter()
                    .any(|r| r.violations().iter().any(|v| v.contains(ask))),
                "{ask} could be dropped with nothing red: {reports:?}"
            );
        }
    }

    /// A drained daemon cannot satisfy any of the three asks — the one failure mode a
    /// "the daemon still calls X" claim has, and why the claim refuses an empty root.
    #[test]
    fn a_drained_daemon_cannot_satisfy_the_ask() {
        let fixture = Fixture::new("apple-daemon-drained");
        for path in [
            "rust/slopdesk-apple-cgevent/src/inject.rs",
            "rust/slopdesk-videohostd/src/injector.rs",
            "rust/slopdesk-apple-cgwindow/src/list.rs",
            "rust/slopdesk-apple-cgdisplay/src/displays.rs",
            "rust/slopdesk-video/src/capture_region.rs",
            "rust/slopdesk-video/src/window_list.rs",
        ] {
            fixture.write(path, "pub fn f() {}\n");
        }
        assert!(!super::the_host_synthesises_no_event(&fixture.tree()).is_clean());
        assert!(!super::the_host_decodes_no_window_record(&fixture.tree()).is_clean());
        assert!(!super::the_host_decides_no_capture_region(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_swift_capture_decider_is_red() {
        // Its own fixture: a second copy of a predicate that drifts one ulp under a green suite.
        let fixture = Fixture::new("apple-region-swift");
        floors(&fixture);
        assert!(super::the_host_decides_no_capture_region(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/RegionRelay.swift",
            "enum CaptureRegionMath { static func union(_ a: CGRect, _ b: CGRect) -> CGRect { a } }\n",
        );
        assert!(!super::the_host_decides_no_capture_region(&fixture.tree()).is_clean());
    }

    /// The rules module the 23 golden vectors are replayed against is a FLOOR: delete it and the
    /// vectors have nothing to replay, with the Swift ban above still perfectly green.
    #[test]
    fn a_deleted_capture_region_module_is_red() {
        let fixture = Fixture::new("apple-region-deleted");
        floors(&fixture);
        fixture.remove("rust/slopdesk-video/src/capture_region.rs");
        let report = super::the_host_decides_no_capture_region(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no Rust behind its capture region")),
            "{report:?}"
        );
    }

    /// Every home the port landed, plus one ordinary Rust file for the ban to read.
    fn homes(fixture: &Fixture) {
        for (home, _call) in super::AREA_FLOORS {
            fixture.write(home, "pub fn f() {}\n");
        }
        fixture.write("rust/slopdesk-hostserver/src/clipsync.rs", "pub fn f() {}\n");
    }

    #[test]
    fn one_rust_home_per_area_is_green_when_only_the_family_calls_the_frameworks() {
        let fixture = Fixture::new("apple-floors-stage-e-green");
        homes(&fixture);
        assert!(
            super::each_apple_area_has_one_rust_home(&fixture.tree())
                .violations()
                .is_empty(),
        );
    }

    #[test]
    fn a_second_caller_of_the_pasteboard_outside_the_family_is_red() {
        let fixture = Fixture::new("apple-floors-stage-e-second-caller");
        homes(&fixture);
        fixture.append(
            "rust/slopdesk-hostserver/src/clipsync.rs",
            "fn peek() { let _ = NSPasteboard::generalPasteboard(); }\n",
        );
        let report = super::each_apple_area_has_one_rust_home(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("clipsync.rs")),
            "{:?}",
            report.violations(),
        );
    }

    #[test]
    fn a_second_caller_of_fsevents_or_the_workspace_is_red_too() {
        for (name, line) in [
            ("fsevents", "fn w() { FSEventStreamCreate(); }\n"),
            ("workspace", "fn w() { NSWorkspace::sharedWorkspace(); }\n"),
            // The stage-F row. A label is the cheapest thing in the tree to re-derive by hand,
            // which is exactly why it needs the same floor as the expensive ones.
            ("machine", "fn w() { NSHost::currentHost(); }\n"),
        ] {
            let fixture = Fixture::new(&format!("apple-floors-stage-e-{name}"));
            homes(&fixture);
            fixture.append("rust/slopdesk-hostserver/src/clipsync.rs", line);
            assert!(
                !super::each_apple_area_has_one_rust_home(&fixture.tree())
                    .violations()
                    .is_empty(),
                "a second {name} caller has to be red",
            );
        }
    }

    #[test]
    fn a_framework_name_in_prose_outside_the_family_stays_green() {
        let fixture = Fixture::new("apple-floors-stage-e-prose");
        homes(&fixture);
        fixture.append(
            "rust/slopdesk-hostserver/src/clipsync.rs",
            "//! `NSPasteboard` declares several types per clip, and `NSWorkspace` freezes.\n",
        );
        assert!(
            super::each_apple_area_has_one_rust_home(&fixture.tree())
                .violations()
                .is_empty(),
            "the ban reads code — the argument for the design has to survive in the file",
        );
    }

    #[test]
    fn a_deleted_home_is_red() {
        let fixture = Fixture::new("apple-floors-stage-e-deleted");
        homes(&fixture);
        fixture.remove("rust/slopdesk-apple-fsevents/src/watch.rs");
        let report = super::each_apple_area_has_one_rust_home(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no Rust behind it")),
            "{:?}",
            report.violations(),
        );
    }
}
