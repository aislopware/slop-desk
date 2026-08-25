//! `slopdesk config` — the file, and the six questions that can be asked about it.
//!
//! Every verb here is LOCAL: no control socket, no running app. That is the design rather than an
//! accident of what is easy — the config FILE is the only place a setting is chosen, so a program
//! that wrote settings would make a state the reader cannot see in their own file. `set`, `unset`
//! and `reload` are gone for that reason and say so by name, because "unknown subcommand 'set'"
//! reads as a typo and this is a decision.
//!
//! The verdicts are all [`slopdesk_settings::config`]'s: the same table the app resolves the file
//! against, the same diagnostics it produced, the same schema an editor completes from. A second
//! grammar written here is how `font-size = 14` came to validate and then be ignored.

use std::path::Path;
use std::process::Command;

use slopdesk_settings::config::{Resolved, path as settings_path, render, schema};

use crate::shell::commands::no_extras;
use crate::shell::{Ctx, Failure, Io, Run, print};

/// The config file this invocation reads: `--config-file`, then `SLOPDESK_CONFIG_FILE`, then the
/// XDG default under `$HOME`.
///
/// The order is [`slopdesk_settings`]'s, and the environment is this process's captured one rather
/// than a fresh read, so a test can state it.
#[must_use]
pub fn resolved_path(ctx: &Ctx) -> String {
    settings_path::resolve_path(
        ctx.invocation.config_file.as_deref(),
        &|key| ctx.environment.get(key).map(str::to_owned),
        ctx.environment.home(),
    )
}

/// The file, resolved against the table.
fn loaded(ctx: &Ctx) -> Resolved {
    settings_path::load(Path::new(&resolved_path(ctx)))
}

/// `config <sub>`.
///
/// # Errors
/// A missing or unknown subcommand, whatever the subcommand failed with, or a removed verb naming
/// what replaced it.
pub fn config(io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let Some(sub) = rest.first().map(String::as_str) else {
        return Err(Failure::usage(
            "config: requires path | edit | validate | schema | show | get",
        ));
    };
    let args = rest.get(1..).unwrap_or_default();
    match sub {
        "path" => path(io, args, ctx),
        "edit" => edit(args, ctx),
        "validate" => validate(io, args, ctx),
        "schema" => json_schema(io, args),
        "show" => show(io, args, ctx),
        "get" => get(io, args, ctx),
        // The two that are GONE, named so the error says why rather than "unknown subcommand".
        "set" | "unset" => {
            Err(Failure::usage(format!(
                "config {sub}: removed — edit {} instead",
                resolved_path(ctx)
            )))
        },
        "reload" => {
            Err(Failure::usage(
                "config reload: removed — the app re-reads the file on its own",
            ))
        },
        other => Err(Failure::usage(format!("config: unknown subcommand '{other}'"))),
    }
}

/// `config path` — where the file is, whether or not it exists.
fn path(io: &mut Io<'_>, args: &[String], ctx: &Ctx) -> Run {
    no_extras(args, "config path")?;
    print(io.out, &format!("{}\n", resolved_path(ctx)))?;
    Ok(0)
}

/// `config show` — the whole resolved configuration as re-pasteable TOML.
fn show(io: &mut Io<'_>, args: &[String], ctx: &Ctx) -> Run {
    no_extras(args, "config show")?;
    print(io.out, &format!("{}\n", render::to_toml(&loaded(ctx))))?;
    Ok(0)
}

/// `config schema` — the JSON Schema every key is described by, which is the same text
/// `docs/config.schema.json` holds.
fn json_schema(io: &mut Io<'_>, args: &[String]) -> Run {
    no_extras(args, "config schema")?;
    print(io.out, &format!("{}\n", schema::json_schema()))?;
    Ok(0)
}

/// `config get <key>` — one resolved value, bare, so a shell can capture it.
///
/// A key the table does not declare exits 2; a key it declares WITHOUT a default that the file
/// never set exits 1 with "unset". The two are different questions — "you typed a key that does not
/// exist" and "nobody has chosen a value for this one" — and a script wants to tell them apart.
fn get(io: &mut Io<'_>, args: &[String], ctx: &Ctx) -> Run {
    let Some(key) = args
        .first()
        .map(String::as_str)
        .filter(|key| !key.starts_with('-'))
    else {
        return Err(Failure::usage("config get: requires <key>"));
    };
    if let Some(extra) = args.get(1) {
        return Err(Failure::usage(format!(
            "config get: unexpected argument '{extra}'"
        )));
    }
    if !render::is_declared(key) {
        return Err(Failure::usage(format!("config get: no such key '{key}'")));
    }
    let Some(value) = render::value_text(&loaded(ctx), key) else {
        return Err(Failure::plain(format!(
            "config get: '{key}' is unset (the daemon's own default applies)"
        )));
    };
    print(io.out, &format!("{value}\n"))?;
    Ok(0)
}

/// `config validate` — every key the file gets wrong, and nothing about the ones it gets right.
///
/// The verdict is the RESOLVER's, not a second grammar: the file is loaded exactly the way the app
/// loads it and the diagnostics it produced are printed. So a key this prints nothing about is a
/// key the app honours, and the two can never drift.
fn validate(io: &mut Io<'_>, args: &[String], ctx: &Ctx) -> Run {
    no_extras(args, "config validate")?;
    let path = resolved_path(ctx);
    if !Path::new(&path).exists() {
        // Not a failure: an install with no config file is the supported shape, and the defaults
        // are the whole configuration.
        print(
            io.out,
            &format!("valid (no config file at {path} — the defaults are the whole configuration)\n"),
        )?;
        return Ok(0);
    }
    let problems = render::diagnostics(&loaded(ctx));
    if problems.is_empty() {
        print(io.out, &format!("valid: {path}\n"))?;
        return Ok(0);
    }
    for problem in problems {
        print(io.err, &format!("{}: {path}: {problem}\n", ctx.program))?;
    }
    Ok(1)
}

/// `config edit` — open the file in `$EDITOR`.
///
/// Creates the parent directory and an empty file first so the editor opens cleanly on a machine
/// that has never had one, and propagates the editor's own exit status: a `:cq` out of vim is a
/// deliberate "I did not mean that", and swallowing it would be a lie.
fn edit(args: &[String], ctx: &Ctx) -> Run {
    no_extras(args, "config edit")?;
    let path = resolved_path(ctx);
    let file = Path::new(&path);
    if let Some(parent) = file.parent() {
        drop(std::fs::create_dir_all(parent));
    }
    if !file.exists() {
        drop(std::fs::write(file, b""));
    }
    let editor = ctx.environment.get("EDITOR").unwrap_or("vi");
    // `sh -c 'exec <editor> "$0"' <path>` — the path arrives as `$0` so an `$EDITOR` carrying its
    // own arguments (`code -w`) still works, with the path quoted rather than re-split.
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("exec {editor} \"$0\""))
        .arg(&path)
        .status()
        .map_err(|error| Failure::plain(format!("failed to launch $EDITOR ({editor}): {error}")))?;
    Ok(status
        .code()
        .and_then(|code| u8::try_from(code).ok())
        .unwrap_or(1))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{config, resolved_path};
    use crate::args::Invocation;
    use crate::shell::commands::tests::{args, drive};
    use crate::shell::{Ctx, EXIT_USAGE, Environment};

    /// A ctx pointing `--config-file` at `file`, with an otherwise empty environment.
    fn at(file: &str) -> Ctx {
        Ctx {
            invocation: Invocation {
                subcommand: "config".to_owned(),
                config_file: Some(file.to_owned()),
                ..Invocation::default()
            },
            environment: Environment::from_pairs(&[("HOME", "/Users/nobody")]),
            program: "slopdesk".to_owned(),
        }
    }

    /// A temp file holding `text`, named after `label` so two tests never share one.
    fn written(label: &str, text: &str) -> String {
        let path = std::env::temp_dir()
            .join(format!("slopdesk-cli-config-{label}.toml"))
            .to_string_lossy()
            .into_owned();
        std::fs::write(&path, text).expect("the temp dir is writable");
        path
    }

    #[test]
    fn the_flag_outranks_the_env_which_outranks_the_xdg_default() {
        let mut ctx = at("/explicit.toml");
        assert_eq!(resolved_path(&ctx), "/explicit.toml");

        ctx.invocation.config_file = None;
        ctx.environment = Environment::from_pairs(&[
            ("HOME", "/Users/nobody"),
            ("SLOPDESK_CONFIG_FILE", "/from/env.toml"),
        ]);
        assert_eq!(resolved_path(&ctx), "/from/env.toml");

        ctx.environment = Environment::from_pairs(&[("HOME", "/Users/nobody")]);
        assert_eq!(resolved_path(&ctx), "/Users/nobody/.config/slopdesk/config.toml");
    }

    #[test]
    fn a_missing_subcommand_lists_the_six_that_exist() {
        let ctx = at("/explicit.toml");
        let (code, _) = drive(|io| config(io, &args(&[]), &ctx));
        let failure = code.expect_err("there is no default config verb");
        assert_eq!(failure.code, EXIT_USAGE);
        assert_eq!(
            failure.message,
            "config: requires path | edit | validate | schema | show | get"
        );
    }

    /// The three removed verbs each say what replaced them, because "unknown subcommand 'set'"
    /// reads as a typo and every one of these is a decision.
    #[test]
    fn the_removed_verbs_name_the_file_rather_than_reading_as_typos() {
        let ctx = at("/explicit.toml");
        for verb in ["set", "unset"] {
            let (code, _) = drive(|io| config(io, &args(&[verb, "terminal.font-size", "14"]), &ctx));
            let failure = code.expect_err("the writer is gone");
            assert_eq!(failure.code, EXIT_USAGE);
            assert_eq!(
                failure.message,
                format!("config {verb}: removed — edit /explicit.toml instead")
            );
        }
        let (code, _) = drive(|io| config(io, &args(&["reload"]), &ctx));
        assert_eq!(
            code.expect_err("there is nothing to reload").message,
            "config reload: removed — the app re-reads the file on its own"
        );
        let (code, _) = drive(|io| config(io, &args(&["frobnicate"]), &ctx));
        assert_eq!(
            code.expect_err("no such verb").message,
            "config: unknown subcommand 'frobnicate'"
        );
    }

    /// THE distinction `config get` exists to make: an undeclared key is a usage error, an unset
    /// declared one is a run that found nothing, and a script branches on which.
    #[test]
    fn an_unknown_key_and_an_unset_one_are_different_exits() {
        let file = written("get", "[terminal]\nfont-size = 15.0\n");
        let ctx = at(&file);

        let (code, text) = drive(|io| config(io, &args(&["get", "terminal.font-size"]), &ctx));
        assert_eq!(code, Ok(0));
        assert!(text.starts_with("15") && text.ends_with('\n'), "{text:?}");

        let (code, _) = drive(|io| config(io, &args(&["get", "terminal.no-such-key"]), &ctx));
        let failure = code.expect_err("the table does not declare it");
        assert_eq!(failure.code, EXIT_USAGE);
        assert_eq!(failure.message, "config get: no such key 'terminal.no-such-key'");

        let (code, _) = drive(|io| config(io, &args(&["get"]), &ctx));
        assert_eq!(code.expect_err("no key").message, "config get: requires <key>");

        let (code, _) = drive(|io| config(io, &args(&["get", "terminal.font-size", "extra"]), &ctx));
        assert_eq!(
            code.expect_err("one key only").message,
            "config get: unexpected argument 'extra'"
        );
    }

    #[test]
    fn every_extra_operand_is_refused_by_the_verb_that_takes_none() {
        let ctx = at("/explicit.toml");
        for verb in ["path", "show", "schema", "validate"] {
            let (code, _) = drive(|io| config(io, &args(&[verb, "extra"]), &ctx));
            let failure = code.expect_err("none of these take an operand");
            assert_eq!(failure.code, EXIT_USAGE);
            assert_eq!(
                failure.message,
                format!("config {verb}: unexpected argument 'extra'")
            );
        }
    }

    #[test]
    fn path_show_and_schema_all_end_in_exactly_one_newline() {
        let ctx = at("/explicit.toml");
        let (code, text) = drive(|io| config(io, &args(&["path"]), &ctx));
        assert_eq!(code, Ok(0));
        assert_eq!(text, "/explicit.toml\n");

        let (code, text) = drive(|io| config(io, &args(&["show"]), &ctx));
        assert_eq!(code, Ok(0));
        assert!(text.ends_with('\n') && !text.ends_with("\n\n"), "{text:?}");

        let (code, text) = drive(|io| config(io, &args(&["schema"]), &ctx));
        assert_eq!(code, Ok(0));
        assert!(text.contains("config.schema.json"), "{text}");
    }

    /// The three verdicts `validate` can reach, and the one that is NOT a failure.
    #[test]
    fn validate_treats_no_file_as_valid_and_a_bad_key_as_a_diagnostic() {
        let ctx = at("/nowhere/slopdesk/config.toml");
        let (code, text) = drive(|io| config(io, &args(&["validate"]), &ctx));
        assert_eq!(code, Ok(0));
        assert!(text.starts_with("valid (no config file at "), "{text}");

        let good = written("validate-good", "[terminal]\nfont-size = 15.0\n");
        let ctx = at(&good);
        let (code, text) = drive(|io| config(io, &args(&["validate"]), &ctx));
        assert_eq!(code, Ok(0));
        assert_eq!(text, format!("valid: {good}\n"));

        let bad = written("validate-bad", "[terminal]\nfont-size = \"enormous\"\n");
        let ctx = at(&bad);
        let (code, text) = drive(|io| config(io, &args(&["validate"]), &ctx));
        assert_eq!(code, Ok(1), "a file with a problem is a non-zero exit");
        assert!(text.is_empty(), "the problems go to stderr, not stdout: {text:?}");
    }
}
