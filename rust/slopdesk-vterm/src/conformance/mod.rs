//! The engine's own picture of a screen, against the one this crate builds.
//!
//! `docs/68` §4 splits the terminal in two: `libghostty-vt` parses every byte, and everything
//! downstream of the grid is ours. That split makes one class of bug invisible to every other test
//! in the tree. Parser conformance is DEFINITIONAL — the parser is ghostty's, at a pinned commit,
//! so "does it handle `CSI 3 J`" is not a question this repo can answer wrongly. What it can answer
//! wrongly is the READ: [`crate::session::VtSession::render`] walks `RenderState` → `RowIterator` →
//! `CellIterator` and assembles a [`Frame`], and a mistake there — a dropped wide-cell tail, a row
//! off by one after a scroll, a grapheme split across two cells — produces a frame that is
//! internally consistent, passes every hand-built unit test, and does not say what the terminal
//! says.
//!
//! So the reference is the engine's OWN renderer of the same state. `libghostty_vt::fmt::Formatter`
//! over a terminal with no selection formats the entire active screen, and it reaches the grid by a
//! different road than the render path does — ghostty's `Screen` rather than its `RenderState`. Two
//! independent readings of one terminal, compared byte for byte. That is what "renders the same as
//! ghostty" can be made to MEAN without a display, a font or a GPU, and it is the strongest form
//! available: the oracle is not a recording of ghostty's behaviour that can go stale, it is ghostty
//! deciding again, in process, at the pin the tree already holds.
//!
//! ## What this does NOT claim
//!
//! **Not pixel identity.** `docs/68` §2 deleted ghostty's renderer on purpose — blocks, padding and
//! variable row heights are the product, and a screenshot diff against ghostty would fail by
//! design. The claim here is one layer up: given the same bytes, the CONTENT of the grid this repo
//! draws is the content ghostty would draw. Where those pixels then land is
//! `slopdesk-termrender`'s, and its own tests pin it.
//!
//! **Not a second parser.** `docs/17:59` rejected a shadow VT parser kept beside the engine. There
//! is one engine here and one parse; the oracle is a second QUESTION asked of it.
//!
//! ## The corpus
//!
//! ghostty ships its fuzzers' corpora, and `stream-cmin` is the minimised set for the terminal
//! stream handler — a few thousand inputs upstream's own fuzzing reduced to the distinct paths
//! through the state machine. It arrives with the source tree `GHOSTTY_SOURCE_DIR` already points
//! at (`ThirdParty/tools/tools.lock`'s `ghostty` record, materialised by `just provision`), so the
//! corpus costs this repo no bytes and no pin of its own: it is whatever the engine at the pin was
//! fuzzed against, which is exactly the input set worth agreeing on.
//!
//! ## The half that is not here
//!
//! Everything below feeds a terminal once and draws it once. [`dynamic`] is the other half: a frame
//! that keeps changing, the pty read boundaries a real program produced, and the keystrokes typed
//! at it. Read its header before adding anything here — a bug that needs a second frame belongs
//! there and would pass quietly in this file.
//!
//! Nothing is committed from it. The oracle is computed beside the answer on every run, so there is
//! no golden file to re-bless when the engine pin moves — a bump changes both sides at once, and
//! the test still asks the only question it ever asked. [`MICRO_CORPUS`] is the committed half, and
//! it exists for the case the provisioned tree is absent: the shapes a terminal in THIS product
//! actually carries, written out so the agreement is still checked on a bare checkout.

#![cfg(test)]
#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

mod dynamic;

use std::fs;
use std::path::PathBuf;

use libghostty_vt::fmt::{Format, Formatter, FormatterOptions};

use crate::session::VtSession;

/// The grid the conformance sweep runs at.
///
/// Not 80×24. A fuzz input is minimised against no particular geometry, and the interesting
/// disagreements are at the edges the common size hides: a wide cell in the last column, a
/// scrolling region that does not start at row 1, a soft wrap. An odd width and an odd height make
/// an off-by-one in either axis land on a different row rather than cancelling out.
const COLS: u16 = 81;
/// See [`COLS`].
const ROWS: u16 = 25;

/// A cell's device-pixel size. Irrelevant to the grid, required by the constructor.
const CELL_PX: (u32, u32) = (8, 16);

/// The shapes a slopdesk pane actually carries, committed so a bare checkout still checks
/// agreement.
///
/// Each is a `(name, bytes)` pair and each was chosen because it exercises a different part of the
/// read, not because it exercises a different part of the PARSER — the parser is not what this
/// file doubts.
const MICRO_CORPUS: &[(&str, &[u8])] = &[
    ("plain-lines", b"hello world\r\nsecond line\r\nthird\r\n"),
    (
        "sgr-build-log",
        b"\x1b[38;5;33m\xe2\x96\x8e\x1b[0m compiling \x1b[1mslopdesk-vterm\x1b[0m v0.1.0\r\n\
          \x1b[38;5;40m\xe2\x96\x8e\x1b[0m    Finished \x1b[32mrelease\x1b[0m in 12.4s\r\n",
    ),
    (
        "truecolor-and-underlines",
        b"\x1b[38;2;255;128;0morange\x1b[0m \x1b[4mplain\x1b[0m \x1b[4:3m\x1b[58;5;9mcurly\x1b[0m\r\n",
    ),
    (
        "cjk-and-telex",
        "\u{65e5}\u{672c}\u{8a9e}\u{30c6}\u{30ad}\u{30b9}\u{30c8} ti\u{1ebf}ng Vi\u{1ec7}t c\u{f3} d\u{ea}\u{301}u \u{1f389}\r\n"
            .as_bytes(),
    ),
    (
        "wide-cell-at-the-right-edge",
        // 80 single-width cells then a double-width one, so the wide cell cannot fit and the engine
        // has to wrap it. The tail half is the cell a naive read duplicates.
        b"\x1b[H\x1b[2Jaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xe6\xbc\xa2\r\n",
    ),
    (
        "soft-wrap-then-scroll",
        // A line longer than the grid, repeated past the bottom, so the viewport is a window onto a
        // screen that has scrolled.
        b"\x1b[H\x1b[2J0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n\
          0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n\
          0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n\
          0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n\
          0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n\
          0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n\
          0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\r\n",
    ),
    (
        "scrolling-region",
        b"\x1b[H\x1b[2J\x1b[5;20r\x1b[10;1Hinside the region\r\n\x1b[1;1Habove it\r\n",
    ),
    (
        "erase-in-display",
        b"\x1b[H\x1b[2Jrow one\r\nrow two\r\nrow three\r\n\x1b[2;1H\x1b[Jgone below\r\n",
    ),
    (
        "tabs-and-cursor-moves",
        b"\x1b[H\x1b[2Jone\tttwo\tthree\r\n\x1b[3;40Hfar right\x1b[1;1Hback\r\n",
    ),
    (
        "alt-screen-round-trip",
        b"before\r\n\x1b[?1049h\x1b[H\x1b[2Jinside the alt screen\r\n\x1b[?1049lafter\r\n",
    ),
    (
        "osc-8-hyperlink",
        b"see \x1b]8;;https://example.invalid/a\x1b\\the link\x1b]8;;\x1b\\ here\r\n",
    ),
    (
        "reverse-video-and-blink",
        b"\x1b[7mreverse\x1b[0m \x1b[5mblink\x1b[0m \x1b[2mfaint\x1b[0m \x1b[3mitalic\x1b[0m\r\n",
    ),
    (
        "combining-marks-alone",
        "e\u{301}a\u{300}o\u{302}u\u{303} base+mark clusters\r\n".as_bytes(),
    ),
    (
        "cursor-parked-mid-row",
        b"\x1b[H\x1b[2Jabcdefghij\x1b[1;5H",
    ),
    (
        "erase-character-and-repeat",
        b"\x1b[H\x1b[2Jabcdefghij\x1b[1;3H\x1b[4X\x1b[2;1Hx\x1b[b\x1b[b\r\n",
    ),
    (
        "spinner-redrawn-in-place",
        // The shape every modern TUI opens with: one row rewritten from column 1 over and over,
        // never scrolling. A read that caches a row and misses the rewrite shows the first frame
        // forever, and only a repeated redraw can catch that.
        b"\x1b[H\x1b[2J\xe2\xa0\x8b building\r\xe2\xa0\x99 building\r\xe2\xa0\xb9 building\r\
          \xe2\xa0\xb8 building\r\xe2\xa0\xbc building\r\xe2\xa0\xb4 building\r",
    ),
    (
        "progress-bar-overwritten",
        // Same row, growing run, and the tail of the previous frame has to be erased rather than
        // left behind — the classic off-by-one a renderer that only paints what changed gets wrong.
        b"\x1b[H\x1b[2J\x1b[38;2;80;200;120m\xe2\x96\x88\xe2\x96\x88\x1b[0m\xe2\x96\x91\xe2\x96\x91\xe2\x96\x91  10%\r\
          \x1b[38;2;80;200;120m\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\x1b[0m\xe2\x96\x91  80%\r",
    ),
    (
        "cursor-hidden-and-shown",
        // DECTCEM cycled around a repaint, which is what a double-buffered TUI does every frame.
        b"\x1b[H\x1b[2J\x1b[?25lframe one\r\x1b[?25h\x1b[?25lframe two\r\x1b[?25h",
    ),
    (
        "region-scrolled-repeatedly",
        // A scrolling region animated in place: the rows inside move, the rows outside must not.
        b"\x1b[H\x1b[2Jheader\r\n\x1b[3;10r\x1b[3;1Ha\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\ni\r\nj\r\nk\r\n",
    ),
    (
        "synchronized-update",
        // DEC 2026. A frame drawn between the begin and the end is a frame the user was never meant
        // to see, and the read has to end up at the same place either way.
        b"\x1b[H\x1b[2J\x1b[?2026hbuilt in one shot\r\n\x1b[?2026l",
    ),
    (
        "csi-6n-and-da",
        // Both compose a pty reply. The screen must be unchanged by them, and the reply must be
        // drained rather than left in the sink.
        b"before\x1b[6n\x1b[c after\r\n",
    ),
];

/// The engine's own rendering of the whole active screen.
///
/// No selection, so the formatter takes the screen. `unwrap` and `trim` are BOTH off, because a
/// disagreement about padding is exactly the class of bug this exists to catch — turning either on
/// would let a frame that pads a short line differently from the engine pass.
fn engine_screen(session: &VtSession, format: Format) -> String {
    let options = FormatterOptions::new()
        .with_format(format)
        .with_unwrap(false)
        .with_trim(false);
    let mut formatter = Formatter::new(&session.terminal, options).expect("formatter");
    let bytes = formatter.format_alloc(None).expect("format");
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The same picture, rebuilt from the [`Frame`](crate::frame::Frame) the render path filled.
///
/// One row per line, trailing blanks kept, in the order the renderer would draw them.
fn frame_screen(session: &VtSession) -> String {
    let frame = session.frame();
    (0..frame.row_count())
        .map(|y| frame.row_text(y))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A session fed `bytes`, rendered, with both push queues drained the way a real caller must.
///
/// The drain is not hygiene. `docs/68` §4.1: a caller that feeds without draining is a caller whose
/// far side hangs, and a fuzz corpus is full of `CSI 6n` and OSC 52. Draining here means the sweep
/// exercises the same door order the shipped surface uses.
fn fed(bytes: &[u8]) -> VtSession {
    let mut session = VtSession::new(COLS, ROWS, CELL_PX.0, CELL_PX.1).expect("session");
    // History bounded as far down as the engine will take it, so a sweep over thousands of inputs
    // is not also a memory test. It does NOT reach zero — `scrollback_is_a_floor_not_a_switch`
    // below pins that it does not — so the screen stays taller than the viewport and `compare`
    // aligns the two at the BOTTOM rather than assuming they are the same rows.
    session.set_scrollback_rows(0).expect("scrollback");
    session.feed(bytes);
    let mut replies = Vec::new();
    session.take_pty_replies(&mut replies);
    drop(session.take_clipboard_writes());
    session.render().expect("render");
    session
}

/// The two readings reduced to the one thing they both claim: the viewport's rows, as text.
///
/// Padding on two axes, because the formatter stops where the screen's content stops and a frame
/// always has every row and every column. Which rows the two sides are talking about is
/// [`compare`]'s problem, not this one's:
///
/// * **Trailing blank rows.** A screen with three written rows formats as three lines.
/// * **Right-edge padding.** A cell nothing wrote and a cell holding a space are the same picture.
///
/// A blank row BETWEEN two written rows is content and survives both.
fn viewport_rows(text: &str) -> Vec<String> {
    let mut rows: Vec<String> = text.split('\n').map(|line| line.trim_end().to_owned()).collect();
    while rows.last().is_some_and(String::is_empty) {
        rows.pop();
    }
    rows
}

/// What one row comparison can end as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RowVerdict {
    /// Every column spells the same character on both sides.
    Same,
    /// Every column either agrees or is one the frame deliberately blanks. See [`row_verdict`].
    BlankedHere,
    /// A column the two readings genuinely disagree about, and its index.
    Differs(usize),
}

/// One row of the frame against one row of the engine's dump.
///
/// Not equality, and the asymmetry is the point. **The engine's text dump is a COPY, the frame is a
/// PICTURE, and SGR 8 is where those two readings are supposed to part.** A concealed cell must not
/// draw its character — that is the whole of what the attribute means, and `session.rs`'s fill
/// implements it by writing no text at all (`frame.rs`'s [`CellFlags`](crate::frame::CellFlags)
/// folds it into "contributes no glyph"). The formatter has no such job: text a user copies out of
/// a concealed run is text they asked for. So the frame showing a blank where the dump shows a
/// character is CORRECT, and it is the only concession made here.
///
/// Every other direction stays strict, including the one that matters most: the frame may never
/// show a character the engine does not have there. Inventing content, shifting a row, splitting a
/// grapheme, dropping a wide cell's tail and losing a column all land in [`RowVerdict::Differs`].
///
/// Both rows are padded with blanks to the longer length first, so a row whose concealed run ran to
/// the right edge — trimmed away on our side by [`viewport_rows`] — takes the same concession as a
/// concealed run in the middle rather than a different one.
fn row_verdict(ours: &str, theirs: &str) -> RowVerdict {
    let width = ours.chars().count().max(theirs.chars().count());
    let mut ours = ours.chars().chain(core::iter::repeat(' '));
    let mut theirs = theirs.chars().chain(core::iter::repeat(' '));
    let mut blanked = false;

    for column in 0..width {
        match (ours.next(), theirs.next()) {
            (Some(a), Some(b)) if a == b => (),
            // The concession, and only in this direction.
            (Some(' '), Some(_)) => blanked = true,
            _ => return RowVerdict::Differs(column),
        }
    }

    if blanked {
        RowVerdict::BlankedHere
    } else {
        RowVerdict::Same
    }
}

/// The first row the two readings spell differently, and whether any row took the blank concession.
///
/// Aligned at the BOTTOM. Both sides stop at the same last non-blank row — [`viewport_rows`] trims
/// the frame's, and the formatter never writes past the screen's — so the tails are the rows they
/// hold in common. The frame's is the shorter one whenever the screen kept history: the engine
/// prepends it, the viewport does not have it, and a row that has scrolled off is not a row this
/// file can ask about. Comparing what they both hold is the whole of what is comparable.
fn compare(session: &VtSession) -> (Option<String>, bool) {
    let ours = viewport_rows(&frame_screen(session));
    let theirs = viewport_rows(&engine_screen(session, Format::Plain));

    let shared = ours.len().min(theirs.len());
    let ours = ours.get(ours.len() - shared..).unwrap_or_default();
    let theirs = theirs.get(theirs.len() - shared..).unwrap_or_default();

    let blank = String::new();
    let mut blanked = false;
    for y in 0..shared {
        let ours = ours.get(y).unwrap_or(&blank);
        let theirs = theirs.get(y).unwrap_or(&blank);
        match row_verdict(ours, theirs) {
            RowVerdict::Same => (),
            RowVerdict::BlankedHere => blanked = true,
            RowVerdict::Differs(column) => {
                return (
                    Some(format!(
                        "row {y} of {shared} shared, column {column}:\n    ours:   {ours:?}\n    engine: \
                         {theirs:?}"
                    )),
                    blanked,
                );
            },
        }
    }
    (None, blanked)
}

#[test]
fn the_committed_corpus_reads_the_same_as_the_engine() {
    for (name, bytes) in MICRO_CORPUS {
        let (verdict, blanked) = compare(&fed(bytes));
        assert!(verdict.is_none(), "{name}: {}", verdict.unwrap_or_default());
        // None of these conceal, so none of them may need the concession. Without this the
        // committed half could drift into passing BECAUSE of the forgiveness rather than despite
        // it, and the one case that is allowed to use it is pinned separately below.
        assert!(
            !blanked,
            "{name}: took the concealed-cell concession and has nothing concealed"
        );
    }
}

#[test]
fn a_concealed_run_is_the_one_thing_the_frame_may_blank() {
    // SGR 8 over the middle word. The engine's dump is a copy and reveals it; the frame is a
    // picture and must not. Both halves are asserted, so this stays a pin on the DIFFERENCE rather
    // than a licence for `row_verdict` to forgive anything else.
    let session = fed(b"\x1b[H\x1b[2Jvisible \x1b[8mhidden\x1b[28m visible\r\n");

    let ours = viewport_rows(&frame_screen(&session));
    assert_eq!(ours.first().map(String::as_str), Some("visible        visible"));

    let theirs = viewport_rows(&engine_screen(&session, Format::Plain));
    assert_eq!(theirs.first().map(String::as_str), Some("visible hidden visible"));

    let (verdict, blanked) = compare(&session);
    assert!(verdict.is_none(), "{}", verdict.unwrap_or_default());
    assert!(
        blanked,
        "the concession exists for exactly this and was not taken"
    );
}

/// ghostty's minimised stream-fuzzer corpus, or `None` when the tree is not provisioned.
///
/// Derived from `GHOSTTY_SOURCE_DIR` rather than from the pin, so this never becomes a second place
/// the engine commit is written — `rust/.cargo/config.toml` exports it and
/// `slopdesk-invariants`' `engine-source-read-at-its-pin` holds it against `tools.lock`.
fn stream_corpus() -> Option<PathBuf> {
    let root = PathBuf::from(std::env::var_os("GHOSTTY_SOURCE_DIR")?);
    let corpus = root.join("test/fuzz-libghostty/corpus/stream-cmin");
    corpus.is_dir().then_some(corpus)
}

#[test]
fn the_engine_corpus_reads_the_same_as_the_engine() {
    let Some(corpus) = stream_corpus() else {
        // Not a silent pass: an unprovisioned tree still checks MICRO_CORPUS above, and
        // `just provision` is what turns this one on.
        return;
    };

    // Fanned out across the machine. Each worker builds its own sessions and never shares one —
    // every `libghostty-vt` handle is confined to the thread that made it (`frame.rs`'s header) —
    // so the split is by FILE and nothing crosses. Serial this sweep is half a minute, which is
    // half a minute added to the inner loop every time a frame field moves.
    let files: Vec<PathBuf> = fs::read_dir(&corpus)
        .expect("read corpus")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();

    let workers = std::thread::available_parallelism().map_or(4, std::num::NonZeroUsize::get);
    let per = files.len().div_ceil(workers.max(1)).max(1);

    let (checked, blanked, mut failures) = std::thread::scope(|scope| {
        // The collect is what makes this parallel: `spawn` must run for every chunk before the
        // first `join`, and a lazy iterator would start each worker only as the previous one was
        // waited on — the same sweep, serial, through a thread apiece.
        #[expect(clippy::needless_collect, reason = "collecting is what starts the workers")]
        let handles: Vec<_> = files
            .chunks(per)
            .map(|chunk| {
                scope.spawn(move || {
                    let mut checked = 0_usize;
                    let mut blanked = 0_usize;
                    let mut failures: Vec<String> = Vec::new();
                    for path in chunk {
                        let Ok(bytes) = fs::read(path) else { continue };
                        checked += 1;
                        let (verdict, took_concession) = compare(&fed(&bytes));
                        blanked += usize::from(took_concession);
                        if let Some(where_) = verdict {
                            let name = path
                                .file_name()
                                .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
                            failures.push(format!("  {name}: {where_}"));
                        }
                    }
                    (checked, blanked, failures)
                })
            })
            .collect();

        handles
            .into_iter()
            .fold((0_usize, 0_usize, Vec::new()), |mut acc, handle| {
                let (checked, blanked, failures) = handle.join().expect("worker");
                acc.0 += checked;
                acc.1 += blanked;
                acc.2.extend(failures);
                acc
            })
    });

    assert!(
        checked > 100,
        "the corpus at {} held only {checked} inputs",
        corpus.display()
    );

    let total = failures.len();
    // Capped, because an assembly bug that reaches this sweep reaches thousands of inputs at once
    // and the first few say the same thing the rest would.
    failures.truncate(8);
    assert!(
        failures.is_empty(),
        "{total} of {checked} corpus inputs disagree with the engine:\n{}",
        failures.join("\n")
    );

    // The concession in `row_verdict` is the one place this sweep can be talked out of a failure,
    // so it is bounded rather than trusted. SGR 8 is rare in a corpus minimised for parser
    // coverage; a read that started blanking cells generally would show up here as a share nothing
    // about conceal explains, and would fail before the comparison had a chance to forgive it.
    assert!(
        blanked * 20 < checked,
        "{blanked} of {checked} inputs needed the concealed-cell concession — that is no longer a long \
         tail, and `row_verdict` is forgiving something other than SGR 8"
    );
}

#[test]
fn scrollback_is_a_floor_not_a_switch() {
    // The one engine behaviour `compare`'s bottom alignment stands on, pinned rather than assumed.
    // `set_scrollback_rows(0)` reads as "keep no history at all" and the engine does not honour it
    // that far — it keeps a page. So the formatter's active screen stays TALLER than the viewport a
    // frame holds, and comparing the two from the top would line row 0 of the viewport up against a
    // row that scrolled off. Should the engine ever take the zero literally this fails, and the
    // alignment can be simplified rather than silently becoming a no-op nobody re-checked.
    let mut bytes = Vec::new();
    for line in 0..(ROWS * 2) {
        bytes.extend_from_slice(format!("line {line}\r\n").as_bytes());
    }
    let session = fed(&bytes);

    assert!(
        session.scrollback_rows().unwrap_or(0) > 0,
        "the engine now honours a zero scrollback — `compare` can align from the top"
    );
    assert!(
        engine_screen(&session, Format::Plain).split('\n').count() > usize::from(ROWS),
        "the active screen is no taller than the viewport, so there is nothing to align away"
    );
}
