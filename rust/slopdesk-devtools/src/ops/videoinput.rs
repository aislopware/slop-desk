//! PATH-2 INPUT verify harness: a fresh video host, one synthetic gesture, then the injection
//! trace.
//!
//! Proves the host-side input-ordering and button-balance behaviour deterministically over real UDP
//! loopback — no GUI client, no computer-use cursor war. The legacy `SLOPDESK_INPUT_UNORDERED` A/B
//! mode is gone (the ordered single-consumer pump is the only path), so what this verifies is that
//! one path.
//!
//! Two things it needs that no code can supply: a real GUI login session with Screen-Recording and
//! Accessibility/Post-Event TCC, and `--window-id` pointing at something actually on screen
//! (`slopdesk-videohostd --list`; `TextEdit` is ideal).
//!
//! ## What the port changed
//! The trace scrape was `grep | sed -E | tr`, then three more `grep -c` passes over the same file.
//! It is one pass over one read here, and the injection indices come back as numbers — which is how
//! [`Trace::out_of_order`] can say the thing the shell could only print and leave to the eye.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;
use std::{fs, thread};

use super::{container, say};
use crate::proc;

/// Everything the harness learned from one host log.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Trace {
    /// The `[inject #N]` indices, in the order the host injected them.
    pub injected: Vec<u64>,
    /// How many `mouseDown` events were injected.
    pub down: usize,
    /// How many `mouseUp` events were injected — equal to [`Trace::down`] on a balanced gesture.
    pub up: usize,
    /// How many `mouseDrag` events were injected.
    pub drag: usize,
}

impl Trace {
    /// The first index that arrived out of order, if any.
    ///
    /// A gesture is injected under one consumer, so the indices must be strictly ascending. They
    /// need not start at 1 or be contiguous — a host that has been up longer than this run has
    /// already injected, and the harness only ever sees the tail.
    #[must_use]
    pub fn out_of_order(&self) -> Option<u64> {
        self.injected
            .windows(2)
            .find(|pair| pair[1] <= pair[0])
            .map(|pair| pair[1])
    }

    /// True when every press was released — the balance the ordered pump exists to keep.
    #[must_use]
    pub const fn balanced(&self) -> bool {
        self.down == self.up
    }
}

/// Read one host log into a [`Trace`].
///
/// The shell matched `[inject #N]: ` with `sed -E` and threw the number away as text; the parse
/// here is the same anchor, and anything that does not carry a number is not an injection line.
#[must_use]
pub fn scrape(log: &str) -> Trace {
    let mut trace = Trace::default();
    for line in log.lines() {
        if let Some(index) = line
            .split_once("[inject #")
            .and_then(|(_, rest)| rest.split_once(']'))
            .and_then(|(number, _)| number.parse::<u64>().ok())
        {
            trace.injected.push(index);
        }
        // Counted per LINE, exactly as `grep -c` counted: one event is one line of the trace.
        if line.contains("mouseDown") {
            trace.down += 1;
        }
        if line.contains("mouseUp") {
            trace.up += 1;
        }
        if line.contains("mouseDrag") {
            trace.drag += 1;
        }
    }
    trace
}

/// Start a fresh video host on `window`, run `slopdesk-synclient` with `args`, dump the trace.
///
/// # Errors
/// When the host binary is missing, the synclient build fails, or the gesture itself fails.
pub fn run(root: &Path, window: &str, args: &[String]) -> Result<(), String> {
    let host = crate::hostbin::binary_of(root, crate::hostbin::Daemon::Video, true);
    if !host.is_file() {
        return Err(format!(
            "{} is missing — run 'just videohostd' first",
            host.display()
        ));
    }

    // A throwaway container for the daemon this harness starts, fresh per run.
    //
    // `parked-windows.json` is why it is not optional: `slopdesk-videohostd` READS that file on its
    // way up — AX-moving whatever windows it names back off a dead virtual display — and UNLINKS it
    // unconditionally, before it even tries to decode it. Pointed at the real container, an
    // un-isolated run restores and then destroys the crash journal belonging to the developer's own
    // videohostd, and moves their windows while doing it. `video-prefs.json` folds into the
    // daemon's `env::Overlay` at the same moment, so it would also measure a configuration
    // nobody wrote.
    let state = std::env::temp_dir().join(format!("slopdesk-input-test.{}", std::process::id()));
    let environment = container(&state)?;

    let log = std::env::temp_dir().join("slopdesk-host.log");
    let _ = Command::new("/usr/bin/pkill")
        .args(["-f", "slopdesk-videohostd --window-id"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    thread::sleep(Duration::from_millis(1200));

    let sink = fs::File::create(&log).map_err(|error| format!("{}: {error}", log.display()))?;
    let errors = sink
        .try_clone()
        .map_err(|error| format!("{}: {error}", log.display()))?;
    let mut command = Command::new(&host);
    command
        .args([
            "--window-id",
            window,
            "--media-port",
            "9000",
            "--cursor-port",
            "9001",
            "--scale",
            "2",
        ])
        .env("SLOPDESK_INPUT_TRACE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::from(sink))
        .stderr(Stdio::from(errors));
    for (key, value) in &environment {
        command.env(key, value);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("{}: {error}", host.display()))?;
    say("video-input", &format!("host pid {} (wid={window})", child.id()));
    thread::sleep(Duration::from_millis(2500));

    let devtools = root.join("rust/slopdesk-devtools");
    let synclient = devtools.join("target/release/slopdesk-synclient");
    if !synclient.is_file() {
        proc::run(
            "cargo",
            &["build", "--release", "--bin", "slopdesk-synclient"],
            &devtools,
        )?;
    }
    let gesture = proc::run(&synclient.to_string_lossy(), args, root);
    thread::sleep(Duration::from_millis(1500));

    let text = fs::read_to_string(&log).unwrap_or_default();
    let trace = scrape(&text);
    let _ = child.kill();
    let _ = child.wait();
    let _ = fs::remove_dir_all(&state);

    say("video-input", "=== INJECTED ORDER ===");
    let order: Vec<String> = trace.injected.iter().map(|index| format!("#{index}")).collect();
    println!("{}", order.join(" "));
    say(
        "video-input",
        &format!("down={}  up={}  drag={}", trace.down, trace.up, trace.drag),
    );
    if let Some(index) = trace.out_of_order() {
        say(
            "video-input",
            &format!("WARNING: #{index} arrived after a higher index — the pump reordered"),
        );
    }
    if !trace.balanced() {
        say(
            "video-input",
            "WARNING: unbalanced buttons — a press was never released",
        );
    }
    gesture
}

#[cfg(test)]
mod tests {
    /// One trace, read once: indices in order, and one count per event kind.
    #[test]
    fn a_trace_reads_indices_and_counts_in_one_pass() {
        let log = r"videohostd: starting
videohostd: [inject #1]: mouseDown at (10, 20)
videohostd: [inject #2]: mouseDrag at (11, 21)
videohostd: [inject #3]: mouseDrag at (12, 22)
videohostd: [inject #4]: mouseUp at (12, 22)
videohostd: idle
";
        let trace = super::scrape(log);
        assert_eq!(trace.injected, [1, 2, 3, 4]);
        assert_eq!((trace.down, trace.up, trace.drag), (1, 1, 2));
        assert_eq!(trace.out_of_order(), None);
        assert!(trace.balanced());
    }

    /// A reordered pump is named, not left to the eye reading a line of `#N`s.
    #[test]
    fn a_lower_index_after_a_higher_one_is_reported() {
        let log = r"[inject #7]: mouseDown
[inject #9]: mouseDrag
[inject #8]: mouseUp
";
        assert_eq!(super::scrape(log).out_of_order(), Some(8));
    }

    /// A press with no release is the imbalance the ordered pump exists to prevent.
    #[test]
    fn a_press_with_no_release_is_unbalanced() {
        let trace = super::scrape("[inject #1]: mouseDown\n[inject #2]: mouseDrag\n");
        assert!(!trace.balanced(), "one down and no up is not balanced");
    }

    /// The tail of a long-lived host starts wherever it starts; only the ORDER is the property.
    #[test]
    fn a_trace_need_not_start_at_one() {
        let trace = super::scrape("[inject #4210]: mouseDown\n[inject #4211]: mouseUp\n");
        assert_eq!(trace.injected, [4210, 4211]);
        assert_eq!(trace.out_of_order(), None);
    }

    /// A line without a number is not an injection, however much it looks like one.
    #[test]
    fn a_bracket_without_a_number_is_not_an_injection() {
        let trace = super::scrape("[inject #]: dropped\n[inject #abc]: dropped\n");
        assert!(trace.injected.is_empty());
    }
}
