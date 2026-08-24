//! The config file, in C: where it is, what it resolves to, and the schema that describes it.
//!
//! The rules are `slopdesk_settings::config`; what is here is the marshalling — plus the file READ
//! itself, which stays on this side of the door for the same reason every other effect does. The
//! near side never opens the file, parses TOML, or holds a default of its own.
//!
//! Three doors, all cold: one at launch, one per reload, one when the CLI is asked for the schema.
//! Nothing here is called from a draw.

use core::ffi::c_uchar;
use std::path::Path;

use slopdesk_settings::config;

use crate::{borrow, deliver};

/// The environment variable that overrides the config-file location.
///
/// The CLI reads it to print `--config-file`'s effective source; nothing else needs it, because
/// [`slopdesk_config_path`] already applies it.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_config_env_key(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(config::path::CONFIG_FILE_ENV_KEY.as_bytes(), out, cap) }
}

/// The resolved config-file path, written into the lent buffer.
///
/// `explicit` is the caller's override — empty on macOS, and on iOS the app's own Documents
/// directory, which is the only place the file can be reached from the Files app. When it is empty
/// the real environment decides: `SLOPDESK_CONFIG_FILE`, then `XDG_CONFIG_HOME`, then `HOME`, then
/// the lent fallback.
///
/// The environment is read HERE rather than passed in pair by pair, as it was when this lived
/// beside the CLI's argument parsing: asking the environment is a system call, and system calls are
/// this side's.
///
/// # Safety
/// Both input pairs must be live for the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_config_path(
    explicit: *const c_uchar,
    explicit_len: usize,
    fallback: *const c_uchar,
    fallback_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the two input pairs.
    let (explicit, fallback) = unsafe {
        (
            String::from_utf8_lossy(borrow(explicit, explicit_len)).into_owned(),
            String::from_utf8_lossy(borrow(fallback, fallback_len)).into_owned(),
        )
    };
    let answer = config::path::resolve_path_from_env(Some(explicit.as_str()), &fallback);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The whole resolved configuration as one JSON snapshot: five maps by type, the two open tables,
/// and the diagnostics.
///
/// A missing file resolves to the defaults with no diagnostic — an install with no config file is
/// the supported shape, not a lesser one.
///
/// # Safety
/// The path pair must be live for the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_config_snapshot(
    path: *const c_uchar,
    path_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the path pair.
    let path = String::from_utf8_lossy(unsafe { borrow(path, path_len) }).into_owned();
    let snapshot = config::path::load(Path::new(&path)).snapshot_json();
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(snapshot.as_bytes(), out, cap) }
}

/// The JSON Schema for the config file, written out of the same table the snapshot resolves
/// against.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_config_schema(out: *mut c_uchar, cap: usize) -> usize {
    let schema = config::schema::json_schema();
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(schema.as_bytes(), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use super::{slopdesk_config_path, slopdesk_config_schema, slopdesk_config_snapshot};
    use crate::testing::delivered;

    /// Calls a `(ptr, len) -> (out, cap)` door with one lent string.
    fn answer(door: unsafe extern "C" fn(*const u8, usize, *mut u8, usize) -> usize, lent: &str) -> String {
        String::from_utf8(delivered(|out, cap| unsafe {
            door(lent.as_ptr(), lent.len(), out, cap)
        }))
        .unwrap_or_default()
    }

    #[test]
    fn an_explicit_path_crosses_back_unchanged() {
        let explicit = "/tmp/slopdesk-explicit.toml";
        let fallback = "/Users/nobody";
        let answered = String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_config_path(
                explicit.as_ptr(),
                explicit.len(),
                fallback.as_ptr(),
                fallback.len(),
                out,
                cap,
            )
        }))
        .unwrap_or_default();
        assert_eq!(answered, explicit);
    }

    #[test]
    fn a_file_that_is_not_there_answers_the_default_install() {
        let snapshot = answer(slopdesk_config_snapshot, "/nowhere/at/all/config.toml");
        assert!(
            snapshot.contains("\"controls.copy-on-select\":false"),
            "{snapshot}"
        );
        assert!(snapshot.ends_with("\"diagnostics\":[]}"), "{snapshot}");
    }

    #[test]
    fn a_written_file_reaches_the_snapshot() {
        let path = std::env::temp_dir().join("slopdesk-ffi-config-door.toml");
        drop(std::fs::write(&path, "[controls]\ncopy-on-select = true\n"));
        let snapshot = answer(slopdesk_config_snapshot, &path.to_string_lossy());
        drop(std::fs::remove_file(&path));
        assert!(
            snapshot.contains("\"controls.copy-on-select\":true"),
            "{snapshot}"
        );
    }

    #[test]
    fn the_schema_crosses_whole() {
        let schema = String::from_utf8(delivered(|out, cap| unsafe { slopdesk_config_schema(out, cap) }))
            .unwrap_or_default();
        assert!(schema.starts_with('{'));
        assert!(schema.contains("\"copy-on-select\""));
        assert_eq!(schema, slopdesk_settings::config::schema::json_schema());
    }
}
