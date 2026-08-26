//! The host synthesises, decodes and decides nothing of its own.
//!
//! Ported from the deleted `check-supervisor.sh`. Three ports out of Swift and into the `objc2`
//! family `docs/57` opens the unsafe gate for, and each is pinned the same way: the crate and the
//! door exist, the Swift no longer does the work beside them, and the macOS-only BIJECTION is
//! spelled in all three of its places.
//!
//! Every ban here reads [`View::Code`], and that is load-bearing rather than tidy. The files still
//! NAME these calls in prose, and should: the comments carry the hardware measurements that decided
//! the tablet path and the suppression interval, why the feed uses `CGWindowList` over
//! `SCShareableContent`, and why the probe walks displays out of process. A gate that could not
//! tell a call from a sentence about one would force that knowledge out of the file to stay green.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::text::matches_line;
use crate::tree::Tree;

/// The generated header both slices compile against.
const HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
/// The shim's manifest, where the macOS-only edges are gated.
const FFI_MANIFEST: &str = "rust/slopdesk-ffi/Cargo.toml";
/// The header's macOS-only region, as an `awk` range.
const MACOS_REGION: (&str, &str) = ("MACOS-ONLY BEGIN", "MACOS-ONLY END");
/// The manifest's macOS-gated dependency table.
///
/// Ended at the NEXT table header rather than a fixed window. This was `grep -A 12`, and the
/// twelfth line was reached the moment a crate arrived with a comment above it — the gate then
/// failed on a `Cargo.toml` that was perfectly gated, naming the wrong defect.
const MACOS_EDGES: (&str, &str) = (
    r#"^\[target\.'cfg\(target_os = "macos"\)'\.dependencies\]"#,
    r"^\[",
);
/// The orchestrator that used to build events.
const INJECTOR: &str = "Sources/SlopDeskVideoHost/InputInjector.swift";

/// The host synthesises no event of its own
///
/// Every injected `CGEvent` is built and posted by `rust/slopdesk-apple-cgevent`, the first crate
/// of the `objc2` family. `InputInjector` still ORCHESTRATES — it owns the bounds, the balance, the
/// resampler, the raise chain — but it no longer builds an event, sets a field on one, warps a
/// cursor or posts anything.
///
/// The line matters because the two languages fail differently here. Swift's `Int32(_:)` TRAPS on a
/// value off the wire; Rust's clamp saturates. Swift's `CGEvent` construction is nine call sites
/// that each had to remember the click-state rule, the untagged-keyboard rule and the suppression
/// interval; Rust's is one. A second `CGEvent` built in Swift would not be a duplicate
/// implementation in the abstract — it would be the specific bug each of those rules was written to
/// close.
///
/// The BIJECTION is three spellings — the `cfg`, the header region, the Cargo edge — and
/// `slopdesk-gate ffi` checks only the third leg, on all three slices. The first two are checked
/// here, because a header that declares an iOS-reachable CoreGraphics door fails at LINK, far from
/// here.
///
/// BREAK-TEST: restored `CGEvent(mouseEventSource:` in `InputInjector` ⇒ FAIL "builds a `CGEvent`
/// itself". Separately restored `static func clampToInt32` there ⇒ FAIL "keeps its own narrowing".
/// Separately deleted the Rust crate ⇒ FAIL "has no Rust behind it". Separately moved the inject
/// declarations out of the MACOS-ONLY region ⇒ FAIL "declares a CoreGraphics door outside the
/// macOS-only region". Separately ungated the Cargo edge ⇒ FAIL "is not target-gated". All five
/// restored from /tmp; PASS.
#[must_use]
pub fn the_host_synthesises_no_event(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Exists {
            path: "rust/slopdesk-apple-cgevent/src/inject.rs",
            message: "InputInjector has no Rust behind it — the host synthesises no event of its own \
                      (docs/57 §5, docs/56 increment 84)",
        },
        Claim::Exists {
            path: "rust/slopdesk-ffi/src/inject.rs",
            message: "InputInjector has no door behind it — the host synthesises no event of its own \
                      (docs/57 §5, docs/56 increment 84)",
        },
        Claim::Lacks {
            path: INJECTOR,
            pattern: r"CGEvent\(|\.setIntegerValueField|\.post\(tap:|\.postToPid\(|CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition|CGEventSource\(",
            view: View::Code,
            message: "InputInjector builds a CGEvent itself — synthesis, field-setting, the warp and the \
                      post are slopdesk-apple-cgevent's, and a second copy here is where the click-state \
                      rule and the untagged-keyboard rule drift apart (docs/57 §5)",
        },
        Claim::Lacks {
            path: INJECTOR,
            pattern: r"func (clampToInt32|scaledScrollDelta)",
            view: View::Code,
            message: "InputInjector keeps its own narrowing — clamp_to_i32 is slopdesk-video's, and a Swift \
                      copy is the trapping Int32(_:) coming back under a new name on a path that parses \
                      hostile datagrams (docs/57 §5)",
        },
        Claim::Within {
            path: HEADER,
            start: MACOS_REGION.0,
            end: MACOS_REGION.1,
            pattern: r"slopdesk_inject_pointer\(",
            view: View::Raw,
            message: "slopdesk_ffi.h declares a CoreGraphics door outside the macOS-only region — iOS has \
                      no CGEvent at all, so an ungated declaration is not a wasted byte, it is a link \
                      failure on two of the three slices (docs/57 §3)",
        },
        Claim::Within {
            path: FFI_MANIFEST,
            start: MACOS_EDGES.0,
            end: MACOS_EDGES.1,
            pattern: "slopdesk-apple-cgevent",
            view: View::Code,
            message: "rust/slopdesk-ffi/Cargo.toml: the slopdesk-apple-cgevent edge is not target-gated — \
                      the macOS-only bijection is three spellings (the cfg, the header region, the Cargo \
                      edge) and slopdesk-gate ffi only checks what the library exports (docs/57 §3)",
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
/// The feed enumeration is the ONE file still allowed its own record build: it needs three `AppKit`
/// reads per pid that no CoreGraphics door can answer, and moving it is increment 86's job. It is
/// named here so the exemption is a decision on the record rather than a grep that happens to miss
/// it.
///
/// BREAK-TEST: restored `CGWindowListCopyWindowInfo` in `WindowGeometryWatcher` ⇒ FAIL "decode a
/// window record themselves". Separately restored `NSWorkspace.shared.frontmostApplication` in
/// `WindowFeedGlue` ⇒ FAIL "read a frozen frontmost". Separately deleted the cgwindow crate ⇒ FAIL
/// "has no Rust behind it". Separately moved the declarations out of the MACOS-ONLY region ⇒ FAIL
/// "declares a `WindowServer` door outside the macOS-only region". Separately ungated a Cargo edge
/// ⇒ FAIL "is not target-gated". All five restored from /tmp; PASS.
#[must_use]
pub fn the_host_decodes_no_window_record(tree: &Tree) -> Report {
    /// The crates and doors this port stands on.
    const REQUIRED: &[&str] = &[
        "rust/slopdesk-apple-cgwindow/src/list.rs",
        "rust/slopdesk-apple-cgdisplay/src/displays.rs",
        "rust/slopdesk-ffi/src/cgwindow.rs",
        "rust/slopdesk-ffi/src/cgdisplay.rs",
    ];
    /// The doors that must sit inside the header's macOS-only region.
    const GATED_DOORS: &[&str] = &[r"slopdesk_cgwindow_frontmost_pid\(", r"slopdesk_cgdisplay_list\("];
    /// The crate edges that must be target-gated in the shim's manifest.
    const GATED_EDGES: &[&str] = &[
        "slopdesk-apple-cgwindow",
        "slopdesk-apple-cgdisplay",
        "slopdesk-apple-sck",
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
                exempt: &[
                    "Sources/slopdesk-videohostd/WindowFeedGlue.swift",
                    "Sources/SlopDeskVideoHost/VirtualDisplay.swift",
                ],
                message: "these decode a window record themselves: {files} — the CGWindowList and \
                          display-list reads are slopdesk-apple-cgwindow's and \
                          slopdesk-apple-cgdisplay's, and a second decode is where 'a missing field \
                          means Int.min' comes back (docs/57 §5)",
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
        ],
    ));
    for door in GATED_DOORS {
        report.absorb(check_all(tree, &[Claim::Within {
            path: HEADER,
            start: MACOS_REGION.0,
            end: MACOS_REGION.1,
            pattern: door,
            view: View::Raw,
            message: "slopdesk_ffi.h declares a WindowServer door outside the macOS-only region — iOS has \
                      no WindowServer at all, so an ungated declaration is not a wasted byte, it is a link \
                      failure on two of the three slices (docs/57 §3)",
        }]));
    }
    for edge in GATED_EDGES {
        report.absorb(check_all(tree, &[Claim::Within {
            path: FFI_MANIFEST,
            start: MACOS_EDGES.0,
            end: MACOS_EDGES.1,
            pattern: edge,
            view: View::Code,
            message: "rust/slopdesk-ffi/Cargo.toml: an apple-family edge is not target-gated — the \
                      macOS-only bijection is three spellings (the cfg, the header region, the Cargo edge) \
                      and slopdesk-gate ffi only checks what the library exports (docs/57 §3)",
        }]));
    }
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
/// The doors are PORTABLE, and that arm is the MIRROR of the two rules above rather than a copy of
/// them: these decide rather than read, so a declaration inside the MACOS-ONLY region would drop
/// them from the iOS slices for no reason and hide that they are pure.
///
/// BREAK-TEST: reintroduced `enum CaptureRegionMath` in `WindowGeometryWatcher` ⇒ FAIL "decide a
/// capture region themselves". Separately deleted `rust/slopdesk-video/src/capture_region.rs` ⇒
/// FAIL "has no Rust behind its capture region". Separately moved `slopdesk_capture_union_region`
/// inside the MACOS-ONLY region ⇒ FAIL "declares a portable decider inside the macOS-only region".
/// All three restored from /tmp; PASS.
#[must_use]
pub fn the_host_decides_no_capture_region(tree: &Tree) -> Report {
    /// The rules and the doors over them.
    const REQUIRED: &[&str] = &[
        "rust/slopdesk-video/src/capture_region.rs",
        "rust/slopdesk-ffi/src/capture_region.rs",
        "rust/slopdesk-ffi/src/window_list.rs",
    ];
    /// The three deciders, which must be declared and must NOT be gated.
    const PORTABLE_DOORS: &[&str] = &[
        r"slopdesk_capture_union_region\(",
        r"slopdesk_capture_region_decision\(",
        r"slopdesk_window_display_for_frame\(",
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
        &[Claim::NoneUnder {
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
        }],
    ));
    for door in PORTABLE_DOORS {
        report.absorb(check_all(tree, &[
            Claim::Matches {
                path: HEADER,
                pattern: door,
                view: View::Raw,
                message: "slopdesk_ffi.h does not declare a capture decider the Swift face calls — a \
                          missing declaration is a link failure the moment anyone rebuilds (docs/55 §3)",
            },
            Claim::LacksWithin {
                path: HEADER,
                start: MACOS_REGION.0,
                end: MACOS_REGION.1,
                pattern: door,
                view: View::Raw,
                message: "slopdesk_ffi.h declares a portable decider inside the macOS-only region — it \
                          reads no WindowServer and its answers are golden-pinned on every slice, so gating \
                          it hides that it is pure and costs the iOS slices a door for nothing (docs/57 §3)",
            },
        ]));
    }
    report
}

/// The three frameworks stage E moved, and the ONE directory each is allowed to be named in.
///
/// A pair per framework: the Rust file that wraps it, and the token no Rust outside
/// `rust/slopdesk-apple-*` may spell. The token is the framework's own entry point rather than a
/// crate name, because what this pins is not "the wrapper is depended on" — a Cargo edge already
/// says that — but "the CALL happens in one place".
const STAGE_E_FLOORS: &[(&str, &str)] = &[
    ("rust/slopdesk-apple-fsevents/src/watch.rs", r"FSEventStream[A-Z]"),
    (
        "rust/slopdesk-apple-pasteboard/src/board.rs",
        r"NSPasteboard(Type)?::|NSPasteboard\b",
    ),
    ("rust/slopdesk-apple-app/src/lib.rs", r"NSWorkspace::"),
];

/// The host reaches `FSEvents`, the pasteboard and Launch Services from ONE crate each
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
/// BREAK-TEST: added `let board = NSPasteboard::generalPasteboard();` to
/// `rust/slopdesk-hostserver/src/clipsync.rs` ⇒ FAIL "reaches `NSPasteboard` directly". Separately
/// deleted `rust/slopdesk-apple-fsevents/src/watch.rs` ⇒ FAIL "has no Rust behind it". Both
/// restored from /tmp; PASS.
#[must_use]
pub fn each_apple_area_has_one_rust_home(tree: &Tree) -> Report {
    let mut report = Report::new();
    for (home, _call) in STAGE_E_FLOORS {
        report.fail_if(
            !tree.has(home),
            format!(
                "{home} is gone — a framework stage E moved has no Rust behind it (docs/60 stage E, docs/57 \
                 §2)",
            ),
        );
    }

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
        for (home, call) in STAGE_E_FLOORS {
            report.fail_if(
                matches_line(file.code(), call),
                format!(
                    "{text} reaches /{call}/ directly — every Apple framework area has ONE Rust home and \
                     this one's is {home}; a second caller is how the four-way CGWindowList decode drift \
                     happened (docs/57 §2, docs/60 stage E)",
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

    /// The crates and doors all three rules stand on, plus a header and a manifest.
    fn floors(fixture: &Fixture, header: &str, injector: &str) {
        for path in [
            "rust/slopdesk-apple-cgevent/src/inject.rs",
            "rust/slopdesk-ffi/src/inject.rs",
            "rust/slopdesk-apple-cgwindow/src/list.rs",
            "rust/slopdesk-apple-cgdisplay/src/displays.rs",
            "rust/slopdesk-ffi/src/cgwindow.rs",
            "rust/slopdesk-ffi/src/cgdisplay.rs",
            "rust/slopdesk-video/src/capture_region.rs",
            "rust/slopdesk-ffi/src/capture_region.rs",
            "rust/slopdesk-ffi/src/window_list.rs",
        ] {
            fixture.write(path, "pub fn f() {}\n");
        }
        fixture
            .write(super::HEADER, header)
            .write(
                super::FFI_MANIFEST,
                "[dependencies]\nslopdesk-wire = { path = \"../slopdesk-wire\" }\n\n[target.'cfg(target_os \
                 = \"macos\")'.dependencies]\nslopdesk-apple-cgevent = { path = \
                 \"../slopdesk-apple-cgevent\" }\nslopdesk-apple-cgdisplay = { path = \
                 \"../slopdesk-apple-cgdisplay\" }\nslopdesk-apple-sck = { path = \"../slopdesk-apple-sck\" \
                 }\nslopdesk-apple-cgwindow = { path = \"../slopdesk-apple-cgwindow\" \
                 }\n\n[profile.release]\nopt-level = 3\n",
            )
            .write(super::INJECTOR, injector);
    }

    /// A header with the gated doors inside the region and the portable deciders outside it.
    fn header(gated: &str, portable: &str) -> String {
        format!(
            "void slopdesk_free(void *p);\n{portable}\n// MACOS-ONLY BEGIN\n{gated}\n// MACOS-ONLY \
             END\nvoid slopdesk_wire_decode(const uint8_t *p, size_t n);\n"
        )
    }

    /// Every door, in the place it belongs.
    fn placed() -> String {
        header(
            "void slopdesk_inject_pointer(int32_t x, int32_t y);\nint32_t \
             slopdesk_cgwindow_frontmost_pid(void);\nsize_t slopdesk_cgdisplay_list(uint32_t *out, size_t \
             cap);",
            "bool slopdesk_capture_union_region(const double *a, double *out);\nbool \
             slopdesk_capture_region_decision(const double *a, double *out);\nbool \
             slopdesk_window_display_for_frame(const double *a, uint32_t *out);",
        )
    }

    #[test]
    fn an_injector_that_builds_an_event_is_red() {
        let fixture = Fixture::new("apple-inject");
        floors(
            &fixture,
            &placed(),
            "// The suppression interval is why this used to call CGEvent(mouseEventSource:).\nlet plan = \
             slopdesk_inject_pointer(x, y)\n",
        );
        // The prose still names the call, and must — the measurements that decided the tablet path
        // live there. A gate that read comments would force them out of the file.
        assert!(super::the_host_synthesises_no_event(&fixture.tree()).is_clean());

        floors(
            &fixture,
            &placed(),
            "let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown)\n",
        );
        assert!(!super::the_host_synthesises_no_event(&fixture.tree()).is_clean());

        // The trapping Int32(_:) coming back under a new name, on a path that parses hostile
        // datagrams.
        floors(
            &fixture,
            &placed(),
            "static func clampToInt32(_ v: Double) -> Int32 { 0 }\n",
        );
        assert!(!super::the_host_synthesises_no_event(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_ungated_coregraphics_door_is_red() {
        // Its own fixture, because writes accumulate and this case moves a declaration.
        let fixture = Fixture::new("apple-region");
        let ungated = header(
            "int32_t slopdesk_cgwindow_frontmost_pid(void);\nsize_t slopdesk_cgdisplay_list(uint32_t *out, \
             size_t cap);",
            "void slopdesk_inject_pointer(int32_t x, int32_t y);\nbool slopdesk_capture_union_region(const \
             double *a, double *out);\nbool slopdesk_capture_region_decision(const double *a, double \
             *out);\nbool slopdesk_window_display_for_frame(const double *a, uint32_t *out);",
        );
        floors(&fixture, &ungated, "let plan = slopdesk_inject_pointer(x, y)\n");
        assert!(!super::the_host_synthesises_no_event(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_window_decode_is_red() {
        let fixture = Fixture::new("apple-window");
        floors(&fixture, &placed(), "let plan = slopdesk_inject_pointer(x, y)\n");
        fixture.write(
            "Sources/slopdesk-videohostd/WindowFeedGlue.swift",
            "// The feed needs three AppKit reads per pid that no door can answer.\nlet info = \
             CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)\n",
        );
        // The ONE exemption, named so it is a decision on the record.
        assert!(super::the_host_decodes_no_window_record(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskVideoHost/WindowGeometryWatcher.swift",
            "let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)\n",
        );
        let found = super::the_host_decodes_no_window_record(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("WindowGeometryWatcher"))
        );
    }

    #[test]
    fn a_frozen_frontmost_read_is_red() {
        // Its own fixture: the daemon's snapshot never updates, so the read answers the launching
        // app for the process's whole life.
        let fixture = Fixture::new("apple-frontmost");
        floors(&fixture, &placed(), "let plan = slopdesk_inject_pointer(x, y)\n");
        fixture.write(
            "Sources/slopdesk-videohostd/WindowFeedGlue.swift",
            "let app = NSWorkspace.shared.frontmostApplication\n",
        );
        assert!(!super::the_host_decodes_no_window_record(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_gated_portable_decider_is_red() {
        let fixture = Fixture::new("apple-region-portable");
        floors(&fixture, &placed(), "let plan = slopdesk_inject_pointer(x, y)\n");
        assert!(super::the_host_decides_no_capture_region(&fixture.tree()).is_clean());

        // Gating a pure decider costs the iOS slices a door for nothing, and hides that it is pure.
        floors(
            &fixture,
            &header(
                "void slopdesk_inject_pointer(int32_t x, int32_t y);\nint32_t \
                 slopdesk_cgwindow_frontmost_pid(void);\nsize_t slopdesk_cgdisplay_list(uint32_t *out, \
                 size_t cap);\nbool slopdesk_capture_union_region(const double *a, double *out);",
                "bool slopdesk_capture_region_decision(const double *a, double *out);\nbool \
                 slopdesk_window_display_for_frame(const double *a, uint32_t *out);",
            ),
            "let plan = slopdesk_inject_pointer(x, y)\n",
        );
        assert!(!super::the_host_decides_no_capture_region(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_swift_capture_decider_is_red() {
        // Its own fixture: a second copy of a predicate that drifts one ulp under a green suite.
        let fixture = Fixture::new("apple-region-swift");
        floors(&fixture, &placed(), "let plan = slopdesk_inject_pointer(x, y)\n");
        fixture.write(
            "Sources/SlopDeskVideoHost/WindowGeometryWatcher.swift",
            "enum CaptureRegionMath { static func union(_ a: CGRect, _ b: CGRect) -> CGRect { a } }\n",
        );
        assert!(!super::the_host_decides_no_capture_region(&fixture.tree()).is_clean());
    }

    /// The three homes stage E landed, plus one ordinary Rust file for the ban to read.
    fn homes(fixture: &Fixture) {
        for (home, _call) in super::STAGE_E_FLOORS {
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
