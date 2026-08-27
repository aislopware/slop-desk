//! Where a `SLOPDESK_*` value comes from, when it does not come from the environment.
//!
//! ## There is no settings GUI, and there is a settings FILE
//! `docs/58`. The client's Settings write `video-prefs.json` beside the launch record, and both
//! host daemons fold it at launch — the daemon cannot live-reload, so a toggle "applies on
//! reconnect". A gate that read `std::env::var` directly would quietly stop honouring a setting the
//! moment its key became user-facing, which is exactly why `slopdesk_video::host_gates` takes
//! RESOLVED TEXTS rather than reading the environment itself.
//!
//! ## Precedence, and why it runs this way round
//! Environment → overlay → the gate's own default. A deliberate `SLOPDESK_X=…` on the command line
//! is the operator's escape hatch and is never silently overridden by a persisted setting; the
//! overlay only fills a key nobody set. That is `EnvConfig.string`'s rule, carried verbatim.
//!
//! ## What this reads, and what it leaves alone
//! The sidecar has three parts and hostd is entitled to two. `agent` is hostd's — both flags name
//! host gates. `rawOverrides` is the free-text box, and the Settings UI documents it as the way a
//! HOST-only knob reaches this daemon, so it lands whole. `video` is deliberately NOT read: those
//! eleven keys are `slopdesk-videohostd`'s operating point, that daemon folds the same file for
//! itself, and mapping them here would be a second copy of `EnvBridge.toEnv(_: VideoPreferences)`.
//!
//! ## One difference from the Swift, stated rather than hidden
//! Swift resolved six of hostd's seven gates through the overlay and `SLOPDESK_AGENT_CONTROL`
//! through `ProcessInfo` alone. Here all seven go through the same door. The asymmetry bought
//! nothing — a raw override IS the documented way to reach a host-only knob, and the one key it
//! could not reach was the one the box exists for.
//!
//! ## A corrupt file is a no-op
//! Validate-then-drop, at every step: no file, unreadable file, JSON that is not an object, a
//! `rawOverrides` that is not a string table — each answers an EMPTY overlay rather than a refusal.
//! A prefs file nobody can parse must not cost a person their terminals.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;

/// The sidecar's file name, inside the Application Support container.
const SIDECAR_NAME: &str = "video-prefs.json";

/// hostd's launch-time settings overlay.
///
/// Built ONCE, before any gate is read, and read-only thereafter — the same write-once-at-launch
/// contract the Swift documented, and the reason no lock appears here.
#[derive(Debug, Default)]
pub struct Overlay {
    values: BTreeMap<String, String>,
}

impl Overlay {
    /// The overlay the sidecar at the default location contributes, or an empty one.
    #[must_use]
    pub fn from_launch() -> Self {
        let Some(path) = slopdesk_hostlaunch::record::app_support_dir().map(|dir| dir.join(SIDECAR_NAME))
        else {
            return Self::default();
        };
        Self::from_file(&path)
    }

    /// The overlay `path` contributes. The seam the suite drives.
    #[must_use]
    pub fn from_file(path: &PathBuf) -> Self {
        let Ok(text) = std::fs::read_to_string(path) else {
            return Self::default();
        };
        Self::from_text(&text)
    }

    /// The overlay this sidecar JSON contributes.
    ///
    /// `rawOverrides` folds LAST and wins on a shared key, mirroring `VideoSidecar.toEnv()`: the
    /// free-text box is the more specific statement, and a user who typed a key by hand meant it.
    #[must_use]
    pub fn from_text(text: &str) -> Self {
        let Ok(sidecar) = serde_json::from_str::<Sidecar>(text) else {
            return Self::default();
        };
        let mut values = BTreeMap::new();
        if let Some(prevent) = sidecar.agent.prevent_sleep {
            values.insert("SLOPDESK_AGENT_PREVENT_SLEEP".to_owned(), switch(prevent));
        }
        if let Some(resume) = sidecar.agent.resume_on_recovery {
            values.insert("SLOPDESK_AGENT_RESUME_ON_RECOVERY".to_owned(), switch(resume));
        }
        // An EMPTY key is a half-typed row in the overrides box, not a request to set `""`.
        for (key, value) in sidecar.raw_overrides {
            if !key.is_empty() {
                values.insert(key, value);
            }
        }
        Self { values }
    }

    /// `key`'s value: the environment's, else the overlay's, else `None`.
    ///
    /// An exported-but-EMPTY variable counts as SET, deliberately — that is what
    /// `ProcessInfo.processInfo.environment[k]` answers, and one gate
    /// (`SLOPDESK_AUTO_PROGRESS_COMMANDS`) reads empty-versus-absent as two different requests.
    #[must_use]
    pub fn get(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().or_else(|| self.values.get(key).cloned())
    }

    /// The default-ON idiom: TRUE unless the resolved value is exactly `"0"`.
    #[must_use]
    pub fn on_unless_zero(&self, key: &str) -> bool {
        self.get(key).as_deref() != Some("0")
    }

    /// The default-OFF idiom: TRUE only when the resolved value is exactly `"1"`.
    #[must_use]
    pub fn on_if_one(&self, key: &str) -> bool {
        self.get(key).as_deref() == Some("1")
    }

    /// The keys the sidecar actually contributed, sorted — one launch-time log line.
    #[must_use]
    pub fn applied(&self) -> Vec<&str> {
        self.values.keys().map(String::as_str).collect()
    }
}

/// `true`/`false` as the literal a read site compares against.
///
/// A present field always pins the exact `"1"`/`"0"` the gate resolves, whatever ITS polarity is —
/// which is what makes one writer safe for a default-ON and a default-OFF key alike.
fn switch(on: bool) -> String {
    if on { "1".to_owned() } else { "0".to_owned() }
}

/// The sidecar, in the two parts hostd reads.
///
/// `video` and `schemaVersion` are absent from this shape on purpose — serde ignores what it is not
/// told about, so an older or newer file loads either way. That is this repo's no-migration
/// contract, and it is why nothing here inspects a version number.
#[derive(Debug, Default, Deserialize)]
struct Sidecar {
    #[serde(default)]
    agent: AgentPrefs,
    #[serde(default, rename = "rawOverrides")]
    raw_overrides: BTreeMap<String, String>,
}

/// The `agent` table: two optional switches, where absent means "the daemon's own default".
#[derive(Debug, Default, Deserialize)]
struct AgentPrefs {
    #[serde(default, rename = "preventSleep")]
    prevent_sleep: Option<bool>,
    #[serde(default, rename = "resumeOnRecovery")]
    resume_on_recovery: Option<bool>,
}
