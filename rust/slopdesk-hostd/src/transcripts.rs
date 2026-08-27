//! hostd's half of disk scrollback: the POLICY, and what a restored transcript is rendered into.
//!
//! ## The file is superd's, and always was
//! Nothing here writes a byte of a journal. superd owns `read` on every PTY master, so superd
//! numbers the stream, and the daemon that numbers a stream is the one that persists it
//! (`docs/DECISIONS.md`, stage 27). What crosses to superd from here is policy — the directory, the
//! per-file cap, the sweep bounds — and what comes back is a path and a geometry.
//!
//! ## What is left here is every decision
//! Where journals are filed, how big one may get, whether a pane has one at all, when one is
//! deleted, how long an orphan lives — and, decisively, what the bytes MEAN. Turning superd's path
//! and geometry into a preamble a fresh shell can be given is this type's job.
//!
//! ## Two ways to render, and the geometry decides
//! With the prior life's PTY size available the raw bytes are rendered ONCE into a plain transcript
//! — O(final state) to paint, mode-free by construction, and screend's to compose. Without it (an
//! older journal, a pane that never resized past a failed sidecar write, the composer switched off)
//! the distilled byte history is used instead, with a mode-sanitizing suffix appended: the prior
//! life may have ended inside an alt-screen TUI with mouse reporting on and the cursor hidden, and
//! replaying that verbatim into a FRESH terminal wedges the pane before its first prompt.
//!
//! ## The restore chain is the ring's, not a second one
//! [`slopdesk_sanitize::sanitize`] is the same function the in-memory ring's cold replay runs, with
//! ONE option flipped: `reassert_input_modes` is false here. The ring fronts a LIVE session that
//! may still be inside a TUI; a journal fronts a shell that was forked seconds ago and has no modes
//! to keep. That single bool is the whole difference between the two replay paths, which is why it
//! is a parameter rather than a second chain.

use std::fs;
use std::sync::Arc;

use slopdesk_hostserver::{Restored, Transcripts};
use slopdesk_muxsession::open_route::{SurvivorResume, survivor_resume};
use slopdesk_muxsession::registry::Uuid;
use slopdesk_sanitize::Options;
use slopdesk_screenclient::client::ScreenClient;
use slopdesk_superclient::client::SupervisorClient;
use slopdesk_superwire::protocol::JournalSpawn;
use slopdesk_wire::replay::ReplayBuffer;

/// How old an orphan may get before a sweep unlinks it.
///
/// Policy, so it crosses the socket on every sweep rather than being read from an environment
/// superd would have to be restarted to see.
const SWEEP_MAX_AGE_SECONDS: u64 = 14 * 24 * 3600;

/// How many of the newest transcripts survive a sweep regardless of age. See
/// [`SWEEP_MAX_AGE_SECONDS`].
const SWEEP_KEEP_NEWEST: usize = 256;

/// hostd's disk-scrollback policy, and the two daemons it asks to enact it.
#[derive(Debug)]
pub struct DiskTranscripts {
    /// Where superd files journals. hostd's choice; superd creates the directory and names the
    /// files inside it.
    directory: String,
    /// Per-file byte cap, handed to superd at spawn.
    byte_cap: usize,
    /// Whether pass 5 — the B→C line-editor collapse — runs on a restore. The ONE remaining opt-out
    /// of seven passes.
    distill: bool,
    /// screend, when the state-transfer composer is on. `None` keeps the distilled-bytes path for
    /// every restore, which is what `SLOPDESK_SCROLLBACK_SNAPSHOT=0` asks for.
    composer: Option<Arc<ScreenClient>>,
    /// superd. Every effect this type has on a file goes through it.
    supervisor: Arc<SupervisorClient>,
}

impl DiskTranscripts {
    /// The production policy, or `None` when disk persistence is off.
    ///
    /// Gates, both default-ON and both read with the `!= "0"` idiom the rest of the host uses:
    /// - `SLOPDESK_SCROLLBACK_PERSIST` — the master scrollback gate, which also governs the
    ///   in-memory ring.
    /// - `SLOPDESK_SCROLLBACK_DISK` — the disk-specific kill switch, so the journal can be turned
    ///   off without losing the warm-resume ring.
    ///
    /// Cap: `SLOPDESK_SCROLLBACK_BYTES`, the same variable the ring reads, because a journal larger
    /// than the ring that fronts it is bytes nobody will ever replay. Location:
    /// `<Application Support>/SlopDesk/scrollback/`, overridable with `SLOPDESK_SCROLLBACK_DIR` —
    /// or wholesale by the app-support override, which moves the container this sits inside.
    ///
    /// One of those two is REQUIRED of any daemon an automation run starts, and `HOME` is neither:
    /// a sweep unlinks everything past the newest 256 in whatever directory it resolves.
    #[must_use]
    pub fn from_environment(
        supervisor: &Arc<SupervisorClient>,
        composer: Option<Arc<ScreenClient>>,
    ) -> Option<Self> {
        if gate_off("SLOPDESK_SCROLLBACK_PERSIST") || gate_off("SLOPDESK_SCROLLBACK_DISK") {
            return None;
        }
        let directory = match std::env::var("SLOPDESK_SCROLLBACK_DIR") {
            Ok(override_dir) if !override_dir.is_empty() => override_dir,
            _ => {
                slopdesk_hostlaunch::record::app_support_dir()?
                    .join("scrollback")
                    .to_str()?
                    .to_owned()
            },
        };
        let byte_cap = match std::env::var("SLOPDESK_SCROLLBACK_BYTES") {
            Ok(raw) => raw.parse().ok()?,
            Err(_) => ReplayBuffer::DEFAULT_SCROLLBACK_BYTES,
        };
        // A zero cap is "keep nothing", which is the disk gate said a third way. Answering `None`
        // rather than asking superd to journal into a zero-byte file keeps ONE representation of
        // "off" rather than two that behave differently on restore.
        if byte_cap == 0 {
            return None;
        }
        Some(Self {
            directory,
            byte_cap,
            distill: !gate_off("SLOPDESK_SCROLLBACK_DISTILL"),
            composer: composer.filter(|_| !gate_off("SLOPDESK_SCROLLBACK_SNAPSHOT")),
            supervisor: Arc::clone(supervisor),
        })
    }

    /// The `spawn` payload that asks superd to journal a pane, or `None` for one nobody would ever
    /// restore.
    ///
    /// A panel backend has no client-owned session id and therefore no transcript with a future; a
    /// journal for it would only ever be swept.
    #[must_use]
    pub fn spawn_request(&self, session_id: &str) -> Option<JournalSpawn> {
        if session_id.is_empty() {
            return None;
        }
        Some(JournalSpawn {
            directory: self.directory.clone(),
            cap_bytes: self.byte_cap,
        })
    }

    /// Bounds the orphans.
    ///
    /// hostd sets the age and the count; superd knows which files a live pane is still writing,
    /// which is the one thing a sweep must not get wrong.
    pub fn sweep(&self) {
        self.supervisor
            .journal_sweep(&self.directory, SWEEP_MAX_AGE_SECONDS, SWEEP_KEEP_NEWEST);
    }

    /// What superd knows about a session's transcript: how much is on disk, at what geometry, and
    /// how much of a LIVE pane's stream it already holds.
    fn info(&self, session: Uuid) -> Option<slopdesk_superwire::protocol::JournalReply> {
        let text = slopdesk_ids::uuid_text(session);
        self.supervisor
            .journal_info(&self.directory, &text)
            .ok()
            .flatten()
    }
}

/// Whether a default-ON `SLOPDESK_*` gate was turned off.
///
/// `!= "0"` rather than a truthiness parse, because that is the idiom every other host gate uses
/// and a variable that read `false` here and `true` two files away would be worse than either.
fn gate_off(name: &str) -> bool {
    std::env::var(name).is_ok_and(|value| value == "0")
}

impl Transcripts for DiskTranscripts {
    /// Removes a session's transcript — the deliberate end of a pane ONLY.
    ///
    /// Every other end (a link drop, a TTL eviction, a daemon stop) keeps the file: that is the
    /// feature. Routed through superd rather than unlinked here because superd may still hold the
    /// file open, and on POSIX an unlink under an open writer is not an error — it is a pane
    /// journaling the rest of its life into an inode nobody can open again.
    fn delete(&self, session: Uuid) {
        let text = slopdesk_ids::uuid_text(session);
        self.supervisor.journal_delete(&self.directory, &text);
    }

    /// The preamble a fresh shell is handed, rendered from what superd has on disk.
    ///
    /// `None` for a journal that is absent, unreadable, empty, or that nothing survives the
    /// transform of — all four mean "nothing to restore", and the caller starts the pane clean.
    fn restore(&self, session: Uuid) -> Option<Restored> {
        let info = self.info(session)?;
        if info.bytes == 0 {
            return None;
        }
        // Read here rather than over the socket: superd answered a PATH precisely so a multi-megabyte
        // transcript never crosses an `AF_UNIX` connection to be handed straight to a renderer.
        let raw = fs::read(&info.path).ok()?;
        if raw.is_empty() {
            return None;
        }
        if let Some(composer) = self.composer.as_ref()
            && info.rows > 0
            && info.cols > 0
            && let Ok(transcript) = composer.transcript(&raw, usize::from(info.rows), usize::from(info.cols))
            && !transcript.is_empty()
        {
            return Some(Restored {
                bytes: transcript,
                snapshot_composed: true,
            });
        }
        // The distilled path, and the reason it is a fallback rather than an error: a composer that
        // is off, a screend that is not up and a journal whose geometry sidecar never landed are
        // three different causes with one right answer, which is the history the user still wants.
        let mut bytes = slopdesk_sanitize::sanitize(&raw, Options {
            reassert_input_modes: false,
            distill: self.distill,
        });
        bytes.extend_from_slice(&slopdesk_sanitize::inputmode::reset_suffix());
        Some(Restored {
            bytes,
            snapshot_composed: false,
        })
    }

    /// Where an adopted pane's supervised stream resumes, and whether that had to be guessed.
    ///
    /// The fold is [`survivor_resume`]'s and the two numbers are superd's; this is the ASK. A
    /// session with no journal at all resumes from 0, which is right for every id with no history.
    fn position(&self, session: Uuid) -> SurvivorResume {
        self.info(session).map_or_else(
            || survivor_resume(0, None),
            |info| survivor_resume(info.bytes, info.head),
        )
    }
}
