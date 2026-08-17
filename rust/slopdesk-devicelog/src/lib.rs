//! The two device consoles' line grammars: a log line in, four byte ranges out.
//!
//! Both panels ask their source for the one stock format whose shape is fixed enough to colour by
//! severity without also being unreadable at a sidebar's width:
//!
//! ```text
//! 08-04 13:50:19.565 D/ActivityManager( 1234): message      <- logcat -v time
//! └ date └ time      │ └ tag           └ pid   └ the rest
//!                    └ priority
//!
//! 2026-08-04 13:50:19.565 Df Poster[76037:219b94d] message  <- log stream --style compact
//! └ date     └ time       │  └ process[pid:tid]    └ the rest
//!                         └ severity
//! ```
//!
//! `logcat -v threadtime` and `log stream`'s default style were the alternatives, and both are
//! rejected for the same reason: the pid/tid pair is noise in a column this narrow, and the TAG (or
//! the process) is what anyone actually scans for. `logcat -v brief` drops the timestamp, which is
//! the one field that makes a log worth reading after the fact.
//!
//! A line that does NOT match is kept verbatim rather than dropped. Both sources emit their own
//! banners — `--------- beginning of crash`, `getpwuid_r did not find a match for uid 501` — and a
//! swallowed banner is a console that looks like it silently lost the boundary between two runs,
//! which is precisely the line someone reading a crash is looking for.
//!
//! # Spans, not strings
//!
//! Every field is a slice of the line it came from, so [`Line`] carries byte ranges and this crate
//! allocates nothing. The Swift it replaces built four `String`s per line, over a device that
//! produces thousands of them a minute.
//!
//! # ASCII, deliberately
//!
//! The shape checks read BYTES, where the Swift read `Character`s and asked Unicode whether each
//! was a number or a letter. Both formats are ASCII by construction, and the narrowing only ever
//! moves a line towards the verbatim fallback — a row whose severity slot holds a non-ASCII
//! uppercase letter now stays whole instead of being split into a severity nobody sent.

pub mod lexer;
pub mod logcat;
pub mod unified;

use core::ops::Range;

/// How loud a row is, which is the only question a console answers at a glance.
///
/// One scale for both grammars, and a SUPERSET of each: `logcat` never yields [`Severity::Debug`]
/// and the unified log never yields [`Severity::Warning`], because neither alphabet has the bucket.
/// It is one type rather than two because the consumer is one console renderer with one set of
/// inks — the GRAMMARS are what stay apart, and they do, in two modules that share only the lexer.
///
/// Coarser than either source's own alphabet on purpose. `logcat` prints eight priority letters and
/// the unified log six type tokens; six tints answer "is anything wrong" worse than three.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
#[repr(u8)]
pub enum Severity {
    /// Uninked. Both consoles put their bulk here — `logcat`'s `D` and the unified log's `Df` are
    /// each the largest share of a busy device's output by a wide margin, so tinting them would
    /// light up most of the console and leave the errors no louder than everything else.
    #[default]
    Plain = 0,
    /// The unified log's `Db` and `A`. `logcat` never answers this.
    Debug = 1,
    /// `I` in both.
    Info = 2,
    /// `logcat`'s `W`. The unified log never answers this.
    Warning = 3,
    /// `E` in both.
    Error = 4,
    /// `F` in both, plus `logcat`'s `A` — its ASSERT, which is what a native abort prints. Same
    /// bucket, because both mean the process is going away.
    Fatal = 5,
}

/// One parsed row: a severity and three slices of the line it came from.
///
/// An unrecognised line is not an error. It answers [`Severity::Plain`], an empty `time` and
/// `name`, and a `message` covering the whole input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    /// `13:50:19.565`, or empty for a line this parse did not recognise. The DATE is dropped — a
    /// console shows the recent past, and the day is the same one in every row of it.
    pub time: Range<usize>,
    /// The `logcat` tag without its `( pid)`, or the process without its `[pid:tid]`.
    pub name: Range<usize>,
    /// Everything after the header, with only the leading gap trimmed. A log line's own alignment
    /// is information: a padded table in someone's output survives the parse.
    pub message: Range<usize>,
    /// The ink.
    pub severity: Severity,
}

impl Line {
    /// The whole line as one uninterpreted message — what a banner, a blank line, or anything the
    /// grammar declines becomes.
    #[must_use]
    pub const fn verbatim(len: usize) -> Self {
        Self {
            time: 0..0,
            name: 0..0,
            message: 0..len,
            severity: Severity::Plain,
        }
    }
}
