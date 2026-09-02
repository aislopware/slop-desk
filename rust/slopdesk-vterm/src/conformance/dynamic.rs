//! The half of conformance a still picture cannot reach: a frame that keeps changing.
//!
//! [`super`] asks one question — does the frame this crate assembles say what the engine says —
//! and asks it of a terminal that was fed once and rendered once. Every bug that needs a SECOND
//! frame to appear is invisible to it, and those are the bugs a modern TUI produces: the read skips
//! rows the engine reported clean ([`crate::session::VtSession::render`] is incremental by design),
//! so a row wrongly believed clean shows the previous frame forever, and nothing that renders once
//! can tell.
//!
//! There is no oracle for this one and none is needed, because the property is internal and exact:
//!
//! > **A terminal fed in pieces, drawn after every piece, must end up holding exactly the frame a
//! > terminal fed the same bytes in one go holds.**
//!
//! Incremental against fresh. Whatever the dirty tracking skipped, whatever a damage region missed,
//! whatever a row kept from a frame ago — all of it shows up as a difference against the session
//! that had no history to keep. The comparison is over CONTENT (text, colours, flags, cursor), not
//! over the frame struct: `revision`, `dirty` and the per-row dirty flags are bookkeeping about how
//! the frame was reached, and they are supposed to differ.
//!
//! ## Where the pieces come from
//!
//! Two sources, and the difference matters.
//!
//! **Recordings** — real programs, run once under `slopdesk-ttyrec`, with every `read(2)` from the
//! pty kept as its own chunk. That boundary schedule is not invented: it is the one the kernel and
//! the program between them produced, which is the only schedule the shipped surface will ever see.
//! `corpus/` holds an `@opentui/core` demo (the framework `OpenCode` ships on), nvim, fzf, lazygit
//! and `less` — five different renderers, three of them redrawing on a timer and one, `less`,
//! subscribing to nothing at all.
//!
//! **The fuzz corpus, re-cut** — the same 3271 inputs [`super`] sweeps, fed at several chunk sizes
//! including one byte at a time. A one-byte cut lands INSIDE every escape sequence in the corpus,
//! which is the state-machine boundary that a hand-written test never thinks to hit.
//!
//! ## And the input path, which only a recording can test
//!
//! A recording carries what was sent up the pty as well as what came down it: the script, and the
//! bytes the encoder produced for it at that point in the stream. Replaying re-encodes against the
//! terminal the preceding output built and compares. That is not a test of ghostty's encoders —
//! they are upstream's — it is a test that the modes the PROGRAM turned on are the modes the NEXT
//! input is encoded under. All four kinds of input have such a mode, each turned on mid-stream by
//! an escape sequence, and a recording is the only place that ordering exists to be checked:
//!
//! | input | the mode that decides its bytes | in the corpus |
//! | --- | --- | --- |
//! | a keystroke | the kitty keyboard protocol | nvim and lazygit turn it on: `<Escape>` is `CSI 27 u` |
//! | a pointer event | mouse tracking, and which report format | four programs report; `less` refuses |
//! | a paste | bracketed paste (mode 2004) | three bracket; `less` never asked, so its paste arrives as live keystrokes |
//! | a focus change | focus reporting (mode 1004) | three report `CSI I`; `less` refuses |
//!
//! **A refusal is a recorded answer, not a gap.** `less` asks for neither pointer reports nor focus
//! reports, so the recorded bytes for both are EMPTY, and a replay that started producing bytes
//! there would be writing into a running program's input on an event it never subscribed to. What
//! the refusal discriminates is the COMPOSITION above the engine — a surface that fabricated a
//! report of its own, a dropped `pointer.sync`, a cell→pixel conversion that drifted — each of
//! which passes every positive case in the corpus. It does NOT catch a lost `is_mouse_tracking`
//! check in [`crate::session::VtSession::encode_mouse`]: deleting that guard leaves the sweep
//! green, because the engine's own pointer encoder refuses one layer down. The guard stays as
//! belt, like the two redundancies noted on the resize below.
//!
//! ## The resize, and why it is synthetic rather than recorded
//!
//! `TIOCSWINSZ` belongs to hostd alone — `slopdesk-invariants`' `pty_winsize_single_writer` pins
//! the two crates that may even compile the setter — so `slopdesk-ttyrec` cannot deliver a
//! `SIGWINCH` and no recording can hold a program's reaction to one. It does not need to. The
//! property under test is the TERMINAL's: a session resized mid-stream must land where a session
//! resized at the same point in a single pass lands. That needs no cooperation from a child
//! process, and doing it synthetically buys resize points at every checkpoint of every recording
//! rather than one per program.

use std::path::PathBuf;

use libghostty_vt::render::{CellIterator, RenderState, RowIterator};

use super::{CELL_PX, COLS, ROWS, compare, fed};
use crate::frame::{CellFlags, Frame, FrameColors, FrameCursor, Rgb, UnderlineStyle};
use crate::recording::{Event, Recording};
use crate::session::VtSession;
use crate::{keyscript, mousescript};

// ---------------------------------------------------------------------------------------------
// The projection everything below compares
// ---------------------------------------------------------------------------------------------

/// One cell, reduced to what a renderer would draw with.
///
/// Text is not here and is not missing: it is compared per ROW, because a cell that hides its glyph
/// contributes nothing to either side and comparing the row's drawn text says so once instead of
/// once per column.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CellShot {
    fg: Rgb,
    bg: Rgb,
    underline_color: Rgb,
    flags: CellFlags,
    underline: UnderlineStyle,
}

/// One row: the text a renderer would draw, and every cell's attributes.
#[derive(Debug, Clone, PartialEq, Eq)]
struct RowShot {
    text: String,
    cells: Vec<CellShot>,
}

/// A frame reduced to content, with every trace of HOW it was reached left out.
///
/// `revision`, `Frame::dirty` and `FrameRow::dirty` are all deliberately absent. They are the
/// bookkeeping that says what changed since last time, so an incremental session and a fresh one
/// disagree about them by construction — including them would make this test fail for the one
/// reason that is not a bug.
#[derive(Debug, Clone, PartialEq, Eq)]
struct FrameShot {
    cols: u16,
    rows: Vec<RowShot>,
    cursor: Option<FrameCursor>,
    colors: FrameColors,
}

/// Reduces a frame to its content.
fn shot(frame: &Frame) -> FrameShot {
    FrameShot {
        cols: frame.cols,
        rows: (0..frame.row_count())
            .map(|y| {
                RowShot {
                    text: frame.row_text(y),
                    cells: frame.row(y).map_or_else(Vec::new, |row| {
                        row.cells
                            .iter()
                            .map(|cell| {
                                CellShot {
                                    fg: cell.fg,
                                    bg: cell.bg,
                                    underline_color: cell.underline_color,
                                    flags: cell.flags,
                                    underline: cell.underline,
                                }
                            })
                            .collect()
                    }),
                }
            })
            .collect(),
        cursor: frame.cursor,
        colors: frame.colors,
    }
}

/// The first place two frames differ, in a form that names a row and a column.
fn first_difference(ours: &FrameShot, theirs: &FrameShot) -> Option<String> {
    if ours.cols != theirs.cols {
        return Some(format!(
            "grid width: incremental {} vs fresh {}",
            ours.cols, theirs.cols
        ));
    }
    if ours.rows.len() != theirs.rows.len() {
        return Some(format!(
            "row count: incremental {} vs fresh {}",
            ours.rows.len(),
            theirs.rows.len()
        ));
    }
    for (y, (ours, theirs)) in ours.rows.iter().zip(theirs.rows.iter()).enumerate() {
        if ours.text != theirs.text {
            return Some(format!(
                "row {y} text:\n    incremental: {:?}\n    fresh:       {:?}",
                ours.text, theirs.text
            ));
        }
        for (x, (ours, theirs)) in ours.cells.iter().zip(theirs.cells.iter()).enumerate() {
            if ours != theirs {
                return Some(format!(
                    "row {y} column {x} attributes:\n    incremental: {ours:?}\n    fresh:       {theirs:?}"
                ));
            }
        }
    }
    if ours.cursor != theirs.cursor {
        return Some(format!(
            "cursor: incremental {:?} vs fresh {:?}",
            ours.cursor, theirs.cursor
        ));
    }
    if ours.colors != theirs.colors {
        return Some(format!(
            "default colours: incremental {:?} vs fresh {:?}",
            ours.colors, theirs.colors
        ));
    }
    None
}

// ---------------------------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------------------------

/// A session at a recording's own geometry, with the queues drained the way a real caller drains
/// them.
fn session_for(cols: u16, rows: u16, cell: (u32, u32)) -> VtSession {
    let mut session = VtSession::new(cols, rows, cell.0, cell.1).expect("session");
    session.set_scrollback_rows(0).expect("scrollback");
    session
}

/// Feeds one chunk and drains everything the engine wants to push back.
///
/// The replies are taken and thrown away here rather than left in the sink: a sink that grows for
/// the length of a sweep is a memory test nobody asked for, and `docs/68` §4.1 makes draining the
/// caller's obligation anyway.
fn feed_chunk(session: &mut VtSession, chunk: &[u8]) -> Vec<u8> {
    session.feed(chunk);
    let mut replies = Vec::new();
    session.take_pty_replies(&mut replies);
    drop(session.take_clipboard_writes());
    replies
}

/// A session fed the whole of `chunks` at once and rendered once.
fn fresh(cols: u16, rows: u16, cell: (u32, u32), chunks: &[&[u8]]) -> VtSession {
    let mut session = session_for(cols, rows, cell);
    let whole: Vec<u8> = chunks.concat();
    drop(feed_chunk(&mut session, &whole));
    session.render().expect("render");
    session
}

// ---------------------------------------------------------------------------------------------
// The recordings
// ---------------------------------------------------------------------------------------------

/// Every committed recording, decoded.
///
/// These are INPUTS. Nothing in one is an expected answer — the frames are recomputed on every run
/// — so there is nothing to re-bless when the engine pin moves, and the golden-vector rule does not
/// reach them.
fn recordings() -> Vec<(String, Recording)> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("corpus");
    let mut found: Vec<(String, Recording)> = std::fs::read_dir(&dir)
        .expect("the corpus directory is committed")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "sdrec"))
        .map(|path| {
            let bytes = std::fs::read(&path).expect("read recording");
            let recording =
                Recording::decode(&bytes).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
            (recording.title.clone(), recording)
        })
        .collect();
    found.sort_by(|left, right| left.0.cmp(&right.0));
    assert!(
        found.len() >= 4,
        "the recorded corpus has shrunk to {} — it is committed, so this is a deletion, not an \
         unprovisioned tree",
        found.len()
    );
    found
}

/// Every output chunk in a recording, in order, as the pty produced them.
fn output_chunks(recording: &Recording) -> Vec<&[u8]> {
    recording
        .events
        .iter()
        .filter_map(|event| {
            match event {
                Event::Output(bytes) => Some(bytes.as_slice()),
                Event::Input { .. }
                | Event::Reply(_)
                | Event::Mouse { .. }
                | Event::Paste { .. }
                | Event::Focus { .. } => None,
            }
        })
        .collect()
}

/// Which chunk indices to stop and compare at.
///
/// Every chunk for a short recording; about forty evenly spaced for a long one. The comparison
/// builds a fresh session per checkpoint, so checking every read of the longest recording would
/// feed hundreds of megabytes to prove what forty checkpoints already prove.
fn checkpoints(count: usize) -> Vec<usize> {
    if count <= 120 {
        return (1..=count).collect();
    }
    let stride = count.div_ceil(40).max(1);
    (1..=count)
        .filter(|index| index % stride == 0 || *index == count)
        .collect()
}

#[test]
fn an_incremental_feed_lands_where_a_fresh_one_does() {
    for (name, recording) in recordings() {
        let chunks = output_chunks(&recording);
        let cell = (recording.cell_width, recording.cell_height);
        let mut incremental = session_for(recording.cols, recording.rows, cell);

        let stops = checkpoints(chunks.len());
        let mut next = 0_usize;
        for (index, chunk) in chunks.iter().enumerate() {
            drop(feed_chunk(&mut incremental, chunk));
            // Drawn after EVERY read, which is what the shipped surface does and what makes the
            // dirty tracking the thing under test.
            incremental.render().expect("render");

            let Some(stop) = stops.get(next) else { continue };
            if *stop != index + 1 {
                continue;
            }
            next += 1;

            let prefix = chunks.get(..=index).unwrap_or_default();
            let fresh = fresh(recording.cols, recording.rows, cell, prefix);
            let difference = first_difference(&shot(incremental.frame()), &shot(fresh.frame()));
            assert!(
                difference.is_none(),
                "{name}: after {} of {} pty reads the incrementally drawn frame is not the frame a fresh \
                 session holds:\n{}",
                index + 1,
                chunks.len(),
                difference.unwrap_or_default()
            );
        }
    }
}

#[test]
fn every_recorded_frame_reads_the_same_as_the_engine() {
    // The oracle from `super`, applied to each frame of a real program rather than to one still
    // picture. A recording is where the engine's own dump and the frame have the most to disagree
    // about: alternate screen, scrolling regions, a cursor parked between frames, and repaints that
    // touch the same rows over and over.
    for (name, recording) in recordings() {
        let cell = (recording.cell_width, recording.cell_height);
        let mut session = session_for(recording.cols, recording.rows, cell);
        let mut frames = 0_usize;
        let mut blanked = 0_usize;

        for (index, chunk) in output_chunks(&recording).iter().enumerate() {
            drop(feed_chunk(&mut session, chunk));
            session.render().expect("render");
            frames += 1;

            let (verdict, took_concession) = compare(&session);
            blanked += usize::from(took_concession);
            assert!(
                verdict.is_none(),
                "{name}: frame {index} disagrees with the engine:\n{}",
                verdict.unwrap_or_default()
            );
        }

        assert!(
            frames > 10,
            "{name}: only {frames} frames — that is not a session"
        );
        // Nothing in the corpus conceals, so the SGR 8 concession must never be reached. A
        // recording that starts taking it is a read that has begun blanking cells for some other
        // reason, and would otherwise pass quietly.
        assert_eq!(
            blanked, 0,
            "{name}: took the concealed-cell concession {blanked} times"
        );
    }
}

/// How many of each recorded input a replay reproduced, so a corpus that quietly lost a whole
/// input kind fails rather than passing on the kinds it kept.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Tally {
    keys: usize,
    pointer: usize,
    pastes: usize,
    focus: usize,
    replies: usize,
    /// Pointer and focus events that correctly produced NOTHING, because no program had asked.
    refusals: usize,
    /// Pastes a program had asked to receive wrapped in `CSI 200~` / `CSI 201~`.
    bracketed: usize,
    /// Pastes that reached a program that never asked, and so arrived as live keystrokes.
    ///
    /// The negative half of the paste path, and it is a different failure from a refused pointer
    /// report: bytes still go out, they just must not be wrapped. A surface that bracketed
    /// unconditionally would put a literal `[200~` on the screen of every program in the corpus
    /// that never asked for the mode.
    bare: usize,
}

impl Tally {
    fn add(&mut self, other: Self) {
        self.keys += other.keys;
        self.pointer += other.pointer;
        self.pastes += other.pastes;
        self.focus += other.focus;
        self.replies += other.replies;
        self.refusals += other.refusals;
        self.bracketed += other.bracketed;
        self.bare += other.bare;
    }
}

/// Replays one recording, checking every byte it sent and every byte it was answered with.
///
/// One ordered walk rather than one walk per input kind, because the ORDER is the content: a
/// pointer event before a program turned tracking on must encode to nothing and the same event
/// after it must encode to a report, and four separate passes would each rebuild the terminal and
/// lose exactly that relationship.
fn replay_input_path(name: &str, recording: &Recording) -> Tally {
    let cell = (recording.cell_width, recording.cell_height);
    let mut session = session_for(recording.cols, recording.rows, cell);
    // The same geometry the recorder used, from the same function, so a re-encoded pointer report
    // resolves to the cell the script named rather than to whatever this test would have guessed.
    session.set_surface_geometry(recording.geometry());

    let mut tally = Tally::default();
    let mut pending: Vec<u8> = Vec::new();

    for event in &recording.events {
        match event {
            Event::Output(bytes) => pending.extend_from_slice(&feed_chunk(&mut session, bytes)),
            Event::Reply(bytes) => {
                assert_eq!(
                    pending,
                    *bytes,
                    "{name}: the engine answered {:?} where the recording answered {:?}",
                    String::from_utf8_lossy(&pending),
                    String::from_utf8_lossy(bytes)
                );
                pending.clear();
                tally.replies += 1;
            },
            Event::Input { script, bytes } => {
                let presses = keyscript::parse(script).expect("recorded script parses");
                let mut encoded = Vec::new();
                for press in &presses {
                    session.encode_key(&press.press(), &mut encoded).expect("encode");
                }
                assert_bytes(name, "keystroke", script, &encoded, bytes);
                tally.keys += 1;
            },
            Event::Mouse { script, bytes } => {
                let moves = mousescript::parse(script).expect("recorded pointer script parses");
                let geometry = session.surface_geometry();
                let mut encoded = Vec::new();
                for moved in &moves {
                    let _reported = session
                        .encode_mouse(&moved.to_move(geometry), &mut encoded)
                        .expect("encode");
                }
                assert_bytes(name, "pointer event", script, &encoded, bytes);
                tally.pointer += 1;
                tally.refusals += usize::from(bytes.is_empty());
            },
            Event::Paste { text, bytes } => {
                let bracketed = session.wants_bracketed_paste().expect("paste mode");
                let encoded = session.encode_paste(text, bracketed).expect("encode");
                assert_bytes(name, "paste", text, &encoded, bytes);
                tally.pastes += 1;
                if bracketed {
                    tally.bracketed += 1;
                } else {
                    // A bare paste must be the text and nothing else. `assert_bytes` already
                    // pinned it against the recording; this pins it against the TEXT, so a
                    // re-record that captured a wrapped paste as bare could not agree with itself.
                    assert_eq!(
                        encoded,
                        text.as_bytes(),
                        "{name}: an unbracketed paste of {text:?} carried framing"
                    );
                    tally.bare += 1;
                }
            },
            Event::Focus { focused, bytes } => {
                session.set_focused(*focused);
                let mut encoded = Vec::new();
                let _queued = session.take_pty_replies(&mut encoded);
                assert_bytes(name, "focus change", &format!("{focused}"), &encoded, bytes);
                tally.focus += 1;
                tally.refusals += usize::from(bytes.is_empty());
            },
        }
    }
    tally
}

/// Asserts that a re-encode reproduced the recorded bytes, naming both sides readably.
fn assert_bytes(name: &str, kind: &str, spelling: &str, encoded: &[u8], recorded: &[u8]) {
    assert_eq!(
        encoded,
        recorded,
        "{name}: the {kind} {spelling:?} encodes to {:?} now and encoded to {:?} when the session was \
         recorded — the modes the program negotiated are no longer reaching the encoder",
        String::from_utf8_lossy(encoded),
        String::from_utf8_lossy(recorded)
    );
}

#[test]
fn a_recorded_session_reproduces_every_byte_of_its_input_path() {
    let mut total = Tally::default();
    for (name, recording) in recordings() {
        let tally = replay_input_path(&name, &recording);
        // Per recording rather than only in total: a corpus where one program carries every
        // pointer event and the rest carry none is one re-record away from covering nothing.
        assert!(
            tally.pointer > 0,
            "{name}: no pointer event — a re-record dropped --send-mouse"
        );
        total.add(tally);
    }

    // Floors, one per kind. Each stands for a flag the re-record commands in `corpus/README.md`
    // pass; forgetting one would otherwise leave this test passing on the kinds that survived.
    assert!(total.keys >= 12, "only {} keystrokes in the corpus", total.keys);
    assert!(
        total.pointer >= 6,
        "only {} pointer events in the corpus",
        total.pointer
    );
    assert!(total.pastes >= 3, "only {} pastes in the corpus", total.pastes);
    assert!(
        total.focus >= 6,
        "only {} focus changes in the corpus",
        total.focus
    );
    assert!(
        total.replies >= 8,
        "only {} recorded replies — the query path is not covered",
        total.replies
    );
    // The discriminating negative. Without at least one recorded refusal, an encoder that reported
    // regardless of whether a program had asked would pass everything above.
    assert!(
        total.refusals >= 4,
        "the corpus holds {} recorded refusals — with none, an encoder that ignored the tracking and \
         focus-reporting modes entirely would pass every assertion above",
        total.refusals
    );
    // Both shapes of paste, for the same reason: one of them alone is passed by a surface that
    // brackets unconditionally, and the other alone by a surface that never brackets.
    assert!(
        total.bracketed >= 2,
        "only {} bracketed pastes in the corpus",
        total.bracketed
    );
    assert!(
        total.bare >= 1,
        "no paste in the corpus reached a program that had NOT asked for bracketing — that is the half \
         where a surface bracketing unconditionally prints `[200~` on a real screen"
    );
}

#[test]
fn a_pointer_report_is_refused_until_a_program_asks_and_then_names_the_cell() {
    // The positive control for the refusals above, and the only place the cell→pixel→cell round
    // trip is checked end to end: the script names a cell, `to_move` puts a pixel in the middle of
    // it, the encoder divides by the same geometry, and the report has to come back naming the cell
    // the script started from. A padding or a rounding rule that drifted would land one cell out.
    let mut session = session_for(COLS, ROWS, CELL_PX);
    session.set_surface_geometry(crate::recording::geometry_of(COLS, ROWS, CELL_PX.0, CELL_PX.1));
    let event = mousescript::parse("left@12,5")
        .expect("parse")
        .first()
        .copied()
        .expect("one event");
    let moved = event.to_move(session.surface_geometry());

    let mut before = Vec::new();
    assert!(
        !session.encode_mouse(&moved, &mut before).expect("encode"),
        "a pointer event was reported before any program asked for mouse reporting"
    );
    assert!(
        before.is_empty(),
        "a refused pointer event still wrote {before:?}"
    );

    // `?1000h` is the button-event mode and `?1006h` the SGR report format — the pair every modern
    // TUI in the corpus turns on together.
    drop(feed_chunk(&mut session, b"\x1b[?1000h\x1b[?1006h"));
    assert!(session.is_mouse_tracking().expect("tracking"));

    let mut after = Vec::new();
    assert!(
        session.encode_mouse(&moved, &mut after).expect("encode"),
        "no report after the program turned mouse tracking on"
    );
    // SGR 1006 is `CSI < button ; col ; row M`, one-based, so cell (12, 5) is `13;6`.
    assert_eq!(
        String::from_utf8_lossy(&after),
        "\u{1b}[<0;13;6M",
        "the report does not name the cell the script pointed at"
    );
}

#[test]
fn a_paste_is_bracketed_only_once_a_program_has_asked_for_bracketing() {
    // The paste counterpart of the refusal above. Both halves matter: an unbracketed paste that
    // arrived wrapped would be printed as `[200~` by a shell that never asked, and a bracketed one
    // that arrived bare is the injection the wrapping exists to prevent.
    let mut session = session_for(COLS, ROWS, CELL_PX);
    assert!(!session.wants_bracketed_paste().expect("mode"));
    let bare = session
        .encode_paste("hi", session.wants_bracketed_paste().expect("mode"))
        .expect("encode");
    assert_eq!(String::from_utf8_lossy(&bare), "hi");

    drop(feed_chunk(&mut session, b"\x1b[?2004h"));
    assert!(session.wants_bracketed_paste().expect("mode"));
    let wrapped = session
        .encode_paste("hi", session.wants_bracketed_paste().expect("mode"))
        .expect("encode");
    assert_eq!(String::from_utf8_lossy(&wrapped), "\u{1b}[200~hi\u{1b}[201~");

    // The breakout: a payload carrying its own end marker must not be able to close the block and
    // have its tail run as typed input.
    let smuggled = session
        .encode_paste("a\u{1b}[201~rm -rf /", true)
        .expect("encode");
    let text = String::from_utf8_lossy(&smuggled);
    assert_eq!(
        text.matches("\u{1b}[201~").count(),
        1,
        "a pasted end marker survived the scrub: {text:?}"
    );
    assert!(
        text.ends_with("\u{1b}[201~"),
        "the block does not close last: {text:?}"
    );
}

#[test]
fn a_focus_change_is_reported_only_once_a_program_has_asked_to_hear_about_it() {
    let mut session = session_for(COLS, ROWS, CELL_PX);
    let mut quiet = Vec::new();
    session.set_focused(true);
    let _queued = session.take_pty_replies(&mut quiet);
    assert!(quiet.is_empty(), "focus was reported before mode 1004: {quiet:?}");

    // Turning the mode on reports the CURRENT focus immediately, which is the half a program that
    // starts up already focused depends on — it has no other way to learn.
    drop(feed_chunk(&mut session, b"\x1b[?1004h"));
    let mut armed = Vec::new();
    session.set_focused(false);
    let _queued = session.take_pty_replies(&mut armed);
    assert_eq!(String::from_utf8_lossy(&armed), "\u{1b}[O");

    let mut regained = Vec::new();
    session.set_focused(true);
    let _queued = session.take_pty_replies(&mut regained);
    assert_eq!(String::from_utf8_lossy(&regained), "\u{1b}[I");

    // Idempotent: a view that pushes its focus from every layout pass must not put one `CSI I` per
    // pass on a program's input.
    let mut again = Vec::new();
    session.set_focused(true);
    let _queued = session.take_pty_replies(&mut again);
    assert!(again.is_empty(), "a repeated focus push reported {again:?}");
}

/// One row of the pointer matrix: the modes a program turned on, a script, and the exact bytes.
///
/// `""` means the event must be REFUSED — the mode combination does not subscribe to it, and a
/// report there would be bytes on a program's input that it never asked for and cannot parse.
const POINTER_MATRIX: &[(&str, &str, &str)] = &[
    // No report format: the original X10 encoding, `CSI M` and three bytes biased by 32. Cell
    // (12, 5) is one-based (13, 6), so the coordinate bytes are 45 (`-`) and 38 (`&`).
    ("\u{1b}[?1000h", "left@12,5", "\u{1b}[M -&"),
    // X10 cannot say WHICH button came up: every release is button 3, byte 32 + 3 = 35 (`#`).
    ("\u{1b}[?1000h", "release:left@12,5", "\u{1b}[M#-&"),
    // 1000 is button-event tracking: motion is not part of the subscription even with a button
    // held, and a drag under it must stay silent.
    ("\u{1b}[?1000h", "motion:left@12,5", ""),
    // 1006, the SGR format every modern TUI asks for: decimal, unbiased, and `m` for a release,
    // which is what makes the button identifiable on the way up.
    ("\u{1b}[?1000h\u{1b}[?1006h", "left@12,5", "\u{1b}[<0;13;6M"),
    (
        "\u{1b}[?1000h\u{1b}[?1006h",
        "release:left@12,5",
        "\u{1b}[<0;13;6m",
    ),
    // Modifiers ride in the button field: shift adds 4, alt 8, ctrl 16.
    ("\u{1b}[?1000h\u{1b}[?1006h", "S-left@12,5", "\u{1b}[<4;13;6M"),
    ("\u{1b}[?1000h\u{1b}[?1006h", "C-left@12,5", "\u{1b}[<16;13;6M"),
    // The wheel is buttons 4-7, offset by 64 rather than by a modifier.
    ("\u{1b}[?1000h\u{1b}[?1006h", "4@12,5", "\u{1b}[<64;13;6M"),
    // 1015, the urxvt format: decimal like SGR but still biased by 32 and with no release button.
    ("\u{1b}[?1000h\u{1b}[?1015h", "left@12,5", "\u{1b}[32;13;6M"),
    // 1016 reports PIXELS, and it is the sharpest test in this file of slopdesk's own conversion:
    // every other row would still pass if `to_move` drifted by up to half a cell, because the
    // divide back to a cell absorbs it. Here the number IS the pixel — cell (12, 5) at 8x16 has
    // its middle at (12*8 + 4, 5*16 + 8) = (100, 88) — so a drift of one pixel fails.
    // Note the pixels are 0-BASED where xterm's SGR-Pixels documents 1-based ones. That is the
    // engine's spelling, measured from it rather than chosen here, and it is pinned as measured:
    // the row exists to catch OUR conversion drifting, and an engine bump that changed the base
    // would fail this row honestly, which is what a pinned byte is for.
    ("\u{1b}[?1000h\u{1b}[?1016h", "left@12,5", "\u{1b}[<0;100;88M"),
    // 1002 adds motion WHILE A BUTTON IS HELD. The motion bit is 32, so a left-drag is 0 + 32.
    (
        "\u{1b}[?1002h\u{1b}[?1006h",
        "motion:left@12,5",
        "\u{1b}[<32;13;6M",
    ),
    // ...and only while held: a bare hover under 1002 is still not subscribed to.
    ("\u{1b}[?1002h\u{1b}[?1006h", "motion:@12,5", ""),
    // 1003 is any-event tracking, where a hover with no button IS reported: 32 for motion plus 3
    // for "no button".
    ("\u{1b}[?1003h\u{1b}[?1006h", "motion:@12,5", "\u{1b}[<35;13;6M"),
];

#[test]
fn a_pointer_report_is_spelled_the_way_the_mode_the_program_chose_spells_it() {
    // The corpus covers exactly one point of this matrix — 1000 + 1006, the pair every TUI in it
    // asks for — so everything else here is a mode a real program could turn on tomorrow and no
    // recording would catch. These spellings are PINNED deliberately, the same doctrine as the
    // recorded bytes: they are xterm's, an engine bump that changes one is a wire change for every
    // program in a pane, and this test is where it is supposed to be noticed.
    for (setup, script, expected) in POINTER_MATRIX {
        let mut session = session_for(COLS, ROWS, CELL_PX);
        session.set_surface_geometry(crate::recording::geometry_of(COLS, ROWS, CELL_PX.0, CELL_PX.1));
        drop(feed_chunk(&mut session, setup.as_bytes()));

        let mut encoded = Vec::new();
        let mut reported = false;
        for moved in mousescript::parse(script).expect("pointer script parses") {
            reported = session
                .encode_mouse(&moved.to_move(session.surface_geometry()), &mut encoded)
                .expect("encode");
        }

        let modes = setup.replace('\u{1b}', "ESC");
        assert_eq!(
            String::from_utf8_lossy(&encoded),
            *expected,
            "under {modes} the pointer event {script:?} encodes to {:?}",
            String::from_utf8_lossy(&encoded).replace('\u{1b}', "ESC")
        );
        assert_eq!(
            reported,
            !expected.is_empty(),
            "under {modes} the pointer event {script:?} reported {reported} with {} bytes",
            encoded.len()
        );
    }
}

#[test]
fn a_clipboard_write_and_a_title_reach_the_surface_from_a_recorded_stream() {
    // OSC is the one output path that does not end in a cell, so nothing above would notice it
    // going missing: a frame with the right pixels and no title is a frame that passes every
    // comparison in this file.
    let mut session = session_for(COLS, ROWS, CELL_PX);
    session.feed(b"\x1b]0;the title\x07\x1b]7;file:///tmp/somewhere\x1b\\");
    assert_eq!(session.title().expect("title"), "the title");
    assert_eq!(session.pwd().expect("pwd"), "file:///tmp/somewhere");

    // OSC 52, base64 of "clip".
    session.feed(b"\x1b]52;c;Y2xpcA==\x07");
    let writes = session.take_clipboard_writes();
    assert_eq!(writes.len(), 1, "OSC 52 produced {} writes", writes.len());
    assert_eq!(writes.first().map(|write| write.text.as_str()), Some("clip"));
    // Drained exactly once: a second take must find nothing, or a surface polling in a loop would
    // paste the same payload for as long as the pane lived.
    assert!(session.take_clipboard_writes().is_empty());
    assert!(!session.has_clipboard_writes());
}

// ---------------------------------------------------------------------------------------------
// Resize, mid-stream
// ---------------------------------------------------------------------------------------------

/// The grids a recording is resized to part-way through.
///
/// One smaller in both directions and one larger in both, because the two are different code: a
/// shrink has to drop or reflow rows the grid no longer has, and a grow has to produce rows that
/// were never written. A resize to the SAME size is in the list on purpose — it is the case a
/// naive implementation treats as free and a dirty-tracking one can still get wrong, because
/// nothing about the grid changed and yet every row must still be re-scanned.
const RESIZE_TARGETS: &[(u16, u16)] = &[(60, 20), (140, 44), (100, 30)];

/// Feeds `chunks`, resizing to `target` once `after` of them are in, and draws after every one.
fn fed_across_a_resize(
    recording: &Recording,
    chunks: &[&[u8]],
    after: usize,
    target: (u16, u16),
    draw_every_chunk: bool,
) -> VtSession {
    let cell = (recording.cell_width, recording.cell_height);
    let mut session = session_for(recording.cols, recording.rows, cell);
    for (index, chunk) in chunks.iter().enumerate() {
        if index == after {
            session
                .resize(target.0, target.1, cell.0, cell.1)
                .expect("resize");
        }
        drop(feed_chunk(&mut session, chunk));
        if draw_every_chunk {
            session.render().expect("render");
        }
    }
    if after >= chunks.len() {
        session
            .resize(target.0, target.1, cell.0, cell.1)
            .expect("resize");
    }
    session.render().expect("render");
    session
}

#[test]
fn a_resize_mid_stream_lands_where_a_fresh_one_does() {
    // The same property as `an_incremental_feed_lands_where_a_fresh_one_does`, with the one event
    // that invalidates every row at once dropped into the middle of it. A dirty-tracking scan that
    // resizes its own buffers without marking the whole grid dirty shows the OLD width's rows for
    // as long as nothing rewrites them, and that is invisible to a session that was the new size
    // from the start.
    //
    // Synthetic rather than recorded, and it has to be: `TIOCSWINSZ` is hostd's alone, so no
    // recorder in this tree can make a child redraw for a `SIGWINCH`. The terminal's own behaviour
    // needs no child.
    let mut checked = 0_usize;
    for (name, recording) in recordings() {
        let chunks = output_chunks(&recording);
        if chunks.len() < 8 {
            continue;
        }
        for target in RESIZE_TARGETS {
            // Four points across the stream: before anything has been drawn, twice inside, and
            // after the last read — the last one being the ordinary "the user dragged the window
            // while nothing was running" case.
            for divisor in [8_usize, 3, 2, 1] {
                #[expect(
                    clippy::integer_division,
                    reason = "a chunk index, and the truncation is the point: the eighth of the way through \
                              is whichever whole read that lands on"
                )]
                let after = chunks.len() / divisor;
                let stepped = fed_across_a_resize(&recording, &chunks, after, *target, true);
                let once = fed_across_a_resize(&recording, &chunks, after, *target, false);
                let difference = first_difference(&shot(stepped.frame()), &shot(once.frame()));
                assert!(
                    difference.is_none(),
                    "{name}: resized to {}x{} after {after} of {} reads, the incrementally drawn frame is \
                     not the frame one drawn once holds:\n{}",
                    target.0,
                    target.1,
                    chunks.len(),
                    difference.unwrap_or_default()
                );
                assert_eq!(
                    stepped.frame().cols,
                    target.0,
                    "{name}: the frame kept the old width across a resize"
                );
                checked += 1;
            }
        }
    }
    assert!(checked > 40, "only {checked} resize points were checked");
}

#[test]
fn a_recorded_session_replays_the_same_with_scrollback_kept() {
    // Every other sweep here runs with scrollback off, which is the cheap setting and also the one
    // where the scrollback code never runs. A scrolling region that pushed a row into history and
    // a viewport that then read one row too far would be invisible to all of them.
    for (name, recording) in recordings() {
        let chunks = output_chunks(&recording);
        let cell = (recording.cell_width, recording.cell_height);

        let mut incremental =
            VtSession::new(recording.cols, recording.rows, cell.0, cell.1).expect("session");
        incremental.set_scrollback_rows(2000).expect("scrollback");
        for chunk in &chunks {
            drop(feed_chunk(&mut incremental, chunk));
            incremental.render().expect("render");
        }

        let mut once = VtSession::new(recording.cols, recording.rows, cell.0, cell.1).expect("session");
        once.set_scrollback_rows(2000).expect("scrollback");
        drop(feed_chunk(&mut once, &chunks.concat()));
        once.render().expect("render");

        let difference = first_difference(&shot(incremental.frame()), &shot(once.frame()));
        assert!(
            difference.is_none(),
            "{name}: with scrollback kept, the incrementally drawn frame is not the frame a fresh session \
             holds:\n{}",
            difference.unwrap_or_default()
        );
        // The viewport is at the bottom because nothing scrolled it, and that is what makes the
        // frames above comparable at all — a viewport parked in history would be a different
        // question, asked by `replay-state`'s own tests.
        assert!(
            incremental.is_viewport_at_bottom().expect("viewport"),
            "{name}: feeding output alone moved the viewport off the bottom"
        );
    }
}

// ---------------------------------------------------------------------------------------------
// Chunk seams
// ---------------------------------------------------------------------------------------------

/// The cut sizes the seam sweep uses.
///
/// One byte is the whole point: it lands inside every escape sequence, every UTF-8 scalar and every
/// grapheme cluster in the corpus at once. Three and seven are there so a bug that happens to be
/// invisible at a period of one still has to survive two periods that share no factor with the
/// sequences' lengths.
const CUTS: &[usize] = &[1, 3, 7];

#[test]
fn a_chunk_seam_never_changes_the_frame() {
    let Some(corpus) = super::stream_corpus() else {
        // The committed micro corpus below covers the bare checkout.
        return seams_over(MICRO_SEAM_CORPUS);
    };

    let files: Vec<PathBuf> = std::fs::read_dir(&corpus)
        .expect("read corpus")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();

    let workers = std::thread::available_parallelism().map_or(4, std::num::NonZeroUsize::get);
    let per = files.len().div_ceil(workers.max(1)).max(1);

    let (checked, mut failures) = std::thread::scope(|scope| {
        #[expect(clippy::needless_collect, reason = "collecting is what starts the workers")]
        let handles: Vec<_> = files
            .chunks(per)
            .map(|chunk| {
                scope.spawn(move || {
                    let mut checked = 0_usize;
                    let mut failures: Vec<String> = Vec::new();
                    for path in chunk {
                        let Ok(bytes) = std::fs::read(path) else { continue };
                        checked += 1;
                        if let Some(report) = seam_verdict(&bytes) {
                            let name = path
                                .file_name()
                                .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
                            failures.push(format!("  {name}: {report}"));
                        }
                    }
                    (checked, failures)
                })
            })
            .collect();

        handles
            .into_iter()
            .fold((0_usize, Vec::new()), |mut acc, handle| {
                let (checked, failures) = handle.join().expect("worker");
                acc.0 += checked;
                acc.1.extend(failures);
                acc
            })
    });

    assert!(checked > 100, "the corpus held only {checked} inputs");
    let total = failures.len();
    failures.truncate(8);
    assert!(
        failures.is_empty(),
        "{total} of {checked} corpus inputs render differently depending on where the pty read boundaries \
         fell:\n{}",
        failures.join("\n")
    );
}

/// The shapes the seam sweep checks on a bare checkout.
///
/// Every one of them has a multi-byte thing to cut through: an escape sequence, a UTF-8 scalar, a
/// grapheme cluster, and an OSC with a string terminator two bytes long.
const MICRO_SEAM_CORPUS: &[&[u8]] = &[
    b"\x1b[38;2;255;128;0mtruecolor\x1b[0m\r\n",
    "\u{65e5}\u{672c}\u{8a9e} e\u{301}\u{1f469}\u{200d}\u{1f4bb}\r\n".as_bytes(),
    b"\x1b]8;;https://example.invalid/a\x1b\\link\x1b]8;;\x1b\\\r\n",
    b"\x1b[?1049h\x1b[H\x1b[2Jalt\x1b[?1049l",
    b"\x1b[H\x1b[2J\x1b[5;20r\x1b[10;1Hregion\r\n",
    // A full reset in the middle of a stream: everything before it must be gone however the bytes
    // were cut, and `ESC c` is two bytes with nothing to resynchronise on if the first is eaten.
    b"\x1b[31mbefore\x1bcafter\r\n",
    // DECCOLM, which changes the GRID rather than its contents — the frame's own bounds move, so a
    // paint that cached a width draws the wrong number of columns for a frame.
    b"\x1b[?3hwide\r\n\x1b[?3lnarrow\r\n",
    // The four modes the input path reads. They carry no glyphs at all, which is the point: a cut
    // that lost one would change no cell and every input encoded afterwards.
    b"\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004hmodes on\r\n",
    // A synchronized update wrapping a repaint, which is what a modern framework emits per frame.
    b"\x1b[?2026h\x1b[H\x1b[2Jframe\r\n\x1b[?2026l",
    // OSC with the two terminators that exist, one of them two bytes long.
    b"\x1b]0;bell terminated\x07\x1b]52;c;Y2xpcA==\x1b\\text\r\n",
];

/// Runs the seam check over a committed list, for the unprovisioned case.
fn seams_over(corpus: &[&[u8]]) {
    for (index, bytes) in corpus.iter().enumerate() {
        assert!(
            seam_verdict(bytes).is_none(),
            "micro seam corpus {index}: {}",
            seam_verdict(bytes).unwrap_or_default()
        );
    }
}

/// Whether `bytes` renders the same however it is cut up.
fn seam_verdict(bytes: &[u8]) -> Option<String> {
    let whole = fresh(COLS, ROWS, CELL_PX, &[bytes]);
    let expected = shot(whole.frame());

    for cut in CUTS {
        let mut session = session_for(COLS, ROWS, CELL_PX);
        for piece in bytes.chunks(*cut) {
            drop(feed_chunk(&mut session, piece));
        }
        session.render().expect("render");
        if let Some(report) = first_difference(&shot(session.frame()), &expected) {
            // The labels in `first_difference` read "incremental vs fresh"; here the left side is
            // the cut feed, which is the same relationship by another name.
            return Some(format!("cut into {cut}-byte reads: {report}"));
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------
// The attribute oracle, and the one part of it that has an oracle at all
// ---------------------------------------------------------------------------------------------

/// The cells whose colours can be checked against the engine without re-deriving the resolution.
///
/// `session.rs`'s fill resolves a cell's colours itself: it brightens a bold palette foreground,
/// swaps foreground and background for SGR 7, dims for SGR 2, and reads a cell-level background out
/// of `content_tag` in preference to the style's. A test that reimplemented all of that would be a
/// mirror of the code it is testing — the thing this codebase refuses to keep two of.
///
/// So the check is narrowed to where no resolution rule applies: a cell with none of bold, inverse
/// or faint set. For those, the engine's own `fg_color`/`bg_color` doors — which resolve the
/// palette and flatten the three background sources, and are NOT the doors the fill walks — say
/// what the colour is, and the frame must agree. Everything the carve-out excludes is covered by
/// the incremental-versus-fresh sweeps above, which compare every attribute of every cell without
/// needing to know what any of them mean.
fn attribute_verdict(bytes: &[u8]) -> Option<String> {
    let ours = fed(bytes);
    let frame = ours.frame();

    // A SECOND session, fed the same bytes and never rendered. `RenderState::update` consumes the
    // terminal's dirty state, so reading through one on the session under test would leave that
    // session's own render nothing to do — the read has to happen on a terminal of its own.
    let mut theirs = session_for(COLS, ROWS, CELL_PX);
    drop(feed_chunk(&mut theirs, bytes));

    let mut state = RenderState::new().expect("render state");
    let snapshot = state.update(&theirs.terminal).expect("update");
    let mut row_iter = RowIterator::new().expect("rows");
    let mut cell_iter = CellIterator::new().expect("cells");
    let mut rows = row_iter.update(&snapshot).expect("row iterator");

    let mut y = 0_u16;
    while let Some(row) = rows.next() {
        let mut cells = cell_iter.update(row).expect("cell iterator");
        let mut x = 0_u16;
        while let Some(cell) = cells.next() {
            let style = cell.style().expect("style");
            let plain = !style.bold && !style.inverse && !style.faint;
            if plain && let Some(ours) = frame.cell(x, y) {
                let fg = cell
                    .fg_color()
                    .expect("fg")
                    .map_or(frame.colors.foreground, Into::into);
                let bg = cell
                    .bg_color()
                    .expect("bg")
                    .map_or(frame.colors.background, Into::into);
                if ours.fg != fg || ours.bg != bg {
                    return Some(format!(
                        "row {y} column {x}: frame has fg {:?} bg {:?}, the engine resolves fg {fg:?} bg \
                         {bg:?}",
                        ours.fg, ours.bg
                    ));
                }
            }
            x = x.saturating_add(1);
        }
        y = y.saturating_add(1);
    }
    None
}

#[test]
fn an_unstyled_cell_resolves_to_the_colour_the_engine_resolves() {
    for (name, bytes) in super::MICRO_CORPUS {
        assert!(
            attribute_verdict(bytes).is_none(),
            "{name}: {}",
            attribute_verdict(bytes).unwrap_or_default()
        );
    }

    // A palette index and a truecolor run, spelled out, so the check is known to be looking at
    // something other than the default colours. Without this the sweep above could pass on a
    // corpus that happens to be entirely unstyled.
    let coloured = b"\x1b[H\x1b[2J\x1b[38;5;208m\x1b[48;5;17mpalette\x1b[0m \
                     \x1b[38;2;12;250;120m\x1b[48;2;40;0;70mtruecolor\x1b[0m\r\n";
    assert!(
        attribute_verdict(coloured).is_none(),
        "{}",
        attribute_verdict(coloured).unwrap_or_default()
    );

    let session = fed(coloured);
    let cell = session.frame().cell(0, 0).expect("a cell at the origin");
    assert_ne!(
        cell.fg,
        session.frame().colors.foreground,
        "the coloured probe resolved to the default foreground, so it proves nothing"
    );
}
