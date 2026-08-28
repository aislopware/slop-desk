//! The GUI video host stopped being Swift, and this is the one place that says so.
//!
//! `docs/61` deleted `Sources/SlopDeskVideoHost`, `Sources/slopdesk-videohostd` and
//! `Tests/SlopDeskVideoHostTests` in a single change and landed `rust/slopdesk-videohostd` beside
//! them. Every capture, encode, mux, feed, injection and virtual-display decision that used to be
//! spelled in one of those files is `rust/slopdesk-video`'s law, asked by the daemon.
//!
//! ## Why this file exists rather than forty re-aims
//!
//! Each of the rules that named one of those Swift files had TWO protections folded together: that
//! the law lives ONCE in `rust/slopdesk-video`, and that the Swift face does not respell it. The
//! first half survives the deletion and stays where it was, re-aimed at the daemon. The second half
//! is now the SAME claim forty times over — "no Swift declares a video-host type" — so it is stated
//! once, here, at full strength: not "this file must not respell the router" but "no file in any
//! Swift target may declare a router at all".
//!
//! That is stronger than what it replaces. The old bans were per-file, so a `VideoMuxRouter` moved
//! one directory sideways satisfied every one of them. This one is tree-wide.
//!
//! Read `View::Code`, like every other ban in this crate: `docs/61` left the names of what it
//! deleted in the doc comments of the Rust that replaced it, and a raw read would fire on the
//! explanation rather than on a revival.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The three trees the Swift GUI host lived in, plus the bench that only measured it.
///
/// The ban is on the DIRECTORY rather than on any file inside it, for the reason
/// [`crate::rules::deleted_host_swift`] gives about hostd's own three: a face re-added under
/// another filename is the same failure, and
/// `package_graph::every_source_directory_is_a_target` would then demand a `Package.swift` entry
/// for it — so a resurrection fires two rules rather than slipping past one.
fn the_swift_targets_stay_deleted() -> Vec<Claim> {
    vec![
        Claim::Absent {
            path: "Sources/SlopDeskVideoHost",
            message: "the GUI video host's Swift target is back — the host half of PATH 2 is \
                      rust/slopdesk-videohostd, which reaches every Apple framework it needs through the \
                      slopdesk-apple-* family (docs/57, docs/61); a Swift file here is the second \
                      implementation of whatever it holds, in the language the port was written to leave",
        },
        Claim::Absent {
            path: "Sources/slopdesk-videohostd",
            message: "the GUI video host's Swift entry point is back — the daemon is \
                      rust/slopdesk-videohostd's main.rs, and a second one would be two processes claiming \
                      one media port (docs/61)",
        },
        Claim::Absent {
            path: "Tests/SlopDeskVideoHostTests",
            message: "the GUI video host's Swift suite is back — every behaviour it would assert is Rust's \
                      now, so a Swift test of it is the cross-language mirror fixture CLAUDE.md bans, not \
                      coverage (docs/61)",
        },
        Claim::Absent {
            path: "Sources/slopdesk-perfbench",
            message: "the encode-wall bench is back in Swift — it drove the Swift VideoEncoder, and the \
                      driver is rust/slopdesk-videohostd's encode.rs; the harness follows the driver, so \
                      the measurement lives in rust/slopdesk-loopback-validate (docs/61 §2)",
        },
    ]
}

/// Every type the deleted host declared, banned by DECLARATION across every Swift target.
///
/// Split from [`the_swift_targets_stay_deleted`] because it answers a different question: that ban
/// is about a directory coming back, this one is about a type coming back ANYWHERE — in the client,
/// in the protocol library, in a workspace view. The failure it catches is the one the old per-file
/// bans could not: `VideoMuxRouter` re-declared in `Sources/SlopDeskVideoProtocol` is not the host
/// target returning, it is the mux law being answered twice with nothing red.
///
/// The list is the deleted tree's own file names, which were its type names — that is why the port
/// could delete them by path. Four are left out on purpose. `SlopDeskVideoHost` and
/// `SlopDeskVideoHostSession` are covered by the directory ban and read as prose everywhere else;
/// `WindowFeedGlue` and `WindowPreviewGlue` were `AppKit` glue with no decision in them.
///
/// `protocol` is in the declaration alternation because `VideoDatagramTransport` WAS one: a Swift
/// re-declaration of that protocol is a second sink shape for a lane whose only sink is the
/// daemon's `sendlane::DatagramSink`.
fn no_swift_declares_a_video_host_type() -> Vec<Claim> {
    vec![Claim::NoneUnder {
        roots: &["Sources", "Tests"],
        extensions: SWIFT,
        pattern: r"\b(enum|struct|final class|class|actor|protocol) (AudioStreamEncoder|CaptureRegionRecovery|CursorSampler|FPSGovernor|HostDisplayWake|HostFrontmostApp|HostNavHistory|HostPrivacyBlank|IdleReapDecider|InputInjector|LTRController|LiveBitratePolicy|LiveCongestionController|MuxFlowTable|NWVideoMuxDatagramTransport|OffScreenWindowMintRescue|PacketizeLane|QPController|RecoveryIDRPolicy|RecoveryRequestDeduper|RetransmitRing|StaticFrameSuppressionDecider|StillnessCrispDecider|StreamableWindowListOrder|SwipeNavHostConfig|UnboundLaneByePolicy|VideoDatagramTransport|VideoEncoder|VideoMuxChannelTransport|VideoMuxRouter|VideoMuxSessionRegistry|VideoSendLane|VideoSessionLogic|VirtualDisplay|VirtualDisplayRecoveryPolicy|WindowCapturer|WindowFeedAXSupport|WindowFeedCache|WindowFeedSnapshotBuilder|WindowFeedSubscribers|WindowGeometryWatcher|WindowParkingLedger|WindowParkingManager|WindowParkingSidecar|WindowPlacement)\b",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "a video-host type is declared in Swift again in {files} — the GUI host is \
                  rust/slopdesk-videohostd and its decisions are rust/slopdesk-video's, so a Swift \
                  declaration of one of these is a second answer to a question that has one (docs/61)",
    }]
}

/// The Swift half of `docs/61`, as one rule.
#[must_use]
pub fn deleted_video_swift(tree: &Tree) -> Report {
    let mut claims = the_swift_targets_stay_deleted();
    claims.extend(no_swift_declares_a_video_host_type());
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use super::deleted_video_swift;
    use crate::tests::Fixture;

    /// A source file under any of the four deleted targets is that target returning.
    #[test]
    fn a_revived_swift_video_target_is_red() {
        for target in [
            "Sources/SlopDeskVideoHost",
            "Sources/slopdesk-videohostd",
            "Tests/SlopDeskVideoHostTests",
            "Sources/slopdesk-perfbench",
        ] {
            let fixture = Fixture::new(&format!("revived-video-{}", target.replace('/', "-")));
            fixture.write("Sources/SlopDeskVideoClient/A.swift", "let ordinary = 1\n");
            assert!(deleted_video_swift(&fixture.tree()).is_clean(), "{target}");
            fixture.write(&format!("{target}/Revived.swift"), "let frame = 1\n");
            assert!(
                !deleted_video_swift(&fixture.tree()).is_clean(),
                "{target}: the ban did not fire on its return"
            );
        }
    }

    /// The drift the per-file bans could not see: the type comes back, one directory sideways.
    ///
    /// `Sources/SlopDeskVideoClient` is a live target, so nothing about this seed is a deleted
    /// directory — it is the mux law answered a second time in the language the port left, with
    /// both suites green because no datagram reaches both copies.
    #[test]
    fn a_video_host_type_declared_in_a_live_target_is_red() {
        for line in [
            "final class VideoMuxRouter {}\n",
            "struct WindowCapturer {}\n",
            "actor VideoEncoder {}\n",
            "enum WindowPlacement {}\n",
            "protocol VideoDatagramTransport {}\n",
        ] {
            let fixture = Fixture::new("revived-video-type");
            fixture.write("Sources/SlopDeskVideoClient/A.swift", "let ordinary = 1\n");
            assert!(deleted_video_swift(&fixture.tree()).is_clean(), "{line}");
            fixture.append("Sources/SlopDeskVideoClient/A.swift", line);
            assert!(
                !deleted_video_swift(&fixture.tree()).is_clean(),
                "the ban did not fire on {line:?}"
            );
        }
    }

    /// `docs/61` left the deleted names in the doc comments of the Rust that replaced them, and the
    /// surviving Swift cites them the same way. Prose is not a revival.
    #[test]
    fn a_comment_naming_a_deleted_video_type_is_not_a_revival() {
        let fixture = Fixture::new("video-type-comment");
        fixture.write(
            "Sources/SlopDeskVideoClient/A.swift",
            "// `final class VideoMuxRouter` used to live here; slopdesk-video owns the routing now.\nlet x \
             = 1\n",
        );
        assert!(deleted_video_swift(&fixture.tree()).is_clean());
    }
}
