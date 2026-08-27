//! Writes `docs/config.schema.json` from the key table — what `just config-schema` runs.
//!
//! The schema is generated, never edited: it is a second declaration of every key, and a
//! hand-maintained one would drift the day somebody added a row. This binary is the only writer,
//! and `tests/checked_in_schema.rs` is the gate that says the checked-in copy still matches — so
//! the file in `docs/` is an ARTIFACT with a producer, not a document with an author.
//!
//! It writes the file itself rather than printing to stdout on purpose. A `>`-redirect is one
//! mistyped path from truncating something else, and a half-written redirect on a failed run leaves
//! an empty schema that looks checked in.
//!
//! The path is resolved from `CARGO_MANIFEST_DIR`, so it does not matter which directory the
//! invocation started in.

use std::path::PathBuf;

#[expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "a generator run reports the path it wrote, and its failure, on the streams make reads"
)]
fn main() -> std::process::ExitCode {
    let root = match PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
    {
        Ok(root) => root,
        Err(why) => {
            eprintln!("write-config-schema: the repo root two directories up: {why}");
            return std::process::ExitCode::FAILURE;
        },
    };
    let path = root.join("docs/config.schema.json");
    match std::fs::write(&path, slopdesk_settings::config::schema::json_schema()) {
        Ok(()) => {
            println!("wrote {}", path.display());
            std::process::ExitCode::SUCCESS
        },
        Err(why) => {
            eprintln!("write-config-schema: {}: {why}", path.display());
            std::process::ExitCode::FAILURE
        },
    }
}
