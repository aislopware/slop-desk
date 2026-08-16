//! The producer: one thread that owns the fold and drives every source through it.
//!
//! Swift ran this as an actor with three `AsyncStream`s hopping onto it. The reason that shape
//! existed was to SERIALISE the [`EventBuilder`] — a source must never race the builder's state, or
//! the emitted order stops being well-defined and a tool card can pair against a half-updated map.
//! One thread owning the builder outright gives the same guarantee with nothing to reason about:
//! there is no second thread that could touch it.
//!
//! The thread polls the main transcript, then each subagent file, folds what it finds, and appends
//! to the [`ReplayLog`]. It runs whether or not anyone is connected — the replay window is exactly
//! what makes a client that connects LATER see the whole session, so stopping when the last
//! subscriber leaves would defeat the point.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::builder::EventBuilder;
use crate::replay::ReplayLog;
use crate::subagents::SubagentWatcher;
use crate::tailer::TranscriptTailer;

/// How often the sources are polled. Small enough to feel live, large enough to be free: a JSONL
/// flush happens per turn, so this is already far faster than anything it observes.
pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// The sources one engine follows.
#[derive(Debug)]
pub struct Sources {
    /// The main session transcript.
    pub transcript: Option<TranscriptTailer>,
    /// The `subagents/` directory beside it.
    pub subagents: Option<SubagentWatcher>,
}

impl Sources {
    /// The sources implied by a transcript path: the file itself, and the `subagents/` directory in
    /// the same folder — which is where Claude Code puts them, and which may not exist yet.
    #[must_use]
    pub fn from_transcript(path: impl AsRef<Path>) -> Self {
        let path = path.as_ref();
        let subagents = path
            .parent()
            .map(|parent| SubagentWatcher::new(parent.join("subagents")));
        Self {
            transcript: Some(TranscriptTailer::new(path)),
            subagents,
        }
    }

    /// Whether there is anything at all to follow. With no source the engine thread is not started:
    /// the daemon still serves (a client can connect and subscribe) and the replay window simply
    /// stays empty, which is what an inspector with no transcript to inspect honestly is.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.transcript.is_none() && self.subagents.is_none()
    }
}

/// A running engine thread.
#[derive(Debug)]
pub struct Engine {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl Engine {
    /// Starts the fold, appending into `log`.
    #[must_use]
    pub fn start(mut sources: Sources, log: Arc<ReplayLog>, poll_interval: Duration) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let handle = thread::Builder::new()
            .name("inspectord-engine".to_owned())
            .spawn(move || {
                let mut builder = EventBuilder::new();
                while !thread_stop.load(Ordering::Relaxed) {
                    let mut produced = false;

                    if let Some(tailer) = sources.transcript.as_mut() {
                        for line in tailer.poll() {
                            for event in builder.ingest(&line) {
                                log.append(&event);
                                produced = true;
                            }
                        }
                    }

                    if let Some(watcher) = sources.subagents.as_mut() {
                        for (agent_id, line) in watcher.poll() {
                            for event in builder.ingest_subagent(&line, &agent_id) {
                                log.append(&event);
                                produced = true;
                            }
                        }
                    }

                    // Only sleep on a QUIET poll. A busy transcript — a large backlog draining
                    // through the read cap — would otherwise take one poll interval per chunk, so a
                    // cold start on a big session would trickle in for minutes.
                    if !produced {
                        thread::sleep(poll_interval);
                    }
                }
            })
            .ok();
        Self { stop, handle }
    }

    /// Signals the thread to stop and waits for it. Idempotent.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            drop(handle.join());
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::panic,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::fs::{self, OpenOptions};
    use std::io::Write as _;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    use super::{Engine, Sources};
    use crate::event::InspectorEvent;
    use crate::replay::{Pull, ReplayLog};

    fn temp_dir(label: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "slopdesk-inspectord-engine-{label}-{}-{unique}",
            std::process::id()
        ));
        drop(fs::remove_dir_all(&dir));
        fs::create_dir_all(&dir).expect("creatable");
        dir
    }

    fn append_line(path: &PathBuf, value: &serde_json::Value) {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("appendable");
        writeln!(file, "{value}").expect("written");
    }

    /// Pulls until an event arrives or the (generous) budget runs out. The assertion is that the
    /// engine DELIVERS, never how fast — a slow CI box must not fail this.
    fn await_event(subscription: &crate::replay::Subscription) -> Option<InspectorEvent> {
        for _ in 0..50 {
            match subscription.subscriber.pull(Duration::from_millis(100)) {
                Pull::Event(event) => return Some(*event),
                Pull::Idle => {},
                Pull::Finished => return None,
            }
        }
        None
    }

    #[test]
    fn the_engine_folds_a_live_transcript_into_the_replay_log() {
        let dir = temp_dir("live");
        let transcript = dir.join("session.jsonl");
        let log = Arc::new(ReplayLog::default());
        let subscription = log.subscribe(0);

        let mut engine = Engine::start(
            Sources::from_transcript(&transcript),
            Arc::clone(&log),
            Duration::from_millis(10),
        );

        append_line(
            &transcript,
            &serde_json::json!({"type": "user", "uuid": "u1", "message": "hello"}),
        );

        let event = await_event(&subscription).expect("the message arrives");
        assert!(matches!(event, InspectorEvent::Message { .. }));
        engine.stop();
    }

    #[test]
    fn subagent_files_are_followed_from_the_transcripts_own_folder() {
        let dir = temp_dir("sub");
        let transcript = dir.join("session.jsonl");
        fs::create_dir_all(dir.join("subagents")).expect("creatable");
        let log = Arc::new(ReplayLog::default());
        let subscription = log.subscribe(0);

        let mut engine = Engine::start(
            Sources::from_transcript(&transcript),
            Arc::clone(&log),
            Duration::from_millis(10),
        );

        append_line(
            &dir.join("subagents").join("agent-abc.jsonl"),
            &serde_json::json!({"type": "user", "uuid": "s1", "message": "from the subagent"}),
        );

        // The node is asserted before its content.
        let first = await_event(&subscription).expect("the node arrives");
        let InspectorEvent::SubagentUpdated { node } = first else {
            panic!("expected subagentUpdated, got {first:?}");
        };
        assert_eq!(node.id, "abc");

        let second = await_event(&subscription).expect("the message arrives");
        let InspectorEvent::Message { message } = second else {
            panic!("expected a message, got {second:?}");
        };
        assert_eq!(message.agent_id.as_deref(), Some("abc"));
        engine.stop();
    }

    #[test]
    fn an_engine_with_no_sources_is_empty_rather_than_an_error() {
        let sources = Sources {
            transcript: None,
            subagents: None,
        };
        assert!(sources.is_empty());
    }

    #[test]
    fn stopping_twice_is_harmless() {
        let dir = temp_dir("stop");
        let mut engine = Engine::start(
            Sources::from_transcript(dir.join("session.jsonl")),
            Arc::new(ReplayLog::default()),
            Duration::from_millis(10),
        );
        engine.stop();
        engine.stop();
    }
}
