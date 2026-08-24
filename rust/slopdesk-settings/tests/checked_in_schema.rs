//! The checked-in `docs/config.schema.json` is the one this build generates.
//!
//! The schema is what makes a file-only settings system usable — the editor completes the key,
//! prints its sentence and underlines a value outside its range — and a starter `config.toml`
//! points at a copy of it. That means a STALE schema is worse than none: it tells the reader a key
//! exists that this build ignores, or refuses one this build honours, and it does so in the editor
//! where a reader is most likely to believe it.
//!
//! Nothing but a `make config-schema` away from green:
//! `cargo run --bin write-config-schema` (or `make config-schema`) rewrites it.
//!
//! This lives here rather than in `slopdesk-invariants` because it is not a pattern over the tree —
//! it is the generator's own output compared to the artifact, and only this crate can produce it.

use std::path::PathBuf;

/// The artifact, read from the repo the crate sits in.
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, and both messages name the fix"
)]
fn checked_in() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/config.schema.json")
        .canonicalize()
        .expect("docs/config.schema.json is checked in — run `make config-schema`");
    std::fs::read_to_string(path).expect("docs/config.schema.json is readable")
}

#[test]
fn the_checked_in_schema_is_the_one_this_build_writes() {
    let generated = slopdesk_settings::config::schema::json_schema();
    let stored = checked_in();
    assert!(
        stored == generated,
        "docs/config.schema.json is stale — run `make config-schema`.\nchecked in {} bytes, this build \
         writes {} bytes; first difference at byte {}",
        stored.len(),
        generated.len(),
        stored
            .bytes()
            .zip(generated.bytes())
            .position(|(a, b)| a != b)
            .unwrap_or_else(|| stored.len().min(generated.len())),
    );
}

/// The two facts a reader's editor depends on, asserted on the ARTIFACT rather than on the
/// generator: a schema that lost its `$schema` line is not a schema any editor will load, and one
/// that lost `additionalProperties: false` stops underlining the typo it exists to catch.
#[test]
fn the_artifact_is_a_draft_2020_12_schema_that_refuses_unknown_keys() {
    let stored = checked_in();
    assert!(stored.contains("\"$schema\": \"https://json-schema.org/draft/2020-12/schema\""));
    assert!(stored.contains("\"additionalProperties\": false"));
    assert!(
        stored.ends_with('\n'),
        "the artifact ends with a newline, so a diff of two builds is a diff of the table"
    );
}
