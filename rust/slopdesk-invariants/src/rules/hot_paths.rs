//! Five per-keystroke, per-row, per-chunk or per-message paths, each of which had a second
//! implementation that was correct and slow.
//!
//! Ported from the deleted `check-supervisor.sh`. What is enforced is not the measurement — a
//! number in a gate rots — but the call site that earned it: the engine that does not backtrack,
//! the ranking that happens once per query, the splitter that skips the walk it does not need.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

// ---------------------------------------------------------------------------------------------
// hostd's side of the seven `docs/59` splits, after `docs/60` F.9.
//
// Each of those rules used to be three claims about a Swift FACE: that the file existed, that it
// called every door of the crate it marshalled for, and that it held no state of its own. The first
// two are gone with the face — hostd is Rust and CALLS `slopdesk-muxsession`, so there is no
// marshalling layer left for a door to be dropped from, and the type system is what says the call
// happened.
//
// The third is not gone, and is the reason these rules survive rather than being deleted. Nothing
// in the build graph stops `slopdesk-hostsession` from growing its own roster beside the crate's,
// its own in-flight counter beside the crate's cap, or its own detach flag beside the crate's
// ladder. Every one of those still compiles, still passes both suites, and still drifts — which is
// the whole shape `docs/59` split apart. So what is ratcheted below is the "no second copy" half,
// spelled the way Rust would write the drift.
// ---------------------------------------------------------------------------------------------

/// The pane's own state — the outbox, the roster, the truths fold and the lifecycle ladder all sit
/// behind handles this crate holds.
const SESSION: &str = "rust/slopdesk-hostsession";

/// The daemon half — routing, the registry relations and the metadata verbs.
const HOST_SERVER: &str = "rust/slopdesk-hostserver";

/// The three spellings of the live-edge sentinel, none of which imports another.
const FROM_NOW_ON_SITES: &[&str] = &[
    "rust/slopdesk-hostpane/src/stream.rs",
    "rust/slopdesk-muxsession/src/lifecycle.rs",
    "rust/slopdesk-muxsession/src/open_route.rs",
];

/// The one home of whether an arriving mux frame is admissible, and of what a channel's ending
/// tears down.
const DOORMAN_HOME: &str = "rust/slopdesk-wire/src/mux/admission.rs";

/// Every verdict that home must keep spelling. Three, and a caller that stops asking one has
/// re-derived it.
const DOORMAN_VERDICTS: &[&str] = &["pub fn admit", "pub const fn poisoned", "pub const fn peer_close"];

/// The connection that routes frames through those verdicts and owns nothing else about them.
const MUX_CONNECTION: &str = "rust/slopdesk-muxnet/src/connection.rs";

/// One relation, one table — and one identity to ask it about
///
/// A fanned-out pane is ONE `MuxChannelSession` under N channel keys, so every event is either
/// about one member or about all of them. hostd told the two apart with seven dictionaries, of
/// which two had to be written in the same critical section to stay in agreement: a key with no
/// subscriber entry MEANT the pane's original channel, so "not registered yet" and "is the primary"
/// were the same missing entry. The identity questions on top of that — remove this key only while
/// it still names THIS session, is this session attached anywhere else, does this teardown still
/// own the hook sink — were `===` against objects a second reader could not see.
///
/// The relations are `rust/slopdesk-muxsession`'s `registry`, and `slopdesk-hostserver` holds the
/// session OBJECTS keyed by an id it already has — which is retention, not a relation.
///
/// What survives F.9 is the ban. hostserver linking the crate does not stop it declaring a second
/// `hook_pane_ids` beside the one `Registry` owns; that compiles, and the two maps that must agree
/// are exactly the invariant nobody can state.
#[must_use]
pub fn one_relation_one_table(tree: &Tree) -> Report {
    let claims = [Claim::NoneUnder {
        roots: &[HOST_SERVER],
        extensions: RUST,
        pattern: r"\b(hook_pane_ids|project_object_ids|control_sessions|subscriber_ids)\s*:\s*(HashMap|BTreeMap)",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "{files} keeps its own channel→pane, subscriber, hook-sink or project-id map — two maps \
                  that must agree is one invariant nobody can state, which is why they are one record in \
                  slopdesk-muxsession's registry (docs/59 §5, step 7)",
    }];
    check_all(tree, &claims)
}

/// One regex engine meets the untrusted rows, and it does not backtrack
///
/// Hint Mode ran ten compiled `NSRegularExpressions` over rows a remote program wrote, bridged
/// through `NSString`, mapping columns with a third cell walk. Two things were wrong with that and
/// this pins both: the columns now come from the link scan's clustering, and the user's
/// `hint-pattern` — a regex a human pasted in, run against text an attacker influences — now runs
/// on a finite automaton whose match time is linear in the row. A backtracking engine here is a
/// hang the user cannot escape, so the Swift face must stay a marshaller.
#[must_use]
pub fn one_regex_engine_over_untrusted(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift"],
            pattern: r"NSRegularExpression|NSString|force_try|displayCellWidth|boundedPrefix|overlapsAccepted",
            view: View::Code,
            message: "{files} scans for hint targets in Swift again — slopdesk-rowscan owns the scan",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            names: &[
                "slopdesk_hint_scan",
                "slopdesk_hint_scan_target",
                "slopdesk_hint_scan_take_arena",
            ],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift no longer asks {entry} \
                      — the hint scan is one implementation",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            names: &["static", "func", "labels", "static", "func", "filter"],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift lost ${kept} — the \
                      label arithmetic stays here on purpose (docs/55)",
        },
        Claim::Matches {
            path: "rust/slopdesk-rowscan/Cargo.toml",
            pattern: r"^regex = ",
            view: View::Statements,
            message: "rust/slopdesk-rowscan dropped the regex crate — a hand-written or backtracking \
                      matcher is the hang",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-terminal/Cargo.toml"],
            pattern: r"^regex = ",
            view: View::Code,
            message: "rust/slopdesk-terminal took an external dependency — that crate is on the PTY hot path",
        },
    ];
    check_all(tree, &claims)
}

/// 3. THE PALETTE'S THREE RESULT PROPERTIES ARE ONE PASS. `paletteResults`, `rankedResults` and
///
/// `selectableResults` each used to re-run the whole mixer: ~8 category sources, and per source a
/// fresh tuple array, a fresh `[String?]` of three fields per row, and one
/// `slopdesk_ws_search_rank` crossing whose blob is every title, subtitle and synonym concatenated.
/// Measured over a 90-row catalog in 8 sources: ~150 µs PER READ (139–167) for a typed query, ~30
/// µs for the empty-query path. `moveSelection` reads `selectableResults` only for `.count`, so
/// every ↑/↓ paid one pass before the body paid another, and the phone's `PaletteView` reads
/// `rankedResults` twice per body — three passes per arrow key on the phone, two on the Mac. They
/// now share one memo keyed on `(generation, query, filter, recents)`, and `mixerGeneration` is
/// what makes a rebuilt mixer invalidate it. BREAK-TESTED twice: pointing `rankedResults` back at
/// `mixer?.ranked(` fires its reader arm, and deleting the `&+= 1` line from `rebuildMixer` fires
/// the generation arm.
#[must_use]
pub fn palette_ranks_once_per_query(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            pattern: r"var paletteResults: \[[A-Za-z]+\] \{ memoizedResults\.",
            view: View::Statements,
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: paletteResults no \
                      longer reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride \
                      one arrow key",
        },
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            pattern: r"var rankedResults: \[[A-Za-z]+\] \{ memoizedResults\.",
            view: View::Statements,
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: rankedResults no longer \
                      reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride one \
                      arrow key",
        },
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            pattern: r"var selectableResults: \[[A-Za-z]+\] \{ memoizedResults\.",
            view: View::Statements,
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: selectableResults no \
                      longer reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride \
                      one arrow key",
        },
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            needle: "mixerGeneration &+= 1",
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: rebuildMixer no longer \
                      bumps mixerGeneration — the memo would serve results from the PREVIOUS catalog",
        },
    ];
    check_all(tree, &claims)
}

/// The nerd-font run splitter is LINEAR, and skips the walk entirely when nothing is a symbol.
///
/// `runs(of:)` had the obvious accumulator — read the last run back out of the array, append one
/// character, write it back — and that is QUADRATIC without looking it: `out.last` hands back a
/// COPY of the tuple, so the run's `String` is two-referenced for an instant and `append` copies
/// the whole run before adding a character. Every `.slateNerdAware` string in three overlays walks
/// this once per keystroke. Measured, `swiftc -O`, two runs agreeing: a plain 48-character title
/// 3,563 → 104 ns, a 240-character one 21,588 → 371 ns (58×). The scalar pre-scan is the other
/// half, and is what makes the ordinary case — no nerd glyph anywhere, which is almost every string
/// — one scalar walk and one `String`, without entering the per-`Character` loop at all. It is also
/// what stops the two splice sites' `registered` guard ORDER from mattering.
#[must_use]
pub fn nerd_font_run_splitter_linear(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: "Sources/SlopDeskFontFaces/NerdSymbolFont.swift",
            pattern: r"guard text.unicodeScalars.contains\(where: isPrivateUse\)",
            view: View::Statements,
            message: "Sources/SlopDeskFontFaces/NerdSymbolFont.swift: runs(of:) lost its scalar pre-scan — \
                      every ordinary title pays a per-Character walk and a String per run again",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskFontFaces/NerdSymbolFont.swift"],
            pattern: r"if var last = out\.last|out\[out\.count - 1\] = ",
            view: View::Raw,
            message: "Sources/SlopDeskFontFaces/NerdSymbolFont.swift: runs(of:) accumulates through \
                      out.last again — that shape is QUADRATIC in the run length (3,563 ns for a 48-char \
                      title against 104)",
        },
    ];
    check_all(tree, &claims)
}

/// One outbound merge, and the face over it holds no bytes of its own
///
/// hostd's PTY read loop appends a chunk per supervised read and ONE drain pops, but what it pops
/// is not what was appended: adjacent chunks coalesce up to the credit-safe payload cap, an
/// over-cap head splits so the 13-byte `.output` header cannot push a frame past the receiver's
/// grant threshold, and `.exit` is a barrier neither may cross. That is
/// `rust/slopdesk-muxsession`'s `outbox` (docs/59 step 2), and `deleted_host_swift`'s
/// `pane_outbound_queue` bans the machinery it replaced.
///
/// What is pinned HERE is the shape docs/55 §4c makes non-negotiable on this path: the door reads
/// LENGTHS and the face keeps the bytes. This runs once per 32 KiB chunk, forever — a door that
/// materialized a `Data` per chunk would cost 227.5 ns against a crossing's 1.0, which is the same
/// trade the recorded +30 ms cold reattach paid for a `sanitize` callback. So the face must still
/// call every entry point (a dropped door is a shadow queue beside the one the verdict is computed
/// from) and must NOT hold a second ordering of its own: no array of queued items, no head cursor.
/// Its one collection is a map from the slot the door minted to the payload that slot names.
#[must_use]
pub fn the_outbound_frame_merges_once(tree: &Tree) -> Report {
    let claims = [Claim::NoneUnder {
        roots: &[SESSION],
        extensions: RUST,
        pattern: r"VecDeque<(Queued|Slot|Frame)>|\bnext_slot\s*:|\bqueued\s*:\s*Vec<",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "{files} keeps an ORDER of its own — hostd holds a slot→payload map and nothing else, \
                  because the order, the merge and the split are slopdesk-muxsession's outbox (docs/59 §4)",
    }];
    check_all(tree, &claims)
}

/// One subscriber set, and every NUMBER in it lives once
///
/// A pane's members are two halves that cannot be one thing: the OBJECTS — a sub-channel pair, four
/// relay tasks, two queues and their `AsyncStream` wakes, none of which has a shape a C ABI could
/// carry — and the NUMBERS: an ack cursor, a delivery frontier, whether a sender exists, whether
/// the exit has been told, whether the member is on its way out. `rust/slopdesk-muxsession`'s
/// `fanout` owns the numbers, the roster, the id mint and both folds over them (docs/45 §8.6,
/// docs/59 step 3).
///
/// A parallel table is the one failure mode that split has, so this pins the line: the near side
/// may key OBJECTS by id, and may keep `retired` — that latch is about an object's tasks being
/// cancelled and it deliberately outlives membership — and nothing else. A `lastAckedSeq` or a
/// `lastSentSeq` declared beside the pair is not a cache, it is a second answer to a question the
/// retention floor and the producer bound are computed from, and the two drift silently: a stale
/// min pins the replay buffer forever, a stale max wedges the read loop paused.
///
/// `noteSent` runs per MESSAGE on every member's sender, so the face is held to the same
/// marshaller bar as the outbox above: it may hold no roster, no cursor and no threshold of its
/// own.
#[must_use]
pub fn the_subscriber_set_is_one_table(tree: &Tree) -> Report {
    let claims = [Claim::NoneUnder {
        roots: &[SESSION],
        extensions: RUST,
        pattern: r"\b(last_acked|last_sent|next_subscriber_id|retention_floor)\s*:",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "{files} keeps a cursor of its own beside the roster — the id mint, both cursors and the \
                  laggard threshold are slopdesk-muxsession's fanout, and a stale copy here pins the replay \
                  buffer forever or wedges the read loop paused (docs/59 §4)",
    }];
    check_all(tree, &claims)
}

/// One batch, one pass, one lock
///
/// A pane's truths were SEVEN stored properties behind seven `NSLock`s, and the read loop took four
/// of them per chunk — one per latch — while the control sockets took the rest. Nothing was faster
/// for the split: the writer is serial, so the seven acquisitions bought no concurrency at all, and
/// they cost every reader the chance of pairing a fresh title with a stale stamp.
///
/// The fold that produces them is `rust/slopdesk-muxsession`'s `truths` now, so this pins the two
/// halves that keep it one implementation: the face asks every door (a face that drops one is a
/// latch growing back beside the handle), and the session declares no second lock over what the
/// handle already serialises.
#[must_use]
pub fn one_batch_one_pass_one_lock(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &[SESSION],
            extensions: RUST,
            pattern: r"\b(title|progress|completion|command_exit|blocks|echo_detect|agent_detect|project_key)_lock\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} declares one of the eight locks again — they collapsed into one Mutex over \
                      the fold because the fields were never the reason they were separate (docs/59 §4, \
                      steps 4-5)",
        },
        // The re-assert is an ORDER, not a set, so what is ratcheted is that hostd still ASKS for it.
        // A ban on building the messages cannot work here: the detector legitimately pushes its own
        // half in the middle of the ladder, which is exactly what `reestablish_head` … detector …
        // `reestablish_tail` means. Dropping either end is the drift — it still compiles, still passes
        // every content assertion, and costs every returning client its title.
        Claim::MentionsUnder {
            root: SESSION,
            names: &["reestablish_head", "reestablish_tail"],
            message: "no file under rust/slopdesk-hostsession asks {entry} any more — the reattach \
                      re-assert is an ORDER the fold owns, and a hand-built one puts the title before the \
                      command stamp it is judged against (docs/59 §4, step 5)",
        },
    ];
    check_all(tree, &claims)
}

/// One open, one route
///
/// `spawnMuxChannel` decided between seven exits by reading five booleans under one lock, in an
/// order that was only ever a comment. The order is load-bearing three separate ways: an unserved
/// class that reaches the PTY path forks a login shell nobody asked for; a live session id that
/// falls past the JOIN into the spawn path rotates the incumbent's journal writer out and stops its
/// transcript mid-session; and a resume verdict above what a session can number tells a returning
/// client to drop every frame it is about to be sent.
///
/// None of those fails a build, and none of them fails a content assertion. So the precedence is
/// `rust/slopdesk-muxsession`'s `open_route` now, and this pins the two halves that keep it one
/// implementation: the face asks every door, and hostd re-derives none of the four answers by hand.
#[must_use]
pub fn one_open_one_route(tree: &Tree) -> Report {
    let mut claims = vec![Claim::NoneUnder {
        roots: &[HOST_SERVER],
        extensions: RUST,
        pattern: r"\.min\([^)]*last_received_seq|channel_class\s*==\s*ChannelClass|owner\s*==\s*supervisor_owner_identity",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "{files} re-derives one of the router's answers by hand — the class routing, the resume \
                  clamp and the adoption owner test are all slopdesk-muxsession's open_route, and each of \
                  them is a rule that still compiles when it is wrong (docs/59 §5, step 6)",
    }];
    // Three crates spell the live-edge sentinel and none of them imports another's, so this half is
    // a count-spellings check rather than a face-and-door one: `hostpane` hands it to a
    // subscriber, `lifecycle` parks a detached pane on it and `open_route` resumes a survivor
    // from it. Two that disagree replay a whole transcript twice, and no compiler sees the
    // third.
    claims.extend(FROM_NOW_ON_SITES.iter().map(|path| {
        Claim::Matches {
            path,
            pattern: r"pub const FROM_NOW_ON: u64 = u64::MAX;",
            view: View::Statements,
            message: "one of the three live-edge sentinels stopped spelling itself u64::MAX — \
                      slopdesk-hostpane's stream, slopdesk-muxsession's lifecycle and its open_route must \
                      agree, and nothing in the build graph makes them (docs/59 §5, step 6)",
        }
    }));
    check_all(tree, &claims)
}

/// One verb, one performer — and one counter that says whether there is room to run it
///
/// A pane answers every host-metadata verb over the SAME unwindowed control sub-channel, so two
/// questions have to be settled before any host work starts, and both used to be settled by
/// arrangement rather than by an answer. The bound was a counter and a cap spelled here; the
/// routing was a CHAIN of six shims each returning "not mine", which is a shape that cannot state
/// the two bugs it is exposed to — a verb claimed by nobody, and a verb claimed by two. The first
/// sends a side-effecting verb into the read-only builder, which performs no side effects, so the
/// host answers `unsupportedVerb` for a request it is perfectly able to serve. The second runs two
/// host operations for one request.
///
/// Neither fails a build. So the table is `rust/slopdesk-muxsession`'s `metadata_admission` now,
/// and this pins the three halves that keep it one implementation: the face asks every door, the
/// session keeps no private counter, and no performer answers an OPTIONAL — an optional return is
/// exactly how a shim says "not mine", which is the ownership decision growing back beside the
/// table that owns it.
#[must_use]
pub fn one_metadata_verb_one_performer(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &[SESSION],
            extensions: RUST,
            pattern: r"max_metadata_in_flight|metadata_in_flight\s*[+-]=",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} keeps its own metadata in-flight count or cap — the bound is \
                      slopdesk-muxsession's Admission, and a second counter beside it is a bound that \
                      silently stops bounding (docs/59 §5, step 8)",
        },
        // The six shims are `slopdesk-hostserver`'s modules now rather than six Swift files, and the ban
        // reads the same: an `Option<WireMessage>` return IS the shim saying "not my verb", which is the
        // ownership decision growing back beside `metadata_admission::performer`, the one table that
        // answers it.
        Claim::NoneUnder {
            roots: &[HOST_SERVER],
            extensions: RUST,
            pattern: r"fn perform\b[^{]*->\s*Option<WireMessage>",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} answers an OPTIONAL response — that `None` IS the claim \"not my verb\", and \
                      which verbs a performer owns is metadata_admission::performer's answer, not a second \
                      opinion at every shim (docs/59 §5, step 8)",
        },
    ];
    check_all(tree, &claims)
}

/// One arc, one ladder — and the two latches that are not locks
///
/// A pane's detach/rebind is all I/O except for the part that decides it: whether THIS detach is
/// the one that tears down, whether a returning client may rebind at all, and where its
/// subscription re-opens. Each of the three used to be a stored flag beside the objects it guarded,
/// and each has a failure a build never catches. A second detach that re-runs the teardown churns
/// state another thread is reading and re-reads a cursor that has stopped advancing. A rebind onto
/// already- finished sub-channels flips the detached flag onto channels every send throws on,
/// leaving a stored session that reads as "attached" and is reachable by no map, store, TTL or
/// `stop()`. A resume cursor kept by `Swift.max` alone stays pinned at the `fromNowOn` sentinel
/// forever.
///
/// So the ladder is `rust/slopdesk-muxsession`'s `lifecycle` now, and this pins the halves that
/// keep it one implementation: the face asks every door, and the session keeps neither the flags
/// nor the two latch LOCKS back. The latches matter as much as the flags: `eofLock` and
/// `exitSentLock` existed only because two pure one-way latches were stored properties, and
/// re-introducing either puts the ingest path back in a queue behind the teardown ladder.
#[must_use]
pub fn one_arc_one_ladder(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &[SESSION],
            extensions: RUST,
            pattern: r"\b(eof_lock|exit_sent_lock)\b|\b(eof_reached|exit_sent|stream_offset)\s*:\s*(bool|u64|AtomicBool)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} keeps a lifecycle flag, cursor or latch LOCK of its own — the arc is \
                      slopdesk-muxsession's Lifecycle, and a second copy beside it is a guard that silently \
                      stops guarding (docs/59 §5, step 5b)",
        },
        Claim::MentionsUnder {
            root: SESSION,
            names: &["slopdesk_muxsession::lifecycle::Lifecycle"],
            message: "no file under rust/slopdesk-hostsession names {entry} any more — the ladder it \
                      answers is what keeps the pane's own lock down to the objects that cannot be folded \
                      (docs/59 §5, step 5b)",
        },
    ];
    check_all(tree, &claims)
}

/// One frame, one doorman.
///
/// The four guards in front of the demux rule, and the two teardowns behind it, are
/// `slopdesk_wire`'s `mux::admission`. What this pins is not that they moved but that they cannot
/// grow back.
///
/// Each guard bounds something a correct peer never touches: a router table grown forever by
/// over-cap opens, a phantom control-table entry nothing closes, one fresh PTY per open/close cycle
/// on a single reused id. None of the four fails a build, and the PRECEDENCE between them is
/// load-bearing — a cap checked after the table advances is a cap that stopped bounding the table
/// it was written to bound. A hand-written `if role == .host, link == .data, case .channelOpen`
/// beside the door is that precedence forking in two.
///
/// The teardown half is banned by the same shape: a channel that ends on one link has to reach the
/// other, and a hand-rolled local/remote close in the connection is the branch that leaves a shell
/// with no close trigger left.
///
/// ## Both sides of this rule became Rust, and it survives for the reason the seven above it did
///
/// It used to pin a Swift PAIR: `MuxAdmission.swift` calling the three `slopdesk_mux_*` doors, and
/// `MuxNWConnection.swift` asking `MuxDoorman` for all three verdicts without reading the channel
/// cap itself. `docs/63` §G.3 deleted both files and retired the three doors with them — the client
/// mux is `slopdesk-muxnet` driving `slopdesk_wire::mux` in-process, and a decoded MESSAGE is what
/// crosses to Swift now.
///
/// The claim did not become redundant when the Swift end died, for exactly the reason `docs/60` F.9
/// left the seven splits above standing: the caller and the rule are still in SEPARATE CRATES with
/// no dependency forcing the question through the door. `slopdesk-muxnet` can grow an `if role ==
/// Role::Host && lane == Link::Data` beside `admit`, or read `MAX_CHANNELS_PER_CONNECTION` at a
/// point in the precedence nobody chose, and every suite stays green. So the pins move to the Rust
/// side of the same fact and the wording of the rule does not change.
#[must_use]
pub fn one_frame_one_doorman(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: DOORMAN_HOME,
            message: "rust/slopdesk-wire/src/mux/admission.rs is gone — whether a frame is admissible, and \
                      what a channel's ending tears down, are not the connection's to re-derive (docs/59 §5)",
        },
        Claim::Doors {
            path: DOORMAN_HOME,
            entries: DOORMAN_VERDICTS,
            message: "rust/slopdesk-wire/src/mux/admission.rs no longer spells {entry} — a verdict that \
                      leaves this file is a guard growing back beside the one that owns it (docs/59 §5)",
        },
        Claim::NoneOf {
            paths: &[MUX_CONNECTION],
            pattern: r"MAX_CHANNELS_PER_CONNECTION",
            view: View::Code,
            message: "{files} reads the per-connection channel cap itself — the cap is one CLAUSE of a \
                      four-guard precedence, and a copy of it here is the bound being re-checked at a point \
                      in that order nobody chose (docs/59 §5)",
        },
        Claim::Doors {
            path: MUX_CONNECTION,
            entries: &["admit", "poisoned", "peer_close"],
            message: "rust/slopdesk-muxnet/src/connection.rs no longer asks {entry} — a frame routed past \
                      the doorman, or an ending torn down without its verdict, is the guard this rule \
                      exists for written a second time (docs/59 §5)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_regex_engine_over_untrusted(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
                "slopdesk_hint_scan\nslopdesk_hint_scan_target\nslopdesk_hint_scan_take_arena\nstatic\nfunc\\
                 \
                 nlabels\nstatic\nfunc\nfilter\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-rowscan/Cargo.toml",
                "regex = \nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-terminal/Cargo.toml",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_regex_engine_over_untrusted_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-regex-engine-over-untrusted");
        write_one_regex_engine_over_untrusted(&fixture);
        assert!(super::one_regex_engine_over_untrusted(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            "",
        );
        assert!(!super::one_regex_engine_over_untrusted(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_regex_engine_over_untrusted(&fixture);
        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            "NSRegularExpression\n",
        );
        assert!(!super::one_regex_engine_over_untrusted(&fixture.tree()).is_clean());
    }

    /// Seeded the way Rust would write the drift, for the same reason as the seven fixtures below:
    /// both halves of this pair are crates now, and a Swift shape translated by hand would match
    /// none of them.
    fn write_one_frame_one_doorman(fixture: &Fixture) {
        let mut home = String::new();
        for verdict in super::DOORMAN_VERDICTS {
            home.push_str(verdict);
            home.push_str("(arrival: &Arrival) {}\n");
        }
        fixture.write(super::DOORMAN_HOME, &home).write(
            super::MUX_CONNECTION,
            "match admit(&Arrival { role: self.role }) {}\nlet verdict = poisoned(self.role, lane);\nlet \
             verdict = peer_close(self.role, lane);\n",
        );
    }

    #[test]
    fn one_frame_one_doorman_keeps_the_precedence_on_one_side() {
        let fixture = Fixture::new("one-frame-one-doorman");
        write_one_frame_one_doorman(&fixture);
        assert!(super::one_frame_one_doorman(&fixture.tree()).is_clean());

        // A verdict left the file that holds the precedence — a guard growing back beside the one
        // that owns it.
        fixture.write(super::DOORMAN_HOME, "pub fn admit(arrival: &Arrival) {}\n");
        assert!(!super::one_frame_one_doorman(&fixture.tree()).is_clean());

        // A second copy of the cap: the bound re-checked at a point in the order nobody chose.
        write_one_frame_one_doorman(&fixture);
        fixture.append(
            super::MUX_CONNECTION,
            "if self.data.state_count() >= MuxFlowControl::MAX_CHANNELS_PER_CONNECTION { return; }\n",
        );
        assert!(!super::one_frame_one_doorman(&fixture.tree()).is_clean());

        // Each verdict the connection must keep asking for, dropped one at a time.
        for kept in ["admit", "poisoned", "peer_close"] {
            write_one_frame_one_doorman(&fixture);
            fixture.write(
                super::MUX_CONNECTION,
                &format!("let verdict = {kept}(self.role, lane);\n"),
            );
            assert!(
                !super::one_frame_one_doorman(&fixture.tree()).is_clean(),
                "the doors claim passed with only {kept}",
            );
        }

        // A bare tree has no admission module at all.
        let bare = Fixture::new("one-frame-one-doorman-bare");
        assert!(!super::one_frame_one_doorman(&bare.tree()).is_clean());
    }

    // -----------------------------------------------------------------------------------------
    // The seven `docs/59` splits, seeded the way Rust would write the drift.
    //
    // Every fixture below is `.rs` under `rust/slopdesk-host*`, snake_case, with the crate's own
    // handle held beside it — because a Swift pattern translated by hand would match none of it and
    // the rule would pass while guarding nothing.
    // -----------------------------------------------------------------------------------------

    /// A hostd shaped the way it is: the crate's handles held, no second copy beside any of them.
    fn hostd(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture
            .write(
                "rust/slopdesk-hostsession/src/shared.rs",
                "use slopdesk_muxsession::lifecycle::Lifecycle;\nstruct Shared {\n\x20   outbox: \
                 Outbox,\n\x20   payloads: BTreeMap<Slot, Queued>,\n\x20   by_id: BTreeMap<SubscriberId, \
                 Arc<Subscriber>>,\n\x20   fanout: Fanout,\n\x20   life: Lifecycle,\n\x20   folds: \
                 Mutex<Folds>,\n}\n",
            )
            .write(
                "rust/slopdesk-hostserver/src/route.rs",
                "let verdict = open_route::route(&facts);\n",
            )
            .write(
                "rust/slopdesk-hostsession/src/facts.rs",
                "truths.reestablish_head().chain(truths.reestablish_tail())\n",
            );
        fixture
    }

    #[test]
    fn a_second_registry_map_in_hostserver_is_caught() {
        let fixture = hostd("one-relation-one-table");
        assert!(super::one_relation_one_table(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostserver/src/host.rs",
            "    hook_pane_ids: HashMap<Uuid, PaneId>,\n",
        );
        assert!(!super::one_relation_one_table(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_outbound_order_in_hostsession_is_caught() {
        let fixture = hostd("outbound-frame-merge");
        assert!(super::the_outbound_frame_merges_once(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostsession/src/drain.rs",
            "    queued: Vec<Queued>,\n    next_slot: Slot,\n",
        );
        assert!(!super::the_outbound_frame_merges_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_member_cursor_kept_beside_the_roster_is_caught() {
        let fixture = hostd("subscriber-set-one-table");
        assert!(super::the_subscriber_set_is_one_table(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostsession/src/subscriber.rs",
            "    last_acked: u64,\n",
        );
        assert!(!super::the_subscriber_set_is_one_table(&fixture.tree()).is_clean());
    }

    #[test]
    fn one_of_the_eight_latch_locks_growing_back_is_caught() {
        let fixture = hostd("one-batch-one-pass-one-lock");
        assert!(super::one_batch_one_pass_one_lock(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostsession/src/facts.rs",
            "    title_lock: Mutex<Option<String>>,\n",
        );
        assert!(!super::one_batch_one_pass_one_lock(&fixture.tree()).is_clean());
    }

    /// The re-assert ORDER is the fold's, so what is seeded is hostd DROPPING one end of the ladder
    /// — the half that still compiles and still passes every content assertion.
    #[test]
    fn dropping_one_end_of_the_reassert_ladder_is_caught() {
        let fixture = hostd("one-batch-reassert");
        assert!(super::one_batch_one_pass_one_lock(&fixture.tree()).is_clean());

        // The tail dropped everywhere — the head still runs, the messages still arrive, and every
        // returning client's title is the one that goes missing.
        fixture.write(
            "rust/slopdesk-hostsession/src/facts.rs",
            "for entry in truths.reestablish_head() { out.push(entry); }\n",
        );
        assert!(!super::one_batch_one_pass_one_lock(&fixture.tree()).is_clean());
    }

    /// A tree where all three crates spell the live-edge sentinel the same way.
    fn sentinels(fixture: &Fixture) {
        for path in super::FROM_NOW_ON_SITES {
            fixture.write(path, "pub const FROM_NOW_ON: u64 = u64::MAX;\n");
        }
    }

    #[test]
    fn re_deriving_a_router_answer_in_hostserver_is_caught() {
        let fixture = hostd("one-open-one-route");
        sentinels(&fixture);
        assert!(super::one_open_one_route(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostserver/src/channel.rs",
            "let resume = offset.min(open.last_received_seq);\n",
        );
        assert!(!super::one_open_one_route(&fixture.tree()).is_clean());
    }

    /// The count-spellings half. Three crates, none importing another's, so a sentinel that moves
    /// in one is invisible to every compiler in the repo.
    #[test]
    fn a_live_edge_sentinel_that_moved_in_one_crate_only_is_caught() {
        let fixture = hostd("live-edge-drift");
        sentinels(&fixture);
        assert!(super::one_open_one_route(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-muxsession/src/lifecycle.rs",
            "pub const FROM_NOW_ON: u64 = u64::MAX - 1;\n",
        );
        assert!(!super::one_open_one_route(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_metadata_bound_and_an_optional_performer_are_caught() {
        let fixture = hostd("one-metadata-verb-one-performer");
        assert!(super::one_metadata_verb_one_performer(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostsession/src/metadata.rs",
            "    max_metadata_in_flight: usize,\n",
        );
        assert!(!super::one_metadata_verb_one_performer(&fixture.tree()).is_clean());

        // The other half: an optional return IS the shim saying "not my verb".
        let second = hostd("optional-performer");
        second.write(
            "rust/slopdesk-hostserver/src/pathaction.rs",
            "fn perform(&self, verb: Verb) -> Option<WireMessage> {\n",
        );
        assert!(!super::one_metadata_verb_one_performer(&second.tree()).is_clean());
    }

    #[test]
    fn a_lifecycle_flag_kept_beside_the_ladder_is_caught() {
        let fixture = hostd("one-arc-one-ladder");
        assert!(super::one_arc_one_ladder(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-hostsession/src/latches.rs",
            "    exit_sent: AtomicBool,\n",
        );
        assert!(!super::one_arc_one_ladder(&fixture.tree()).is_clean());
    }

    /// …and the ladder dropped outright, which is the failure the flags were a symptom of.
    #[test]
    fn dropping_the_lifecycle_handle_altogether_is_caught() {
        let fixture = Fixture::new("one-arc-no-ladder");
        fixture.write(
            "rust/slopdesk-hostsession/src/shared.rs",
            "struct Shared { detached: bool }\n",
        );
        assert!(!super::one_arc_one_ladder(&fixture.tree()).is_clean());
    }
}
