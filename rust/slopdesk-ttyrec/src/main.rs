//! Records a real terminal program into a [`slopdesk_vterm::recording::Recording`].
//!
//! Run once, by hand, to add a program to the conformance corpus. Nothing in the build runs it —
//! the recordings it writes are committed and the tests replay those.
//!
//! ```text
//! slopdesk-ttyrec --out corpus/nvim.sdrec --title nvim \
//!     --startup-ms 1500 --settle-ms 400 \
//!     --send 'ihello<Escape>' --send ':q!<Enter>' \
//!     -- /opt/homebrew/bin/nvim
//! ```
//!
//! ## Why the reads are threaded rather than polled
//!
//! Each [`Event::Output`] must be one `read(2)`, because that boundary is the chunk schedule the
//! replay gets for free — a terminal that only ever sees whole escape sequences is not the terminal
//! that ships. A blocking read on its own thread keeps every boundary exactly as the kernel handed
//! it over; a non-blocking poll loop would coalesce whatever arrived between two wakeups and
//! quietly throw that away.
//!
//! ## Why replies are written back
//!
//! A modern TUI asks the terminal what it is — primary DA, DSR, XTGETTCAP, the kitty keyboard
//! query — and blocks until it is answered. A recorder that never answered would record the first
//! two hundred milliseconds of a program that then gave up. The engine's answers go back down the
//! pty and into the recording, so the replay can check that the same plumbing still produces them.
//!
//! ## Why the four kinds of input keep their command-line order
//!
//! `--send`, `--send-mouse`, `--paste` and `--focus` are collected into ONE ordered list rather
//! than four. Order is the whole content of a recording's input half: a click before the program
//! turned mouse reporting on must encode to nothing and a click after it must encode to a report,
//! and four separate lists would silently sort that difference away.
//!
//! ## What is deliberately NOT recordable here
//!
//! A resize. `TIOCSWINSZ` on a terminal is hostd's alone — the `winsize-set` feature is how that is
//! enforced, and `slopdesk-invariants`' `pty_winsize_single_writer` pins the set of crates that may
//! turn it on — so this tool cannot deliver a `SIGWINCH` and a recording cannot contain a program's
//! reaction to one. The terminal side of a resize is covered instead by a synthetic sweep in
//! `slopdesk-vterm`'s `conformance::dynamic`, which resizes the session under test mid-stream and
//! needs no cooperation from a child process to do it.

use std::io::{Read as _, Write as _};
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use slopdesk_posix::pty::{SpawnPlan, spawn_pty};
use slopdesk_vterm::recording::{Event, Recording};
use slopdesk_vterm::session::VtSession;
use slopdesk_vterm::{keyscript, mousescript};

/// One thing the operator asked to send, in the order they asked for it.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Action {
    /// A `--send` keystroke run.
    Keys(String),
    /// A `--send-mouse` pointer run.
    Pointer(String),
    /// A `--paste` text.
    Paste(String),
    /// A `--focus` change.
    Focus(bool),
}

/// What the operator asked for.
#[derive(Debug, PartialEq, Eq)]
struct Options {
    out: String,
    title: String,
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    startup: Duration,
    settle: Duration,
    actions: Vec<Action>,
    command: Vec<String>,
    /// Extra `NAME=VALUE` pairs the operator asked for by hand.
    passed: Vec<String>,
    /// Whether the child gets this shell's whole environment.
    ///
    /// Off by default, and that is a privacy decision rather than a taste — see
    /// [`child_environment`].
    inherit: bool,
}

fn main() {
    let options = match parse_from(std::env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("slopdesk-ttyrec: {message}");
            eprintln!("{USAGE}");
            std::process::exit(2);
        },
    };
    if let Err(message) = record(&options) {
        eprintln!("slopdesk-ttyrec: {message}");
        std::process::exit(1);
    }
}

const USAGE: &str = "\
usage: slopdesk-ttyrec --out FILE --title NAME [options] -- COMMAND [ARGS...]

  --cols N            grid width          (default 100)
  --rows N            grid height         (default 30)
  --cell-width N      cell width in px    (default 8)
  --cell-height N     cell height in px   (default 16)
  --startup-ms N      settle before the first input      (default 1500)
  --settle-ms N       settle after each input            (default 400)

The four input flags share ONE order — the order they appear on the command line:

  --send SCRIPT       a keyscript run:    'ihello<Escape>', '<C-c>', ':q!<Enter>'
  --send-mouse SCRIPT a mousescript run:  'left@12,5', 'left@2,1 release:left@6,1'
  --paste TEXT        a paste, bracketed if the program asked for bracketing
  --focus on|off      a focus change, reported if the program asked to hear about it

The child runs under a MINIMAL environment (PATH, HOME, LANG, LC_ALL plus the terminal's own
four), because a recording is committed and everything the program prints goes into it:

  --env NAME=VALUE    pass one more variable through, by hand
  --inherit-env       give the child this shell's whole environment instead (not for a corpus
                      recording: a developer shell exports credentials)";

/// The variables a child keeps when the environment is not inherited.
///
/// Short on purpose. Every program in the corpus runs under exactly these, and anything one of them
/// turns out to need is added by `--env` at the call site where the reason is visible — which is
/// the difference between a variable a recording depends on and a variable that happened to be
/// exported by whoever ran the tool.
const KEPT: [&str; 4] = ["PATH", "HOME", "LANG", "LC_ALL"];

/// Reads argv, in the tree's own hand-rolled style.
///
/// Split from `main` so the ORDER of the four input flags — the whole content of a recording's
/// input half — is testable without spawning anything.
fn parse_from(arguments: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut out = None;
    let mut title = None;
    let mut cols = 100_u16;
    let mut rows = 30_u16;
    let mut cell_width = 8_u32;
    let mut cell_height = 16_u32;
    let mut startup = 1500_u64;
    let mut settle = 400_u64;
    let mut actions: Vec<Action> = Vec::new();
    let mut command = Vec::new();
    let mut passed: Vec<String> = Vec::new();
    let mut inherit = false;

    let mut arguments = arguments;
    while let Some(argument) = arguments.next() {
        let mut value = || {
            arguments
                .next()
                .ok_or_else(|| format!("`{argument}` wants a value"))
        };
        match argument.as_str() {
            "--out" => out = Some(value()?),
            "--title" => title = Some(value()?),
            "--cols" => cols = value()?.parse().map_err(|_ignored| "bad --cols")?,
            "--rows" => rows = value()?.parse().map_err(|_ignored| "bad --rows")?,
            "--cell-width" => {
                cell_width = value()?.parse().map_err(|_ignored| "bad --cell-width")?;
            },
            "--cell-height" => {
                cell_height = value()?.parse().map_err(|_ignored| "bad --cell-height")?;
            },
            "--startup-ms" => startup = value()?.parse().map_err(|_ignored| "bad --startup-ms")?,
            "--settle-ms" => settle = value()?.parse().map_err(|_ignored| "bad --settle-ms")?,
            "--send" => actions.push(Action::Keys(value()?)),
            "--send-mouse" => actions.push(Action::Pointer(value()?)),
            "--paste" => actions.push(Action::Paste(value()?)),
            "--focus" => {
                let word = value()?;
                let focused = match word.as_str() {
                    "on" | "true" | "1" => true,
                    "off" | "false" | "0" => false,
                    other => return Err(format!("--focus wants on or off, not `{other}`")),
                };
                actions.push(Action::Focus(focused));
            },
            "--env" => {
                let pair = value()?;
                if !pair.contains('=') {
                    return Err(format!("--env wants NAME=VALUE, not `{pair}`"));
                }
                passed.push(pair);
            },
            "--inherit-env" => inherit = true,
            "--" => {
                command.extend(arguments.by_ref());
                break;
            },
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            },
            other => return Err(format!("unknown argument `{other}`")),
        }
    }

    // Every script is parsed before anything is spawned. A typo in the last `--send` of a long
    // command line should not cost a recording that has already run.
    for action in &actions {
        match action {
            Action::Keys(script) => {
                drop(keyscript::parse(script).map_err(|error| format!("--send {script:?}: {error}"))?);
            },
            Action::Pointer(script) => {
                drop(
                    mousescript::parse(script)
                        .map_err(|error| format!("--send-mouse {script:?}: {error}"))?,
                );
            },
            Action::Paste(_) | Action::Focus(_) => (),
        }
    }

    Ok(Options {
        out: out.ok_or("--out is required")?,
        title: title.ok_or("--title is required")?,
        cols,
        rows,
        cell_width,
        cell_height,
        startup: Duration::from_millis(startup),
        settle: Duration::from_millis(settle),
        actions,
        command: if command.is_empty() {
            return Err("a command after `--` is required".to_owned());
        } else {
            command
        },
        passed,
        inherit,
    })
}

/// The whole recording pass: spawn, settle, send, settle, reap.
fn record(options: &Options) -> Result<(), String> {
    let (executable, arguments) = options
        .command
        .split_first()
        .ok_or("a command after `--` is required")?;

    if options.inherit {
        eprintln!(
            "slopdesk-ttyrec: --inherit-env — the child gets this shell's whole environment. Do not commit \
             this recording to the corpus."
        );
    }
    let environment = child_environment(options, &std::env::vars().collect::<Vec<_>>());
    let plan = SpawnPlan {
        executable,
        argv0: None,
        arguments,
        environment: &environment,
        cwd: None,
        rows: options.rows,
        cols: options.cols,
    };
    let spawned = spawn_pty(&plan).map_err(|error| format!("spawn: {error:?}"))?;
    let master = spawned.master;
    let reader_fd = master
        .try_clone()
        .map_err(|error| format!("dup the master: {error}"))?;
    let (sender, receiver) = mpsc::channel::<Vec<u8>>();
    let reader = std::thread::spawn(move || read_forever(reader_fd, &sender));

    let mut session = VtSession::new(
        options.cols,
        options.rows,
        options.cell_width,
        options.cell_height,
    )
    .map_err(|error| format!("session: {error:?}"))?;
    let mut writer = std::fs::File::from(
        master
            .try_clone()
            .map_err(|error| format!("dup the master: {error}"))?,
    );
    // Set once and never again: the geometry a pointer report resolves against is the recording's
    // own grid, and `Recording::geometry` is the single place that conversion lives so that the
    // replay resolves the identical pixel.
    session.set_surface_geometry(slopdesk_vterm::recording::geometry_of(
        options.cols,
        options.rows,
        options.cell_width,
        options.cell_height,
    ));
    let mut events = Vec::new();

    drain(&receiver, options.startup, &mut session, &mut writer, &mut events);

    for action in &options.actions {
        let (event, bytes) = encode_action(action, &mut session)?;
        // A write that fails means the program has already exited and its pty is gone — which is
        // normal for a command that quits on its own, and is not a reason to throw the recording
        // away. The input is NOT recorded: nothing received it, so a replay must not act as if
        // something had.
        if !bytes.is_empty() && writer.write_all(&bytes).and_then(|()| writer.flush()).is_err() {
            eprintln!("slopdesk-ttyrec: {action:?} was not sent — the program had already exited");
            break;
        }
        events.push(event);
        drain(&receiver, options.settle, &mut session, &mut writer, &mut events);
    }

    // Whatever is still running is asked to stop, then reaped. The recording is already complete —
    // this only stops the tool hanging on a program that never exits on its own.
    let pid = nix::unistd::Pid::from_raw(spawned.pid);
    let _ignored = nix::sys::signal::kill(pid, nix::sys::signal::Signal::SIGHUP);
    drain(
        &receiver,
        Duration::from_millis(200),
        &mut session,
        &mut writer,
        &mut events,
    );
    let _reaped = nix::sys::wait::waitpid(pid, None);
    drop(writer);
    drop(master);
    drop(reader.join());

    let recording = Recording {
        cols: options.cols,
        rows: options.rows,
        cell_width: options.cell_width,
        cell_height: options.cell_height,
        title: options.title.clone(),
        events,
    };
    let bytes = recording.encode();
    std::fs::write(&options.out, &bytes).map_err(|error| format!("write {}: {error}", options.out))?;

    let reads = recording
        .events
        .iter()
        .filter(|event| matches!(event, Event::Output(_)))
        .count();
    println!(
        "{}: {} events ({reads} pty reads), {} bytes -> {}",
        options.title,
        recording.events.len(),
        bytes.len(),
        options.out
    );
    Ok(())
}

/// Turns one asked-for action into the event to record and the bytes to send.
///
/// The bytes come out of the session — never out of a literal here — because that is the whole
/// point of the tool: a recording whose input bytes were typed by hand would compare a human's
/// guess against the encoder rather than the encoder against itself under the modes a real program
/// set.
///
/// An empty answer is a real one and is recorded as such: a pointer event no program subscribed to,
/// or a focus change under a program that never enabled mode 1004, produces nothing, and the replay
/// checks that the same nothing is produced.
fn encode_action(action: &Action, session: &mut VtSession) -> Result<(Event, Vec<u8>), String> {
    match action {
        Action::Keys(script) => {
            let presses = keyscript::parse(script).map_err(|error| format!("{script:?}: {error}"))?;
            let mut bytes = Vec::new();
            for press in &presses {
                session
                    .encode_key(&press.press(), &mut bytes)
                    .map_err(|error| format!("encode {script:?}: {error:?}"))?;
            }
            Ok((
                Event::Input {
                    script: script.clone(),
                    bytes: bytes.clone(),
                },
                bytes,
            ))
        },
        Action::Pointer(script) => {
            let moves = mousescript::parse(script).map_err(|error| format!("{script:?}: {error}"))?;
            let geometry = session.surface_geometry();
            let mut bytes = Vec::new();
            for event in &moves {
                let _reported = session
                    .encode_mouse(&event.to_move(geometry), &mut bytes)
                    .map_err(|error| format!("encode {script:?}: {error:?}"))?;
            }
            Ok((
                Event::Mouse {
                    script: script.clone(),
                    bytes: bytes.clone(),
                },
                bytes,
            ))
        },
        Action::Paste(text) => {
            let bracketed = session
                .wants_bracketed_paste()
                .map_err(|error| format!("bracketed paste mode: {error:?}"))?;
            let bytes = session
                .encode_paste(text, bracketed)
                .map_err(|error| format!("encode paste: {error:?}"))?;
            Ok((
                Event::Paste {
                    text: text.clone(),
                    bytes: bytes.clone(),
                },
                bytes,
            ))
        },
        Action::Focus(focused) => {
            // The report leaves by the same door a query answer does, so it is taken immediately
            // rather than left for the next drain — which would record it as a `Reply` and lose the
            // fact that a focus change caused it.
            session.set_focused(*focused);
            let mut bytes = Vec::new();
            let _queued = session.take_pty_replies(&mut bytes);
            Ok((
                Event::Focus {
                    focused: *focused,
                    bytes: bytes.clone(),
                },
                bytes,
            ))
        },
    }
}

/// The environment the child runs under.
///
/// ## Minimal by default, and that is a privacy decision
///
/// Everything the child prints lands in a file that is committed. A child holding the operator's
/// whole shell holds their credentials, their machine's paths and their user name — and any program
/// that prints an environment, a path, or a prompt writes some of that into the recording. The
/// corpus already lost one program to exactly this class (`corpus/README.md`, "never record a
/// program that prints machine state"), so the tool no longer relies on the operator remembering
/// `env -i`: [`KEPT`] is the whole default and `--env NAME=VALUE` adds anything a program needs by
/// hand.
///
/// `--inherit-env` gives back the old behaviour for a one-off recording that is not going into the
/// corpus, and says so on stderr when it is used.
///
/// The four a terminal owns are always overwritten. `TERM` is deliberately `xterm-256color` rather
/// than a ghostty entry: a recording has to be reproducible on a machine that has never installed
/// ghostty's terminfo, and every program in the corpus speaks this one.
fn child_environment(options: &Options, inherited: &[(String, String)]) -> Vec<String> {
    let owned_by_the_terminal = ["TERM", "COLUMNS", "LINES", "COLORTERM"];
    let mut environment: Vec<String> = inherited
        .iter()
        .filter(|(name, _)| !owned_by_the_terminal.contains(&name.as_str()))
        .filter(|(name, _)| options.inherit || KEPT.contains(&name.as_str()))
        .map(|(name, value)| format!("{name}={value}"))
        .collect();
    // The operator's own pairs come after the inherited ones, so `--env PATH=…` wins rather than
    // being shadowed by the shell's.
    environment.extend(options.passed.iter().cloned());
    environment.push("TERM=xterm-256color".to_owned());
    environment.push("COLORTERM=truecolor".to_owned());
    environment.push(format!("COLUMNS={}", options.cols));
    environment.push(format!("LINES={}", options.rows));
    environment
}

/// Blocks on the master until it closes, sending every read on as its own chunk.
fn read_forever(fd: OwnedFd, sender: &mpsc::Sender<Vec<u8>>) {
    slopdesk_posix::pty::set_blocking(fd.as_raw_fd());
    let mut file = std::fs::File::from(fd);
    let mut buffer = vec![0_u8; 65536];
    loop {
        match file.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(count) => {
                let Some(chunk) = buffer.get(..count) else {
                    return;
                };
                if sender.send(chunk.to_vec()).is_err() {
                    return;
                }
            },
        }
    }
}

/// Collects everything the program writes for `window`, feeding it and answering its queries.
fn drain(
    receiver: &mpsc::Receiver<Vec<u8>>,
    window: Duration,
    session: &mut VtSession,
    writer: &mut std::fs::File,
    events: &mut Vec<Event>,
) {
    let deadline = Instant::now() + window;
    loop {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return;
        };
        let Ok(chunk) = receiver.recv_timeout(remaining) else {
            return;
        };
        session.feed(&chunk);
        events.push(Event::Output(chunk));

        let mut replies = Vec::new();
        if session.take_pty_replies(&mut replies) && !replies.is_empty() {
            // Written before the next read is waited on: a program blocked on a DA never produces
            // the read that would otherwise carry us past this point.
            drop(writer.write_all(&replies));
            drop(writer.flush());
            events.push(Event::Reply(replies));
        }
        // Clipboard writes are dropped rather than recorded: OSC 52 is a decision the surface makes
        // with the user's `clipboard-write` setting, and a recorder has no user.
        drop(session.take_clipboard_writes());
    }
}

#[cfg(test)]
mod tests {
    use super::{Action, Options, child_environment, parse_from};

    fn words(line: &str) -> impl Iterator<Item = String> {
        line.split(' ').map(str::to_owned).collect::<Vec<_>>().into_iter()
    }

    fn parsed(line: &str) -> Options {
        match parse_from(words(line)) {
            Ok(options) => options,
            Err(message) => panic!("{line}: {message}"),
        }
    }

    /// The property the whole tool is built around: the four input flags share ONE order, and it is
    /// the order they were typed in. Four lists would sort a click before mouse tracking into the
    /// same bucket as a click after it, and those encode to different bytes.
    #[test]
    fn the_four_input_flags_keep_the_order_they_were_typed_in() {
        let options = parsed(
            "--out o.sdrec --title t --send-mouse left@1,1 --paste hi --focus on --send q -- /bin/cat",
        );
        assert_eq!(options.actions, vec![
            Action::Pointer("left@1,1".to_owned()),
            Action::Paste("hi".to_owned()),
            Action::Focus(true),
            Action::Keys("q".to_owned()),
        ]);
    }

    /// Every script is parsed before anything is spawned — a typo in the last `--send` of a long
    /// command line must not cost a recording that has already run.
    #[test]
    fn a_script_that_does_not_parse_is_refused_before_the_spawn() {
        let bad_key = parse_from(words("--out o --title t --send <Nope> -- /bin/cat"));
        assert!(bad_key.is_err(), "{bad_key:?}");
        let bad_pointer = parse_from(words("--out o --title t --send-mouse sideways@1 -- /bin/cat"));
        assert!(bad_pointer.is_err(), "{bad_pointer:?}");
    }

    /// Everything after `--` is the command, including words that spell flags of this tool.
    #[test]
    fn the_command_after_the_separator_is_taken_whole() {
        let options = parsed("--out o --title t -- /usr/bin/less --send docs/68.md");
        assert_eq!(options.command, vec!["/usr/bin/less", "--send", "docs/68.md"]);
        assert!(options.actions.is_empty());
    }

    /// The three ways a command line is incomplete, each named rather than defaulted: a recording
    /// with no destination, no title or no program is not a recording.
    #[test]
    fn the_required_arguments_are_required() {
        assert!(parse_from(words("--title t -- /bin/cat")).is_err());
        assert!(parse_from(words("--out o -- /bin/cat")).is_err());
        assert!(parse_from(words("--out o --title t")).is_err());
        assert!(parse_from(words("--out o --title t --focus sideways -- /bin/cat")).is_err());
        assert!(parse_from(words("--out o --title t --cols wide -- /bin/cat")).is_err());
    }

    /// The default environment is the allowlist and nothing else — the tool's own half of "never
    /// record a program that prints machine state", and the reason it no longer depends on the
    /// operator remembering `env -i`.
    #[test]
    fn a_child_is_given_nothing_the_allowlist_does_not_name() {
        let options = parsed("--out o --title t --cols 80 --rows 24 -- /bin/cat");
        let inherited = vec![
            ("PATH".to_owned(), "/usr/bin".to_owned()),
            ("HOME".to_owned(), "/Users/someone".to_owned()),
            ("GITLAB_TOKEN".to_owned(), "glpat-secret".to_owned()),
            ("AWS_SECRET_ACCESS_KEY".to_owned(), "shhh".to_owned()),
        ];
        let environment = child_environment(&options, &inherited);
        assert!(environment.contains(&"PATH=/usr/bin".to_owned()));
        assert!(environment.contains(&"HOME=/Users/someone".to_owned()));
        assert!(
            !environment
                .iter()
                .any(|pair| pair.contains("TOKEN") || pair.contains("SECRET")),
            "{environment:?}"
        );
        assert!(environment.contains(&"TERM=xterm-256color".to_owned()));
        assert!(environment.contains(&"COLUMNS=80".to_owned()));
        assert!(environment.contains(&"LINES=24".to_owned()));
    }

    /// `--inherit-env` is the escape hatch, and it really does hand everything over — which is why
    /// `record` prints a warning when it is used and the README does not use it.
    #[test]
    fn inherit_env_hands_the_whole_shell_over() {
        let options = parsed("--out o --title t --inherit-env -- /bin/cat");
        let inherited = vec![("GITLAB_TOKEN".to_owned(), "glpat-secret".to_owned())];
        assert!(child_environment(&options, &inherited).contains(&"GITLAB_TOKEN=glpat-secret".to_owned()));
    }

    /// A variable a program needs is passed by hand, and it WINS over the inherited spelling —
    /// otherwise `--env` could not correct one.
    #[test]
    fn a_passed_variable_overrides_the_inherited_one() {
        let options = parsed("--out o --title t --env HOME=/tmp/fresh -- /bin/cat");
        let inherited = vec![("HOME".to_owned(), "/Users/someone".to_owned())];
        let environment = child_environment(&options, &inherited);
        let home: Vec<&String> = environment
            .iter()
            .filter(|pair| pair.starts_with("HOME="))
            .collect();
        assert_eq!(home.last(), Some(&&"HOME=/tmp/fresh".to_owned()));
    }

    /// A pair with no `=` is a typo, not a variable to invent a value for.
    #[test]
    fn an_env_pair_without_a_value_is_refused() {
        assert!(parse_from(words("--out o --title t --env HOME -- /bin/cat")).is_err());
    }

    /// The terminal's own four are the tool's to decide: a `TERM` from the operator's shell would
    /// make a recording depend on a terminfo entry the next machine may not have.
    #[test]
    fn the_terminals_own_variables_are_never_inherited() {
        let options = parsed("--out o --title t --inherit-env --cols 100 --rows 30 -- /bin/cat");
        let inherited = vec![
            ("TERM".to_owned(), "xterm-ghostty".to_owned()),
            ("COLUMNS".to_owned(), "999".to_owned()),
        ];
        let environment = child_environment(&options, &inherited);
        assert!(!environment.contains(&"TERM=xterm-ghostty".to_owned()));
        assert!(!environment.contains(&"COLUMNS=999".to_owned()));
        assert!(environment.contains(&"COLUMNS=100".to_owned()));
    }
}
