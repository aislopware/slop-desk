//! A panel backend held by superd instead of by hostd — the port of
//! `SupervisedServiceProcess.swift`.
//!
//! `code-server`, `baguette serve`. superd forks and keeps them, so a hostd rebuild no longer costs
//! the user a multi-second workbench reboot: hostd's stop RELINQUISHES these rather than
//! terminating them, and the next hostd adopts what it finds.
//!
//! ## Held on a PTY, deliberately
//! superd's one spawn primitive is `openpty` + `fork` + `execve`, and it stays that way. Both
//! services were checked on a real terminal before the Swift was written: neither colourises,
//! neither changes its announce line, and the only difference in the stream is `\r\n` — which
//! [`LineAssembler`] strips. Teaching superd a second, pipe-flavoured spawn would mean a second
//! pre-exec window beside the disassembly-pinned one, to buy a carriage return.
//!
//! ## Spawn-or-adopt, by a STABLE pane id
//! The id is `service:<name>` — not a UUID, and not derived from anything about this hostd, for the
//! reason in `docs/51` §1. A starting hostd tries adopt first: a hit means the service ran straight
//! through the restart, and the port is re-learned by replaying the ring from offset 0, which still
//! holds the announce line. No state file, no port handshake, nothing to go stale — the child's own
//! words are the record.
//!
//! A non-UUID pane id also keeps these out of the survivor sweep, which parses one and leaves
//! anything else running untouched.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex, Weak};

use slopdesk_hostpane::stream::{PaneChunkSink, PaneOutputStream};
use slopdesk_sidecars::line_assembler::LineAssembler;
use slopdesk_superclient::client::{DisconnectToken, SupervisorClient};
use slopdesk_superwire::blockwire::BlockEvent;
use slopdesk_superwire::protocol::SpawnRequest;
use slopdesk_superwire::sniffwire::SniffEvent;

use crate::service::{LogSink, ServiceHandle, SpawnFailed};

/// A service reads no input and redraws nothing, so its window size is arbitrary. It is not zero
/// because a zero winsize makes some libraries think the terminal is gone.
const SERVICE_ROWS: u16 = 24;
/// The other half of the same arbitrary size, wide enough that no announce line wraps.
const SERVICE_COLS: u16 = 200;

/// The stable pane id for `service` — `service:code-server`, `service:baguette`. The same on every
/// hostd this machine ever runs.
#[must_use]
pub fn pane_id_for(service: &str) -> String {
    format!("service:{service}")
}

/// The mutable half: whether the child is over, and the two registrations that must be dropped when
/// it is.
#[derive(Debug)]
struct Guarded {
    ended: bool,
    /// Held so the subscription outlives the construction; released by a terminate or a relinquish.
    stream: Option<PaneOutputStream>,
    /// Forgotten at the end of this handle's life, so a released service stops being told about
    /// connections it no longer has anything to do with.
    disconnect: Option<DisconnectToken>,
}

/// One panel backend, forked and held by superd.
#[derive(Debug)]
pub struct ServiceProcess {
    pane_id: String,
    client: Arc<SupervisorClient>,
    guarded: Mutex<Guarded>,
    /// Whether this handle adopted a service that survived a hostd restart rather than spawning
    /// one. Reported to the log, and the one fact a test of this type asserts on.
    adopted: bool,
}

impl ServiceProcess {
    /// Takes over the named service if superd still holds it, else starts it.
    ///
    /// # Errors
    /// [`SpawnFailed`] when superd is unreachable, or when the spawn itself fails — a missing or
    /// broken binary. The caller reports the panel `unavailable`, which is the same answer it gave
    /// when this was a child hostd forked itself.
    pub fn spawn_or_adopt(
        service: &str,
        binary: &str,
        arguments: Vec<String>,
        environment: BTreeMap<String, String>,
        client: &Arc<SupervisorClient>,
        on_log_line: LogSink,
        on_log: Option<LogSink>,
    ) -> Result<Arc<Self>, SpawnFailed> {
        let pane_id = pane_id_for(service);
        if let Some(survivor) = Self::adopt_survivor(service, &pane_id, client, &on_log_line, on_log.as_ref())
        {
            return Ok(survivor);
        }
        let spawn = SpawnRequest {
            pane_id: pane_id.clone(),
            // superd only records this, and a service has no scrollback journal to re-associate.
            // Its own id is the most truthful thing to say.
            session_id: pane_id.clone(),
            executable: binary.to_owned(),
            argv0: None,
            arguments,
            environment,
            cwd: None,
            rows: SERVICE_ROWS,
            cols: SERVICE_COLS,
            // A service is not one of this hostd's panes: its id is not a UUID, so the survivor
            // sweep walks past it, and an owner would only ever be read by that sweep.
            owner: None,
            // Neither is asked for, and that is what makes the sink's two batches always empty: a
            // daemon's stdout is not an OSC stream, and its log has no commands to segment.
            shell_integration: false,
            journal: None,
            blocks: None,
        };
        let (_record, master) = client.spawn(spawn).map_err(|error| {
            SpawnFailed {
                reason: error.to_string(),
            }
        })?;
        // hostd wants nothing from this descriptor: no keystrokes, no resizes, no foreground probe.
        // superd holds the original, so closing the duplicate immediately is not a hangup — it is
        // the same act a relinquish performs at the end of a pane's hostd-side life.
        drop(master);
        Ok(Self::wired(pane_id, client, false, on_log_line, on_log))
    }

    /// Whether this handle adopted a survivor rather than spawning one.
    #[must_use]
    pub const fn adopted(&self) -> bool {
        self.adopted
    }

    /// The pane id superd knows this service by.
    #[must_use]
    pub fn pane_id(&self) -> &str {
        &self.pane_id
    }

    // MARK: Internals

    /// Takes back the service superd is still holding, or `None` — including when it is holding one
    /// this hostd cannot USE.
    ///
    /// The port is re-learned by replaying the ring from offset 0, because the announce line is the
    /// first thing the service ever said. A service that has since written more than the ring holds
    /// — hours of an editor's chatter — no longer has that line in there, and an adopt would leave
    /// the manager with a live handle and no port: `is_running` says true, so it never respawns,
    /// and the panel reports `starting` for the rest of the daemon's life with nothing in the
    /// log to say why.
    ///
    /// So a lossy resume is treated as a FAILED adoption. The service is ended and the caller
    /// spawns a fresh one — a few seconds of Node boot, in the rare case, rather than a panel
    /// that never comes back.
    fn adopt_survivor(
        service: &str,
        pane_id: &str,
        client: &Arc<SupervisorClient>,
        on_log_line: &LogSink,
        on_log: Option<&LogSink>,
    ) -> Option<Arc<Self>> {
        let (_record, master) = client.adopt(pane_id).ok()?;
        drop(master);
        let handle = Self::wired(
            pane_id.to_owned(),
            client,
            true,
            Arc::clone(on_log_line),
            on_log.map(Arc::clone),
        );
        if handle.replay_missed_the_start() {
            if let Some(on_log) = on_log {
                on_log(&format!(
                    "service {service}: survived under superd, but its output ring no longer reaches the \
                     announce line, so the port cannot be re-learned — restarting it rather than adopting \
                     one hostd can never address",
                ));
            }
            handle.terminate();
            return None;
        }
        if let Some(on_log) = on_log {
            on_log(&format!(
                "service {service}: still running under superd — adopted, not restarted",
            ));
        }
        Some(handle)
    }

    /// Builds the handle, subscribes it, and registers the disconnect latch.
    ///
    /// The `Arc` exists before the stream does, because both the chunk sink and the disconnect
    /// handler hold a `Weak` back to it: the handle owns the stream that owns the sink, so a strong
    /// edge either way would be a cycle no drop could break.
    fn wired(
        pane_id: String,
        client: &Arc<SupervisorClient>,
        adopted: bool,
        on_log_line: LogSink,
        on_log: Option<LogSink>,
    ) -> Arc<Self> {
        let process = Arc::new(Self {
            pane_id: pane_id.clone(),
            client: Arc::clone(client),
            guarded: Mutex::new(Guarded {
                ended: false,
                stream: None,
                disconnect: None,
            }),
            adopted,
        });

        let sink: Arc<dyn PaneChunkSink> = Arc::new(ServiceLog {
            assembler: Mutex::new(LineAssembler::new()),
            on_line: on_log_line,
            on_log,
            process: Arc::downgrade(&process),
        });
        // From offset 0, always. On the adopt path that is what re-learns the port: the announce
        // line is the first thing the service ever said and superd's ring still has it.
        let stream = PaneOutputStream::new(Arc::clone(client), Some(pane_id), 0, sink);
        stream.start();
        // superd holds the ONLY master for this service, so superd dying kills the child — and hostd
        // would otherwise never hear about it, because the `exited` notice travels the connection
        // that just died. Marking the handle ended makes the next ensure re-run `spawn_or_adopt`,
        // which adopts the survivor if superd was merely unreachable and spawns a fresh one if it
        // really restarted. An OBSERVER rather than the owner's `disconnected`, because this client
        // is shared by every panel service.
        let latch = Arc::downgrade(&process);
        let token = client.observe_disconnect(Arc::new(move || {
            if let Some(process) = Weak::upgrade(&latch) {
                process.mark_ended();
            }
        }));

        if let Ok(mut guarded) = process.guarded.lock() {
            guarded.stream = Some(stream);
            guarded.disconnect = Some(token);
        }
        process
    }

    /// Whether the adopt replay started past the beginning of the service's output — i.e. whether
    /// the announce line, and with it the port, is unrecoverable. Always false on the spawn path.
    fn replay_missed_the_start(&self) -> bool {
        self.guarded.lock().is_ok_and(|guarded| {
            guarded
                .stream
                .as_ref()
                .is_some_and(PaneOutputStream::resumed_lossily)
        })
    }

    fn mark_ended(&self) {
        if let Ok(mut guarded) = self.guarded.lock() {
            guarded.ended = true;
        }
    }

    /// Drops the subscription and the disconnect registration, answering whether the service was
    /// still live — the half a terminate and a relinquish share.
    ///
    /// The stream is stopped and the token forgotten OUTSIDE the lock, because both call into
    /// objects that call back: the stream unsubscribes over the client, and forgetting a token
    /// takes the client's own handler lock.
    fn unwire(&self, ending: bool) -> bool {
        let (live, stream, token) = match self.guarded.lock() {
            Ok(mut guarded) => {
                let live = !guarded.ended;
                if ending {
                    guarded.ended = true;
                }
                (live, guarded.stream.take(), guarded.disconnect.take())
            },
            Err(_poisoned) => (false, None, None),
        };
        if let Some(token) = token {
            self.client.forget_disconnect(token);
        }
        if let Some(stream) = stream {
            stream.stop();
        }
        live
    }
}

impl ServiceHandle for ServiceProcess {
    /// `false` once the child's stream has ended, which is the next ensure round's cue to respawn.
    fn is_running(&self) -> bool {
        self.guarded.lock().is_ok_and(|guarded| !guarded.ended)
    }

    fn terminate(&self) {
        if self.unwire(true) {
            let _ignored = self.client.release(&self.pane_id, true);
        }
    }

    /// Nothing is signalled and superd is told nothing — the next hostd finds the service in `list`
    /// and adopts it.
    fn relinquish(&self) {
        let _ignored = self.unwire(false);
    }
}

/// The chunk sink: superd's bytes in, whole log lines out.
///
/// A service pane is neither sniffed nor tapped — it was spawned without shell integration and
/// without blocks, so superd never reads it for either and both batches are always empty. A
/// daemon's stdout is not an OSC stream.
struct ServiceLog {
    assembler: Mutex<LineAssembler>,
    on_line: LogSink,
    on_log: Option<LogSink>,
    process: Weak<ServiceProcess>,
}

impl fmt::Debug for ServiceLog {
    /// Written out because both handlers are bare closures, and `PaneChunkSink` requires `Debug`.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("ServiceLog").finish_non_exhaustive()
    }
}

impl PaneChunkSink for ServiceLog {
    fn chunk(&self, payload: &[u8], _ends_at: u64, _sniffed: &[SniffEvent], _blocks: &[BlockEvent]) {
        // The lines are taken under the lock and emitted OUTSIDE it: the sink runs on the client's
        // one reader thread, and a line handler that reached back into anything holding this lock
        // would stop every pane in the process, not just this service.
        let lines = match self.assembler.lock() {
            Ok(mut assembler) => assembler.append(payload),
            Err(_poisoned) => return,
        };
        for line in &lines {
            (self.on_line)(line);
        }
    }

    fn ended(&self) {
        if let Some(process) = Weak::upgrade(&self.process) {
            process.mark_ended();
        }
    }

    /// Wired, because this stream's warnings are the only account of a re-learn that went wrong.
    fn log(&self, line: &str) {
        if let Some(on_log) = self.on_log.as_ref() {
            on_log(line);
        }
    }
}
