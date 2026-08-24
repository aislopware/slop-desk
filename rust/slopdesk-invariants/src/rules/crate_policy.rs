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

/// The ONE `slopdesk-apple-*` crate exempt from the raw-pointer ban. See [`apple_family`].
const SAMPLE_MEMORY_CRATE: &str = "rust/slopdesk-apple-audio";

/// How many raw-pointer sites that exemption is worth today.
///
/// Two slice constructions over a captured buffer's runs, one flexible-array read of the buffer
/// list, one copy of the stream description, and the pointer arithmetic and slot writes the two
/// converter callbacks are, on both ends of the wire. The number is a RATCHET rather than a budget:
/// it is what the crate needs EXACTLY, and it moves only in a commit that says what the new site is
/// for. Slack here would be a budget to spend quietly, which is the thing a ratchet is not.
const SAMPLE_MEMORY_SITE_CAP: usize = 19;

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
/// ## The amendment, and why it is one crate and not a category
/// `slopdesk-apple-audio` is exempt from the raw-pointer ban, and it is the ONLY crate that is.
/// Every other framework in this family hands out OBJECTS — `objc2` models those, and the binding
/// answers the ownership question, so the crate never has to. Core Audio hands out SAMPLE MEMORY:
/// `AudioConverterFillComplexBuffer` takes a C input proc whose whole job is to publish a
/// `(pointer, length)` through an `AudioBufferList`, `CMSampleBuffer` delivers captured audio the
/// same way, and `AVAudioConverter`'s block API reaches the same samples through
/// `floatChannelData`, which is a `*mut NonNull<c_float>`. There is no version of that crate
/// without raw-pointer work, and the operation cannot move to `slopdesk-ffi` either —
/// `slopdesk-ffi` already depends on this family, so the reverse edge is a cycle.
///
/// What keeps this from being the hole a category would be is the SITE COUNT, the same instrument
/// the two Core Foundation admissions use. The exemption is a ratchet, not a door: the count below
/// is what the crate needs today, and a change that wants one more has to move it here and say why
/// in the same commit. Every other §2 obligation still applies to that crate and is still checked —
/// `unsafe_op_in_unsafe_fn`, the `objc2` edge, and one `CFRetained::from_raw`.
/// What one crate's sources spend, in the four counts §2 argues about.
#[derive(Default)]
struct Spend {
    /// Whether any Rust source was read at all. A ban that reads nothing passes for the wrong
    /// reason.
    read_any: bool,
    /// A raw-pointer operation outside both admissions, in a crate that is not the exempt one.
    hand_written: bool,
    /// The exempt crate's ratchet count. Always zero elsewhere.
    sample_memory_sites: usize,
    /// `CFRetained::from_raw`, the Copy/Create-rule admission. At most one per crate.
    copy_rule_sites: usize,
    /// `CFRetained::retain`, the Get-rule admission. At most one per crate, independently.
    get_rule_sites: usize,
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
        for line in file.code().lines() {
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
        let sample_memory = crate_dir == SAMPLE_MEMORY_CRATE;
        let Spend {
            read_any,
            hand_written,
            sample_memory_sites,
            copy_rule_sites,
            get_rule_sites,
        } = scan_spend(tree, &src, sample_memory);
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
        report.fail_if(
            sample_memory && sample_memory_sites == 0,
            format!(
                "{crate_dir} is the ONE crate exempt from the raw-pointer ban and writes none — the \
                 exemption exists because Core Audio publishes SAMPLE MEMORY as (pointer, length); a crate \
                 that no longer needs it should lose it, not keep it (docs/57 §2's amendment)",
            ),
        );
        report.fail_if(
            sample_memory_sites > SAMPLE_MEMORY_SITE_CAP,
            format!(
                "{crate_dir} touches raw pointers at {sample_memory_sites} sites — the sample-memory \
                 amendment is a RATCHET at {SAMPLE_MEMORY_SITE_CAP}, so a new site moves the cap here and \
                 says why in the same commit (docs/57 §2's amendment)",
            ),
        );
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
                "{crate_dir} takes a Core Foundation Get-rule retain in {get_rule_sites} places — the \
                 family admits CFRetained::retain at ONE site per crate, so the question 'is this borrowed \
                 pointer still the framework's' is answered once, at the boundary the framework hands it \
                 across (docs/57 §2)",
            ),
        );
    }
    report
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

    /// The amendment is one crate, and it is a RATCHET rather than a door: the exempt crate may
    /// write raw-pointer work, and a site past the cap fails exactly as a transmute elsewhere does.
    #[test]
    fn the_sample_memory_crate_is_exempt_up_to_its_cap() {
        let fixture = policy_fixture("apple-sample-memory");
        let one = "pub fn read() { let _ = unsafe { std::slice::from_raw_parts(base, len) }; }\n";
        fixture.write(
            &format!("{}/Cargo.toml", super::SAMPLE_MEMORY_CRATE),
            APPLE_MANIFEST,
        );
        fixture.write(&format!("{}/src/lib.rs", super::SAMPLE_MEMORY_CRATE), one);
        assert!(
            super::apple_family(&fixture.tree()).is_clean(),
            "the one exempt crate may publish sample memory"
        );

        // The same line in any OTHER crate of the family is still the ban's business.
        fixture.write("rust/slopdesk-apple-cgevent/src/lib.rs", one);
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
    /// nothing about what the crate actually needs.
    #[test]
    fn a_sample_memory_site_past_the_cap_is_caught() {
        let fixture = policy_fixture("apple-sample-cap");
        fixture.write(
            &format!("{}/Cargo.toml", super::SAMPLE_MEMORY_CRATE),
            APPLE_MANIFEST,
        );
        let over = "pub fn read() { let _ = unsafe { std::slice::from_raw_parts(base, len) }; }\n"
            .repeat(super::SAMPLE_MEMORY_SITE_CAP + 1);
        fixture.write(&format!("{}/src/lib.rs", super::SAMPLE_MEMORY_CRATE), &over);
        let report = super::apple_family(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("RATCHET")),
            "{report:?}"
        );
    }

    /// An exemption nothing spends is an exemption to delete, and it reads for years like a crate
    /// that needs it.
    #[test]
    fn an_unspent_sample_memory_exemption_is_caught() {
        let fixture = policy_fixture("apple-sample-unspent");
        fixture.write(
            &format!("{}/Cargo.toml", super::SAMPLE_MEMORY_CRATE),
            APPLE_MANIFEST,
        );
        fixture.write(
            &format!("{}/src/lib.rs", super::SAMPLE_MEMORY_CRATE),
            "pub fn f() {}\n",
        );
        let report = super::apple_family(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("writes none")),
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
        fixture
    }
}
