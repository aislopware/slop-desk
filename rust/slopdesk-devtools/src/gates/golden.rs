//! The golden regression pin: the wire corpus, byte for byte.
//!
//! `golden/golden_vectors.json` is the FROZEN source of truth for every codec's exact bytes.
//! `slopdesk-corevectors` regenerates the emitted subset from the live codecs; this gate asserts
//! they are byte-identical to the committed corpus. It is a regression pin, not a parity proof —
//! there is no second implementation to diff against since the Rust codecs were deleted.
//!
//! ## The key sets are PINNED, not inferred
//! Both buckets are exact: the generator must emit EXACTLY [`EMITTED_KEYS`], and the corpus must
//! hold EXACTLY [`EMITTED_KEYS`] ∪ [`FROZEN_KEYS`]. Deriving the diffed set as `corpus ∩ regen`
//! instead lets a key that stops being emitted slide silently into the un-diffed frozen bucket —
//! the gate prints one fewer emitted key and still PASSES, so a refactor that drops a `root["…"]`
//! assignment while changing that codec's bytes ships a changed wire under a green gate. Membership
//! drift in either direction is a hard failure naming the key.
//!
//! ## A frozen key is pinned by a SUITE, or it is not pinned at all
//! [`FROZEN_KEYS`] are in the corpus but not emitted, because their implementations live in modules
//! the generator does not import. That sentence used to be the whole guarantee, and for ten of the
//! thirteen it was false: `terminalModeTracker` was replayed by nothing, `inputMotionCoalesce` was
//! not named anywhere in the repository, and the capture / virtual-display / window-placement keys
//! were covered by a note claiming a `slopdesk_core` crate and a `golden_parity` test — neither of
//! which existed. Unread vectors do not stay true: `vdRefreshRates` had silently recorded a
//! superseded law since `6281fae2` changed it.
//!
//! So [`readers`] checks the claim. A reader must OPEN the corpus, not merely say the key's name:
//! the hand-written virtual-display suite named three of these in `// MARK:` headings above
//! assertions written by hand, which is exactly the shape that looks like coverage and is not. That
//! suite is gone — the arithmetic is `slopdesk_video::virtual_display`'s, and the four keys are
//! replayed from both sides, through the Swift face and through the rule.
//!
//! ## Updating the corpus
//! Regenerate with NO `SLOPDESK_*` env set and merge surgically — never `>` over
//! `golden/golden_vectors.json`, which drops the frozen keys the generator does not emit. A NEW
//! vector key must also be added to [`EMITTED_KEYS`], or this gate fails by design.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use serde_json::Value;

/// The committed corpus.
pub const CORPUS: &str = "golden/golden_vectors.json";

/// Every key `slopdesk-corevectors` emits. Exact in both directions.
pub const EMITTED_KEYS: &[&str] = &[
    "adaptiveGroupSize",
    "adaptiveTier",
    "audioWire",
    "blocksWireMessages",
    "coordWindowPoint",
    "cursorShape",
    "cursorUpdate",
    "fecParity",
    "fecRecover",
    "fragmentEncode",
    "inputEvent",
    "metadataCodecPayloads",
    "metadataWireMessages",
    "muxBare",
    "muxEnvelopes",
    "muxFragment",
    "owdLateDrive",
    "pacerDepthFloats",
    "pacerDepthHinted",
    "recovery",
    "swipeNavStatus",
    "terminalWireMessages",
    "trendlineDrive",
    "udpBackoff",
    "udpRearm",
    "videoControl",
    "windowGeometry",
    "workspaceIntentArgs",
    "workspaceIntentOps",
    "workspaceStateCodec",
    "workspaceWireMessages",
    "ycbcr",
];

/// In the corpus, NOT emitted; pinned by their own suites. See the module docs before touching.
pub const FROZEN_KEYS: &[&str] = &[
    "captureRetarget",
    "captureUnion",
    "fpsGovernorEwma",
    "hostOutputSniffer",
    "inputMotionCoalesce",
    "inspectorEvents",
    "naluJoin",
    "naluSplit",
    "networkEstimateFold",
    "sizeNegotiationClamp",
    "sizeNegotiationEpoch",
    "staticIdrDrive",
    "systemDialogClassify",
    "systemDialogDetect",
    "terminalModeTracker",
    "vdChipPixelLimit",
    "vdOriginToRight",
    "vdRefreshRates",
    "virtualDisplayGeometry",
    "windowFits",
    "windowPlacement",
];

/// A file counts as a reader only if it also mentions one of these.
const CORPUS_MENTIONS: &[&str] = &["golden_vectors", "GoldenCorpus"];

/// Where a reader may live: a Swift suite under `Tests/`, or a Rust INTEGRATION test.
///
/// `rust/*/tests` and not `rust/` — a crate's own `src/` is not a replay. This module names every
/// frozen key and opens the corpus, so a walk over all of `rust/` would find THIS file as a reader
/// for all thirteen and the check could never fail again.
const READER_TREES: &[&str] = &["Tests"];

/// The other half: each `rust/<crate>/tests` directory, one level down.
const RUST_TESTS: &str = "rust";

/// One thing wrong with the pin, phrased for the author who has to fix it.
pub type Failure = String;

/// A key set, as a set.
fn set(keys: &[&str]) -> BTreeSet<String> {
    keys.iter().map(|key| (*key).to_owned()).collect()
}

/// The top-level keys of a JSON object.
///
/// # Errors
/// When the text is not a JSON object.
pub fn keys_of(json: &str) -> Result<BTreeSet<String>, String> {
    let document: Value = serde_json::from_str(json).map_err(|error| error.to_string())?;
    let object = document
        .as_object()
        .ok_or_else(|| "not a JSON object".to_owned())?;
    Ok(object.keys().cloned().collect())
}

/// Compare the corpus against a fresh generation, and report every disagreement.
///
/// Returns the number of keys byte-diffed alongside the failures, because "0 diffed, PASS" is a
/// reading a gate must never print without the count that exposes it.
///
/// # Errors
/// When either document is not a JSON object.
pub fn verdict(corpus_json: &str, regenerated_json: &str) -> Result<(usize, Vec<Failure>), String> {
    let corpus: Value = serde_json::from_str(corpus_json).map_err(|error| format!("corpus: {error}"))?;
    let regenerated: Value =
        serde_json::from_str(regenerated_json).map_err(|error| format!("regenerated: {error}"))?;
    let emitted = set(EMITTED_KEYS);
    let frozen = set(FROZEN_KEYS);
    let mut failures = Vec::new();

    // A key in both buckets would make the corpus assertion pass while excusing a dropped emission.
    let overlap: Vec<&String> = emitted.intersection(&frozen).collect();
    if !overlap.is_empty() {
        failures.push(format!(
            "pin is self-inconsistent — both emitted and frozen: {overlap:?}"
        ));
    }

    let present = keys_of(regenerated_json).map_err(|error| format!("regenerated: {error}"))?;
    pin(
        "generator",
        &emitted,
        &present,
        "pinned key NO LONGER EMITTED (add the emission back, or move it to FROZEN_KEYS with a suite that \
         pins its bytes)",
        "emits UNPINNED key (hand-merge it into the corpus and add it to EMITTED_KEYS)",
        &mut failures,
    );
    let held = keys_of(corpus_json).map_err(|error| format!("corpus: {error}"))?;
    pin(
        "corpus",
        &emitted.union(&frozen).cloned().collect(),
        &held,
        "pinned key MISSING FROM THE CORPUS (a `>`-redirect over golden_vectors.json does this)",
        "holds UNPINNED key (add it to EMITTED_KEYS or FROZEN_KEYS)",
        &mut failures,
    );

    // Byte-diff over the keys present on BOTH sides, so a set drift reports as a set drift rather
    // than as a missing key. The pins above independently guarantee this covers all of EMITTED_KEYS.
    let diffed: Vec<&String> = emitted
        .iter()
        .filter(|key| held.contains(*key) && present.contains(*key))
        .collect();
    let diverged: Vec<&&String> = diffed
        .iter()
        .filter(|key| canonical(&corpus[key.as_str()]) != canonical(&regenerated[key.as_str()]))
        .collect();
    if !diverged.is_empty() {
        failures.push(format!(
            "DIVERGED bytes ({}): {:?}",
            diverged.len(),
            diverged.iter().map(|key| key.as_str()).collect::<Vec<_>>()
        ));
    }
    Ok((diffed.len(), failures))
}

/// Assert an exact key set, naming BOTH drift directions.
fn pin(
    label: &str,
    expected: &BTreeSet<String>,
    actual: &BTreeSet<String>,
    gone: &str,
    new: &str,
    into: &mut Vec<Failure>,
) {
    let missing: Vec<&String> = expected.difference(actual).collect();
    if !missing.is_empty() {
        into.push(format!("{label}: {gone}: {missing:?}"));
    }
    let extra: Vec<&String> = actual.difference(expected).collect();
    if !extra.is_empty() {
        into.push(format!("{label}: {new}: {extra:?}"));
    }
}

/// A value in one canonical spelling, so key order and float formatting cannot fake a difference.
fn canonical(value: &Value) -> String {
    match value {
        Value::Object(fields) => {
            let sorted: Vec<String> = fields
                .iter()
                .collect::<std::collections::BTreeMap<_, _>>()
                .into_iter()
                .map(|(key, nested)| format!("{}:{}", Value::String(key.clone()), canonical(nested)))
                .collect();
            format!("{{{}}}", sorted.join(","))
        },
        Value::Array(items) => format!("[{}]", items.iter().map(canonical).collect::<Vec<_>>().join(",")),
        other => other.to_string(),
    }
}

/// Every frozen key with no file that both NAMES it and OPENS the corpus.
///
/// # Errors
/// When a reader tree cannot be walked.
pub fn readers(root: &Path) -> Result<Vec<String>, String> {
    let mut candidates = Vec::new();
    for tree in READER_TREES {
        collect(&root.join(tree), &mut candidates)?;
    }
    for crate_dir in crate_test_dirs(root)? {
        collect(&crate_dir, &mut candidates)?;
    }
    let bodies: Vec<String> = candidates
        .iter()
        .map(|path| fs::read_to_string(path).unwrap_or_default())
        .collect();
    Ok(FROZEN_KEYS
        .iter()
        .filter(|key| {
            !bodies
                .iter()
                .any(|body| body.contains(**key) && CORPUS_MENTIONS.iter().any(|mark| body.contains(mark)))
        })
        .map(|key| (*key).to_owned())
        .collect())
}

/// Regenerate the emitted subset from the live codecs.
///
/// Every `SLOPDESK_*` variable is stripped from the child's environment: the generator must resolve
/// its compile-time-const defaults, and a developer's own override would silently regenerate a
/// different corpus than the one committed.
///
/// # Errors
/// When the generator cannot be run, or exits non-zero.
pub fn regenerate(root: &Path) -> Result<String, String> {
    let mut command = std::process::Command::new("swift");
    command
        .args(["run", "-q", "slopdesk-corevectors"])
        .current_dir(root);
    for (name, _) in std::env::vars_os().filter_map(|(name, value)| {
        name.to_str()
            .filter(|text| text.starts_with("SLOPDESK_"))
            .map(|text| (text.to_owned(), value))
    }) {
        command.env_remove(name);
    }
    let output = command
        .stderr(std::process::Stdio::inherit())
        .output()
        .map_err(|error| format!("swift run slopdesk-corevectors: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "slopdesk-corevectors exited {}",
            output.status.code().unwrap_or(-1)
        ));
    }
    String::from_utf8(output.stdout).map_err(|_| "the generator wrote output that is not UTF-8".to_owned())
}

/// The whole gate: regenerate, pin the key sets, byte-diff, then prove every frozen key has a
/// reader.
///
/// The corpus is only ever READ here. Regeneration goes to memory, never over the committed file.
///
/// # Errors
/// When the corpus cannot be read, the generator fails, or any pin is violated.
pub fn run(root: &Path) -> Result<(), String> {
    let corpus_text = fs::read_to_string(root.join(CORPUS)).map_err(|error| format!("{CORPUS}: {error}"))?;
    let regenerated = regenerate(root)?;
    let (diffed, failures) = verdict(&corpus_text, &regenerated)?;

    println!("golden-check: {diffed} emitted keys diffed vs {CORPUS}");
    if !failures.is_empty() {
        for failure in &failures {
            println!("  FAIL — {failure}");
        }
        return Err("golden-check: the pin is violated".to_owned());
    }
    println!("  PASS — all emitted keys byte-identical");
    println!(
        "  ({} frozen keys are suite-pinned, not emitted: {FROZEN_KEYS:?})",
        FROZEN_KEYS.len()
    );

    let unread = readers(root)?;
    if !unread.is_empty() {
        eprintln!(
            "golden-check: FAIL — frozen key with NO reader: {}",
            unread.join(" ")
        );
        eprintln!("  A frozen key is pinned by a suite that replays it, or it is not pinned at all.");
        return Err("golden-check: an unread frozen key".to_owned());
    }
    println!("golden-check: every frozen key has a suite that replays it.");
    Ok(())
}

/// Every `rust/<crate>/tests` that exists.
fn crate_test_dirs(root: &Path) -> Result<Vec<std::path::PathBuf>, String> {
    let rust = root.join(RUST_TESTS);
    if !rust.is_dir() {
        return Ok(Vec::new());
    }
    let entries = fs::read_dir(&rust).map_err(|error| format!("{}: {error}", rust.display()))?;
    let mut found: Vec<std::path::PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path().join("tests")))
        .filter(|path| path.is_dir())
        .collect();
    found.sort_unstable();
    Ok(found)
}

/// Every Swift and Rust source under `dir`, skipping build output.
fn collect(dir: &Path, into: &mut Vec<std::path::PathBuf>) -> Result<(), String> {
    if !dir.is_dir() {
        return Ok(());
    }
    let entries = fs::read_dir(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    for entry in entries {
        let path = entry.map_err(|error| error.to_string())?.path();
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        if path.is_dir() {
            if name != "target" && name != ".build" {
                collect(&path, into)?;
            }
        } else if matches!(
            path.extension().and_then(|value| value.to_str()),
            Some("swift" | "rs")
        ) {
            into.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{EMITTED_KEYS, FROZEN_KEYS, canonical, keys_of, verdict};

    /// The two buckets must not overlap, which the verdict also checks at run time.
    #[test]
    fn the_two_buckets_are_disjoint() {
        for key in EMITTED_KEYS {
            assert!(!FROZEN_KEYS.contains(key), "{key} is in both buckets");
        }
    }

    fn corpus_of(pairs: &[(&str, &str)]) -> String {
        let body: Vec<String> = pairs
            .iter()
            .map(|(key, value)| format!("\"{key}\":{value}"))
            .collect();
        format!("{{{}}}", body.join(","))
    }

    /// The whole point: identical bytes under a different key ORDER is not a difference.
    #[test]
    fn key_order_is_not_a_difference() {
        let corpus = corpus_of(&[("muxBare", r#"{"a":1,"b":2}"#)]);
        let regen = corpus_of(&[("muxBare", r#"{"b":2,"a":1}"#)]);
        let (_, failures) = verdict(&corpus, &regen).unwrap();
        assert!(
            failures.iter().all(|line| !line.contains("DIVERGED")),
            "{failures:?}"
        );
    }

    #[test]
    fn a_changed_byte_is_a_divergence() {
        let corpus = corpus_of(&[("muxBare", r#"{"a":1}"#)]);
        let regen = corpus_of(&[("muxBare", r#"{"a":2}"#)]);
        let (_, failures) = verdict(&corpus, &regen).unwrap();
        assert!(
            failures.iter().any(|line| line.contains("DIVERGED")),
            "{failures:?}"
        );
    }

    /// The failure the exact-set rule exists for: a key that stops being emitted.
    #[test]
    fn a_key_that_stops_being_emitted_fails_rather_than_going_quiet() {
        let corpus = corpus_of(&[("muxBare", "1"), ("captureUnion", "1")]);
        let regen = corpus_of(&[("captureUnion", "1")]);
        let (_, failures) = verdict(&corpus, &regen).unwrap();
        assert!(
            failures.iter().any(|line| line.contains("NO LONGER EMITTED")),
            "{failures:?}"
        );
    }

    #[test]
    fn a_key_the_pin_never_heard_of_fails_in_both_documents() {
        let corpus = corpus_of(&[("surprise", "1")]);
        let regen = corpus_of(&[("surprise", "1")]);
        let (_, failures) = verdict(&corpus, &regen).unwrap();
        assert!(
            failures.iter().any(|line| line.contains("emits UNPINNED key")),
            "{failures:?}"
        );
        assert!(
            failures.iter().any(|line| line.contains("holds UNPINNED key")),
            "{failures:?}"
        );
    }

    /// What a `>`-redirect over the corpus looks like from here.
    #[test]
    fn a_corpus_missing_its_frozen_keys_fails() {
        let corpus = corpus_of(&[("muxBare", "1")]);
        let regen = corpus_of(&[("muxBare", "1")]);
        let (_, failures) = verdict(&corpus, &regen).unwrap();
        assert!(
            failures
                .iter()
                .any(|line| line.contains("MISSING FROM THE CORPUS") && line.contains("captureUnion")),
            "{failures:?}"
        );
    }

    #[test]
    fn canonical_sorts_nested_objects_too() {
        let left: serde_json::Value = serde_json::from_str(r#"{"x":{"b":1,"a":[2,3]}}"#).unwrap();
        let right: serde_json::Value = serde_json::from_str(r#"{"x":{"a":[2,3],"b":1}}"#).unwrap();
        assert_eq!(canonical(&left), canonical(&right));
    }

    /// The gate must not be able to read ITSELF.
    ///
    /// This module names all thirteen frozen keys and mentions the corpus, so a reader walk over
    /// `rust/` rather than `rust/*/tests` finds it as the reader for every one of them and the
    /// check can never fail again — a gate that cannot fail, found by break-test, pinned here.
    #[test]
    fn a_crates_own_source_is_not_a_reader() {
        let root = std::env::temp_dir().join(format!("slopdesk-golden-{}", std::process::id()));
        let _ignored = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("rust/slopdesk-thing/src")).unwrap();
        fs::create_dir_all(root.join("rust/slopdesk-thing/tests")).unwrap();
        fs::create_dir_all(root.join("Tests")).unwrap();
        let claim = "naluJoin golden_vectors\n";
        fs::write(root.join("rust/slopdesk-thing/src/lib.rs"), claim).unwrap();
        assert!(
            super::readers(&root).unwrap().contains(&"naluJoin".to_owned()),
            "a crate's own src/ was accepted as a replay"
        );

        fs::write(root.join("rust/slopdesk-thing/tests/golden.rs"), claim).unwrap();
        assert!(!super::readers(&root).unwrap().contains(&"naluJoin".to_owned()));
    }

    /// Naming the key is not enough — the file has to OPEN the corpus.
    #[test]
    fn a_file_that_only_says_the_name_is_not_a_reader() {
        let root = std::env::temp_dir().join(format!("slopdesk-golden-name-{}", std::process::id()));
        let _ignored = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("Tests")).unwrap();
        fs::write(
            root.join("Tests/Hand.swift"),
            "// MARK: naluJoin\nXCTAssertEqual(1, 1)\n",
        )
        .unwrap();
        assert!(super::readers(&root).unwrap().contains(&"naluJoin".to_owned()));
    }

    #[test]
    fn a_document_that_is_not_an_object_is_an_error() {
        assert!(keys_of("[1,2]").is_err());
        assert!(keys_of("nope").is_err());
    }
}
