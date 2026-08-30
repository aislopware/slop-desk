//! What `watch` decides and prints, the borderless dwell, the divider's pixel-to-weight
//! conversion, and the rail render that reads its badge gates once.
//!
//! Ported from the deleted `check-supervisor.sh`. Three are one-implementation rules of the
//! ordinary kind. The fourth is a PERFORMANCE claim held the same way, because the only durable
//! statement about a measurement is which call site still exists to make it.

use crate::claim::{Claim, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// What `slopdesk watch` DECIDES and what it PRINTS.
///
/// The decision is `rust/slopdesk-agent`'s `watch` and the bytes are `rust/slopdesk-wire`'s `osc`.
/// The bytes are pinned to the crate the host's sniffer parses WITH, so the wrapper cannot emit a
/// sequence the host would drop; the exit codes are pinned because a second at-rest set would make
/// `watch:claude` return on a state the app calls busy.
///
/// ## Only the READING half is still a cross-language claim
/// The wrapper had a Swift face — two files calling eleven doors to decide and to print — and this
/// rule held both. `slopdesk watch` is Rust now and calls `slopdesk-wire::osc` as a library, so
/// there is no face to hold and the eleven writing doors are deleted. What remains is genuinely
/// two-sided: the host's byte reader PARSES the progress sequence, and the client's notification
/// router RECOGNISES the finish sentinel. Both are Swift, both read what the Rust wrapper wrote,
/// and neither may respell the grammar it is reading.
#[must_use]
pub fn what_watch_decides_what_prints(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskProtocol/ProgressState.swift",
            entries: &["slopdesk_osc_parse_progress"],
            message: "Sources/SlopDeskProtocol/ProgressState.swift no longer calls {entry} — the ConEmu \
                      progress grammar is slopdesk-wire's osc",
        },
        Claim::Doors {
            path: "Sources/SlopDeskWorkspaceCore/Connection/NotificationPolicy.swift",
            entries: &["slopdesk_watch_notification_is_marked"],
            message: "Sources/SlopDeskWorkspaceCore/Connection/NotificationPolicy.swift no longer calls \
                      {entry} — a watch-finish banner would route to the generic master switch",
        },
        Claim::Doors {
            path: "Sources/SlopDeskProtocol/WatchNotificationMarker.swift",
            entries: &["slopdesk_watch_notification_marker"],
            message: "Sources/SlopDeskProtocol/WatchNotificationMarker.swift no longer calls {entry} — the \
                      watch vocabulary is slopdesk-agent's and slopdesk-wire's",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskProtocol/ProgressState.swift",
                "Sources/SlopDeskProtocol/WatchNotificationMarker.swift",
                "Sources/SlopDeskWorkspaceCore/Connection/NotificationPolicy.swift",
            ],
            pattern: r#"case \.idle,|0x1B|0x07|"9;4;|777;notify|watch: "#,
            view: View::Code,
            message: "{files} spells a watch at-rest set or escape sequence again — those live in watch.rs \
                      and osc.rs",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskProtocol/WatchNotificationMarker.swift"],
            pattern: r"slopdesk:watch-finish",
            view: View::Code,
            message: "Sources/SlopDeskProtocol/WatchNotificationMarker.swift spells the sentinel again — it \
                      is osc.rs's WATCH_NOTIFICATION_MARKER",
        },
    ];
    check_all(tree, &claims)
}

/// One dwell, and the top edge stays the remote's
///
/// The dwell that decides who owns the top edge in borderless fullscreen lives in
/// `slopdesk_workspace::chrome`. A Swift copy of the phase machine would be a second answer to "may
/// the local menu bar take this click", and the wrong one steals a click from the remote menu bar —
/// which reads as a dropped click, not as a policy bug.
#[must_use]
pub fn one_dwell_decides_who_owns(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskClientCore/App/BorderlessDwellGate.swift",
            needle: "slopdesk_ws_dwell_update",
            message: "BorderlessDwellGate stopped calling slopdesk_ws_dwell_update — the top edge has two \
                      owners",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskClientCore/App/BorderlessDwellGate.swift"],
            pattern: r"dwellSeconds *[:=] *0\.5|revealZonePoints *[:=] *2\b",
            view: View::Code,
            message: "a dwell distance grew back in Swift — rust/slopdesk-settings/src/chrome.rs owns them",
        },
    ];
    check_all(tree, &claims)
}

/// One pixel→weight conversion, and the seam owns it
///
/// `Δweight = Δpixel / parent_span * flex_sum` is the inverse of the partition the solver tiles
/// with, so it can only be right against the seam's OWN span and flex sum. Written out anywhere
/// else it takes those from whatever is in scope — which is how the seam came to trail the cursor
/// at half speed. It lives on `SplitDividerHandle` now, sourced from
/// `slopdesk_workspace::split_layout`, and nothing else — not a view, not a test helper — may spell
/// the formula again.
#[must_use]
pub fn one_pixel_weight_conversion_seam(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift",
            needle: "slopdesk_ws_divider_weight_delta",
            message: "SplitDividerHandle stopped calling slopdesk_ws_divider_weight_delta — the seam trails \
                      the cursor",
        },
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift",
            needle: "slopdesk_ws_divider_percents",
            message: "SplitDividerHandle stopped calling slopdesk_ws_divider_percents — the ratio readout \
                      has two answers",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: r"Double\(span\)|/ *Double\(.*[Ss]pan\)|axisSpan|PaneMath",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the pixel→weight conversion grew back in Swift — SplitDividerHandle.weightDelta is \
                      the one",
        },
    ];
    check_all(tree, &claims)
}

/// A rail render reads its badge settings ONCE, not once per row.
///
/// `chrome(...)` asks the store for `commandBadgeGates` — three `UserDefaults` reads behind a
/// computed property with NO per-pane override — and for `agentBadgeGates`, three more whenever the
/// pane has no override, which is the ordinary case. A list built row by row therefore re-read the
/// same two globals per row. Measured, `swiftc -O`, two runs agreeing inside 0.3%: one
/// `UserDefaults` bool read is 305 ns, a row's six are 1.85 µs, and a 24-row rail render spent 44.5
/// µs on settings that cannot change while it draws. The batch entry reads them once and resolves
/// the active session and its tab list once too. BREAK-TESTED twice: deleting the batch overload
/// fires the entry arm, and deleting the `commandGates` parameter from `chrome` fires the threading
/// arm.
#[must_use]
pub fn rail_render_reads_its_badge(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift",
            needle: "func liveChrome(for rows: [RailRow]",
            message: "Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift lost the batched liveChrome — a \
                      rail render goes back to 6 UserDefaults reads per row (44.5 µs at 24 rows)",
        },
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift",
            pattern: r"commandGates \?\? store.commandBadgeGates",
            view: View::Statements,
            message: "Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift: chrome() no longer accepts \
                      pre-read command gates — the batch entry has nothing to hand it and the per-row reads \
                      come back",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_what_watch_decides_what_prints(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskProtocol/ProgressState.swift",
                "slopdesk_osc_parse_progress(\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Connection/NotificationPolicy.swift",
                "slopdesk_watch_notification_is_marked(\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskProtocol/WatchNotificationMarker.swift",
                "slopdesk_watch_notification_marker(\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn what_watch_decides_what_prints_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("what-watch-decides-what-prints");
        write_what_watch_decides_what_prints(&fixture);
        assert!(super::what_watch_decides_what_prints(&fixture.tree()).is_clean());

        // The reader stopped asking — a parse grew back where the call used to be.
        fixture.write("Sources/SlopDeskProtocol/ProgressState.swift", "");
        assert!(!super::what_watch_decides_what_prints(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_what_watch_decides_what_prints(&fixture);
        fixture.append("Sources/SlopDeskProtocol/ProgressState.swift", "\"9;4;\n");
        assert!(!super::what_watch_decides_what_prints(&fixture.tree()).is_clean());
    }

    fn write_one_dwell_decides_who_owns(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskClientCore/App/BorderlessDwellGate.swift",
            "slopdesk_ws_dwell_update\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn one_dwell_decides_who_owns_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-dwell-decides-who-owns");
        write_one_dwell_decides_who_owns(&fixture);
        assert!(super::one_dwell_decides_who_owns(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskClientCore/App/BorderlessDwellGate.swift", "");
        assert!(!super::one_dwell_decides_who_owns(&fixture.tree()).is_clean());
    }

    fn write_one_pixel_weight_conversion_seam(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift",
                "slopdesk_ws_divider_weight_delta\nslopdesk_ws_divider_percents\nkept so the ban has a \
                 haystack\n",
            )
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n");
    }

    #[test]
    fn one_pixel_weight_conversion_seam_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-pixel-weight-conversion-seam");
        write_one_pixel_weight_conversion_seam(&fixture);
        assert!(super::one_pixel_weight_conversion_seam(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift",
            "",
        );
        assert!(!super::one_pixel_weight_conversion_seam(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_pixel_weight_conversion_seam(&fixture);
        fixture.append("Sources/Generated.swift", "Double(span)\n");
        assert!(!super::one_pixel_weight_conversion_seam(&fixture.tree()).is_clean());
    }
}
