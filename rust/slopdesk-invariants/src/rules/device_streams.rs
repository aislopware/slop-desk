//! The two byte streams that leave this repo for something else — the scrcpy control channel and
//! the agent wait scan.
//!
//! Ported from the deleted `check-supervisor.sh`. Both are read by code nobody here maintains, so a
//! second writer is a wire drift with no test on the other side of it.

use crate::claim::{Claim, RUST, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// And ONE writer for the scrcpy control channel
///
/// scrcpy publishes no wire specification — its own documentation says the protocol is defined by
/// the unit tests on both sides — so every layout was transcribed by hand, and the Swift copy laid
/// each field out with a local `appendBigEndian`: the same idiom already banned for the screend
/// frame.
#[must_use]
pub fn one_writer_for_scrcpy_control(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift"],
            pattern: r"mutating func appendBigEndian|appendPosition|truncatingIfNeeded:|func truncateUTF8|FixedPoint\(",
            view: View::Code,
            message: "{files} lays out a scrcpy control message in Swift again — slopdesk-androidd owns \
                      every layout",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift",
            needle: "slopdesk_android_control_encode",
            message: "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift no longer asks \
                      slopdesk_android_control_encode — one implementation",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-androidd/src/control.rs"],
            pattern: r"GET_CLIPBOARD|Uhid",
            view: View::Code,
            message: "{files} names a reply-bearing control type — a device reply lands inside the video \
                      stream",
        },
        Claim::Names {
            path: "rust/slopdesk-androidd/src/control.rs",
            needle: "0_u64.to_be_bytes()",
            message: "rust/slopdesk-androidd/src/control.rs: SET_CLIPBOARD's sequence stopped being the \
                      constant zero",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift",
            needle: "enum AndroidBodilessMessage: UInt8",
            message: "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift: the bodiless \
                      messages stopped being a closed enum",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift"],
            pattern: r", nil, 0\)",
            view: View::Code,
            message: "{files} probes the control encoder with a null output again — docs/55 §4 says a short \
                      buffer writes NOTHING, so guess and retry",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift",
            needle: "private static let firstGuessBytes",
            message: "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift: the first-guess \
                      buffer stopped being a named constant",
        },
    ];
    check_all(tree, &claims)
}

/// `wait --until` runs an agent's pattern on the PTY read loop, so it may not backtrack
///
/// The third and worst of the untrusted-pattern sites: the pattern is an agent's, the text is
/// whatever holds the far side of the PTY, and the match runs on the thread every pane's bytes come
/// through. A pathological match there stalls the whole host, not one window. The carry, the
/// overlap window and the accumulator's cap are the crate's now — a second copy of any of them
/// beside the listener is two implementations of an incremental scan, which is how the strip and
/// the holdback drifted before. The plain-text strip is NOT banned here: the read/output verbs in
/// the same file strip a finished string through the same crate, which is the one implementation,
/// not a second one.
///
/// The listener is `rust/slopdesk-hostserver`'s control dispatch since `docs/60` F.9, so the three
/// doors it used to call are one `use` the compiler checks. What no import states is that the
/// scanner is still the CRATE's — a hand-rolled carry beside it would compile.
#[must_use]
pub fn wait_stream_scanned_once_off(tree: &Tree) -> Report {
    /// hostd's control dispatch, which holds the one live `Scanner`.
    const CONTROL: &str = "rust/slopdesk-hostserver/src/control.rs";

    let claims = [
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r"max_carry_bytes|overlap_window|Regex::new",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} scans the wait stream itself again — slopdesk-rowscan::waituntil owns the \
                      carry, the overlap and the cap, and the match runs on every pane's read loop",
        },
        Claim::Matches {
            path: CONTROL,
            pattern: r"slopdesk_rowscan::waituntil::Scanner::new\(",
            view: View::Statements,
            message: "rust/slopdesk-hostserver/src/control.rs no longer opens the crate's scanner — the \
                      wait scan is one implementation",
        },
        Claim::Matches {
            path: CONTROL,
            pattern: r"slopdesk_rowscan::waituntil::WAIT_BUFFER_CAP",
            view: View::Statements,
            message: "rust/slopdesk-hostserver/src/control.rs picked its own accumulator cap — the cap is \
                      the crate's, or a pathological pattern grows the buffer on the read loop",
        },
        Claim::Matches {
            path: "rust/slopdesk-rowscan/Cargo.toml",
            pattern: r"^slopdesk-sanitize = ",
            view: View::Statements,
            message: "rust/slopdesk-rowscan dropped slopdesk-sanitize — the wait scan would need its own \
                      stripper",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_writer_for_scrcpy_control(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift",
                "slopdesk_android_control_encode\nenum AndroidBodilessMessage: UInt8\nprivate static let \
                 firstGuessBytes\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-androidd/src/control.rs",
                "0_u64.to_be_bytes()\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_writer_for_scrcpy_control_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-writer-for-scrcpy-control");
        write_one_writer_for_scrcpy_control(&fixture);
        assert!(super::one_writer_for_scrcpy_control(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift",
            "",
        );
        assert!(!super::one_writer_for_scrcpy_control(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_writer_for_scrcpy_control(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Android/AndroidControlMessage.swift",
            "mutating func appendBigEndian\n",
        );
        assert!(!super::one_writer_for_scrcpy_control(&fixture.tree()).is_clean());
    }

    fn write_wait_stream_scanned_once_off(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-hostserver/src/control.rs",
                "let scanner = slopdesk_rowscan::waituntil::Scanner::new(\n    pattern,\n    \
                 slopdesk_rowscan::waituntil::WAIT_BUFFER_CAP,\n);\n",
            )
            .write(
                "rust/slopdesk-rowscan/Cargo.toml",
                "slopdesk-sanitize = \nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn wait_stream_scanned_once_off_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("wait-stream-scanned-once-off");
        write_wait_stream_scanned_once_off(&fixture);
        assert!(super::wait_stream_scanned_once_off(&fixture.tree()).is_clean());

        // The caller stopped asking — an implementation grew back where the call used to be.
        fixture.write("rust/slopdesk-hostserver/src/control.rs", "");
        assert!(!super::wait_stream_scanned_once_off(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled — anywhere in the host, not only in
        // the file that holds the call.
        write_wait_stream_scanned_once_off(&fixture);
        fixture.write(
            "rust/slopdesk-hostd/src/wait.rs",
            "let re = Regex::new(pattern)?;\n",
        );
        assert!(!super::wait_stream_scanned_once_off(&fixture.tree()).is_clean());
    }
}
