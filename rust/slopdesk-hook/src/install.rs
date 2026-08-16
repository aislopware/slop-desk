//! `slopdesk integration install claude` — the merge that wires Claude Code's hooks to the relay.
//!
//! ## Why this lives in the relay's crate
//! Every string here describes the RELAY: the command an installed entry runs is a path to a copy
//! of it, and the sentinel that identifies our entries ([`HOOK_MARKER`]) is the basename that copy
//! is installed under. Two crates would be two places to change one name, and the failure mode of
//! getting it wrong is silent — a marker that no longer matches the installed command turns
//! [`remove`] into a no-op and [`merge`] into a duplicator, with no error anywhere.
//!
//! It ships as a SECOND BINARY rather than a subcommand of the relay, and that is not a style
//! choice. The relay is forked twice per tool call and its whole cost is process startup, so its
//! dependency list is a latency budget. `serde_json` is reachable only from `slopdesk-agenthooks`,
//! so the linker leaves it out of the relay: measured at the release profile, the relay binary is
//! byte-for-byte the same size with this module in the crate as without it.
//!
//! ## Validate-then-repair, everywhere
//! This writes a file the user also edits by hand. A settings file that is missing, unreadable, not
//! JSON, or not an object is treated as an empty root rather than an error — the alternative is an
//! install that refuses to proceed because of a stray comma in a key we do not own. Only the two
//! steps that can lose data throw: staging the binary, and the write itself.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

/// A sentinel substring embedded in every command we install, so the merge can identify OUR hook
/// command blocks (for idempotency and removal) without touching the user's own hooks for the same
/// event.
///
/// It is not a separate token bolted onto the command: it is the BASENAME the relay is installed
/// under, so any entry built from [`hook_command`] carries it by construction.
pub const HOOK_MARKER: &str = "slopdesk-agent";

/// The relay binary's name as it ships beside this one — what [`install`] copies to the hook path.
pub const RELAY_NAME: &str = "slopdesk-hook";

/// The Claude Code hook events we install (`docs/41` §2.6).
///
/// Each drives a status transition through the status machine: `SessionStart`→idle,
/// `UserPromptSubmit`/`PreToolUse`/`PostToolUse`→working (`PreToolUse` of
/// `AskUserQuestion`→blocked), `PermissionRequest`/`Notification`→blocked,
/// `Stop`/`StopFailure`→done, `SessionEnd`→none, `PreCompact`→(no status; it arms the compaction
/// marker so the `Stop` ending a `/compact` lands on idle rather than announcing a finished task).
///
/// Deliberately NOT installed: `SubagentStart`/`SubagentStop` — a subagent completing after the
/// main turn stopped must never revive an idle pane.
///
/// `PreCompact` was in that same excluded list until 2026-08-10, on the reading that it has "no
/// status meaning". It has no status of its OWN — that much was right — but it is the only signal
/// that distinguishes the two things a `Stop` can mean, and without it finishing a `/compact` fired
/// the full done treatment (banner, unread badge) for housekeeping the user had just watched.
pub const INSTALLED_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    // A tool that FAILS or is interrupted emits this INSTEAD of `PostToolUse`, with the same
    // `tool_use_id` — the only thing that can resolve that call's block-ledger entry.
    "PostToolUseFailure",
    "PermissionRequest",
    // …and its "no" answer. The next `PreToolUse` would clear the block too (a permission dialog is
    // modal), but that is an inference standing in for an announcement.
    "PermissionDenied",
    // MCP structured input: the same block a permission dialog is, with its own id namespace.
    // Otherwise caught only by text-classifying a `Notification` as `elicitation_dialog`.
    "Elicitation",
    "ElicitationResult",
    "Notification",
    "Stop",
    "StopFailure",
    "SessionEnd",
    "PreCompact",
];

// MARK: - The pure merge

/// Merges our hook entries (one per [`INSTALLED_EVENTS`] event, each running `command`) into a
/// decoded `settings.json` root.
///
/// Idempotent by construction: it first strips the entries we previously installed, then appends
/// the current one, so running it twice produces the same file as running it once. A non-object
/// root is REPLACED by a minimal `{"hooks": …}` — a corrupt settings file never blocks an install —
/// while every unrelated key and every hook entry that is not ours survives untouched.
#[must_use]
pub fn merge(root: Value, command: &str) -> Value {
    let stripped = remove(root);
    let Value::Object(object) = stripped else {
        // Corrupt / non-object settings → build a minimal valid root carrying only hooks.
        let mut fresh = Map::new();
        fresh.insert("hooks".to_owned(), fresh_hooks(command));
        return Value::Object(fresh);
    };

    let mut object = object;
    let mut hooks = match object.get("hooks") {
        Some(Value::Object(existing)) => existing.clone(),
        _ => Map::new(),
    };
    for event in INSTALLED_EVENTS {
        let ours = command_block(command);
        // Append to the user's existing entries for this event rather than replacing them: a hook
        // list is additive, and the entry we own is the only one this file has any claim on.
        match hooks.get_mut(*event) {
            Some(Value::Array(entries)) => entries.push(ours),
            _ => {
                hooks.insert((*event).to_owned(), Value::Array(vec![ours]));
            },
        }
    }
    object.insert("hooks".to_owned(), Value::Object(hooks));
    Value::Object(object)
}

/// Removes exactly OUR hook entries (matched by [`HOOK_MARKER`]) from a decoded settings root.
///
/// The user's own hooks and every other setting survive. An event whose only entries were ours is
/// dropped from `hooks`; an emptied `hooks` map is removed entirely, so an uninstall leaves a file
/// indistinguishable from one we never touched. A non-object root comes back unchanged — there is
/// nothing of ours in it to strip.
#[must_use]
pub fn remove(root: Value) -> Value {
    let Value::Object(object) = root else {
        return root;
    };
    let Some(Value::Object(hooks)) = object.get("hooks") else {
        return Value::Object(object);
    };

    let mut kept_hooks = Map::new();
    for (event, value) in hooks {
        let Value::Array(entries) = value else {
            // Not an array we manage — keep it verbatim rather than guessing at its shape.
            kept_hooks.insert(event.clone(), value.clone());
            continue;
        };
        let kept: Vec<Value> = entries
            .iter()
            .filter(|entry| !entry_is_ours(entry))
            .cloned()
            .collect();
        if !kept.is_empty() {
            kept_hooks.insert(event.clone(), Value::Array(kept));
        }
        // else: the event had only our entries → drop the now-empty event key.
    }

    let mut object = object;
    if kept_hooks.is_empty() {
        object.remove("hooks");
    } else {
        object.insert("hooks".to_owned(), Value::Object(kept_hooks));
    }
    Value::Object(object)
}

/// True when one hook ENTRY (`{matcher?, hooks: [{type, command}]}`) is one of ours — it carries a
/// command block whose command contains [`HOOK_MARKER`].
fn entry_is_ours(entry: &Value) -> bool {
    let Some(Value::Array(blocks)) = entry.get("hooks") else {
        return false;
    };
    blocks.iter().any(|block| {
        block
            .get("command")
            .and_then(Value::as_str)
            .is_some_and(|command| command.contains(HOOK_MARKER))
    })
}

/// One hook ENTRY for an event: `{"hooks": [{"type": "command", "command": <cmd>}]}`.
///
/// No `matcher`, so it matches every occurrence of the event — the listener classifies the payload
/// itself, and a matcher here would be a second, staler copy of that decision.
fn command_block(command: &str) -> Value {
    let mut block = Map::new();
    block.insert("type".to_owned(), Value::String("command".to_owned()));
    block.insert("command".to_owned(), Value::String(command.to_owned()));
    let mut entry = Map::new();
    entry.insert("hooks".to_owned(), Value::Array(vec![Value::Object(block)]));
    Value::Object(entry)
}

/// A fresh `hooks` object (every installed event → one block) for the corrupt-root path.
fn fresh_hooks(command: &str) -> Value {
    let mut hooks = Map::new();
    for event in INSTALLED_EVENTS {
        hooks.insert((*event).to_owned(), Value::Array(vec![command_block(command)]));
    }
    Value::Object(hooks)
}

/// The command string an installed entry runs: the relay, quoted so a home directory with a space
/// in it still executes.
///
/// The path ends in [`HOOK_MARKER`], which is what makes the entry recognisable to
/// [`entry_is_ours`] — the marker is never written separately.
#[must_use]
pub fn hook_command(hook_path: &Path) -> String {
    format!("\"{}\"", hook_path.display())
}

// MARK: - Where the files are

/// The environment these resolvers read, passed rather than sampled.
///
/// The same discipline the profile seeder's paths use, and for the same reason: a resolver that
/// reaches for ambient process state cannot be tested against a home directory the test machine
/// does not have.
pub type Environment = BTreeMap<String, String>;

/// This process's environment.
#[must_use]
pub fn process_environment() -> Environment {
    std::env::vars().collect()
}

/// The Claude config base dir: `$CLAUDE_CONFIG_DIR` when set (tilde-expanded), else `~/.claude`.
#[must_use]
pub fn config_base(environment: &Environment, home: &str) -> PathBuf {
    match environment.get("CLAUDE_CONFIG_DIR") {
        Some(dir) if !dir.is_empty() => {
            dir.strip_prefix('~').map_or_else(
                || PathBuf::from(dir),
                |rest| PathBuf::from(format!("{home}{rest}")),
            )
        },
        _ => PathBuf::from(home).join(".claude"),
    }
}

/// The Claude Code settings file we merge into.
#[must_use]
pub fn settings_path(environment: &Environment, home: &str) -> PathBuf {
    config_base(environment, home).join("settings.json")
}

/// Where the relay is installed. The basename IS [`HOOK_MARKER`].
#[must_use]
pub fn hook_path(environment: &Environment, home: &str) -> PathBuf {
    config_base(environment, home).join("hooks").join(HOOK_MARKER)
}

/// The home directory, from the environment the way every child of ours resolves it.
///
/// Empty when there is no `HOME` at all, which makes the resulting paths relative and the install
/// fail visibly rather than seeding a directory nobody will look in.
#[must_use]
pub fn home_in(environment: &Environment) -> String {
    environment.get("HOME").cloned().unwrap_or_default()
}

// MARK: - The disk shim

/// Reads and decodes `settings.json`, answering an empty object for a missing, unreadable or
/// non-JSON file. Never an error: see the module note on validate-then-repair.
#[must_use]
pub fn read_settings(path: &Path) -> Value {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_else(|| Value::Object(Map::new()))
}

/// Encodes `root` sorted and pretty, then replaces `path` atomically.
///
/// Sorted comes free: `serde_json`'s object is a `BTreeMap`, which is what Foundation's
/// `.sortedKeys` produced here before the port. The one byte-level difference from the Swift
/// encoder is that `/` is no longer written as `\/` — Foundation escapes it by default and
/// `serde_json` does not. Both decode to the same string, so the only visible effect is that the
/// installed command in a user's settings file is now a readable path.
///
/// # Errors
/// The parent directory could not be created, or the staged file could not be written or renamed.
pub fn write_settings(root: &Value, path: &Path) -> io::Result<String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let text = serde_json::to_string_pretty(root)?;
    // Same directory as the target, so the rename is a rename and not a cross-device copy.
    let staged = path.with_extension("json.slopdesk-staging");
    std::fs::write(&staged, text.as_bytes())?;
    std::fs::rename(&staged, path)?;
    Ok(text)
}

/// True iff `settings` carries one of OUR hook entries for EVERY event in [`INSTALLED_EVENTS`].
///
/// ALL, not ANY, and the asymmetry is deliberate. A settings file written by an older build carries
/// the events THAT build knew; answering "installed" for it would leave the newer ones permanently
/// unregistered while the row offering the fix reads as already done. Under-reporting is the safe
/// direction — [`merge`] is idempotent, so re-installing over a complete install costs nothing,
/// while the reverse is a silently degraded pane forever.
#[must_use]
pub fn is_installed(settings: &Path) -> bool {
    let root = read_settings(settings);
    let Some(Value::Object(hooks)) = root.get("hooks") else {
        return false;
    };
    INSTALLED_EVENTS.iter().all(|event| {
        matches!(hooks.get(*event), Some(Value::Array(entries))
            if entries.iter().any(entry_is_ours))
    })
}

/// Stages the relay at `hook` and merges the hook config into `settings`.
///
/// The relay is copied through a staging name and RENAMED into place rather than written over: the
/// binary at `hook` may be mid-exec in another pane's hook at this instant, and a copy that wrote
/// through the inode would corrupt a running process. A rename swaps the directory entry and leaves
/// the running image alone.
///
/// # Errors
/// Only from the two steps that can lose something — staging the relay (it is missing, or the hooks
/// directory cannot be written) and writing the settings. The merge itself cannot fail.
pub fn install(settings: &Path, hook: &Path, relay: &Path) -> io::Result<String> {
    if !relay.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("the hook relay is missing at {}", relay.display()),
        ));
    }
    let Some(directory) = hook.parent() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} has no parent directory", hook.display()),
        ));
    };
    std::fs::create_dir_all(directory)?;
    let staged = directory.join(format!("{RELAY_NAME}.staging"));
    std::fs::copy(relay, &staged)?;
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&staged, hook)?;

    let merged = merge(read_settings(settings), &hook_command(hook));
    write_settings(&merged, settings)
}

/// Strips exactly our entries from `settings`.
///
/// The staged relay is left where it is — harmless, and a re-install reuses it.
///
/// # Errors
/// The settings file could not be written.
pub fn uninstall(settings: &Path) -> io::Result<String> {
    let stripped = remove(read_settings(settings));
    write_settings(&stripped, settings)
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    /// A scratch directory that cleans up after itself — the crate takes no dev-dependencies for
    /// the same reason it takes almost no dependencies.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(label: &str) -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "slopdesk-agenthooks-{label}-{}-{unique}",
                std::process::id()
            ));
            std::fs::create_dir_all(&path).expect("scratch dir");
            Self(path)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _unused = std::fs::remove_dir_all(&self.0);
        }
    }

    fn environment(pairs: &[(&str, &str)]) -> Environment {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    fn ours() -> &'static str {
        "\"/Users/ada/.claude/hooks/slopdesk-agent\""
    }

    fn hooks_of(root: &Value) -> &Map<String, Value> {
        root.get("hooks").unwrap().as_object().unwrap()
    }

    // MARK: The merge

    #[test]
    fn merge_installs_every_event_we_declare() {
        let merged = merge(Value::Object(Map::new()), ours());
        let hooks = hooks_of(&merged);
        assert_eq!(hooks.len(), INSTALLED_EVENTS.len());
        for event in INSTALLED_EVENTS {
            let entries = hooks.get(*event).unwrap().as_array().unwrap();
            assert_eq!(entries.len(), 1, "{event}");
            assert!(entry_is_ours(&entries[0]), "{event}");
        }
    }

    #[test]
    fn merge_is_idempotent_however_many_times_it_runs() {
        let once = merge(Value::Object(Map::new()), ours());
        let twice = merge(once.clone(), ours());
        let thrice = merge(twice.clone(), ours());
        assert_eq!(once, twice);
        assert_eq!(twice, thrice);
    }

    #[test]
    fn merge_preserves_unrelated_settings_and_unrelated_hooks() {
        let root: Value = serde_json::from_str(
            r#"{
                 "model": "opus",
                 "hooks": {
                   "Stop": [{"hooks":[{"type":"command","command":"/usr/bin/say done"}]}],
                   "SomeEventWeDoNotInstall": [{"hooks":[{"type":"command","command":"true"}]}]
                 }
               }"#,
        )
        .unwrap();
        let merged = merge(root, ours());
        assert_eq!(merged.get("model").unwrap(), "opus");
        let hooks = hooks_of(&merged);
        // The user's `Stop` hook survives, ours is APPENDED beside it.
        let stop = hooks.get("Stop").unwrap().as_array().unwrap();
        assert_eq!(stop.len(), 2);
        assert!(!entry_is_ours(&stop[0]));
        assert!(entry_is_ours(&stop[1]));
        // An event we do not manage is untouched.
        assert_eq!(
            hooks
                .get("SomeEventWeDoNotInstall")
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1,
        );
    }

    #[test]
    fn a_corrupt_root_is_repaired_rather_than_refused() {
        for root in [Value::Null, Value::Bool(true), Value::Array(vec![])] {
            let merged = merge(root, ours());
            assert_eq!(hooks_of(&merged).len(), INSTALLED_EVENTS.len());
        }
    }

    // MARK: The unmerge

    #[test]
    fn remove_strips_exactly_ours_and_leaves_a_clean_file() {
        let installed = merge(Value::Object(Map::new()), ours());
        let stripped = remove(installed);
        // Every event held only our entry, so `hooks` empties and the key itself goes.
        assert_eq!(stripped, Value::Object(Map::new()));
    }

    #[test]
    fn remove_keeps_the_users_own_hook_for_an_event_we_share() {
        let root: Value = serde_json::from_str(
            r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/say done"}]}]}}"#,
        )
        .unwrap();
        let stripped = remove(merge(root, ours()));
        let stop = hooks_of(&stripped).get("Stop").unwrap().as_array().unwrap();
        assert_eq!(stop.len(), 1);
        assert_eq!(
            stop[0].get("hooks").unwrap()[0].get("command").unwrap(),
            "/usr/bin/say done",
        );
    }

    #[test]
    fn remove_keeps_a_hooks_value_whose_shape_we_do_not_manage() {
        let root: Value = serde_json::from_str(r#"{"hooks":{"Stop":"not-an-array"}}"#).unwrap();
        let stripped = remove(root.clone());
        assert_eq!(stripped, root);
    }

    #[test]
    fn remove_leaves_a_non_object_root_alone() {
        assert_eq!(remove(Value::Bool(true)), Value::Bool(true));
    }

    // MARK: The marker

    #[test]
    fn an_entry_is_ours_only_when_a_command_carries_the_marker() {
        let theirs: Value =
            serde_json::from_str(r#"{"hooks":[{"type":"command","command":"echo hi"}]}"#).unwrap();
        assert!(!entry_is_ours(&theirs));
        assert!(entry_is_ours(&command_block(ours())));
        // Nothing about the shape alone makes an entry ours.
        assert!(!entry_is_ours(&Value::Object(Map::new())));
    }

    #[test]
    fn the_command_carries_the_marker_by_construction() {
        let path = PathBuf::from("/Users/ada/.claude/hooks").join(HOOK_MARKER);
        let command = hook_command(&path);
        assert!(command.contains(HOOK_MARKER));
        assert!(command.starts_with('"') && command.ends_with('"'));
    }

    // MARK: Paths

    #[test]
    fn the_config_dir_override_wins_and_expands_a_tilde() {
        assert_eq!(
            config_base(&environment(&[("CLAUDE_CONFIG_DIR", "~/alt")]), "/Users/ada"),
            PathBuf::from("/Users/ada/alt"),
        );
        assert_eq!(
            config_base(&environment(&[("CLAUDE_CONFIG_DIR", "/etc/c")]), "/Users/ada"),
            PathBuf::from("/etc/c"),
        );
        // Empty is not an override — it is an unset variable spelled differently.
        assert_eq!(
            config_base(&environment(&[("CLAUDE_CONFIG_DIR", "")]), "/Users/ada"),
            PathBuf::from("/Users/ada/.claude"),
        );
    }

    #[test]
    fn the_installed_relay_basename_is_the_marker() {
        let path = hook_path(&environment(&[]), "/Users/ada");
        assert_eq!(path, PathBuf::from("/Users/ada/.claude/hooks").join(HOOK_MARKER),);
        assert_eq!(
            settings_path(&environment(&[]), "/Users/ada"),
            PathBuf::from("/Users/ada/.claude/settings.json"),
        );
    }

    // MARK: Disk

    #[test]
    fn a_missing_or_corrupt_settings_file_reads_as_an_empty_root() {
        let scratch = Scratch::new("read");
        assert_eq!(
            read_settings(&scratch.join("absent.json")),
            Value::Object(Map::new()),
        );
        let corrupt = scratch.join("corrupt.json");
        std::fs::write(&corrupt, b"{not json,,,").unwrap();
        assert_eq!(read_settings(&corrupt), Value::Object(Map::new()));
    }

    #[test]
    fn install_stages_the_relay_and_writes_a_settings_file_that_reads_back_installed() {
        let scratch = Scratch::new("install");
        let relay = scratch.join("slopdesk-hook");
        std::fs::write(&relay, b"#!/bin/sh\ntrue\n").unwrap();
        let settings = scratch.join("settings.json");
        let hook = scratch.join("hooks").join(HOOK_MARKER);

        assert!(!is_installed(&settings));
        let written = install(&settings, &hook, &relay).unwrap();

        assert!(hook.is_file());
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&hook).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }
        assert!(is_installed(&settings));
        // The answer is the bytes on disk, not a rendering of them.
        assert_eq!(written, std::fs::read_to_string(&settings).unwrap());
        // No staging file survives a successful install.
        assert!(!scratch.join("hooks").join("slopdesk-hook.staging").exists());
    }

    #[test]
    fn install_refuses_when_the_relay_is_not_there() {
        let scratch = Scratch::new("norelay");
        let error = install(
            &scratch.join("settings.json"),
            &scratch.join("hooks").join(HOOK_MARKER),
            &scratch.join("nothing-here"),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        // An install that wired settings to a command that does not exist would look installed and
        // relay nothing, so nothing is written at all.
        assert!(!scratch.join("settings.json").exists());
    }

    #[test]
    fn uninstall_restores_a_file_indistinguishable_from_one_we_never_touched() {
        let scratch = Scratch::new("uninstall");
        let relay = scratch.join("slopdesk-hook");
        std::fs::write(&relay, b"x").unwrap();
        let settings = scratch.join("settings.json");
        std::fs::write(&settings, br#"{"model":"opus"}"#).unwrap();

        install(&settings, &scratch.join("hooks").join(HOOK_MARKER), &relay).unwrap();
        assert!(is_installed(&settings));

        uninstall(&settings).unwrap();
        assert!(!is_installed(&settings));
        assert_eq!(
            read_settings(&settings),
            serde_json::from_str::<Value>(r#"{"model":"opus"}"#).unwrap(),
        );
    }

    #[test]
    fn is_installed_answers_no_when_one_event_is_missing() {
        let scratch = Scratch::new("partial");
        let settings = scratch.join("settings.json");
        let mut root = merge(Value::Object(Map::new()), ours());
        // Stand in for a file an older build wrote: every event but the newest.
        root.get_mut("hooks")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove("PreCompact");
        write_settings(&root, &settings).unwrap();
        assert!(!is_installed(&settings));
    }

    #[test]
    fn the_written_file_is_sorted_and_pretty() {
        let scratch = Scratch::new("shape");
        let settings = scratch.join("settings.json");
        let root: Value = serde_json::from_str(r#"{"zeta":1,"alpha":2}"#).unwrap();
        let text = write_settings(&root, &settings).unwrap();
        assert_eq!(text, "{\n  \"alpha\": 2,\n  \"zeta\": 1\n}");
        // No staging file survives, and no trailing newline is added — the bytes are the answer.
        assert!(!scratch.join("settings.json.slopdesk-staging").exists());
    }

    #[test]
    fn a_path_with_a_space_still_executes() {
        let command = hook_command(&PathBuf::from("/Users/a b/.claude/hooks/slopdesk-agent"));
        assert_eq!(command, "\"/Users/a b/.claude/hooks/slopdesk-agent\"");
    }
}
