//! Which crates may write `unsafe`, and which lints every workspace must refuse.
//!
//! Ported from the deleted `check-supervisor.sh`. Both rules read MANIFESTS rather than source, and
//! for the same reason: rustc already enforces `unsafe_code = "forbid"` inside a crate that states
//! it, and clippy already enforces a lint level a crate configures. What neither can notice is the
//! POLICY drifting — a new crate that quietly says `deny` instead of `forbid`, or one that says
//! nothing and inherits nothing, or a workspace that never opted out of a lint whose only offered
//! fix breaks a repo invariant. Those are manifest facts, and a manifest is what this file reads.

use std::collections::BTreeSet;

use crate::report::Report;
use crate::tree::Tree;

const ROOT_MANIFEST: &str = "rust/Cargo.toml";

/// The three crates that may HAND-WRITE `unsafe`, each about one narrow obligation.
///
/// `slopdesk-posix` argues about syscalls; `slopdesk-ffi` argues about one thing repeated, whether
/// a `(ptr, len)` from Swift is live for the call; `slopdesk-gfsimd` argues about one thing
/// narrower still, whether a 16-byte load stays inside its chunk — which does not name a language
/// boundary at all. The third was bought with a MEASUREMENT rather than an argument
/// (`docs/DECISIONS.md`), and that is the bar a fourth would have to clear.
const HAND_WRITTEN: [&str; 3] = [
    "rust/slopdesk-posix/Cargo.toml",
    "rust/slopdesk-ffi/Cargo.toml",
    "rust/slopdesk-gfsimd/Cargo.toml",
];

/// One `slopdesk-apple-*` crate exempt from the raw-pointer ban, and what the exemption is worth.
///
/// A named pair rather than two parallel lists, so a crate cannot be admitted without a count and a
/// count cannot outlive the crate it was measured for. See [`apple_family`].
struct SampleMemory {
    /// The crate directory, without a trailing slash.
    crate_dir: &'static str,
    /// How many raw-pointer sites the exemption is worth TODAY.
    ///
    /// A RATCHET rather than a budget: it is what the crate needs EXACTLY, and it moves only in a
    /// commit that says what the new site is for. Slack here would be a budget to spend quietly,
    /// which is the thing a ratchet is not.
    cap: usize,
}

/// Every crate exempt from the raw-pointer ban, and there are two.
///
/// Each is here for the SAME reason and it is the SDK's, never the code's: the framework publishes
/// memory as a bare `(pointer, length)` and offers no copy-out variant, so there is no version of
/// the crate without a raw read. Neither is here because a raw pointer was convenient.
///
/// * `slopdesk-apple-audio` — Core Audio publishes SAMPLE MEMORY everywhere: the
///   `AudioConverterFillComplexBuffer` input proc exists to hand back an `AudioBufferList`,
///   `CMSampleBuffer` delivers captured audio the same way, and `AVAudioConverter`'s
///   `floatChannelData` is a `*mut NonNull<c_float>`. Its count is two slice constructions over a
///   captured buffer's runs, one flexible-array read of the buffer list, one copy of the stream
///   description, and the pointer arithmetic and slot writes the two converter callbacks are, on
///   both ends of the wire.
/// * `slopdesk-apple-vt` — TWO framework areas hand this crate memory rather than an object, and
///   its count is one site each way. HEVC parameter sets live in the FORMAT DESCRIPTION rather than
///   inline, and `CMVideoFormatDescriptionGetHEVCParameterSetAtIndex` is the only way to reach
///   them: it reports a pointer, and the SDK has no call that copies one into a caller's buffer —
///   that is `EncodedSample::copy_parameter_sets_into`. A LOCKED pixel buffer is the other:
///   `CVPixelBufferGetBaseAddressOfPlane` answers where a plane starts and `…GetBytesPerRowOfPlane`
///   how far apart its rows are, and a mapping is what those two describe — there is no plane
///   object to hold instead. Every other reading in the crate is a framework copy into memory this
///   process allocated.
///
/// `slopdesk-apple-vt` joined this list in the commit that deleted `Sources/SlopDeskVideoHost`, and
/// the timing is the whole argument. `docs/57` §2's three-route test rejects an exemption while the
/// "move the obligation to `slopdesk-ffi`" hatch is open, and for years it was: the encoder driver
/// lived in `slopdesk-ffi`, whose entire remit is that question. That hatch closed when the C doors
/// died — a shim crate is no longer the natural home for a driver no Swift calls — and the site had
/// to land somewhere a `forbid(unsafe_code)` daemon could reach. `docs/61` §2 is the ledger.
///
/// The plane site arrived in the SAME commit and by the same argument: it lived in
/// `slopdesk-ffi::pixel_plane`, a module that existed for no reason but "this crate may write
/// `unsafe` and apple-vt may not". When the daemon stopped linking the shim, that module's home
/// stopped being a home, and the mapping went to the crate that locks the buffer. Both moves paid
/// for the exemption the same way — the raw type went with them, so `slopdesk-apple-vt` now hands
/// out no framework pointer at all.
const SAMPLE_MEMORY: [SampleMemory; 2] = [
    SampleMemory {
        crate_dir: "rust/slopdesk-apple-audio",
        cap: 19,
    },
    SampleMemory {
        crate_dir: "rust/slopdesk-apple-vt",
        cap: 3,
    },
];

/// The exemption for one crate directory, or `None` when it has none.
fn sample_memory_for(crate_dir: &str) -> Option<&'static SampleMemory> {
    SAMPLE_MEMORY.iter().find(|exempt| exempt.crate_dir == crate_dir)
}

/// `docs/57` §3.4's bar: a wrapper past this many lines of CODE drew its framework area too wide.
///
/// Lines of [`Source::code`](crate::tree::Source::code) before the first `#[cfg(test)]`, counting
/// neither blank lines nor comments — these crates run about half prose, because every `unsafe`
/// block owes a `# Safety` note naming a framework rule, and a bar that counted the prose would be
/// a bar on writing it down.
const BAR: usize = 600;

/// One crate booked over [`BAR`]: where it is, and how wide it measured.
struct Wide {
    /// The crate directory, without a trailing slash.
    crate_dir: &'static str,
    /// The width MEASURED when the row was written, never [`BAR`] — see [`WIDE`].
    cap: usize,
}

/// One `slopdesk-apple-*` crate past [`BAR`], and its measured width.
///
/// §3.4 states the bar and the ONE-framework-area rule above it, and it already decided which wins
/// where they collide: `slopdesk-apple-ax` is booked there at "the accessibility client API
/// genuinely is [that wide], and splitting it would break the rule above it". Four more rows have
/// landed on the same side of that collision since, so the sentence is a PATTERN rather than one
/// crate's excuse — and a pattern with no instrument is drift.
///
/// Each was checked for the OTHER thing an over-bar count can mean: portable RULES that belong one
/// crate down, the way `slopdesk-apple-vt`'s Swift original was mostly rules before they moved.
/// Every module in all five names its framework — the thinnest are `sck/handoff.rs` and
/// `cgvirtualdisplay/classes.rs`, at one call each — so no rules-only module hides in any of them
/// and the width really is the area's:
///
/// * `slopdesk-apple-vt` — `VideoToolbox` publishes compression and decompression as two session
///   types with no shared object between them: each owns a session, an output handler and a sample
///   shape, and the format-description and pixel-buffer reads belong to neither alone. A split
///   would put the session on one side of a crate edge and the sample it emits on the other, and
///   would mint a second §2 admission budget for one framework's ownership rules.
/// * `slopdesk-apple-sck` — `ScreenCaptureKit` is ONE handshake in four parts: the
///   shareable-content query, the filter built from it, the stream that filter configures, and the
///   output tap the stream delivers to. Every seam a split could use runs THROUGH the handshake
///   rather than around it.
/// * `slopdesk-apple-audio` — the converter, the encoder and the decoder are one codec pipeline
///   over one `AudioStreamBasicDescription`, and this crate holds the family's sample-memory
///   exemption for exactly that pipeline. Splitting it would carry the exemption to both halves.
/// * `slopdesk-apple-cgvirtualdisplay` — a PRIVATE framework reached by runtime class lookup. The
///   descriptor, the settings and the main-thread hop are three stages of constructing one object,
///   and the class handles they look up are the crate's whole vocabulary.
/// * `slopdesk-apple-ax` — §3.4's own row, and the one this table generalises.
///
/// `cap` is the width measured when the row was written: a crate excused for its AREA may not also
/// GROW unremarked. Raising one is a number here and a sentence in the commit, which is the review.
const WIDE: [Wide; 5] = [
    Wide {
        crate_dir: "rust/slopdesk-apple-vt",
        cap: 1248,
    },
    Wide {
        crate_dir: "rust/slopdesk-apple-sck",
        cap: 836,
    },
    Wide {
        crate_dir: "rust/slopdesk-apple-audio",
        cap: 815,
    },
    Wide {
        crate_dir: "rust/slopdesk-apple-cgvirtualdisplay",
        cap: 705,
    },
    Wide {
        crate_dir: "rust/slopdesk-apple-ax",
        cap: 664,
    },
];

/// The booking for one crate directory, or `None` when it has none.
fn wide_for(crate_dir: &str) -> Option<&'static Wide> {
    WIDE.iter().find(|wide| wide.crate_dir == crate_dir)
}

/// Every crate is `unsafe_code = "forbid"` except two named families.
///
/// rustc enforces the level a crate states. What it cannot notice is the SHAPE drifting back: a new
/// crate that quietly says "deny", or a manifest that says nothing at all and inherits nothing.
/// Both reopen the hole stage 28 closed — `deny` is liftable by one `#[allow]`, and a missing
/// policy is `allow` by default. So the manifests are gated, not the source.
///
/// The exemption is not a blank cheque. Each exempt crate must state `deny`, the level the doc
/// argues for, and nothing else: `allow` there would take every per-site `#[expect]` with it, since
/// a lint nobody fires cannot expire. A missing FILE is the same failure wearing a different hat —
/// an entry naming a crate that has been renamed or folded away protects nothing, and reads for
/// years like it does.
///
/// `workspace = true` is only an answer for a crate that INHERITS from the root, and only because
/// the root is checked here too and must state `forbid` itself. Almost every crate under `rust/` is
/// its OWN `[workspace]` root, and for one of those the same two lines say nothing at all: a
/// manifest can carry `[workspace.lints.rust] unsafe_code = "allow"` and `[lints] workspace = true`
/// together and inherit permission. So inheritance is accepted only from the root, and the member
/// list is read OUT of the root rather than kept beside it.
#[must_use]
pub fn unsafe_policy(tree: &Tree) -> Report {
    let mut report = Report::new();
    let exempt = exempt_manifests(tree);

    // A stated `allow`/`warn` anywhere in a manifest is decisive, whatever else it also says: the
    // narrower `[lints.rust]` table wins over `[workspace.lints.rust]`, so a `forbid` above one of
    // these is not protection, it is camouflage.
    let members = root_members(tree, &mut report);
    let mut offenders = Vec::new();
    for manifest in manifests(tree) {
        if exempt.contains(&manifest) {
            continue;
        }
        let Some(source) = tree.get(&manifest) else {
            continue;
        };
        if states(&source.text, r#"unsafe_code = "allow""#) || states(&source.text, r#"unsafe_code = "warn""#)
        {
            offenders.push(format!("{manifest} (states allow/warn)"));
            continue;
        }
        if states(&source.text, r#"unsafe_code = "forbid""#) {
            continue;
        }
        let crate_name = crate_name_of(&manifest);
        if states(&source.text, "workspace = true") && members.contains(&crate_name) {
            continue;
        }
        offenders.push(manifest);
    }
    report.fail_if(
        !offenders.is_empty(),
        format!(
            "a crate is not unsafe_code = \"forbid\" ({}) — the exempt crates are the three hand-written \
             ones plus the slopdesk-apple-* objc2 family, and a fourth hand-written one is a design change \
             (docs/51 §6.15, docs/55 §5, docs/57)",
            offenders.join(", "),
        ),
    );

    for allowed in &exempt {
        let Some(source) = tree.get(allowed) else {
            report.fail(format!(
                "{allowed} is exempt from the unsafe-code policy and does not exist — the exemption list \
                 has gone stale (docs/55 §5)",
            ));
            continue;
        };
        report.fail_if(
            !states(&source.text, r#"unsafe_code = "deny""#),
            format!(
                "{allowed} is allowed to write unsafe and does not state unsafe_code = \"deny\" — the \
                 per-site #[expect] audit depends on that exact level (docs/51 §6.15, docs/55 §5)",
            ),
        );
    }
    report
}

/// The `slopdesk-apple-*` family, and the three extra conditions its permission costs.
///
/// This is a different permission rather than three more seats at the same table. A crate here
/// wraps ONE Apple framework area, reaches it only through `objc2`'s generated bindings, and may
/// write `unsafe` only to call a binding that is itself `unsafe` — never to dereference a pointer
/// it made. That is what makes the family bounded where a fourth hand-written crate would not be:
/// the obligation each block carries is the FRAMEWORK's rule, which the framework documents, not a
/// Rust rule about memory nobody else can check.
///
/// A raw-pointer operation here is not a framework obligation — it is a Rust one, and `docs/57` §2
/// says it belongs in `slopdesk-posix` or `slopdesk-ffi`, where a reviewer already holds that
/// question. Read over CODE only: a crate in this family has to EXPLAIN, in prose, which Rust
/// obligations it is not carrying — that sentence is the argument for its own existence — and a
/// gate that could not tell `transmute` in a doc comment from a call to one would force the
/// argument out of the crate to keep the crate green.
///
/// ## The one admission, and why it is narrower than an exception
/// `CFRetained::from_raw` is admitted, at most ONCE per crate. Core Foundation's Copy/Create rule
/// says a function whose name contains `Copy` or `Create` hands the caller a +1 retain, and some of
/// those functions return it through an OUT-PARAMETER rather than as a value — `objc2` generates
/// those as a raw `NonNull<*const CFType>` and offers nothing owned, because the ownership is
/// stated by Apple's naming convention, not by the C signature. Taking that retain is therefore a
/// FRAMEWORK obligation in exactly the sense this rule is built around: it is documented, and a
/// reviewer checks it by reading the callee's name. Moving it to `slopdesk-posix` would file an
/// accessibility read under "a syscall with no safe wrapper", which is worse than saying it here.
///
/// The count is what keeps this from being a hole. One site per crate means the crate has exactly
/// one place where a Copy-rule pointer becomes an owned value, so every typed reader is a caller of
/// that helper rather than a second obligation — and a second `from_raw` fails the gate with the
/// same message as a `transmute` would.
///
/// ## The amendment, and why it is a NAMED LIST and not a category
/// Two crates are exempt from the raw-pointer ban, they are named in [`SAMPLE_MEMORY`] with the
/// reason each earned it, and no third gets in by resembling them. Every other framework in this
/// family hands out OBJECTS — `objc2` models those, and the binding answers the ownership question,
/// so the crate never has to. The two on the list are the two whose SDK hands out MEMORY and offers
/// no call that copies it out, which is a fact about Apple's headers rather than about the code.
///
/// What keeps this from being the hole a category would be is the SITE COUNT, the same instrument
/// the two Core Foundation admissions use. Each exemption is a ratchet, not a door: the cap beside
/// a crate is what it needs today, and a change that wants one more has to move it there and say
/// why in the same commit. Every other §2 obligation still applies to both crates and is still
/// checked — `unsafe_op_in_unsafe_fn`, the `objc2` edge, and one `CFRetained::from_raw`.
/// What one crate's sources spend, in the four counts §2 argues about.
#[derive(Default)]
struct Spend {
    /// Whether any Rust source was read at all. A ban that reads nothing passes for the wrong
    /// reason.
    read_any: bool,
    /// A raw-pointer operation outside both admissions, in a crate that is not the exempt one.
    hand_written: bool,
    /// An exempt crate's ratchet count. Always zero elsewhere.
    sample_memory_sites: usize,
    /// `CFRetained::from_raw`, the Copy/Create-rule admission. At most one per crate.
    copy_rule_sites: usize,
    /// `CFRetained::retain` and its `objc2` twin `Retained::retain`, the Get-rule admission — ONE
    /// admission in two spellings, so the two counts are added rather than kept apart. At most one
    /// per crate, independently of the Copy rule's.
    get_rule_sites: usize,
    /// Non-blank lines of code before the first `#[cfg(test)]`, against [`BAR`].
    code_lines: usize,
}

/// Counts one crate's `src` tree. Split out of [`apple_family`] because the WALK and the VERDICTS
/// are two different arguments, and only the verdicts read as a policy.
fn scan_spend(tree: &Tree, src: &str, sample_memory: bool) -> Spend {
    let mut spend = Spend::default();
    for (path, file) in tree.under(src) {
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        spend.read_any = true;
        // The size bar measures the crate somebody READS. A test module is not that — it grows with
        // the assertions rather than with the framework area, which is the thing the bar is about —
        // so counting stops at its attribute. `code()` has already dropped the comment lines.
        let mut sized = true;
        for line in file.code().lines() {
            sized &= !line.contains("#[cfg(test)]");
            if sized && !line.trim().is_empty() {
                spend.code_lines += 1;
            }
            // The admission is recognised BEFORE the ban, and by the qualified path only. A bare
            // `from_raw` is still a raw-pointer operation whatever it is reconstructing.
            if line.contains("CFRetained::from_raw") {
                spend.copy_rule_sites += 1;
                continue;
            }
            // The Get-rule twin: a framework hands out a BORROWED +0 pointer valid only for the
            // call — a callback's sample buffer, a delegate's argument — and taking a reference of
            // one's own is how it outlives that call. Qualified path only, for the same reason:
            // `something.retain()` on a live typed reference asserts nothing and is not this
            // admission.
            if line.contains("CFRetained::retain") {
                spend.get_rule_sites += 1;
                continue;
            }
            // The same admission in Objective-C spelling. `objc2` gives an `NSObject` subclass
            // `Retained::retain` and a Core Foundation type `CFRetained::retain`, and the rule they
            // satisfy is one rule — `ScreenCaptureKit` hands its completion handlers a borrowed
            // `SCShareableContent` for exactly the reason `VideoToolbox` hands its output handler a
            // borrowed `CMSampleBuffer`. Counting only the CF spelling left the ObjC one
            // UNCOUNTED, which is how `slopdesk-apple-sck` came to spend the admission twice with
            // this gate reading green. The branch above matches first and `continue`s, so the
            // qualified `CFRetained::retain` is never counted here as well.
            if line.contains("Retained::retain") {
                spend.get_rule_sites += 1;
                continue;
            }
            let raw = crate::text::matches_line(
                line,
                r"transmute|from_raw|slice::from_raw_parts|ptr::(read|write|copy)",
            );
            if sample_memory {
                // Counted rather than waved through — see the amendment note above. The pattern is
                // WIDER here than the ban's, on purpose: the ban catches the qualified spellings,
                // and a ratchet that missed `pointer.read()` would let the exempt crate grow raw
                // sites the count never saw.
                if raw || crate::text::matches_line(line, r"\.(read|write|add|offset)\(") {
                    spend.sample_memory_sites += 1;
                }
                continue;
            }
            spend.hand_written |= raw;
        }
    }
    spend
}

#[must_use]
pub fn apple_family(tree: &Tree) -> Report {
    let mut report = Report::new();
    let family = apple_manifests(tree);
    report.fail_if(
        family.is_empty(),
        "no slopdesk-apple-* crate exists — this gate reads nothing and would pass (docs/57)".to_owned(),
    );

    stale_bookings(tree, &mut report);

    for manifest in family {
        let Some(source) = tree.get(&manifest) else {
            continue;
        };
        report.fail_if(
            !states(&source.text, r#"unsafe_op_in_unsafe_fn = "deny""#),
            format!(
                "{manifest} is in the objc2 family and does not state unsafe_op_in_unsafe_fn = \"deny\" — \
                 the family's permission is 'call an unsafe binding', which means every such call must be \
                 inside a block that named its obligation (docs/57 §3)",
            ),
        );
        report.fail_if(
            !source.text.contains("objc2"),
            format!(
                "{manifest} is named slopdesk-apple-* and depends on no objc2 crate — the family exists \
                 BECAUSE the bindings are generated from SDK metadata; a hand-rolled extern block wearing \
                 this name has the permission without the reason for it (docs/57 §1)",
            ),
        );

        let crate_dir = manifest.trim_end_matches("/Cargo.toml");
        let src = format!("{crate_dir}/src");
        let sample_memory = sample_memory_for(crate_dir);
        let Spend {
            read_any,
            hand_written,
            sample_memory_sites,
            copy_rule_sites,
            get_rule_sites,
            code_lines,
        } = scan_spend(tree, &src, sample_memory.is_some());
        report.fail_if(
            !read_any,
            format!("{src} holds no Rust source — the ban below reads nothing and would pass"),
        );
        report.fail_if(
            hand_written,
            format!(
                "{crate_dir} hand-writes a raw-pointer operation — the objc2 family may write unsafe only \
                 to CALL an unsafe binding; a transmute or a from_raw is a Rust obligation and belongs in \
                 slopdesk-posix or slopdesk-ffi (docs/57 §2)",
            ),
        );
        if let Some(exempt) = sample_memory {
            let cap = exempt.cap;
            report.fail_if(
                sample_memory_sites == 0,
                format!(
                    "{crate_dir} is exempt from the raw-pointer ban and writes none — the exemption exists \
                     because its SDK publishes memory as (pointer, length) and offers no copy-out; a crate \
                     that no longer needs it should LOSE it, not keep it (docs/57 §2's amendment)",
                ),
            );
            report.fail_if(
                sample_memory_sites > cap,
                format!(
                    "{crate_dir} touches raw pointers at {sample_memory_sites} sites — its sample-memory \
                     amendment is a RATCHET at {cap}, so a new site moves the cap here and says why in the \
                     same commit (docs/57 §2's amendment)",
                ),
            );
        }
        report.fail_if(
            copy_rule_sites > 1,
            format!(
                "{crate_dir} takes a Core Foundation Copy-rule retain in {copy_rule_sites} places — the \
                 family admits CFRetained::from_raw at ONE site per crate, so that every typed reader is a \
                 caller of that helper rather than a second obligation (docs/57 §2)",
            ),
        );
        report.fail_if(
            get_rule_sites > 1,
            format!(
                "{crate_dir} takes a Get-rule retain in {get_rule_sites} places — the family admits it at \
                 ONE site per crate in EITHER spelling (CFRetained::retain, or objc2's Retained::retain), \
                 so the question 'is this borrowed pointer still the framework's' is answered once, at the \
                 boundary the framework hands it across (docs/57 §2)",
            ),
        );
        size_verdict(crate_dir, code_lines, &mut report);
    }
    report
}

/// Every hand-written booking names a crate that still exists.
///
/// A ratchet naming a crate that has been renamed or folded away protects nothing, and reads for
/// years like it does — the same failure `unsafe_policy` checks for its own exemption list, which
/// cannot see either of these because both are subsets chosen by hand rather than by glob. The two
/// tables are walked separately because they overlap in two crates and agree in neither direction.
fn stale_bookings(tree: &Tree, report: &mut Report) {
    for exempt in &SAMPLE_MEMORY {
        report.fail_if(
            !tree.has(&format!("{}/Cargo.toml", exempt.crate_dir)),
            format!(
                "{} holds a sample-memory exemption and does not exist — the ratchet has gone stale \
                 (docs/57 §2's amendment)",
                exempt.crate_dir,
            ),
        );
    }
    for wide in &WIDE {
        report.fail_if(
            !tree.has(&format!("{}/Cargo.toml", wide.crate_dir)),
            format!(
                "{} is booked over the size bar and does not exist — the ratchet has gone stale (docs/57 \
                 §3.4)",
                wide.crate_dir,
            ),
        );
    }
}

/// One crate against [`BAR`] and, if it has one, against its [`WIDE`] booking.
///
/// Split out of [`apple_family`] for the reason [`scan_spend`] is: the bar is a different argument
/// from the admissions, and reading them interleaved makes neither easier to check.
fn size_verdict(crate_dir: &str, code_lines: usize, report: &mut Report) {
    let Some(wide) = wide_for(crate_dir) else {
        report.fail_if(
            code_lines > BAR,
            format!(
                "{crate_dir} is {code_lines} lines of code against docs/57 §3.4's ~{BAR}-line bar — either \
                 the framework area was drawn too wide and the crate splits, or the area genuinely is this \
                 wide and it joins WIDE with the reason, which is the review (docs/57 §3.4)",
            ),
        );
        return;
    };
    report.fail_if(
        code_lines <= BAR,
        format!(
            "{crate_dir} is booked over docs/57 §3.4's ~{BAR}-line bar and measures {code_lines} — it is \
             UNDER the bar now, so the booking excuses nothing and comes out with the commit that narrowed \
             it (docs/57 §3.4)",
        ),
    );
    report.fail_if(
        code_lines > wide.cap,
        format!(
            "{crate_dir} measures {code_lines} lines of code against a booked {} — the booking is a RATCHET \
             at the width it was written for rather than a licence to grow, so a wider crate moves the \
             number and says why in the same commit (docs/57 §3.4)",
            wide.cap,
        ),
    );
}

/// The two lints that would talk you out of bit-exact floats.
///
/// `CLAUDE.md` forbids the fused multiply-add: `a * b + c` stays two roundings because that is what
/// `golden/golden_vectors.json` pins. Clippy's `suboptimal_flops` and `imprecise_flops` argue the
/// opposite, both live in `nursery`, and every workspace here denies the whole nursery group — so
/// in any crate that does not opt out, the FIRST float expression to land is a hard clippy error
/// whose only offered fix is `f64::mul_add`. That is a lint teaching the opposite of an invariant,
/// and it teaches it at the moment nobody is reading a manifest.
///
/// Four crates carried the opt-out because four crates had float math. The rest were one expression
/// away from the trap; they all carry it now, and this keeps the next one honest.
#[must_use]
pub fn flops_opt_out(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut unguarded = Vec::new();
    let mut seen = 0usize;
    for manifest in manifests(tree) {
        let Some(source) = tree.get(&manifest) else {
            continue;
        };
        if manifest != ROOT_MANIFEST && !states(&source.text, "[workspace]") {
            continue;
        }
        seen += 1;
        for lint in ["suboptimal_flops", "imprecise_flops"] {
            if !states(&source.text, &format!("{lint} = \"allow\"")) {
                unguarded.push(format!("{manifest} ({lint})"));
            }
        }
    }
    report.fail_if(
        seen == 0,
        "no Rust workspace root was found — this gate reads nothing and would pass".to_owned(),
    );
    report.fail_if(
        !unguarded.is_empty(),
        format!(
            "a Rust workspace does not allow the FMA-suggesting nursery lints ({}) — clippy would demand \
             mul_add and break the bit-exact floats CLAUDE.md pins",
            unguarded.join(", "),
        ),
    );
    report
}

/// The only three lints a MANIFEST may disable, and why no fourth can be.
///
/// Each of these is a fact about the whole crate that no code site could carry:
/// [`flops_opt_out`] REQUIRES the first two in every workspace, and `multiple_crate_versions` is a
/// dependency-GRAPH lint that fires on a resolved tree rather than on a line anyone wrote.
const WORKSPACE_WIDE: [&str; 3] = ["suboptimal_flops", "imprecise_flops", "multiple_crate_versions"];

/// An opt-out lives where the reason is TRUE, and no wider.
///
/// A `lint = "allow"` in a manifest is a statement about every file in the crate, including the
/// ones nobody has written yet — and the reason written beside it is almost never that wide. The
/// tree had sixteen of them when this rule landed. Two were DEAD, firing nowhere at all;
/// `slopdesk-sanitize` disabled `indexing_slicing` for a clamped terminal grid it does not contain;
/// `slopdesk-audio-out` named three of the four modules its exemption actually covered, and
/// `slopdesk-apple-audio` named a module the lint never fired in. Every one of those reads, for
/// years, like a checked claim.
///
/// So the manifests state the DENY and the code states the exemption: `#![expect(…, reason = "…")]`
/// at the top of the one module that earns it, or `#[expect(…)]` on the one item. The scope is then
/// as wide as the argument and no wider, and a reader who wants to know what an opt-out covers
/// reads the file it covers.
///
/// ## Why `expect` and not `allow` at the site either
/// `expect` EXPIRES: rustc errors when the lint it names stops firing. `allow` goes quiet instead,
/// which is how the two dead ones survived. Converting the four hand-written `#[allow]`s in this
/// tree found a fifth immediately — `release::pack::run` had shrunk under `too_many_lines` and
/// nobody could have known.
#[must_use]
pub fn scoped_opt_outs(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut blanket = Vec::new();
    let mut seen = 0usize;
    for manifest in manifests(tree) {
        let Some(source) = tree.get(&manifest) else {
            continue;
        };
        seen += 1;
        for line in source.text.lines() {
            let Some(lint) = line.strip_suffix(r#" = "allow""#) else {
                continue;
            };
            // Anchored: a `#`-commented copy of a level is prose about the policy, not the policy.
            if lint.starts_with(' ') || lint.starts_with('#') || WORKSPACE_WIDE.contains(&lint) {
                continue;
            }
            blanket.push(format!("{manifest} ({lint})"));
        }
    }
    report.fail_if(
        seen == 0,
        "no Rust manifest was found — this gate reads nothing and would pass".to_owned(),
    );
    report.fail_if(
        !blanket.is_empty(),
        format!(
            "a manifest disables a code-level lint for a whole crate ({}) — an opt-out belongs at the site \
             as #![expect(…, reason = \"…\")] on the module that earns it, so it cannot cover a file nobody \
             has written yet; the only three a manifest may state are {}",
            blanket.join(", "),
            WORKSPACE_WIDE.join(", "),
        ),
    );

    let mut silent = Vec::new();
    let mut read_any = false;
    for (path, file) in tree.under("rust") {
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        read_any = true;
        // Anchored at the line's first non-space, because an attribute IS the first thing on its
        // line. A `"#[allow(…)]"` inside a quoted string is a fixture — this rule's own break-test
        // writes one — and a gate that could not tell the two apart would force the test that
        // proves it works out of the crate to keep the crate green.
        if file.code().lines().any(|line| {
            line.trim_start().starts_with("#[allow(") || line.trim_start().starts_with("#![allow(")
        }) {
            silent.push(path.to_string_lossy().into_owned());
        }
    }
    report.fail_if(
        !read_any,
        "no Rust source was found — the #[allow] ban below reads nothing and would pass".to_owned(),
    );
    silent.sort();
    report.fail_if(
        !silent.is_empty(),
        format!(
            "a Rust source writes #[allow] where #[expect] would do ({}) — expect ERRORS once the lint \
             stops firing, which is the only thing that ever deletes a stale opt-out",
            silent.join(", "),
        ),
    );
    report
}

/// Whether a manifest STATES something, at the start of a line — the shell's `grep -q '^…'`.
///
/// Anchored, because a `#`-commented copy of a lint level is prose about the policy and not the
/// policy. Everything read here is TOML, where a setting at column 0 is the setting.
fn states(text: &str, needle: &str) -> bool {
    text.lines().any(|line| line.starts_with(needle))
}

/// `rust/Cargo.toml` and every `rust/*/Cargo.toml`, in sorted order.
fn manifests(tree: &Tree) -> Vec<String> {
    let mut found: Vec<String> = tree
        .paths()
        .filter_map(|path| {
            let display = path.to_string_lossy().into_owned();
            let is_crate_manifest = display.starts_with("rust/")
                && display.ends_with("/Cargo.toml")
                && display.matches('/').count() == 2;
            (display == ROOT_MANIFEST || is_crate_manifest).then_some(display)
        })
        .collect();
    found.sort();
    found
}

fn apple_manifests(tree: &Tree) -> Vec<String> {
    manifests(tree)
        .into_iter()
        .filter(|path| path.starts_with("rust/slopdesk-apple-"))
        .collect()
}

/// The three hand-written crates plus every `slopdesk-apple-*` one.
///
/// Membership of the second family is by NAME, so adding one is visible in the diff of the crate
/// that adds it — and the three extra conditions [`apple_family`] checks are checked per crate
/// rather than trusted.
fn exempt_manifests(tree: &Tree) -> BTreeSet<String> {
    HAND_WRITTEN
        .iter()
        .map(|path| (*path).to_owned())
        .chain(apple_manifests(tree))
        .collect()
}

fn crate_name_of(manifest: &str) -> String {
    manifest
        .trim_start_matches("rust/")
        .trim_end_matches("/Cargo.toml")
        .to_owned()
}

/// The root workspace's member list, read out of the root rather than kept beside it.
fn root_members(tree: &Tree, report: &mut Report) -> BTreeSet<String> {
    let Some(source) = tree.get(ROOT_MANIFEST) else {
        report.fail(format!(
            "{ROOT_MANIFEST} is gone — the root workspace defines the inheritance"
        ));
        return BTreeSet::new();
    };
    let members: BTreeSet<String> = source
        .text
        .lines()
        .filter(|line| line.starts_with("members = "))
        .flat_map(|line| crate::text::capture_all(line, r#""([a-z0-9-]+)""#))
        .collect();
    report.fail_if(
        members.is_empty(),
        "the root workspace's members list did not parse — the unsafe-policy gate would accept any \
         'workspace = true' (docs/55 §5)"
            .to_owned(),
    );
    members
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A manifest shaped like the objc2 family's: the `objc2` edge, and the two lint levels the
    /// permission costs. Shared, because three of the cases below write a SECOND crate of the
    /// family into the fixture and the shape has to be the same one `policy_fixture` lays down.
    const APPLE_MANIFEST: &str = "[workspace]\n[dependencies]\nobjc2 = \"0.6\"\n[lints.rust]\nunsafe_code = \
                                  \"deny\"\nunsafe_op_in_unsafe_fn = \
                                  \"deny\"\n[lints.clippy]\nsuboptimal_flops = \"allow\"\nimprecise_flops = \
                                  \"allow\"\n";

    /// A new crate that says nothing at all inherits `allow` — the hole stage 28 closed. rustc
    /// cannot notice it, because there is no crate stating a level for rustc to enforce.
    #[test]
    fn a_crate_with_no_stated_policy_is_caught() {
        let fixture = policy_fixture("policy-silent");
        assert!(super::unsafe_policy(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-new/Cargo.toml",
            "[workspace]\n[package]\nname = \"x\"\n",
        );
        let report = super::unsafe_policy(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("rust/slopdesk-new/Cargo.toml")),
            "{report:?}",
        );
    }

    /// A `forbid` above a narrower `allow` is camouflage, not protection: the `[lints.rust]` table
    /// wins over `[workspace.lints.rust]`, so the stated `allow` is what the crate gets.
    #[test]
    fn a_forbid_above_a_narrower_allow_does_not_count() {
        let fixture = policy_fixture("policy-camouflage");
        fixture.write(
            "rust/slopdesk-new/Cargo.toml",
            "[workspace]\n[workspace.lints.rust]\nunsafe_code = \"forbid\"\n[lints.rust]\nunsafe_code = \
             \"allow\"\n",
        );
        let report = super::unsafe_policy(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("states allow/warn")),
            "{report:?}"
        );
    }

    /// `workspace = true` is an answer only for a crate the ROOT lists. Every other crate under
    /// `rust/` is its own workspace root, where the same line inherits from itself.
    #[test]
    fn inheritance_is_accepted_only_from_the_root() {
        let fixture = policy_fixture("policy-inherit");
        fixture.write("rust/slopdesk-member/Cargo.toml", "[lints]\nworkspace = true\n");
        let report = super::unsafe_policy(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("rust/slopdesk-member/Cargo.toml")),
            "{report:?}",
        );

        fixture.write(
            "rust/Cargo.toml",
            "[workspace]\nmembers = [\"slopdesk-member\"]\n[workspace.lints.rust]\nunsafe_code = \
             \"forbid\"\n[workspace.lints.clippy]\nsuboptimal_flops = \"allow\"\nimprecise_flops = \
             \"allow\"\n",
        );
        assert!(super::unsafe_policy(&fixture.tree()).is_clean());
    }

    /// An exemption naming a crate that was renamed away protects nothing, and reads for years like
    /// it does.
    #[test]
    fn a_stale_exemption_entry_is_caught() {
        let fixture = policy_fixture("policy-stale");
        assert!(super::unsafe_policy(&fixture.tree()).is_clean());

        std::fs::remove_file(fixture.tree().root().join("rust/slopdesk-gfsimd/Cargo.toml"))
            .expect("remove the exempt manifest");
        let report = super::unsafe_policy(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("has gone stale")),
            "{report:?}"
        );
    }

    /// The line that separates the objc2 family from the three hand-written crates: a raw-pointer
    /// operation is a RUST obligation, and belongs where a reviewer already holds that question.
    #[test]
    fn a_raw_pointer_operation_in_the_apple_family_is_caught() {
        let fixture = policy_fixture("apple-raw");
        assert!(super::apple_family(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            "pub fn f() { let _ = unsafe { std::mem::transmute::<u32, i32>(0) }; }\n",
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("raw-pointer operation")),
            "{report:?}"
        );
    }

    /// One raw-pointer site, in the spelling the ban's own pattern recognises.
    const ONE_RAW_SITE: &str =
        "pub fn read() { let _ = unsafe { std::slice::from_raw_parts(base, len) }; }\n";

    /// The amendment is a NAMED LIST and a RATCHET rather than a door: a listed crate may write
    /// raw-pointer work, and the same line in an unlisted one fails exactly as a transmute does.
    #[test]
    fn a_listed_crate_is_exempt_and_an_unlisted_one_is_not() {
        let fixture = policy_fixture("apple-sample-memory");
        assert!(
            super::apple_family(&fixture.tree()).is_clean(),
            "every listed crate may publish the memory its SDK hands out"
        );

        // The same line in any OTHER crate of the family is still the ban's business.
        fixture.write("rust/slopdesk-apple-cgevent/src/lib.rs", ONE_RAW_SITE);
        let report = super::apple_family(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-apple-cgevent") && v.contains("raw-pointer operation")),
            "{report:?}"
        );
    }

    /// A ratchet with slack is a budget. One site past the cap has to fail, or the count says
    /// nothing about what the crate actually needs — and it has to fail per crate, at that crate's
    /// own number, or the tighter cap is protected by the looser one.
    #[test]
    fn a_sample_memory_site_past_a_crates_own_cap_is_caught() {
        for exempt in &super::SAMPLE_MEMORY {
            let fixture = policy_fixture(&format!("apple-sample-cap-{}", exempt.cap));
            fixture.write(
                &format!("{}/src/lib.rs", exempt.crate_dir),
                &ONE_RAW_SITE.repeat(exempt.cap + 1),
            );
            let report = super::apple_family(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains(exempt.crate_dir) && v.contains("RATCHET")),
                "{} must ratchet at {}: {report:?}",
                exempt.crate_dir,
                exempt.cap,
            );
        }
    }

    /// An unbooked crate over the bar is the case the whole table exists for: §3.4 states a width
    /// and, until this rule, nothing read one.
    #[test]
    fn an_unbooked_crate_past_the_size_bar_is_caught() {
        let fixture = policy_fixture("apple-size-unbooked");
        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            &"pub fn f() {}\n".repeat(super::BAR + 1),
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-apple-cgevent") && v.contains("drawn too wide")),
            "{report:?}"
        );
    }

    /// A booking is a ratchet at ONE width, and it has to bind per crate at that crate's own
    /// number — otherwise the widest row protects every narrower one.
    #[test]
    fn a_booked_crate_growing_past_its_own_width_is_caught() {
        for wide in &super::WIDE {
            let fixture = policy_fixture(&format!("apple-size-grown-{}", wide.cap));
            fixture.write(
                &format!("{}/src/lib.rs", wide.crate_dir),
                &format!("{ONE_RAW_SITE}{}", "pub fn wide() {}\n".repeat(wide.cap + 1)),
            );
            let report = super::apple_family(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains(wide.crate_dir) && v.contains("RATCHET at the width")),
                "{} must ratchet at {}: {report:?}",
                wide.crate_dir,
                wide.cap,
            );
        }
    }

    /// The excuse has to expire. A crate that has come back under the bar keeps a booking that now
    /// argues for nothing, and reads for years like a crate that still needs one.
    #[test]
    fn a_booking_for_a_crate_that_is_no_longer_wide_is_caught() {
        for wide in &super::WIDE {
            let fixture = policy_fixture(&format!("apple-size-narrowed-{}", wide.cap));
            fixture.write(&format!("{}/src/lib.rs", wide.crate_dir), ONE_RAW_SITE);
            let report = super::apple_family(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains(wide.crate_dir) && v.contains("UNDER the bar")),
                "{}: {report:?}",
                wide.crate_dir,
            );
        }
    }

    /// A test module grows with its assertions rather than with the framework area, so it is not
    /// what the bar is about — and a rule that counted it would push a crate over the bar for
    /// writing the leak test §3.3 demands of it.
    #[test]
    fn a_test_module_does_not_count_towards_the_size_bar() {
        let fixture = policy_fixture("apple-size-tests-free");
        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            &format!(
                "pub fn f() {{}}\n#[cfg(test)]\nmod tests {{\n{}}}\n",
                "    // a body\n    fn t() {}\n".repeat(super::BAR)
            ),
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            !report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-apple-cgevent") && v.contains("drawn too wide")),
            "{report:?}"
        );
    }

    /// An exemption nothing spends is an exemption to delete, and it reads for years like a crate
    /// that needs it.
    #[test]
    fn an_unspent_sample_memory_exemption_is_caught() {
        for exempt in &super::SAMPLE_MEMORY {
            let fixture = policy_fixture(&format!("apple-sample-unspent-{}", exempt.cap));
            fixture.write(&format!("{}/src/lib.rs", exempt.crate_dir), "pub fn f() {}\n");
            let report = super::apple_family(&fixture.tree());
            assert!(
                report
                    .violations()
                    .iter()
                    .any(|v| v.contains(exempt.crate_dir) && v.contains("writes none")),
                "{}: {report:?}",
                exempt.crate_dir,
            );
        }
    }

    /// A ratchet naming a crate that has been folded away protects nothing. This one cannot ride on
    /// `unsafe_policy`'s stale check, which reads a GLOB of the family rather than this hand-picked
    /// subset — so it is checked here and broken here.
    #[test]
    fn a_stale_sample_memory_entry_is_caught() {
        let fixture = policy_fixture("apple-sample-stale");
        let manifest = format!("{}/Cargo.toml", super::SAMPLE_MEMORY[0].crate_dir);
        std::fs::remove_file(fixture.tree().root().join(&manifest)).expect("remove the exempt manifest");
        let report = super::apple_family(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("gone stale")),
            "{report:?}"
        );
    }

    /// And the prose that ARGUES for the crate's existence must be able to name the thing it is not
    /// doing — a gate that could not tell a doc comment from a call would force that sentence out.
    #[test]
    fn prose_naming_a_transmute_does_not_trip_the_family_ban() {
        let fixture = policy_fixture("apple-prose");
        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            "//! This crate never writes a transmute or a from_raw: those are Rust obligations.\npub fn f() \
             {}\n",
        );
        assert!(super::apple_family(&fixture.tree()).is_clean());
    }

    /// One Copy-rule retain passes; two are the same failure a transmute is. The count is the whole
    /// difference between an admission and a hole — one site means every typed reader CALLS it.
    #[test]
    fn a_second_copy_rule_retain_is_caught_where_the_first_is_admitted() {
        let one = "pub fn copy() { let _ = unsafe { CFRetained::from_raw(value) }; }\n";
        let fixture = policy_fixture("apple-copy-rule");
        fixture.write("rust/slopdesk-apple-cgevent/src/lib.rs", one);
        assert!(super::apple_family(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            &format!("{one}pub fn again() {{ let _ = unsafe {{ CFRetained::from_raw(other) }}; }}\n"),
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("Copy-rule retain")),
            "{report:?}"
        );
    }

    /// The Get-rule admission is counted the same way and for the same reason: one site per crate,
    /// so the question "is this borrowed pointer still the framework's" is answered where the
    /// framework hands it across rather than at every place someone found a pointer.
    #[test]
    fn a_second_get_rule_retain_is_caught_where_the_first_is_admitted() {
        let one = "pub fn borrow() { let _ = unsafe { CFRetained::retain(value) }; }\n";
        let fixture = policy_fixture("apple-get-rule");
        fixture.write("rust/slopdesk-apple-cgevent/src/lib.rs", one);
        assert!(super::apple_family(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            &format!("{one}pub fn again() {{ let _ = unsafe {{ CFRetained::retain(other) }}; }}\n"),
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("Get-rule retain")),
            "{report:?}"
        );
    }

    /// The `objc2` spelling is the SAME admission, and the two counts add rather than run in
    /// parallel. This is the hole `slopdesk-apple-sck` was sitting in: two `Retained::retain` sites
    /// over `ScreenCaptureKit`'s completion-handler arguments, and a gate that read only the Core
    /// Foundation spelling called it clean. One site is one site whichever type it is over.
    #[test]
    fn the_objc_spelling_of_the_get_rule_is_the_same_one_admission() {
        let objc = "pub fn borrow() { let _ = unsafe { Retained::retain(content) }; }\n";
        let fixture = policy_fixture("apple-get-rule-objc");
        fixture.write("rust/slopdesk-apple-cgevent/src/lib.rs", objc);
        assert!(super::apple_family(&fixture.tree()).is_clean());

        // One of each spelling is still TWO retains, not one of each budget.
        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            &format!("{objc}pub fn again() {{ let _ = unsafe {{ CFRetained::retain(other) }}; }}\n"),
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("Get-rule retain")),
            "{report:?}"
        );
    }

    /// The two admissions are counted SEPARATELY, so a crate may hold one of each — the Create rule
    /// and the Get rule are different obligations and a crate that owns a session and reads its
    /// callback's samples genuinely carries both.
    #[test]
    fn the_copy_and_get_admissions_do_not_consume_each_other() {
        let fixture = policy_fixture("apple-both-rules");
        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            "pub fn create() { let _ = unsafe { CFRetained::from_raw(out) }; }\npub fn borrow() { let _ = \
             unsafe { CFRetained::retain(value) }; }\n",
        );
        assert!(super::apple_family(&fixture.tree()).is_clean());
    }

    /// The admission is by QUALIFIED path. `Box::from_raw`, `CString::from_raw` and friends
    /// reconstruct an owned value from a pointer this crate made, which is the Rust obligation the
    /// family does not carry — so a bare `from_raw` is still caught.
    #[test]
    fn an_unqualified_from_raw_is_not_the_copy_rule_admission() {
        let fixture = policy_fixture("apple-bare-from-raw");
        fixture.write(
            "rust/slopdesk-apple-cgevent/src/lib.rs",
            "pub fn f() { let _ = unsafe { Box::from_raw(handle) }; }\n",
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("raw-pointer operation")),
            "{report:?}"
        );
    }

    /// A workspace one float expression away from a hard clippy error whose only offered fix breaks
    /// the golden corpus.
    #[test]
    fn a_workspace_without_the_flops_opt_out_is_caught() {
        let fixture = policy_fixture("flops");
        assert!(super::flops_opt_out(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-new/Cargo.toml",
            "[workspace]\n[lints.rust]\nunsafe_code = \"forbid\"\n",
        );
        let report = super::flops_opt_out(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("suboptimal_flops")),
            "{report:?}"
        );
    }

    /// A tree with the whole `rust/` directory renamed away must FAIL rather than report that every
    /// workspace is compliant — there being none is not the same as all of them passing.
    #[test]
    fn an_empty_workspace_set_says_so_instead_of_passing() {
        let fixture = Fixture::new("flops-empty");
        fixture.write("Sources/A.swift", "let x = 1\n");
        let report = super::flops_opt_out(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("reads nothing")),
            "{report:?}"
        );
    }

    /// The shape this rule exists to refuse: a lint disabled for a whole crate because ONE module
    /// earns it. The allow reads like a checked claim and covers every file the crate will ever
    /// have.
    #[test]
    fn a_crate_wide_code_lint_opt_out_is_caught() {
        let fixture = opt_out_fixture("opt-out-blanket");
        assert!(super::scoped_opt_outs(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-new/Cargo.toml",
            "[workspace]\n[lints.clippy]\nindexing_slicing = \"allow\"\n",
        );
        let report = super::scoped_opt_outs(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("indexing_slicing")),
            "{report:?}"
        );
    }

    /// The three the manifests may keep. Two are REQUIRED by `flops_opt_out`, and the third has no
    /// code site to attach to — a rule that failed on them would be unsatisfiable.
    #[test]
    fn the_three_workspace_wide_lints_stay_in_the_manifest() {
        let fixture = opt_out_fixture("opt-out-carve-outs");
        fixture.write(
            "rust/slopdesk-new/Cargo.toml",
            "[workspace]\n[lints.clippy]\nsuboptimal_flops = \"allow\"\nimprecise_flops = \
             \"allow\"\nmultiple_crate_versions = \"allow\"\n",
        );
        assert!(super::scoped_opt_outs(&fixture.tree()).is_clean());
    }

    /// `allow` at the site is the same failure wearing a smaller hat: it goes quiet instead of
    /// expiring, which is how a dead opt-out survives a rewrite of the code it covered.
    #[test]
    fn an_allow_at_the_site_is_caught_where_an_expect_would_do() {
        let fixture = opt_out_fixture("opt-out-silent");
        fixture.write(
            "rust/slopdesk-new/src/lib.rs",
            "#[allow(clippy::too_many_lines)]\npub fn f() {}\n",
        );
        let report = super::scoped_opt_outs(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("#[expect] would do")),
            "{report:?}"
        );
    }

    /// A commented-out level is prose ABOUT the policy. The rule reads TOML, where a setting at
    /// column 0 is the setting — and the manifests here explain their denies in comments that quote
    /// the old allow.
    #[test]
    fn a_commented_allow_is_prose_and_not_the_policy() {
        let fixture = opt_out_fixture("opt-out-prose");
        fixture.write(
            "rust/slopdesk-new/Cargo.toml",
            "[workspace]\n[lints.clippy]\n# it used to say indexing_slicing = \"allow\" \
             here\nindexing_slicing = \"deny\"\n",
        );
        assert!(super::scoped_opt_outs(&fixture.tree()).is_clean());
    }

    /// A tree with no Rust source must FAIL rather than report that nothing writes `#[allow]`.
    #[test]
    fn an_opt_out_gate_that_reads_nothing_says_so() {
        let fixture = Fixture::new("opt-out-empty");
        fixture.write("Sources/A.swift", "let x = 1\n");
        let report = super::scoped_opt_outs(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("reads nothing")),
            "{report:?}"
        );
    }

    /// A tree the opt-out rule is silent on: one manifest carrying only the three workspace-wide
    /// lints, and one source with no `#[allow]` in it.
    fn opt_out_fixture(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "rust/slopdesk-wire/Cargo.toml",
                "[workspace]\n[lints.clippy]\nsuboptimal_flops = \"allow\"\nimprecise_flops = \"allow\"\n",
            )
            .write("rust/slopdesk-wire/src/lib.rs", "pub fn f() {}\n");
        fixture
    }

    /// A compliant tree: the root, one exempt hand-written crate, one apple crate and one ordinary
    /// one. Every rule here should be silent on it.
    fn policy_fixture(name: &str) -> Fixture {
        const CLEAN: &str = "[workspace]\n[lints.rust]\nunsafe_code = \
                             \"forbid\"\n[lints.clippy]\nsuboptimal_flops = \"allow\"\nimprecise_flops = \
                             \"allow\"\n";
        const EXEMPT: &str = "[workspace]\n[lints.rust]\nunsafe_code = \
                              \"deny\"\n[lints.clippy]\nsuboptimal_flops = \"allow\"\nimprecise_flops = \
                              \"allow\"\n";

        let fixture = Fixture::new(name);
        // The root carries a members list because the inheritance rule is read out of it: a
        // fixture without one would fail every case for the wrong reason.
        fixture
            .write(
                "rust/Cargo.toml",
                &format!("members = [\"slopdesk-hook\"]\n{CLEAN}"),
            )
            .write("rust/slopdesk-posix/Cargo.toml", EXEMPT)
            .write("rust/slopdesk-ffi/Cargo.toml", EXEMPT)
            .write("rust/slopdesk-gfsimd/Cargo.toml", EXEMPT)
            .write("rust/slopdesk-apple-cgevent/Cargo.toml", APPLE_MANIFEST)
            .write("rust/slopdesk-apple-cgevent/src/lib.rs", "pub fn f() {}\n")
            .write("rust/slopdesk-wire/Cargo.toml", CLEAN);
        // Every crate holding a sample-memory exemption, each SPENDING exactly one site. Both
        // halves are required of a compliant tree — a listed crate that is missing is a
        // stale ratchet, and one that writes nothing is an exemption to delete — so a
        // fixture that left either out would fail every case above for a reason the case is
        // not about.
        for exempt in &super::SAMPLE_MEMORY {
            fixture
                .write(&format!("{}/Cargo.toml", exempt.crate_dir), APPLE_MANIFEST)
                .write(&format!("{}/src/lib.rs", exempt.crate_dir), ONE_RAW_SITE);
        }
        // Every crate booked over the size bar, each written at a width its booking is TRUE of:
        // over the bar and inside its cap. A booking whose crate reads UNDER the bar is a stale
        // excuse and fails, so a fixture that left these thin would fail every case above for a
        // reason the case is not about. This loop runs LAST because two crates are in both tables
        // and the sample-memory line has to survive the padding.
        for wide in &super::WIDE {
            let raw = if super::sample_memory_for(wide.crate_dir).is_some() {
                ONE_RAW_SITE
            } else {
                ""
            };
            fixture
                .write(&format!("{}/Cargo.toml", wide.crate_dir), APPLE_MANIFEST)
                .write(
                    &format!("{}/src/lib.rs", wide.crate_dir),
                    &format!("{raw}{}", "pub fn wide() {}\n".repeat(super::BAR + 1)),
                );
        }
        fixture
    }
}
