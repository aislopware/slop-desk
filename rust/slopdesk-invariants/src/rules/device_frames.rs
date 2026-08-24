//! The two framings a device panel decodes — screend's request frame and the scrcpy video
//! stream.
//!
//! Ported from the deleted `check-supervisor.sh`. Both are byte layouts with a far side that does
//! not live here, so a second speller produces a frame the other end drops without a word, or an
//! access unit that decodes to green.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// And ONE encoder for the screend frame
///
/// The wire left screend for its own crate, for `slopdesk-sanitize`'s reason: two callers, one
/// implementation. hostd is the other caller, and while the layouts lived inside the daemon the
/// only way to reach them was to BE the daemon — so hostd hand-wrote a second copy in Swift.
///
/// `docs/DECISIONS.md` recorded in stage 17 that each protocol's client end moves into Rust, so the
/// round trip becomes a TEST rather than an agreement two files keep by review. dropd's Swift
/// original was deleted in that change; screend's was not, and `ScreenProtocol.swift` went on
/// hand-writing the same frame for a whole stage afterwards. The two had already diverged on an
/// over-long detect label — Swift threw where Rust truncated.
#[must_use]
pub fn one_encoder_for_screend_frame(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskScreen/ScreenProtocol.swift"],
            pattern: r"func appendBigEndian|truncatingIfNeeded: value|UInt16\(clamping: paneBytes",
            view: View::Code,
            message: "{files} lays out the screend frame in Swift again — slopdesk-screenwire owns every \
                      layout",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskScreen/ScreenProtocol.swift",
            names: &[
                "slopdesk_screen_encode_request",
                "slopdesk_screen_encode_detect_payload",
                "slopdesk_screen_reply_status",
            ],
            message: "Sources/SlopDeskScreen/ScreenProtocol.swift no longer asks {entry} — the screend wire \
                      is one implementation",
        },
        Claim::Mentions {
            path: "rust/slopdesk-screenwire/src/lib.rs",
            names: &[
                "pub fn encode_request",
                "pub fn decode_request",
                "pub fn encode_reply",
                "pub fn decode_reply",
            ],
            message: "rust/slopdesk-screenwire/src/lib.rs lost '{entry}' — both ends live together so the \
                      round trip is a test",
        },
    ];
    check_all(tree, &claims)
}

/// The scrcpy stream is reassembled ONCE, and not in Swift
///
/// The bridge relays the device's stream verbatim, so nothing in Rust had ever read it and the
/// whole decoder sat in Swift — a stateful reassembler over bytes a DEVICE wrote, on the per-frame
/// path, whose own comment admitted it copied the buffer remainder on every message. Stage 17's
/// rule puts a protocol's client end in the crate that owns the protocol, and `slopdesk-androidd`
/// owns scrcpy's dialect. Nothing here may grow a second reader of that wire.
#[must_use]
pub fn one_reader_for_scrcpy_stream(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift"],
            pattern: r"func readUInt32|private mutating func take|maximumPacketSize|headerSize = |sessionFlag|keyFrameFlag",
            view: View::Code,
            message: "{files} frames the scrcpy stream in Swift again — slopdesk-androidd owns the framing",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift"],
            pattern: r"codeLength|starts\.append|first & 0x1F|first >> 1",
            view: View::Code,
            message: "{files} walks Annex-B in Swift again — slopdesk_video::annexb owns both start-code \
                      lengths",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            names: &[
                "slopdesk_android_stream_new",
                "slopdesk_android_stream_free",
                "slopdesk_android_stream_append",
                "slopdesk_android_stream_next",
                "slopdesk_android_stream_decodable_codec",
                "slopdesk_annexb_split",
                "slopdesk_annexb_parameter_sets",
                "slopdesk_annexb_to_avcc",
            ],
            message: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift no longer asks \
                      {entry} — the scrcpy stream is one implementation",
        },
        Claim::Names {
            path: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            needle: "final class AndroidStreamParser",
            message: "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift: the parser stopped \
                      being a class — a copied handle is a double free",
        },
        Claim::Mentions {
            path: "rust/slopdesk-video/src/annexb.rs",
            names: &[
                "pub fn split_ranges",
                "pub fn to_avcc",
                "pub fn h264_parameter_sets",
                "pub fn h265_parameter_sets",
            ],
            message: "rust/slopdesk-video/src/annexb.rs lost '{entry}' — the Annex-B walk is one \
                      implementation",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_encoder_for_screend_frame(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskScreen/ScreenProtocol.swift",
                "slopdesk_screen_encode_request\nslopdesk_screen_encode_detect_payload\\
                 nslopdesk_screen_reply_status\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-screenwire/src/lib.rs",
                "pub fn encode_request\npub fn decode_request\npub fn encode_reply\npub fn \
                 decode_reply\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_encoder_for_screend_frame_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-encoder-for-screend-frame");
        write_one_encoder_for_screend_frame(&fixture);
        assert!(super::one_encoder_for_screend_frame(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskScreen/ScreenProtocol.swift", "");
        assert!(!super::one_encoder_for_screend_frame(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_encoder_for_screend_frame(&fixture);
        fixture.append(
            "Sources/SlopDeskScreen/ScreenProtocol.swift",
            "func appendBigEndian\n",
        );
        assert!(!super::one_encoder_for_screend_frame(&fixture.tree()).is_clean());
    }

    fn write_one_reader_for_scrcpy_stream(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
                "slopdesk_android_stream_new\nslopdesk_android_stream_free\nslopdesk_android_stream_append\\
                 nslopdesk_android_stream_next\nslopdesk_android_stream_decodable_codec\\
                 nslopdesk_annexb_split\nslopdesk_annexb_parameter_sets\nslopdesk_annexb_to_avcc\nfinal \
                 class AndroidStreamParser\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-video/src/annexb.rs",
                "pub fn split_ranges\npub fn to_avcc\npub fn h264_parameter_sets\npub fn \
                 h265_parameter_sets\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_reader_for_scrcpy_stream_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-reader-for-scrcpy-stream");
        write_one_reader_for_scrcpy_stream(&fixture);
        assert!(super::one_reader_for_scrcpy_stream(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            "",
        );
        assert!(!super::one_reader_for_scrcpy_stream(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_reader_for_scrcpy_stream(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Android/AndroidStreamProtocol.swift",
            "func readUInt32\n",
        );
        assert!(!super::one_reader_for_scrcpy_stream(&fixture.tree()).is_clean());
    }
}
