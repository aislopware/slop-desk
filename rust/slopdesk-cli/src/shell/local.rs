//! The verbs that need no running app — plus the two that reach the FILESYSTEM rather than the
//! socket.
//!
//! `version` and `completions` answer out of this binary. `sidecars` reads two manifest FILES,
//! deliberately: `brew upgrade` runs while every daemon is still serving the old binaries, so
//! asking a live daemon at that moment reports all of them as stale whether one changed or twelve.
//! `font import` copies a face into `~/Library/Fonts` and asks Core Text what the system calls it.
//! `font list` is the exception that dials the app, because the list worth having is the one the
//! app's own text stack resolved.
//!
//! `launch_gui` is the bare-invocation path: `slopdesk` with no verb opens the window, the way bare
//! `xterm`/`alacritty`/`ghostty` do, and `-e <cmd>` forwards a command into the first pane.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value};
use slopdesk_hostlaunch::record::APP_SUPPORT_DIR_ENV;
use slopdesk_sidecars::manifest::{self, Manifest, Step};

use crate::args::OutputFormat;
use crate::shell::commands::{emit_list, value_after};
use crate::shell::config::resolved_path as config_path;
use crate::shell::{Control, Ctx, Environment, Failure, Io, Run, print, version_summary};
use crate::{clientctl, completions, formatting};

/// Bundle identifier of the macOS client app (`Apps/ClientApp-macOS/project.yml`).
pub const CLIENT_BUNDLE_ID: &str = "com.slopdesk.client.macos";

/// Points at the `MANIFEST.json` this install shipped. Set it and neither guess below is made.
pub const MANIFEST_ENV_KEY: &str = "SLOPDESK_MANIFEST";

/// The name the recorded copy is kept under, inside the Application Support container.
///
/// Recorded rather than derived: Homebrew replaces the Cellar directory wholesale, so the previous
/// release's `MANIFEST.json` is GONE by the time anything could read it. A copy in the user's
/// container is the only place the previous answer can survive the thing it describes.
pub const MANIFEST_RECORD_NAME: &str = "sidecars-manifest.json";

/// The exit code for "there is no manifest to diff, or it cannot be read".
///
/// Distinct from a usage error because nothing the caller typed was wrong: a developer tree simply
/// has no `MANIFEST.json`, because nothing packaged it.
pub const EXIT_NO_MANIFEST: u8 = 4;

/// The exit code for a plan that was printed and a baseline that was not recorded.
///
/// Its own code because the two halves failed independently: the diff above is still correct, and
/// only the NEXT upgrade is poorer for it.
pub const EXIT_NO_RECORD: u8 = 5;

/// The extensions macOS will activate out of `~/Library/Fonts`.
const FONT_EXTENSIONS: &[&str] = &["ttf", "otf", "ttc", "dfont"];

// ---------------------------------------------------------------------------------------------
// version / completions
// ---------------------------------------------------------------------------------------------

/// `version` — the banner, with the build hash when the release pipeline stamped one.
///
/// # Errors
/// A write failure.
pub fn version(io: &mut Io<'_>, ctx: &Ctx) -> Run {
    print(io.out, &format!("{}\n", version_summary(&ctx.environment)))?;
    Ok(0)
}

/// `completions <shell>` — the completion script for one of the five shells.
///
/// # Errors
/// A missing or unrecognised shell name. Both are exit 1 rather than 2, which is what the Swift
/// original did and what the install scripts that eval this already branch on.
pub fn completions(io: &mut Io<'_>, rest: &[String]) -> Run {
    let Some(raw) = rest.first().map(String::as_str) else {
        return Err(Failure::plain(
            "completions requires a shell: bash | zsh | fish | elvish | powershell",
        ));
    };
    let Some(shell) = completions::Shell::parse(raw) else {
        return Err(Failure::plain(format!(
            "unsupported shell '{raw}': expected bash | zsh | fish | elvish | powershell"
        )));
    };
    print(io.out, &completions::script(shell))?;
    Ok(0)
}

// ---------------------------------------------------------------------------------------------
// sidecars
// ---------------------------------------------------------------------------------------------

/// The flags `sidecars` takes.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct SidecarFlags {
    record: bool,
    manifest: Option<String>,
    previous: Option<String>,
}

/// Parses `[--record] [--manifest PATH] [--previous PATH]`.
fn parse_sidecar_flags(rest: &[String]) -> Result<SidecarFlags, Failure> {
    let mut flags = SidecarFlags::default();
    let mut index = 0;
    while let Some(argument) = rest.get(index) {
        match argument.as_str() {
            "--record" => flags.record = true,
            "--manifest" => {
                flags.manifest = Some(
                    rest.get(index.saturating_add(1))
                        .ok_or_else(|| Failure::usage("'--manifest' requires a path"))?
                        .clone(),
                );
                index = index.saturating_add(1);
            },
            "--previous" => {
                flags.previous = Some(
                    rest.get(index.saturating_add(1))
                        .ok_or_else(|| Failure::usage("'--previous' requires a path"))?
                        .clone(),
                );
                index = index.saturating_add(1);
            },
            other => {
                return Err(Failure::usage(format!(
                    "unknown flag '{other}' for sidecars (run with --help)"
                )));
            },
        }
        index = index.saturating_add(1);
    }
    Ok(flags)
}

/// Where the `MANIFEST.json` belonging to `binary` is, in the three layouts that actually ship.
///
/// 1. [`MANIFEST_ENV_KEY`], for a test and for an install that puts it somewhere else entirely;
/// 2. beside the binary — the release TARBALL's layout, where the manifest travels inside
///    `slopdesk-cli-<version>-arm64/` next to the tools;
/// 3. one directory up — Homebrew's, where the tools are in `#{prefix}/bin` and the manifest is the
///    formula's `prefix.install`.
///
/// `binary` must already be symlink-resolved: Homebrew's `bin` is a farm of links into the Cellar,
/// and the unresolved path's parent has no manifest under it.
#[must_use]
pub fn installed_manifest_path(binary: Option<&Path>, environment: &Environment) -> Option<PathBuf> {
    if let Some(override_path) = environment.get(MANIFEST_ENV_KEY) {
        return Some(PathBuf::from(override_path));
    }
    let directory = binary?.parent()?;
    let mut candidates = vec![directory.join("MANIFEST.json")];
    if let Some(above) = directory.parent() {
        candidates.push(above.join("MANIFEST.json"));
    }
    candidates.into_iter().find(|candidate| candidate.is_file())
}

/// The Application Support container every `SlopDesk` file lands in.
///
/// Honours [`APP_SUPPORT_DIR_ENV`], unlike the control-socket default beside it — the asymmetry
/// `socket.rs` documents: the socket has to name the same file the APP resolved, and this file is
/// only ever written by this program.
#[must_use]
pub fn app_support_dir(environment: &Environment) -> Option<PathBuf> {
    if let Some(override_dir) = environment.get(APP_SUPPORT_DIR_ENV) {
        return Some(PathBuf::from(override_dir));
    }
    Some(PathBuf::from(environment.get("HOME")?).join("Library/Application Support/SlopDesk"))
}

/// The copy recorded by the last `slopdesk sidecars --record`.
#[must_use]
pub fn recorded_manifest_path(environment: &Environment) -> Option<PathBuf> {
    Some(app_support_dir(environment)?.join(MANIFEST_RECORD_NAME))
}

/// One table row per tool, with an em-dash where a version does not exist yet.
fn sidecar_rows(steps: &[Step]) -> Vec<Vec<String>> {
    /// What a version reads as when this release added or dropped the tool.
    const ABSENT: &str = "—";

    steps
        .iter()
        .map(|step| {
            vec![
                step.tool.clone(),
                step.previous.clone().unwrap_or_else(|| ABSENT.to_owned()),
                step.current.clone().unwrap_or_else(|| ABSENT.to_owned()),
                step.change.name().to_owned(),
                step.note(),
            ]
        })
        .collect()
}

/// `sidecars [--record] [--manifest PATH] [--previous PATH]` — what the last upgrade changed, tool
/// by tool, and what each change means.
///
/// It NEVER ends a daemon. hostd owns the lifetime of the ones it spawned and restarts the stale
/// ones at its next start; screend retires itself; superd is the user's call because ending it ends
/// every live pane. So the useful actions are to SAY what changed and to `--record` the baseline
/// the next upgrade is diffed against — which is what a formula's `post_install` runs, and the only
/// reason the next diff can be about one tool rather than twelve.
///
/// # Errors
/// A bad flag (exit 2), no readable manifest or no resolvable container (exit 4), or a record that
/// could not be written (exit 5, after the plan has already been printed).
pub fn sidecars(io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let flags = parse_sidecar_flags(rest)?;
    let installed = flags
        .manifest
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| installed_manifest_path(std::env::current_exe().ok().as_deref(), &ctx.environment));
    let Some(installed) = installed else {
        return Err(no_manifest());
    };
    let Ok(current_text) = std::fs::read_to_string(&installed) else {
        return Err(no_manifest());
    };
    let Ok(current) = manifest::parse(&current_text) else {
        return Err(Failure::new(
            EXIT_NO_MANIFEST,
            format!("{} is not a readable manifest", installed.display()),
        ));
    };

    let recorded = flags
        .previous
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| recorded_manifest_path(&ctx.environment));
    // A previous manifest that is missing is a first install; one that is CORRUPT is treated the
    // same way, deliberately. Refusing to plan because a file written two versions ago cannot be
    // read would strand exactly the user who most needs to be told what changed.
    let previous: Option<Manifest> = recorded
        .as_ref()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| manifest::parse(&text).ok());

    if ctx.invocation.format == OutputFormat::Json {
        print(
            io.out,
            &format!("{}\n", manifest::plan_json(previous.as_ref(), &current)),
        )?;
    } else {
        let steps = manifest::plan(previous.as_ref(), &current);
        print(
            io.out,
            &format!(
                "{}\n",
                formatting::render_table(
                    &["TOOL", "WAS", "NOW", "CHANGE", "NEXT"],
                    &sidecar_rows(&steps),
                    ctx.invocation.no_headers,
                )
            ),
        )?;
    }

    if flags.record {
        let Some(recorded) = recorded else {
            return Err(Failure::new(
                EXIT_NO_MANIFEST,
                "cannot resolve the Application Support container",
            ));
        };
        // Written whole, and the container is created if it is not there — this runs from a
        // formula's `post_install`, the one moment the container may not exist yet.
        let written = recorded
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| std::fs::write(&recorded, current_text.as_bytes()));
        if let Err(error) = written {
            return Err(Failure::new(
                EXIT_NO_RECORD,
                format!("recorded nothing to {}: {error}", recorded.display()),
            ));
        }
    }
    Ok(0)
}

/// The one sentence both "there is no manifest" paths say, naming the variable that overrides the
/// guess rather than the guess that failed.
fn no_manifest() -> Failure {
    Failure::new(
        EXIT_NO_MANIFEST,
        format!("no MANIFEST.json — set {MANIFEST_ENV_KEY}, or run this from an install"),
    )
}

// ---------------------------------------------------------------------------------------------
// font
// ---------------------------------------------------------------------------------------------

/// `font <verb>`.
///
/// # Errors
/// A verb other than `list`/`import`, the removed `apply`, or anything the verb failed with.
pub fn font(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let tail = rest.get(1..).unwrap_or_default();
    match rest.first().map(String::as_str) {
        Some("list") => font_list(ctl, io, tail, ctx),
        Some("import") => font_import(io, tail, ctx),
        Some("apply") => {
            Err(Failure::usage(format!(
                "font apply: removed — set font-family under [terminal] in {}",
                config_path(ctx)
            )))
        },
        _ => Err(Failure::usage("font: expected 'list', 'apply', or 'import'")),
    }
}

/// `font list [--monospace] [--family <v>] [--system|--user]` — the faces the RUNNING app resolved.
///
/// The one font verb that dials the app, because the list worth having is the one the app's own
/// text stack could actually render. A second enumeration in this process would answer a slightly
/// different question and look like the same one.
fn font_list(ctl: &mut impl Control, io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let mut monospace = false;
    let mut family: Option<&str> = None;
    let mut scope: Option<&str> = None;
    let mut index = 0;
    while let Some(flag) = rest.get(index) {
        match flag.as_str() {
            "--monospace" => monospace = true,
            "--family" => {
                family = Some(value_after(rest, index, "font list", "--family")?);
                index = index.saturating_add(1);
            },
            "--system" => scope = Some("system"),
            "--user" => scope = Some("user"),
            other => {
                return Err(Failure::usage(format!("font list: unknown flag '{other}'")));
            },
        }
        index = index.saturating_add(1);
    }
    emit_list(
        ctl,
        io,
        ctx,
        clientctl::FONT_LIST,
        clientctl::font_list_params(monospace, family, scope),
        "fonts",
        formatting::fonts,
    )
}

/// Expands a leading `~/` (and a bare `~`) against `$HOME`, leaving every other path alone.
///
/// `~user` is deliberately NOT expanded: resolving another user's home means a passwd lookup, and a
/// path a shell already expanded never arrives here with a tilde at all.
#[must_use]
pub fn expand_tilde(path: &str, environment: &Environment) -> String {
    if path == "~" {
        return environment.home().to_owned();
    }
    path.strip_prefix("~/").map_or_else(
        || path.to_owned(),
        |rest| format!("{}/{rest}", environment.home()),
    )
}

/// `font import <path>` — install a face into `~/Library/Fonts` and print the family name Core Text
/// reads out of it.
///
/// It does NOT apply the font. `--apply` used to write `font-family` into the running app, and
/// there is no writer any more — the config file is the only place a font is chosen. Printing the
/// family name is the half a program can do for you: the name is the awkward part (it is not the
/// filename — `JetBrainsMonoNerdFont-Regular.ttf` is `JetBrainsMono Nerd Font`), and pasting it
/// under `[terminal]` is the part that belongs to the reader.
fn font_import(io: &mut Io<'_>, rest: &[String], ctx: &Ctx) -> Run {
    let source = parse_font_import(rest, ctx)?;
    let source = PathBuf::from(expand_tilde(&source, &ctx.environment));
    if !source.exists() {
        return Err(Failure::usage(format!(
            "font import: no such file '{}'",
            source.display()
        )));
    }
    let name = source
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let extension = source
        .extension()
        .map(|extension| extension.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if !FONT_EXTENSIONS.contains(&extension.as_str()) {
        return Err(Failure::usage(format!(
            "font import: '{name}' is not a font file (expected .ttf/.otf/.ttc/.dfont)"
        )));
    }

    let fonts_dir = PathBuf::from(ctx.environment.home()).join("Library/Fonts");
    drop(std::fs::create_dir_all(&fonts_dir));
    let destination = fonts_dir.join(&name);
    // Removed first rather than copied over: replacing a face in place leaves a half-written file
    // readable by the font server for as long as the copy takes.
    if destination.exists() {
        drop(std::fs::remove_file(&destination));
    }
    std::fs::copy(&source, &destination).map_err(|error| {
        Failure::plain(format!(
            "font import: failed to install into ~/Library/Fonts: {error}"
        ))
    })?;

    let family = family_name(&destination);
    if ctx.invocation.format == OutputFormat::Json {
        let mut payload = Map::new();
        drop(payload.insert(
            "installed".to_owned(),
            Value::from(destination.to_string_lossy().into_owned()),
        ));
        if let Some(ref family) = family {
            drop(payload.insert("family".to_owned(), Value::from(family.clone())));
        }
        print(
            io.out,
            &format!(
                "{}\n",
                formatting::render_json_text(&Value::Object(payload).to_string())
            ),
        )?;
    } else {
        print(io.out, &format!("imported font: {name}\n"))?;
        if let Some(family) = family {
            print(io.out, &format!("  [terminal]\n  font-family = \"{family}\"\n"))?;
        }
    }
    Ok(0)
}

/// The single `<path>` operand, or the usage error explaining which flag is gone.
fn parse_font_import(rest: &[String], ctx: &Ctx) -> Result<String, Failure> {
    let mut path: Option<&str> = None;
    for argument in rest {
        if argument == "--apply" {
            return Err(Failure::usage(format!(
                "font import: --apply is removed — put the printed family name under [terminal] in {}",
                config_path(ctx)
            )));
        }
        if argument.starts_with('-') {
            return Err(Failure::usage(format!("font import: unknown flag '{argument}'")));
        }
        if path.is_none() {
            path = Some(argument);
        } else {
            return Err(Failure::usage(format!(
                "font import: unexpected argument '{argument}'"
            )));
        }
    }
    path.filter(|path| !path.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Failure::usage("font import: requires a <path>"))
}

/// What the system calls the face in this file, through `slopdesk-apple-text`.
#[cfg(target_os = "macos")]
fn family_name(path: &Path) -> Option<String> {
    slopdesk_apple_text::of_file(&path.to_string_lossy())
}

/// Always `None` off macOS, where there is no Core Text to ask.
#[cfg(not(target_os = "macos"))]
fn family_name(_path: &Path) -> Option<String> {
    None
}

// ---------------------------------------------------------------------------------------------
// GUI launch
// ---------------------------------------------------------------------------------------------

/// A bare `slopdesk` (or `slopdesk -e <cmd>`) — open the window, the way bare `xterm` does.
///
/// # Errors
/// A `/usr/bin/open` that could not be spawned or that refused, at exit 1. The `-e` forward is
/// deliberately NOT an error path: the window is already up, which is the whole xterm-compat
/// guarantee, and a forward that never lands just leaves the command untyped.
#[cfg(target_os = "macos")]
pub fn launch_gui(ctx: &Ctx) -> Run {
    let status = std::process::Command::new("/usr/bin/open")
        .arg("-b")
        .arg(CLIENT_BUNDLE_ID)
        .status()
        .map_err(|error| Failure::plain(format!("failed to launch the SlopDesk app: {error}")))?;
    if !status.success() {
        return Err(Failure::plain(format!(
            "the SlopDesk app did not launch ({CLIENT_BUNDLE_ID})"
        )));
    }
    if let Some(command) = ctx
        .invocation
        .exec_command
        .as_ref()
        .filter(|command| !command.is_empty())
    {
        forward_exec_command(ctx, command);
    }
    Ok(0)
}

/// Off macOS there is no app to open.
#[cfg(not(target_os = "macos"))]
pub fn launch_gui(_ctx: &Ctx) -> Run {
    Err(Failure::plain("launching the GUI is only supported on macOS"))
}

/// How long to keep trying the freshly-launched app's socket, and how long to wait between tries.
#[cfg(target_os = "macos")]
const FORWARD_ATTEMPTS: u32 = 34;
/// 150 ms between attempts while the workspace initialises — 34 of them is a hair over five
/// seconds, which is the bound the Swift original polled to.
#[cfg(target_os = "macos")]
const FORWARD_INTERVAL: std::time::Duration = std::time::Duration::from_millis(150);

/// Best-effort `-e <cmd>` forward: poll the control socket until the app publishes it, then deliver
/// the joined command to the focused pane as verbatim text plus an Enter.
///
/// Fire-and-forget and NEVER fatal — every failure here is a silent return, because the GUI is
/// already visible.
#[cfg(target_os = "macos")]
fn forward_exec_command(ctx: &Ctx, command: &[String]) {
    use crate::shell::socket;

    let socket_path = socket::resolve_socket_path(ctx);
    let line = clientctl::encode_request_line(
        "1",
        clientctl::PANE_SEND_KEYS,
        clientctl::pane_send_keys_params(None, &command.join(" "), &["Enter".to_owned()]),
    );
    for _ in 0..FORWARD_ATTEMPTS {
        if socket::deliver(&socket_path, &line) {
            return;
        }
        std::thread::sleep(FORWARD_INTERVAL);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::path::{Path, PathBuf};

    use super::{
        EXIT_NO_MANIFEST, MANIFEST_ENV_KEY, app_support_dir, completions, expand_tilde, font,
        installed_manifest_path, parse_sidecar_flags, recorded_manifest_path, sidecars, version,
    };
    use crate::args::{Invocation, OutputFormat};
    use crate::shell::commands::tests::{Fake, args, drive};
    use crate::shell::{Ctx, EXIT_USAGE, Environment};

    fn ctx(pairs: &[(&str, &str)]) -> Ctx {
        Ctx {
            invocation: Invocation::default(),
            environment: Environment::from_pairs(pairs),
            program: "slopdesk".to_owned(),
        }
    }

    /// A directory under the temp dir, emptied first so a rerun starts clean.
    fn scratch(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("slopdesk-cli-local-{label}"));
        drop(std::fs::remove_dir_all(&dir));
        std::fs::create_dir_all(&dir).expect("the temp dir is writable");
        dir
    }

    /// The shape `slopdesk-release package` parses the number out of.
    #[test]
    fn the_version_banner_is_one_block_ending_in_a_single_newline() {
        let (code, text) = drive(|io| version(io, &ctx(&[])));
        assert_eq!(code, Ok(0));
        assert!(text.starts_with("slopdesk "), "{text}");
        assert!(text.ends_with('\n') && !text.ends_with("\n\n"), "{text:?}");
    }

    #[test]
    fn completions_names_the_five_shells_when_it_cannot_pick_one() {
        let (code, _) = drive(|io| completions(io, &args(&[])));
        let failure = code.expect_err("a shell is required");
        assert_eq!(failure.code, 1);
        assert!(
            failure
                .message
                .contains("bash | zsh | fish | elvish | powershell")
        );

        let (code, _) = drive(|io| completions(io, &args(&["tcsh"])));
        assert_eq!(
            code.expect_err("no tcsh script").message,
            "unsupported shell 'tcsh': expected bash | zsh | fish | elvish | powershell"
        );

        let (code, text) = drive(|io| completions(io, &args(&["zsh"])));
        assert_eq!(code, Ok(0));
        assert!(!text.is_empty());
    }

    #[test]
    fn a_dangling_sidecar_path_flag_names_itself() {
        assert_eq!(
            parse_sidecar_flags(&args(&["--manifest"]))
                .expect_err("dangling")
                .message,
            "'--manifest' requires a path"
        );
        assert_eq!(
            parse_sidecar_flags(&args(&["--previous"]))
                .expect_err("dangling")
                .message,
            "'--previous' requires a path"
        );
        assert_eq!(
            parse_sidecar_flags(&args(&["--force"]))
                .expect_err("no such flag")
                .message,
            "unknown flag '--force' for sidecars (run with --help)"
        );
        let flags = parse_sidecar_flags(&args(&["--record", "--manifest", "/m.json"]))
            .expect("a well-formed invocation");
        assert!(flags.record);
        assert_eq!(flags.manifest.as_deref(), Some("/m.json"));
    }

    /// The three layouts that ship, in the order they are tried.
    #[test]
    fn the_manifest_is_found_beside_the_binary_then_one_directory_up() {
        let root = scratch("manifest");
        let bin = root.join("bin");
        std::fs::create_dir_all(&bin).expect("writable");
        let binary = bin.join("slopdesk");
        std::fs::write(&binary, b"").expect("writable");

        // Neither layout yet.
        assert_eq!(
            installed_manifest_path(Some(&binary), &Environment::default()),
            None
        );

        // Homebrew's: the tools in `bin`, the manifest in the prefix above it.
        let above = root.join("MANIFEST.json");
        std::fs::write(&above, b"{}").expect("writable");
        assert_eq!(
            installed_manifest_path(Some(&binary), &Environment::default()),
            Some(above)
        );

        // The tarball's beats it: the manifest travels beside the tools.
        let beside = bin.join("MANIFEST.json");
        std::fs::write(&beside, b"{}").expect("writable");
        assert_eq!(
            installed_manifest_path(Some(&binary), &Environment::default()),
            Some(beside)
        );

        // And the override beats both, without the file having to exist.
        assert_eq!(
            installed_manifest_path(
                Some(&binary),
                &Environment::from_pairs(&[(MANIFEST_ENV_KEY, "/elsewhere/M.json")])
            ),
            Some(PathBuf::from("/elsewhere/M.json"))
        );
    }

    /// The record honours the container override; the socket beside it deliberately does not.
    #[test]
    fn the_record_lands_in_the_container_the_environment_names() {
        let environment = Environment::from_pairs(&[("HOME", "/Users/x")]);
        assert_eq!(
            app_support_dir(&environment),
            Some(PathBuf::from("/Users/x/Library/Application Support/SlopDesk"))
        );
        assert_eq!(
            recorded_manifest_path(&Environment::from_pairs(&[(
                "SLOPDESK_APP_SUPPORT_DIR",
                "/tmp/container"
            )])),
            Some(PathBuf::from("/tmp/container/sidecars-manifest.json"))
        );
        assert_eq!(recorded_manifest_path(&Environment::default()), None);
    }

    #[test]
    fn a_tree_with_no_manifest_says_which_variable_would_point_at_one() {
        let context = ctx(&[("HOME", "/Users/nobody")]);
        let rest = args(&["--manifest", "/no/such/MANIFEST.json"]);
        let (code, _) = drive(|io| sidecars(io, &rest, &context));
        let failure = code.expect_err("there is no manifest");
        assert_eq!(failure.code, EXIT_NO_MANIFEST);
        assert!(
            failure.message.starts_with("no MANIFEST.json — set"),
            "{failure:?}"
        );
    }

    /// A manifest that parses, a previous one that does not, and the `--record` that leaves the
    /// baseline the NEXT run diffs against.
    #[test]
    fn the_plan_reads_as_a_first_install_and_record_leaves_the_baseline_behind() {
        let root = scratch("plan");
        let manifest = root.join("MANIFEST.json");
        let text = r#"{"product":"0.4.0","tools":[{"name":"slopdesk-superd","version":"0.4.0"}]}"#;
        std::fs::write(&manifest, text).expect("writable");

        let mut context = ctx(&[("SLOPDESK_APP_SUPPORT_DIR", &root.to_string_lossy())]);
        context.invocation.format = OutputFormat::Json;
        let rest = args(&["--record", "--manifest", &manifest.to_string_lossy()]);
        let (code, printed) = drive(|io| sidecars(io, &rest, &context));
        assert_eq!(code, Ok(0));
        assert!(printed.contains("\"added\""), "a first install adds: {printed}");

        let recorded = root.join("sidecars-manifest.json");
        assert_eq!(
            std::fs::read_to_string(&recorded).expect("the baseline was written"),
            text
        );

        // The second run sees the baseline, so nothing changed.
        let (code, printed) = drive(|io| sidecars(io, &rest, &context));
        assert_eq!(code, Ok(0));
        assert!(printed.contains("\"changed\":0"), "{printed}");
    }

    #[test]
    fn a_tilde_is_expanded_against_home_and_a_bare_user_is_left_alone() {
        let environment = Environment::from_pairs(&[("HOME", "/Users/x")]);
        assert_eq!(expand_tilde("~", &environment), "/Users/x");
        assert_eq!(expand_tilde("~/f.ttf", &environment), "/Users/x/f.ttf");
        assert_eq!(expand_tilde("~root/f.ttf", &environment), "~root/f.ttf");
        assert_eq!(expand_tilde("/abs/f.ttf", &environment), "/abs/f.ttf");
    }

    /// Both removed font verbs point at the file rather than at a flag that no longer exists.
    #[test]
    fn the_removed_font_verbs_point_at_the_config_file() {
        let context = ctx(&[("SLOPDESK_CONFIG_FILE", "/c.toml")]);
        let mut ctl = Fake::empty();
        let (code, _) = drive(|io| font(&mut ctl, io, &args(&["apply", "Menlo"]), &context));
        assert_eq!(
            code.expect_err("there is no writer").message,
            "font apply: removed — set font-family under [terminal] in /c.toml"
        );

        let (code, _) = drive(|io| font(&mut ctl, io, &args(&["import", "--apply", "f.ttf"]), &context));
        let failure = code.expect_err("--apply is gone");
        assert_eq!(failure.code, EXIT_USAGE);
        assert!(
            failure.message.ends_with("under [terminal] in /c.toml"),
            "{failure:?}"
        );

        let (code, _) = drive(|io| font(&mut ctl, io, &args(&["enumerate"]), &context));
        assert_eq!(
            code.expect_err("no such verb").message,
            "font: expected 'list', 'apply', or 'import'"
        );
    }

    #[test]
    fn font_list_flags_reach_the_wire_and_an_unknown_one_does_not() {
        let context = ctx(&[]);
        let mut ctl = Fake::answering(r#"{"fonts":[{"family":"Menlo","monospace":true,"system":true}]}"#);
        let (code, text) = drive(|io| {
            font(
                &mut ctl,
                io,
                &args(&["list", "--monospace", "--family", "Men", "--user"]),
                &context,
            )
        });
        assert_eq!(code, Ok(0));
        assert!(text.contains("Menlo"), "{text}");
        let (method, params) = ctl.sent.first().expect("one call").clone();
        assert_eq!(method, "font-list");
        assert_eq!(
            params.get("monospace").and_then(serde_json::Value::as_bool),
            Some(true)
        );
        assert_eq!(
            params.get("family").and_then(serde_json::Value::as_str),
            Some("Men")
        );
        assert_eq!(
            params.get("scope").and_then(serde_json::Value::as_str),
            Some("user")
        );

        let (code, _) = drive(|io| font(&mut ctl, io, &args(&["list", "--family"]), &context));
        assert_eq!(
            code.expect_err("dangling").message,
            "font list: --family requires a value"
        );
        let (code, _) = drive(|io| font(&mut ctl, io, &args(&["list", "--serif"]), &context));
        assert_eq!(
            code.expect_err("no such flag").message,
            "font list: unknown flag '--serif'"
        );
    }

    /// The import refusals a person actually hits, before anything is copied anywhere.
    #[test]
    fn an_import_refuses_a_missing_file_and_a_file_that_is_not_a_font() {
        let root = scratch("font");
        let context = ctx(&[("HOME", &root.to_string_lossy())]);
        let mut ctl = Fake::empty();

        let (code, _) = drive(|io| font(&mut ctl, io, &args(&["import"]), &context));
        assert_eq!(
            code.expect_err("no path").message,
            "font import: requires a <path>"
        );

        let missing = root.join("nope.ttf");
        let rest = args(&["import", &missing.to_string_lossy()]);
        let (code, _) = drive(|io| font(&mut ctl, io, &rest, &context));
        assert_eq!(
            code.expect_err("no such file").message,
            format!("font import: no such file '{}'", missing.display())
        );

        let readme = root.join("README.md");
        std::fs::write(&readme, b"not a font").expect("writable");
        let rest = args(&["import", &readme.to_string_lossy()]);
        let (code, _) = drive(|io| font(&mut ctl, io, &rest, &context));
        assert_eq!(
            code.expect_err("not a font").message,
            "font import: 'README.md' is not a font file (expected .ttf/.otf/.ttc/.dfont)"
        );
    }

    /// A real install, end to end, into a `$HOME` the test owns. The family line is only asserted
    /// when Core Text answered one — the bytes copied are what this verb is responsible for.
    #[test]
    fn an_import_copies_the_face_into_the_library_and_prints_what_to_paste() {
        let root = scratch("font-install");
        let context = ctx(&[("HOME", &root.to_string_lossy())]);
        let mut ctl = Fake::empty();

        let source = root.join("Fake-Regular.ttf");
        std::fs::write(&source, b"not really a font, but it has the extension").expect("writable");
        let rest = args(&["import", &source.to_string_lossy()]);
        let (code, text) = drive(|io| font(&mut ctl, io, &rest, &context));
        assert_eq!(code, Ok(0));
        assert!(text.starts_with("imported font: Fake-Regular.ttf\n"), "{text}");
        assert!(
            Path::new(&root.join("Library/Fonts/Fake-Regular.ttf")).exists(),
            "the face landed in ~/Library/Fonts"
        );

        // A second import over the same name replaces rather than failing.
        let (code, _) = drive(|io| font(&mut ctl, io, &rest, &context));
        assert_eq!(code, Ok(0));
    }
}
