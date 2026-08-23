//! The two byte streams that leave this repo for something else — the scrcpy control channel and
//! the agent wait scan.
//!
//! Ported from `scripts/check-supervisor.sh`. Both are read by code nobody here maintains, so a
//! second writer is a wire drift with no test on the other side of it.

use crate::claim::{Claim, View, check_all};
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
/// overlap window and the accumulator's cap are the crate's now — a second copy of any of them in
/// Swift is two implementations of an incremental scan, which is how the strip and the holdback
/// drifted before. `ANSIStripper` is NOT banned here: the read/output verbs in the same file strip
/// a finished string through the same door, which is the one implementation, not a second one.
#[must_use]
pub fn wait_stream_scanned_once_off(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskHost/AgentControlListener.swift"],
            pattern: r"NSRegularExpression|maxCarryBytes|overlapWindow",
            view: View::Code,
            message: "{files} scans the wait stream in Swift again — slopdesk-rowscan::waituntil owns the \
                      scan",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskHost/AgentControlListener.swift",
            names: &[
                "slopdesk_wait_scan_new",
                "slopdesk_wait_scan_ingest",
                "slopdesk_wait_scan_free",
            ],
            message: "Sources/SlopDeskHost/AgentControlListener.swift no longer asks {entry} — the wait \
                      scan is one implementation",
        },
        Claim::Matches {
            path: "rust/slopdesk-rowscan/Cargo.toml",
            pattern: r"^slopdesk-sanitize = ",
            view: View::Code,
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
                "Sources/SlopDeskHost/AgentControlListener.swift",
                "slopdesk_wait_scan_new\nslopdesk_wait_scan_ingest\nslopdesk_wait_scan_free\nkept so the \
                 ban has a haystack\n",
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

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskHost/AgentControlListener.swift", "");
        assert!(!super::wait_stream_scanned_once_off(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_wait_stream_scanned_once_off(&fixture);
        fixture.append(
            "Sources/SlopDeskHost/AgentControlListener.swift",
            "NSRegularExpression\n",
        );
        assert!(!super::wait_stream_scanned_once_off(&fixture.tree()).is_clean());
    }
}
