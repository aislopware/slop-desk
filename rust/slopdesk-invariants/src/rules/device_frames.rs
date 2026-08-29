//! The framings a device panel speaks — screend's request frame, the scrcpy video stream, the
//! simulator server's own dialect, and the virtual finger both panels plant.
//!
//! The first two were ported from the deleted `check-supervisor.sh`. Every one of them is a layout
//! or a machine whose far side does not live here, so a second speller produces a frame the other
//! end drops without a word, an access unit that decodes to green, or a gesture the device reads as
//! a system swipe.

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
        // Re-keyed in `docs/60` Batch B: `ScreenProtocol.swift` was deleted with the rest of
        // `Sources/SlopDeskScreen`, and hostd's end of this wire is `slopdesk-screenclient` now. The
        // ban survives the language change because the failure did: a client that lays the frame out
        // itself is a second implementation of a layout screend already owns, and the two agree
        // until the day they do not.
        Claim::NoneOf {
            paths: &["rust/slopdesk-screenclient/src/client.rs"],
            pattern: r"to_be_bytes\(\)|from_be_bytes|as u16\s*\)?\s*\.to_be",
            view: View::Code,
            message: "{files} lays out the screend frame by hand again — slopdesk-screenwire owns every \
                      layout",
        },
        Claim::Mentions {
            path: "rust/slopdesk-screenclient/src/client.rs",
            names: &["encode_request", "encode_detect_payload", "decode_reply"],
            message: "rust/slopdesk-screenclient/src/client.rs no longer asks {entry} — the screend wire is \
                      one implementation",
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

/// The simulator server's dialect is spoken ONCE, and not in Swift
///
/// Five faces, one crate. `baguette serve` defines this wire and this side speaks it, so there are
/// no golden vectors to pin and no version byte anyone here controls — which is exactly why a
/// second speller is undetectable until a device stops responding. Each of the five had its own
/// way to fail quietly: an avcC record walked by hand builds a format description that decodes
/// nothing, a hand-built JSON object drops a gesture the server ignores without an error, a route
/// assembled from `URLComponents` sends a request to an endpoint nobody asked for, a verb or a
/// timeout typed at a call site gives a poll a cache or an install eight seconds, and a log
/// envelope parsed here reads a `type` this build has no case for as a dead socket.
///
/// The CONTROL bans are about a table rather than a grammar, and that is the point: eleven
/// `URLSession` call sites each choosing their own verb, budget, cache policy and content type were
/// eleven chances to get one wrong in a way only a live server reports. `slopdesk_sim_control_plan`
/// answers all four at once, and the two request BODIES the panel posts — the status-bar preset the
/// server rejects whole on one bad field, and the rounded coordinate that must agree with the
/// readout beside it — come from the same crate rather than from a dictionary literal.
///
/// The ROUTE bans are the sharpest of the three. A query value assembled here escaped `&` only
/// because Foundation did it silently; the Rust set spells the four sub-delimiters out, and a
/// `URLQueryItem` back in this file is that guarantee traded for a habit.
#[must_use]
pub fn one_dialect_for_the_simulator_server(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Simulator/SimulatorWireProtocol.swift"],
            pattern: r"struct ByteReader|lengthSizeMinusOne|& 0x1F|& 0x03|spsCount|ppsCount",
            view: View::Code,
            message: "{files} walks the avcC layout in Swift again — slopdesk_devicepanel::sim_stream owns \
                      every field of it",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorWireProtocol.swift",
            names: &["slopdesk_sim_stream_kind", "slopdesk_sim_avcc_parse"],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorWireProtocol.swift no longer asks \
                      {entry} — the simulator's downstream dialect is one implementation",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Simulator/SimulatorInputEnvelope.swift"],
            pattern: r"JSONSerialization|sortedKeys|touch1-|touch2-|\[String: Any\]",
            view: View::Code,
            message: "{files} builds the input envelope in Swift again — slopdesk_devicepanel::sim_input \
                      owns the key set and the escaping",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorInputEnvelope.swift",
            names: &[
                "slopdesk_sim_input_tap",
                "slopdesk_sim_input_swipe",
                "slopdesk_sim_input_touch",
                "slopdesk_sim_input_touch2",
                "slopdesk_sim_input_button",
                "slopdesk_sim_input_key",
                "slopdesk_sim_input_text",
                "slopdesk_sim_input_copy",
                "slopdesk_sim_default_tap_duration",
            ],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorInputEnvelope.swift no longer asks \
                      {entry} — one verb, one door, so the wrong combination stays unrepresentable",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Simulator/SimulatorEndpoints.swift"],
            pattern: r"URLComponents|URLQueryItem|addingPercentEncoding|percentEncodedPath|CharacterSet",
            view: View::Code,
            message: "{files} assembles a URL in Swift again — slopdesk_devicepanel::sim_routes owns the \
                      table AND the escaping set that keeps a filename from ending its own parameter",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorEndpoints.swift",
            names: &["slopdesk_sim_route", "SlopDeskSimRoute"],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorEndpoints.swift no longer asks \
                      {entry} — every route is one table lookup a caller cannot mis-spell",
        },
    ];
    let mut claims = Vec::from(claims);
    claims.extend(the_control_table_is_not_typed_at_a_call_site());
    check_all(tree, &claims)
}

/// The HOW half of the dialect: the request table, the two bodies, and the console envelope.
///
/// Split out because the rule outgrew one function, not because it is a different claim — a table
/// read at eleven call sites and a batch parsed on the near side fail the same way, quietly and
/// only against a live server.
fn the_control_table_is_not_typed_at_a_call_site() -> Vec<Claim> {
    vec![
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Simulator/SimulatorControlClient.swift"],
            pattern: r#"JSONSerialization|"9:41"|"POST"|"DELETE"|200\.\.<|TimeInterval = [0-9]|"application/json"|"latitude""#,
            view: View::Code,
            message: "{files} types the panel's HTTP dialect at a call site again — the verb, the budget, \
                      the cache policy, the content type, the 2xx window and both request bodies are \
                      slopdesk_devicepanel::sim_control's, and a live server is the only thing that reports \
                      one of them wrong",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorControlClient.swift",
            names: &[
                "slopdesk_sim_control_plan",
                "slopdesk_sim_control_status_ok",
                "slopdesk_sim_status_bar_body",
                "slopdesk_sim_location_body",
                "slopdesk_sim_thumbnail_scale",
                "slopdesk_sim_thumbnail_quality",
            ],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorControlClient.swift no longer asks \
                      {entry} — what is left in Swift is the URLSession lifetime and nothing that decides",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskDevicePanels/Simulator/SimulatorLogMessage.swift"],
            pattern: r#"JSONSerialization|"log_started"|\[String: Any\]"#,
            view: View::Code,
            message: "{files} parses the console envelope in Swift again — slopdesk_devicepanel::sim_log \
                      owns it, so a `type` a newer server adds costs that MESSAGE and not the socket",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskDevicePanels/Simulator/SimulatorLogMessage.swift",
            names: &["slopdesk_sim_log_message"],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorLogMessage.swift no longer asks \
                      {entry} — the batch envelope has one decoder",
        },
        Claim::Mentions {
            path: "rust/slopdesk-devicepanel/src/sim_control.rs",
            names: &[
                "pub const fn plan",
                "pub fn status_bar_body",
                "pub fn location_body",
            ],
            message: "rust/slopdesk-devicepanel/src/sim_control.rs lost '{entry}' — the request table is \
                      one implementation or it is none",
        },
        Claim::Mentions {
            path: "rust/slopdesk-devicepanel/src/sim_routes.rs",
            names: &["const QUERY_VALUE", ".add(b'&')", ".add(b'=')"],
            message: "rust/slopdesk-devicepanel/src/sim_routes.rs lost '{entry}' — a query value that can \
                      end its own parameter is a 400 nobody traces back to the filename",
        },
    ]
}

/// ONE virtual finger, planted by both panels
///
/// A scroll wheel becomes a continuous contact, and the machine that decides where it plants, moves
/// and re-grips is the same on both panels — it arrived on the simulator lane as a fix for a
/// `swipe` verb costing 275 ms of the server's main actor, and on the Android lane because
/// `INJECT_SCROLL_EVENT` reaches a list as a notch with no fling. Neither reason is a reason to
/// spell it twice.
///
/// Each face is a CLASS holding the handle, and that is load-bearing rather than taste: a struct
/// holding the pointer frees it once per copy while every copy still points at it, and a struct
/// holding the STATE puts the half that decides where the next plant lands back on this side. What
/// stays per-panel is only what a contact BECOMES on the wire — the simulator sends the fitted
/// rect's own coordinates, the Android lane the video's pixel grid, because its server drops a
/// mismatched pair rather than rescaling it.
#[must_use]
pub fn one_virtual_finger_for_both_panels(tree: &Tree) -> Report {
    const FACES: [&str; 2] = [
        "Sources/SlopDeskDevicePanels/Simulator/SimulatorScrollGesture.swift",
        "Sources/SlopDeskDevicePanels/Android/AndroidScrollGesture.swift",
    ];
    let claims = [
        Claim::NoneOf {
            paths: &FACES,
            pattern: r"clamped != target|scrollVector\(|Self\.planted\(|Self\.regrip\(travel",
            view: View::Code,
            message: "{files} runs the plant-and-regrip machine in Swift again — \
                      slopdesk_devicepanel::scroll owns it for both panels",
        },
        Claim::Mentions {
            path: FACES[0],
            names: &[
                "slopdesk_panel_scroll_new",
                "slopdesk_panel_scroll_free",
                "slopdesk_panel_scroll_accept",
                "slopdesk_panel_scroll_lift",
                "slopdesk_panel_scroll_abandon",
                "slopdesk_panel_scroll_finger",
            ],
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorScrollGesture.swift no longer asks \
                      {entry} — the virtual finger is one implementation",
        },
        Claim::Mentions {
            path: FACES[1],
            names: &[
                "slopdesk_panel_scroll_new",
                "slopdesk_panel_scroll_free",
                "slopdesk_panel_scroll_accept",
                "slopdesk_panel_scroll_lift",
                "slopdesk_panel_scroll_abandon",
                "slopdesk_panel_scroll_finger",
            ],
            message: "Sources/SlopDeskDevicePanels/Android/AndroidScrollGesture.swift no longer asks \
                      {entry} — the virtual finger is one implementation",
        },
        Claim::Names {
            path: FACES[0],
            needle: "package final class SimulatorScrollGesture",
            message: "Sources/SlopDeskDevicePanels/Simulator/SimulatorScrollGesture.swift: the gesture \
                      stopped being a class — a copied handle is a double free",
        },
        Claim::Names {
            path: FACES[1],
            needle: "package final class AndroidScrollGesture",
            message: "Sources/SlopDeskDevicePanels/Android/AndroidScrollGesture.swift: the gesture stopped \
                      being a class — a copied handle is a double free",
        },
        Claim::Mentions {
            path: "rust/slopdesk-devicepanel/src/scroll.rs",
            names: &["pub fn accept", "pub fn lift", "pub const fn abandon"],
            message: "rust/slopdesk-devicepanel/src/scroll.rs lost '{entry}' — the machine both panels \
                      share must stay whole",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// hostd's end asking screenwire for every layout — the `slopdesk-screenclient` shape since
    /// `docs/60` Batch B deleted `ScreenProtocol.swift`.
    const SCREEN_CLIENT: &str = "rust/slopdesk-screenclient/src/client.rs";

    fn write_one_encoder_for_screend_frame(fixture: &Fixture) {
        fixture
            .write(
                SCREEN_CLIENT,
                "encode_request\nencode_detect_payload\ndecode_reply\nkept so the ban has a haystack\n",
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

        // The caller stopped asking — an implementation grew back where the call used to be.
        fixture.write(SCREEN_CLIENT, "");
        assert!(!super::one_encoder_for_screend_frame(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_encoder_for_screend_frame(&fixture);
        fixture.append(SCREEN_CLIENT, "let n = len.to_be_bytes();\n");
        assert!(!super::one_encoder_for_screend_frame(&fixture.tree()).is_clean());
    }

    fn write_one_dialect_for_the_simulator_server(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorWireProtocol.swift",
                "slopdesk_sim_stream_kind\nslopdesk_sim_avcc_parse\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorInputEnvelope.swift",
                "slopdesk_sim_input_tap\nslopdesk_sim_input_swipe\nslopdesk_sim_input_touch\\
                 nslopdesk_sim_input_touch2\nslopdesk_sim_input_button\nslopdesk_sim_input_key\\
                 nslopdesk_sim_input_text\nslopdesk_sim_input_copy\nslopdesk_sim_default_tap_duration\\
                 nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorEndpoints.swift",
                "slopdesk_sim_route\nSlopDeskSimRoute\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorControlClient.swift",
                "slopdesk_sim_control_plan\nslopdesk_sim_control_status_ok\nslopdesk_sim_status_bar_body\\
                 nslopdesk_sim_location_body\nslopdesk_sim_thumbnail_scale\\
                 nslopdesk_sim_thumbnail_quality\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorLogMessage.swift",
                "slopdesk_sim_log_message\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-devicepanel/src/sim_control.rs",
                "pub const fn plan\npub fn status_bar_body\npub fn location_body\nkept so the ban has a \
                 haystack\n",
            )
            .write(
                "rust/slopdesk-devicepanel/src/sim_routes.rs",
                "const QUERY_VALUE\n.add(b'&')\n.add(b'=')\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_dialect_for_the_simulator_server_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-dialect-for-the-simulator-server");
        write_one_dialect_for_the_simulator_server(&fixture);
        assert!(super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorEndpoints.swift",
            "",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // And the escaping set the routes are built on, thinned.
        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.write(
            "rust/slopdesk-devicepanel/src/sim_routes.rs",
            "const QUERY_VALUE\nkept so the ban has a haystack\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // And the law each face was banned from respelling, respelled — one per face.
        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorWireProtocol.swift",
            "struct ByteReader\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorInputEnvelope.swift",
            "JSONSerialization\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorEndpoints.swift",
            "URLQueryItem\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // A verb typed back at the call site — the drift the plan door exists to make impossible.
        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorControlClient.swift",
            "request.httpMethod = \"DELETE\"\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // And the status-bar preset, back as a dictionary literal the server rejects whole.
        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorControlClient.swift",
            "let demo = [\"time\": \"9:41\"]\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // The console envelope, parsed here again.
        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorLogMessage.swift",
            "JSONSerialization\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        // And each of the two new faces, stopping asking.
        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorLogMessage.swift",
            "kept so the ban has a haystack\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());

        write_one_dialect_for_the_simulator_server(&fixture);
        fixture.write(
            "rust/slopdesk-devicepanel/src/sim_control.rs",
            "pub const fn plan\nkept so the ban has a haystack\n",
        );
        assert!(!super::one_dialect_for_the_simulator_server(&fixture.tree()).is_clean());
    }

    fn write_one_virtual_finger_for_both_panels(fixture: &Fixture) {
        let doors = "slopdesk_panel_scroll_new\nslopdesk_panel_scroll_free\\
                     nslopdesk_panel_scroll_accept\nslopdesk_panel_scroll_lift\\
                     nslopdesk_panel_scroll_abandon\nslopdesk_panel_scroll_finger\n";
        fixture
            .write(
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorScrollGesture.swift",
                &format!("{doors}package final class SimulatorScrollGesture\nkept as a haystack\n"),
            )
            .write(
                "Sources/SlopDeskDevicePanels/Android/AndroidScrollGesture.swift",
                &format!("{doors}package final class AndroidScrollGesture\nkept as a haystack\n"),
            )
            .write(
                "rust/slopdesk-devicepanel/src/scroll.rs",
                "pub fn accept\npub fn lift\npub const fn abandon\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_virtual_finger_for_both_panels_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-virtual-finger-for-both-panels");
        write_one_virtual_finger_for_both_panels(&fixture);
        assert!(super::one_virtual_finger_for_both_panels(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidScrollGesture.swift",
            "package final class AndroidScrollGesture\n",
        );
        assert!(!super::one_virtual_finger_for_both_panels(&fixture.tree()).is_clean());

        // The handle went back into a value type, which frees it once per copy.
        write_one_virtual_finger_for_both_panels(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorScrollGesture.swift",
            "slopdesk_panel_scroll_new\nslopdesk_panel_scroll_free\nslopdesk_panel_scroll_accept\\
             nslopdesk_panel_scroll_lift\nslopdesk_panel_scroll_abandon\\
             nslopdesk_panel_scroll_finger\npackage struct SimulatorScrollGesture\n",
        );
        assert!(!super::one_virtual_finger_for_both_panels(&fixture.tree()).is_clean());

        // And the machine itself, respelled beside the door that owns it.
        write_one_virtual_finger_for_both_panels(&fixture);
        fixture.append(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorScrollGesture.swift",
            "clamped != target\n",
        );
        assert!(!super::one_virtual_finger_for_both_panels(&fixture.tree()).is_clean());
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
