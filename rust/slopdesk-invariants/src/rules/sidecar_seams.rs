//! One decision per master, two lifecycles over five sidecars, and four shapes nobody may write
//! twice.
//!
//! Ported from the deleted `check-supervisor.sh`. What links these is the failure they all share:
//! two copies of one contract that agree today. The pair does not diverge on the change that
//! creates it — it diverges on the seventh channel, the next daemon, the one manager somebody edits
//! alone — so the moment to catch it is while there is still only one copy.

use crate::claim::{Claim, RUST, SWIFT, SWIFT_ROOTS, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// superd's pane map, which decides a master exactly once.
const REGISTRY: &str = "rust/slopdesk-superd/src/registry.rs";
/// The wire that carries the duplicate out.
const FRAME: &str = "rust/slopdesk-superd/src/frame.rs";
/// The two lifecycles the five sidecar faces share.
const LIFECYCLE: &str = "rust/slopdesk-hostserver/src/service.rs";
/// The five-line latch with three load-bearing details in it.
const LATCH: &str = "Sources/SlopDeskWorkspaceCore/Support/DeadlineLatch.swift";
/// Where a pasteboard becomes a clip, both directions, once.
const CLIENT_BOARD: &str = "Sources/SlopDeskWorkspaceCore/Terminal/ClientPasteboard.swift";
/// `WorkspaceCore`'s one sidecar encoder.
const SIDECAR_JSON: &str = "Sources/SlopDeskWorkspaceCore/Support/SidecarJSON.swift";
/// The one file that reads a client-side debug gate.
const DEBUG_TRACE: &str = "Sources/SlopDeskWorkspaceCore/Support/DebugTrace.swift";
/// The channel tag both sides send.
const VIDEO_CHANNEL: &str = "Sources/SlopDeskVideoProtocol/VideoChannel.swift";

/// A pane's master is decided once, and it is OWNED
///
/// superd used to answer `spawn` by inserting the pane and then asking the map for its master fd by
/// name, and the two steps are not one decision. The reaper removes a pane and drops its master the
/// instant the child dies, and a child like `exit 0` is usually already dead by the time the reply
/// is assembled — so the second lookup either found nothing (an `ok` reply carrying no descriptor,
/// which hostd reports as `missingDescriptor` for a child that really ran) or found a raw number
/// the reaper had closed and the kernel had reissued to something else, which hostd would have
/// adopted in silence.
///
/// Both windows close the same way: take the duplicate where the pane is decided, hand it back
/// OWNED, and let the wire BORROW it — see `docs/51` §2.3. Which is why the ban on `fn master_fd`
/// is as load-bearing as the three positive pins: the lookup is what races, so the lookup is what
/// may not exist, however carefully its next author guards it.
#[must_use]
pub fn a_master_crosses_owned(tree: &Tree) -> Report {
    /// The three spellings that say "decided where the pane is, handed back owned".
    const OWNED: &[&str] = &[
        r"Result<\(PaneRecord, OwnedFd\), RegistryError>",
        r"duplicate_master\(&spawned\.master\)",
        r"duplicate_master\(&pane\.master\)",
    ];

    let mut claims: Vec<Claim> = OWNED
        .iter()
        .map(|entry| {
            Claim::Matches {
                path: REGISTRY,
                pattern: entry,
                view: View::Code,
                message: "superd's registry no longer hands its caller an owned master duplicate — see \
                          docs/51 §2.3",
            }
        })
        .collect();
    claims.push(Claim::Lacks {
        path: REGISTRY,
        pattern: r"fn master_fd",
        view: View::Code,
        message: "superd's registry looks a master up by pane id again — that lookup races the reaper \
                  (docs/51 §2.3)",
    });
    claims.push(Claim::Matches {
        path: FRAME,
        pattern: r"descriptor: Option<BorrowedFd<'_>>",
        view: View::Code,
        message: "the frame takes a descriptor it cannot prove is still open — BorrowedFd is the proof",
    });
    check_all(tree, &claims)
}

/// One sidecar lifecycle per KIND, and five faces over the two
///
/// `HostServiceProcess` held the shape's prose — spawn with port 0, learn the bound port from the
/// child's own line, probe with a bounded loopback connect — and its production seams, but not the
/// code, so five managers each wrote it out. They had already drifted where nobody could see it:
/// `CodeServerManager`'s probe-and-latch wrote its updated record inside the `if due` block and the
/// other two wrote it after, and the dropd/inspectord parse accepted a `:0` announce that
/// androidd's rejected.
///
/// Both lifecycles live in `rust/slopdesk-hostserver/src/service.rs` since `docs/60` F.9 moved the
/// daemon: `ProbedPortService` (the OS picks the port, `ensure` never waits) and
/// `AnnouncedPortService` (hostd picks it, so the announce is WAITED for and VERIFIED). What stays
/// with each face is what the daemons genuinely disagree about — the socket name, the announce
/// marker, the argv, the env override, and whether a spawn that failed reads `unavailable` or
/// `starting`.
///
/// Both ends are Rust now, and the reason this rule did not retire with the language is that
/// nothing in the build graph stops a face from writing the shape out AGAIN. It would compile, and
/// it would drift the way the five Swift managers already had: `CodeServerManager`'s probe latch
/// wrote its updated record inside the `if due` block where the other two wrote it after, and the
/// dropd/inspectord parse accepted a `:0` announce that androidd's rejected.
///
/// So the ban is the whole rule, and it names the latch's own vocabulary — `last_probe`,
/// `spawn_generation`, a port scraped off a line by hand. Those three words appear in `service.rs`
/// and NOWHERE else in the host crates, which is what makes the ban a measurement rather than a
/// wish.
///
/// The Swift's third piece and its last arm both DIED in the port rather than moving.
/// `enum AnnouncedPort` dissolved into the private `Announced` record and `Boot`, which the
/// compiler sees inside the one crate that has them. And the "no second lock beside a
/// `ProbedPortService`" arm was answered differently by the port on purpose:
/// [`CodeServerManager`](slopdesk_hostserver::code::CodeServerManager) holds a `Mutex<Gates>` for
/// its four boot gates, which are not the spawn's critical section and were only ever under the
/// service's lock because Swift had one lock to give. Re-asserting it would ban the live code.
#[must_use]
pub fn two_sidecar_lifecycles_five_faces(tree: &Tree) -> Report {
    /// The two types the five faces share.
    const PIECES: &[&str] = &[
        r"pub struct ProbedPortService",
        r"pub struct AnnouncedPortService",
    ];

    let mut claims: Vec<Claim> = PIECES
        .iter()
        .map(|piece| {
            Claim::Matches {
                path: LIFECYCLE,
                pattern: piece,
                view: View::Code,
                message: "rust/slopdesk-hostserver/src/service.rs no longer holds one of its two lifecycles \
                          — the five faces share one of each",
            }
        })
        .collect();
    claims.push(Claim::NoneUnder {
        roots: HOSTD_CRATES,
        extensions: RUST,
        pattern: r"last_probe|spawn_generation|parse::<u16>",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[LIFECYCLE],
        message: "a sidecar face grew its own probe latch, spawn generation or port parse back ({files}) — \
                  the latch is ProbedPortService and the parse is slopdesk-sidecars' port_directly_after, \
                  once",
    });
    check_all(tree, &claims)
}

/// One re-armable deadline, armed by six callers
///
/// `DeadlineLatch` is five lines with three load-bearing details in them, and each reads as noise
/// until the one time it is missing: the cancel comes FIRST (a re-arm during a live drag otherwise
/// stacks one timer per layout pass), `Task.isCancelled` is checked AFTER the sleep (`try?`
/// swallows the cancellation throw, so a cancelled timer would run its body anyway), and the
/// caller's closure is `[weak self]`. Four models had it written out; a fifth must ask for the
/// latch instead.
///
/// The banned shape is narrow on purpose — a `Task` holding a SLEEP and then a cancellation check —
/// so a repeating loop (`while !Task.isCancelled { … await sleep }`) does not match it: that is a
/// different law with a different lifetime. It is a WINDOW rather than a line, which is why this is
/// a file-level ban with a multi-line pattern: the introducer and the guard are two lines that only
/// mean something together, and no single line carries the shape.
///
/// Scoped to the three targets that can SEE the latch. `SlopDeskVideoClient` holds one-shots of the
/// same shape and depends on nothing that could carry `DeadlineLatch` down to it, so pinning it
/// here would only demand an impossible import. The GUI video host held the same shape and is no
/// longer a Swift target at all — `docs/61` moved it to `rust/slopdesk-videohostd`, where a
/// re-armable deadline is a `tokio` task rather than this five-line type, so it is out of this
/// rule's reach in a second way as well.
///
/// The six arming sites are pinned positively for the reason every shared helper needs it: the
/// timer is shared, the state is not, and a caller that quietly grows its own back passes the ban
/// above by spelling the sleep differently.
#[must_use]
pub fn one_re_armable_deadline(tree: &Tree) -> Report {
    /// Each caller and the latch it arms.
    const SHARES: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift",
            r"reflowDeadline\.arm",
        ),
        (
            "Sources/SlopDeskWorkspaceCore/Video/RemoteWindowModel.swift",
            r"reflowDeadline\.arm",
        ),
        (
            "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift",
            r"noticeClear\.arm",
        ),
        (
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift",
            r"noticeClear\.arm",
        ),
        (
            "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift",
            r"reattempt\.arm",
        ),
        (
            "Sources/SlopDeskClientCore/Pane/PaneDragCoordinator.swift",
            r"springLoadTask\.arm",
        ),
    ];

    let mut claims = vec![Claim::NoFileUnder {
        roots: &[
            "Sources/SlopDeskPhoneUI/",
            "Sources/SlopDeskClientCore/",
            "Sources/SlopDeskWorkspaceCore/",
        ],
        extensions: &["swift"],
        // The `grep -A2` window, as one pattern: the introducer, then the guard on that line or
        // within the two under it.
        //
        // RAW, and this is the one place in the crate where that is the careful choice rather than
        // the lazy one. `View::Code` DELETES a comment line rather than blanking it, so a window
        // read through it is measured in surviving lines, not source lines — and the live tree has
        // exactly that file: a `Task { [weak self] in`, a comment, a sleep, and the guard on the
        // THIRD line under the introducer. Stripping the comment pulls the guard into the window and
        // fails a file that is correct. A window is a fact about the source, so it is read there.
        pattern: r"Task \{ \[weak self\] in[^\n]*\n?[^\n]*\n?[^\n]*guard !Task\.isCancelled",
        rescued_by: None,
        view: View::Raw,
        exempt: &[LATCH],
        message: "a cancel-and-re-arm deadline grew back ({files}) — DeadlineLatch.arm owns the three \
                  details",
    }];
    for (caller, latch) in SHARES {
        claims.push(Claim::Matches {
            path: caller,
            pattern: latch,
            view: View::Code,
            message: "a caller stopped arming a DeadlineLatch — the timer is shared, the state is not",
        });
    }
    check_all(tree, &claims)
}

/// One pasteboard↔clip conversion, read by both ends of the wire
///
/// Clipboard sync's two ends are two halves of ONE wire contract, so the conversion is one file.
/// They had already drifted once — the client refuses to push a CONCEALED clip and the host did not
/// refuse to ship one back — which is a named parameter now rather than two bodies.
///
/// The two banned spellings are the ones a second conversion cannot avoid writing: the TIFF type it
/// must ask the pasteboard for, and the byte ceiling it must clamp against.
///
/// **BOTH ends are Rust now, and the rule was re-aimed rather than dropped.** The four rules are
/// `rust/slopdesk-clipboard`, a crate the host end and the client end BOTH read; the Swift
/// `PasteboardClip` that used to be the client's half is deleted, and what is left on that side is
/// `ClientPasteboard`, a face over the `slopdesk_clipboard_*` doors. So the claims fail differently
/// and are stated separately: a fold that stopped naming the codec is a drift against the wire, a
/// performer or a face that stopped naming the fold is a drift against the other end, and a Swift
/// file that spells a flavour or a UTI at all is the SECOND conversion growing back in the one
/// language that no longer has a first.
#[must_use]
pub fn one_pasteboard_clip(tree: &Tree) -> Report {
    /// The fold both ends read, which takes the record and the cap off the codec they encode
    /// through.
    const FOLD: &str = "rust/slopdesk-clipboard/src/lib.rs";
    /// The host's end, which owns the two verbs and the echo guard and asks [`FOLD`] for the rest.
    const HOST_CLIP: &str = "rust/slopdesk-hostserver/src/clipsync.rs";
    /// The client's end and the two directions it must still get through the board face rather
    /// than from a conversion of its own.
    const SHARES: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift",
            r"board\.clip\(skippingConcealed:",
        ),
        (
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift",
            r"board\.apply\(",
        ),
    ];

    let mut claims = vec![
        // `Sources` alone, for [`crate::claim::SWIFT_ROOTS`]'s third reason, and the message below
        // already says why: a fixture is meant to reach these through the door, and
        // `ClipboardSyncEngineTests` does — it bounds a payload with
        // `MetadataCodec.maxClipboardContentBytes` rather than re-typing the number, and it names
        // `.tiff` only to read the board BACK and assert the AppKit twin landed. Reading a flavour
        // to check it shipped is this rule's enforcement; converting into one is the ban. The view
        // cannot tell those apart, and the assertion has no other spelling.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"forType: \.tiff|MetadataCodec\.maxClipboardContentBytes|org\.nspasteboard\.ConcealedType|public\.file-url",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a second pasteboard↔clip conversion grew back ({files}) — the flavour, the cap and \
                      the two refused UTIs are rust/slopdesk-clipboard's, and Swift asks the \
                      slopdesk_clipboard_* doors for all four (ClientPasteboard.concealedTypeIdentifier is \
                      how a fixture SEEDS one without re-typing it)",
        },
        // The host may not re-type the ceiling either. The TIFF half is not banned in Rust: asking
        // for the flavour is `slopdesk-apple-pasteboard`'s whole job, and the host reaches it
        // through that crate rather than beside it.
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r"12 \* 1024 \* 1024",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} re-typed the clipboard ceiling — MAX_CLIPBOARD_CONTENT_BYTES is the codec's, \
                      and a host that clamps lower ships a clip the client will accept whole",
        },
        // The fold is outside `HOSTD_CRATES` and must not re-type the ceiling either — it is the
        // ONE place the cap is checked, so a literal here is the drift the ban above prevents in
        // the crate that used to hold these rules.
        Claim::NoneUnder {
            roots: &["rust/slopdesk-clipboard"],
            extensions: RUST,
            pattern: r"12 \* 1024 \* 1024",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} re-typed the clipboard ceiling — MAX_CLIPBOARD_CONTENT_BYTES is the codec's, \
                      and the fold is the one place it is checked for BOTH ends",
        },
        Claim::Mentions {
            path: FOLD,
            names: &["ClipboardClip", "MAX_CLIPBOARD_CONTENT_BYTES"],
            message: "rust/slopdesk-clipboard/src/lib.rs no longer takes {entry} from slopdesk-wire — the \
                      two ends agree by sharing the codec, not by luck",
        },
        Claim::Mentions {
            path: CLIENT_BOARD,
            names: &["slopdesk_clipboard_read", "slopdesk_clipboard_write"],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/ClientPasteboard.swift no longer calls {entry} \
                      — the client's board is a FACE over the doors, and Swift that reads or writes a clip \
                      itself is the deleted PasteboardClip growing back",
        },
        Claim::Mentions {
            path: HOST_CLIP,
            names: &["slopdesk_clipboard"],
            message: "rust/slopdesk-hostserver/src/clipsync.rs no longer names {entry} — the host end keeps \
                      the two verbs and the echo guard, and asks the shared fold for the four rules rather \
                      than re-deciding them where the client cannot see",
        },
    ];
    for (end, direction) in SHARES {
        claims.push(Claim::Matches {
            path: end,
            pattern: direction,
            view: View::Code,
            message: "a clipboard end stopped reaching the board through ClientPasteboard — the two ends \
                      agree by sharing the fold, not by luck",
        });
    }
    check_all(tree, &claims)
}

/// Every JSON sidecar sorts its keys, and `WorkspaceCore` has one encoder
///
/// Not tidiness: `docs/22` §8's round-trip tests compare BYTES, and Swift's default key order is
/// not stable across runs, so an encoder that omits `.sortedKeys` writes a perfectly good file and
/// turns a passing test into one that fails on a Tuesday.
///
/// A CONDITIONAL check rather than a ban, because a `JSONEncoder` is ordinary Foundation used in
/// plenty of places that never touch disk: the file that names `outputFormatting` is the one that
/// has to name `.sortedKeys` too, and a file that names neither is not this rule's business.
///
/// The second arm is the narrower one it implies inside `WorkspaceCore`, where four stores wrote
/// sidecars: there, one encoder answers all of them, so `outputFormatting` outside `SidecarJSON` is
/// a second encoder no matter how it is spelled.
#[must_use]
pub fn one_sidecar_encoder(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::NoFileUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: r"outputFormatting",
            rescued_by: Some(r"\.sortedKeys"),
            view: View::Code,
            exempt: &[],
            message: "a sidecar encoder set outputFormatting without .sortedKeys ({files}) — docs/22 §8 \
                      compares bytes",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskWorkspaceCore/"],
            extensions: &["swift"],
            pattern: r"outputFormatting",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[SIDECAR_JSON],
            message: "a second sidecar encoder grew back in WorkspaceCore ({files}) — SidecarJSON.encoder \
                      is the one",
        },
    ])
}

/// The two client-side debug gates are read in ONE file
///
/// Not tidiness either. `SLOPDESK_BLOCKS_DEBUG` traces a block jump END-TO-END across three files
/// (`[blocks]` issue → `[flash]` arm/settle → `[flash]` paint), so a reader that spells the gate
/// itself is one that can spell it `!= nil` while the others say `== "1"` — and then half the trace
/// appears and the missing half reads as "that step never ran". One of the three had already
/// drifted to its own copy of gate + tag when this check was written.
///
/// Reads CODE, which is load-bearing: five of the seven surviving mentions are doc comments that
/// cite the gate to explain what the file does behind it, and a ban that fired on those would be a
/// ban against documenting the flag.
#[must_use]
pub fn one_debug_gate_spelling(tree: &Tree) -> Report {
    // Shipping only, for [`crate::claim::SWIFT_ROOTS`]'s third reason. The ban is about a TRACE
    // staying coherent across three readers, which is a property of the running client; a test that
    // sets the gate to prove `DebugTrace` reads it has to spell the name, and that is this rule's
    // own enforcement rather than a fourth reader. The same fragility the `View::Code` note above
    // records — most mentions are prose about the flag — is worse in a suite, not better.
    check_all(tree, &[Claim::NoneUnder {
        roots: &["Sources"],
        extensions: &["swift"],
        pattern: r"SLOPDESK_BLOCKS_DEBUG|SLOPDESK_WORKSPACE_DEBUG",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[DEBUG_TRACE],
        message: "a debug gate is read outside DebugTrace ({files}) — one gate, one spelling, one tag \
                  grammar",
    }])
}

/// The channel tag is ONE enum, and its raw values are the wire
///
/// The host and the client each used to declare their own copy, byte-identical, each with a doc
/// paragraph explaining that the wire contract — not a Swift type — was the agreement. True of the
/// modules (the client must not depend on the macOS-only host), false of `SlopDeskVideoProtocol`,
/// which both already depend on. Two declarations of one contract is the `process::basename` shape
/// (`docs/55` §6): they agree until a seventh channel lands on one side.
///
/// The numbers are pinned as well as the type, because they ARE the wire tags on every media-socket
/// datagram. Renumbering one re-routes a channel on the far side with nothing failing to compile —
/// no test can catch it that does not already know the intended number, which is what this list is.
#[must_use]
pub fn one_channel_tag(tree: &Tree) -> Report {
    /// Each tag and the number the wire gives it (doc 17 §3.3).
    const TAGS: &[&str] = &[
        "case control = 0",
        "case video = 1",
        "case geometry = 2",
        "case cursor = 3",
        "case input = 4",
        "case recovery = 5",
        "case audio = 6",
    ];

    check_all(tree, &[
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: r"enum VideoChannel",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[VIDEO_CHANNEL],
            message: "a second VideoChannel grew back ({files}) — SlopDeskVideoProtocol owns the tag both \
                      sides send",
        },
        Claim::Mentions {
            path: VIDEO_CHANNEL,
            names: TAGS,
            message: "VideoChannel lost '{entry}' — the raw values are the wire tags (doc 17 §3.3)",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A registry that decides once and a frame that borrows.
    fn superd(fixture: &Fixture) {
        fixture
            .write(
                super::REGISTRY,
                "fn spawn() -> Result<(PaneRecord, OwnedFd), RegistryError> {\nlet d = \
                 duplicate_master(&spawned.master)?;\nlet a = duplicate_master(&pane.master)?;\n}\n",
            )
            .write(super::FRAME, "fn send(descriptor: Option<BorrowedFd<'_>>) {}\n");
    }

    #[test]
    fn a_master_looked_up_by_name_is_red() {
        let fixture = Fixture::new("seams-master");
        superd(&fixture);
        assert!(super::a_master_crosses_owned(&fixture.tree()).is_clean());

        // The lookup is what races the reaper, so the lookup is what may not exist.
        fixture.append(
            super::REGISTRY,
            "fn master_fd(&self, pane: &str) -> RawFd { 0 }\n",
        );
        assert!(!super::a_master_crosses_owned(&fixture.tree()).is_clean());

        // And a raw number on the wire is one nobody can prove is still open.
        superd(&fixture);
        fixture.write(super::FRAME, "fn send(descriptor: Option<RawFd>) {}\n");
        assert!(!super::a_master_crosses_owned(&fixture.tree()).is_clean());
    }

    /// The two lifecycles, and three faces holding a service rather than a latch of their own.
    fn lifecycles(fixture: &Fixture) {
        fixture.write(
            super::LIFECYCLE,
            "pub struct ProbedPortService {\n    probe: ReadinessProbe,\n}\nstruct Instance {\n    \
             last_probe: Option<Instant>,\n}\nstruct Live {\n    spawn_generation: u64,\n}\npub struct \
             AnnouncedPortService {\n    deadline: Duration,\n}\n",
        );
        for face in [
            "rust/slopdesk-hostserver/src/ensure.rs",
            "rust/slopdesk-hostserver/src/code.rs",
            "rust/slopdesk-hostd/src/sidecar.rs",
        ] {
            fixture.write(
                face,
                "let service = Arc::new(ProbedPortService::new(probe, interval));\n",
            );
        }
    }

    #[test]
    fn a_face_that_rewrites_the_lifecycle_is_red() {
        let fixture = Fixture::new("seams-lifecycle");
        lifecycles(&fixture);
        assert!(super::two_sidecar_lifecycles_five_faces(&fixture.tree()).is_clean());

        // The latch written out again, in a face one crate over from the one that owns it.
        fixture.write(
            "rust/slopdesk-hostd/src/sidecar.rs",
            "struct Profile {\n    spawn_generation: u64,\n}\n",
        );
        assert!(!super::two_sidecar_lifecycles_five_faces(&fixture.tree()).is_clean());

        // And the port scraped off the line by hand, which is the half that had already drifted:
        // the dropd/inspectord parse accepted a `:0` announce that androidd's rejected.
        lifecycles(&fixture);
        fixture.write(
            "rust/slopdesk-hostd/src/services.rs",
            "let port = line.rsplit(':').next()?.parse::<u16>().ok()?;\n",
        );
        assert!(!super::two_sidecar_lifecycles_five_faces(&fixture.tree()).is_clean());

        // And the lifecycle itself, gone.
        lifecycles(&fixture);
        fixture.write(super::LIFECYCLE, "pub struct ProbedPortService {}\n");
        assert!(!super::two_sidecar_lifecycles_five_faces(&fixture.tree()).is_clean());
    }

    /// The latch owning the shape, and the six callers arming it.
    fn latches(fixture: &Fixture) {
        fixture.write(
            super::LATCH,
            "func arm() {\ntask?.cancel()\ntask = Task { [weak self] in\ntry? await Task.sleep(for: \
             delay)\nguard !Task.isCancelled else { return }\nbody() }\n}\n",
        );
        for (caller, latch) in [
            (
                "Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift",
                "reflowDeadline.arm(after: .milliseconds(16))",
            ),
            (
                "Sources/SlopDeskWorkspaceCore/Video/RemoteWindowModel.swift",
                "reflowDeadline.arm(after: .milliseconds(16))",
            ),
            (
                "Sources/SlopDeskDevicePanels/Android/AndroidSidebarModel.swift",
                "noticeClear.arm(after: .seconds(4))\nreattempt.arm(after: .seconds(1))",
            ),
            (
                "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift",
                "noticeClear.arm(after: .seconds(4))",
            ),
            (
                "Sources/SlopDeskClientCore/Pane/PaneDragCoordinator.swift",
                "springLoadTask.arm(after: .milliseconds(600))",
            ),
        ] {
            fixture.write(caller, &format!("{latch}\n"));
        }
    }

    #[test]
    fn a_hand_rolled_re_arm_is_red() {
        let fixture = Fixture::new("seams-latch");
        latches(&fixture);
        assert!(super::one_re_armable_deadline(&fixture.tree()).is_clean());

        // The window, written out again by a fifth model.
        fixture.write(
            "Sources/SlopDeskClientCore/Pane/PaneDragCoordinator.swift",
            "springLoadTask.arm(after: .milliseconds(600))\ntask = Task { [weak self] in\ntry? await \
             Task.sleep(for: delay)\nguard !Task.isCancelled else { return } }\n",
        );
        assert!(!super::one_re_armable_deadline(&fixture.tree()).is_clean());

        // A repeating loop is a DIFFERENT law with a different lifetime, and stays clean.
        latches(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Video/RemoteWindowModel.swift",
            "reflowDeadline.arm(after: .milliseconds(16))\nTask { [weak self] in\nwhile !Task.isCancelled \
             {\ntry? await Task.sleep(for: tick)\npoll() } }\n",
        );
        assert!(super::one_re_armable_deadline(&fixture.tree()).is_clean());

        // And a caller that stopped sharing the timer.
        latches(&fixture);
        fixture.write(
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorSidebarModel.swift",
            "// the notice clears itself now\n",
        );
        assert!(!super::one_re_armable_deadline(&fixture.tree()).is_clean());
    }

    /// One conversion, called by both ends — one Swift, one Rust.
    fn clipboard(fixture: &Fixture) {
        fixture
            .write(
                super::CLIENT_BOARD,
                "slopdesk_clipboard_read(name, len, true, out, cap)\nslopdesk_clipboard_write(name, len, \
                 kind, bytes, len)\n",
            )
            .write(
                "rust/slopdesk-clipboard/src/lib.rs",
                "use slopdesk_wire::metadata::codec::{ClipboardClip, MAX_CLIPBOARD_CONTENT_BYTES};\n",
            )
            .write(
                "rust/slopdesk-hostserver/src/clipsync.rs",
                "use slopdesk_clipboard::{Pasteboard, apply_clip, shippable_clip};\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift",
                "board.clip(skippingConcealed: true)\nboard.apply(clip)\n",
            );
    }

    #[test]
    fn a_second_clipboard_conversion_is_red() {
        let fixture = Fixture::new("seams-clip");
        clipboard(&fixture);
        assert!(super::one_pasteboard_clip(&fixture.tree()).is_clean());

        clipboard(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift",
            "board.clip(skippingConcealed: true)\nboard.apply(clip)\nlet tiff = board.data(forType: .tiff)\n",
        );
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        // The UTI re-typed in Swift, which is the seam this port opened: the refusals are the
        // fold's, so a literal here is a marker that keeps passing after the fold stops
        // recognising it.
        clipboard(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift",
            "board.clip(skippingConcealed: true)\nboard.apply(clip)\nlet t = \
             \"org.nspasteboard.ConcealedType\"\n",
        );
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        // The FACE going back to the framework instead of the doors — green under every ban,
        // because AppKit spelled from Swift names none of the patterns above.
        clipboard(&fixture);
        fixture.write(super::CLIENT_BOARD, "NSPasteboard.general.clearContents()\n");
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        // The host re-typing the ceiling rather than importing it — the skew that is silent in the
        // worst direction, since a host clamping lower ships a clip nobody rejects.
        clipboard(&fixture);
        fixture.write(
            "rust/slopdesk-hostd/src/clip.rs",
            "const CAP: usize = 12 * 1024 * 1024;\n",
        );
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        // The FOLD re-typing it is the same skew one crate over, and outside `HOSTD_CRATES` the
        // ban above cannot reach it — which is why it has a claim of its own.
        clipboard(&fixture);
        fixture.write(
            "rust/slopdesk-clipboard/src/lib.rs",
            "use slopdesk_wire::metadata::codec::ClipboardClip;\nconst CAP: usize = 12 * 1024 * 1024;\n",
        );
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        // And an end that stopped sharing, which the bans above cannot see.
        clipboard(&fixture);
        fixture.write("rust/slopdesk-clipboard/src/lib.rs", "");
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        // The host keeping its own copy of the four rules instead of asking the fold: green under
        // every ban here, because a second opinion spelled in Rust names neither `.tiff` nor the
        // literal — it just quietly disagrees with the client.
        clipboard(&fixture);
        fixture.write(
            "rust/slopdesk-hostserver/src/clipsync.rs",
            "fn shippable(board: &B) -> Option<ClipboardClip> { board.png().map(Into::into) }\n",
        );
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());

        clipboard(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/ClipboardSyncEngine.swift",
            "board.clip(skippingConcealed: true)\n",
        );
        assert!(!super::one_pasteboard_clip(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_encoder_without_sorted_keys_is_red() {
        let fixture = Fixture::new("seams-encoder");
        fixture
            .write(
                super::SIDECAR_JSON,
                "encoder.outputFormatting = [.prettyPrinted, .sortedKeys]\n",
            )
            // The second encoder in the tree, since `docs/61` deleted the parking sidecar's: the
            // env bridge's, which writes the settings sidecar `slopdesk config` reads back.
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift",
                "encoder.outputFormatting = [.sortedKeys]\n",
            );
        assert!(super::one_sidecar_encoder(&fixture.tree()).is_clean());

        // The file that names outputFormatting is the one that has to name .sortedKeys too.
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift",
            "encoder.outputFormatting = [.prettyPrinted]\n",
        );
        assert!(!super::one_sidecar_encoder(&fixture.tree()).is_clean());

        // And a second encoder inside WorkspaceCore, where one answers all four stores.
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift",
            "encoder.outputFormatting = [.sortedKeys]\n",
        );
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/BlockStore.swift",
            "encoder.outputFormatting = [.sortedKeys]\n",
        );
        assert!(!super::one_sidecar_encoder(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_gate_read_outside_debug_trace_is_red() {
        let fixture = Fixture::new("seams-gates");
        fixture
            .write(
                super::DEBUG_TRACE,
                "let blocks = env[\"SLOPDESK_BLOCKS_DEBUG\"] == \"1\"\nlet workspace = \
                 env[\"SLOPDESK_WORKSPACE_DEBUG\"] == \"1\"\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Pane/MacPromptJumpFlashOverlay.swift",
                "/// gated by `SLOPDESK_BLOCKS_DEBUG == \"1\"` — the paint end.\nguard DebugTrace.blocks \
                 else { return }\n",
            );
        // A doc comment that CITES the gate is not a second reader of it.
        assert!(super::one_debug_gate_spelling(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskMacUI/Pane/MacPromptJumpFlashOverlay.swift",
            "guard env[\"SLOPDESK_BLOCKS_DEBUG\"] != nil else { return }\n",
        );
        assert!(!super::one_debug_gate_spelling(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_channel_tag_is_red() {
        let fixture = Fixture::new("seams-channel");
        fixture.write(
            super::VIDEO_CHANNEL,
            "public enum VideoChannel: UInt8 {\ncase control = 0\ncase video = 1\ncase geometry = 2\ncase \
             cursor = 3\ncase input = 4\ncase recovery = 5\ncase audio = 6\n}\n",
        );
        assert!(super::one_channel_tag(&fixture.tree()).is_clean());

        // Renumbering re-routes a channel on the far side with nothing failing to compile.
        fixture.write(
            super::VIDEO_CHANNEL,
            "public enum VideoChannel: UInt8 {\ncase control = 0\ncase video = 1\ncase geometry = 2\ncase \
             cursor = 3\ncase input = 4\ncase audio = 5\ncase recovery = 6\n}\n",
        );
        assert!(!super::one_channel_tag(&fixture.tree()).is_clean());

        // And the byte-identical copy that agrees until a seventh channel lands on one side.
        fixture.write(
            super::VIDEO_CHANNEL,
            "public enum VideoChannel: UInt8 {\ncase control = 0\ncase video = 1\ncase geometry = 2\ncase \
             cursor = 3\ncase input = 4\ncase recovery = 5\ncase audio = 6\n}\n",
        );
        // Seeded in the CLIENT since `docs/61`. The host's copy is what the rule was written
        // against, and it went with the Swift host — but the client's was the other half of that
        // pair, it is still Swift, and it still depends on SlopDeskVideoProtocol, so it is where a
        // byte-identical redeclaration can be written today rather than where one used to be.
        fixture.write(
            "Sources/SlopDeskVideoClient/ClientChannels.swift",
            "enum VideoChannel: UInt8 { case control = 0 }\n",
        );
        assert!(!super::one_channel_tag(&fixture.tree()).is_clean());
    }
}
