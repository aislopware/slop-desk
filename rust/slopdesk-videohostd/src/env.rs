//! Where a `SLOPDESK_*` value comes from, when it does not come from the environment.
//!
//! ## There is no settings GUI, and there is a settings FILE
//! `docs/58`. The client's Settings write `video-prefs.json` beside the launch record, and both
//! host daemons fold it at launch — neither can live-reload, so a toggle "applies on reconnect".
//! A gate that read `std::env::var` directly would quietly stop honouring a setting the moment its
//! key became user-facing, which is exactly why `slopdesk_video::host_gates` and its siblings take
//! RESOLVED TEXTS rather than reading the environment themselves.
//!
//! ## Precedence, and why it runs this way round
//! Environment → overlay → the gate's own default. A deliberate `SLOPDESK_X=…` on the command line
//! is the operator's escape hatch and is never silently overridden by a persisted setting; the
//! overlay only fills a key nobody set. That is `EnvConfig.string`'s rule, carried verbatim.
//!
//! ## What this reads, and what its sibling leaves alone
//! The sidecar has three parts and this daemon is entitled to two. `video` is THIS daemon's — all
//! eleven keys are its operating point, and `slopdesk-hostd`'s own `env.rs` says out loud that it
//! does not read them for that reason. `rawOverrides` is the free-text box, documented as the way
//! a HOST-only knob reaches a daemon, so it lands whole and LAST. `agent` is deliberately NOT read:
//! both its flags name hostd gates, and mapping them here would be the second copy of
//! `EnvBridge.toEnv(_: AgentPreferences)` that the split exists to avoid.
//!
//! ## A corrupt file is a no-op
//! Validate-then-drop, at every step: no file, unreadable file, JSON that is not an object, a
//! `rawOverrides` that is not a string table — each answers an EMPTY overlay rather than a refusal.
//! A prefs file nobody can parse must not cost a person their screen.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;
use slopdesk_terminal::config::{ENV_INTEGRAL_LIMIT, number_text};

/// The sidecar's file name, inside the Application Support container.
const SIDECAR_NAME: &str = "video-prefs.json";

/// The video daemon's launch-time settings overlay.
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
    pub fn from_file(path: &Path) -> Self {
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
        let video = sidecar.video;
        if let Some(value) = video.qp_sharp {
            values.insert("SLOPDESK_QP_SHARP".to_owned(), value.to_string());
        }
        if let Some(value) = video.qp_coarse {
            values.insert("SLOPDESK_QP_COARSE".to_owned(), value.to_string());
        }
        if let Some(value) = video.qp_decouple {
            values.insert("SLOPDESK_QP_DECOUPLE".to_owned(), switch(value));
        }
        if let Some(value) = video.fec_m {
            values.insert("SLOPDESK_FEC_M".to_owned(), value.to_string());
        }
        if let Some(value) = video.fec_k {
            values.insert("SLOPDESK_FEC_K".to_owned(), value.to_string());
        }
        // The two enum rows carry their RAW VALUE, which is the token the read site compares
        // against. An unknown token never gets here: serde refuses the whole file, which is the
        // same validate-then-drop the Swift's `init(rawValue:)` did one field at a time.
        if let Some(value) = video.pacer {
            values.insert("SLOPDESK_PACER".to_owned(), value.as_str().to_owned());
        }
        if let Some(value) = video.playout_ms {
            values.insert("SLOPDESK_PLAYOUT_MS".to_owned(), number(value));
        }
        if let Some(value) = video.capture_scale {
            values.insert("SLOPDESK_CAPTURE_SCALE".to_owned(), number(value));
        }
        if let Some(value) = video.display_capture {
            values.insert("SLOPDESK_DISPLAY_CAPTURE".to_owned(), value.as_str().to_owned());
        }
        if let Some(value) = video.virtual_display {
            values.insert("SLOPDESK_VD".to_owned(), switch(value));
        }
        // Client-side, and written here anyway: the sidecar is ONE file read by both ends, and
        // dropping a key because this daemon does not consume it would make the file a different
        // document depending on who opened it.
        if let Some(value) = video.sharpen {
            values.insert("SLOPDESK_SHARPEN".to_owned(), number(value));
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
    /// `ProcessInfo.processInfo.environment[k]` answers, and more than one gate on this path reads
    /// empty-versus-absent as two different requests.
    #[must_use]
    pub fn get(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().or_else(|| self.values.get(key).cloned())
    }

    /// Every key in `keys`, resolved, in the order asked.
    ///
    /// The shape `slopdesk_video`'s gate tables take: they are handed RESOLVED TEXTS positionally,
    /// because the precedence above is the overlay owner's rule and not theirs.
    #[must_use]
    pub fn resolve(&self, keys: &[&str]) -> Vec<Option<String>> {
        keys.iter().map(|key| self.get(key)).collect()
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

/// A number as the text a user would have typed: integral values without a decimal point.
///
/// `slopdesk_terminal::config::number_text` and nothing local, because that is the ONE
/// implementation of this rule — the libghostty config text writes its numbers by it, and
/// `EnvBridge.formatDouble` already crossed the boundary to ask the same function.
fn number(value: f64) -> String {
    number_text(value, ENV_INTEGRAL_LIMIT)
}

/// The sidecar, in the two parts this daemon reads.
///
/// `agent` and `schemaVersion` are absent from this shape on purpose — serde ignores what it is not
/// told about, so an older or newer file loads either way. That is this repo's no-migration
/// contract, and it is why nothing here inspects a version number.
#[derive(Debug, Default, Deserialize)]
struct Sidecar {
    #[serde(default)]
    video: VideoPrefs,
    #[serde(default, rename = "rawOverrides")]
    raw_overrides: BTreeMap<String, String>,
}

/// The `video` table: eleven optional knobs, where absent means "the daemon's own default".
#[derive(Debug, Default, Deserialize)]
struct VideoPrefs {
    #[serde(default, rename = "qpSharp")]
    qp_sharp: Option<i64>,
    #[serde(default, rename = "qpCoarse")]
    qp_coarse: Option<i64>,
    #[serde(default, rename = "qpDecouple")]
    qp_decouple: Option<bool>,
    #[serde(default, rename = "fecM")]
    fec_m: Option<i64>,
    #[serde(default, rename = "fecK")]
    fec_k: Option<i64>,
    #[serde(default)]
    pacer: Option<Pacer>,
    #[serde(default, rename = "playoutMs")]
    playout_ms: Option<f64>,
    #[serde(default, rename = "captureScale")]
    capture_scale: Option<f64>,
    #[serde(default, rename = "displayCapture")]
    display_capture: Option<DisplayCapture>,
    #[serde(default, rename = "virtualDisplay")]
    virtual_display: Option<bool>,
    #[serde(default)]
    sharpen: Option<f64>,
}

/// Presentation pacer mode. `deadline` is the smoothness-tuned buffer; `arrival` presents on
/// arrival, and is the default the client falls back to.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Pacer {
    /// Hold each frame to its deadline.
    Deadline,
    /// Present as soon as it decodes.
    Arrival,
}

impl Pacer {
    /// The token the read site compares against.
    const fn as_str(self) -> &'static str {
        match self {
            Self::Deadline => "deadline",
            Self::Arrival => "arrival",
        }
    }
}

/// Which filter the capture stream is built with.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum DisplayCapture {
    /// The window alone.
    Window,
    /// The whole display the window sits on.
    Display,
    /// The display, with the window's own set included.
    Include,
}

impl DisplayCapture {
    /// The token the read site compares against.
    const fn as_str(self) -> &'static str {
        match self {
            Self::Window => "window",
            Self::Display => "display",
            Self::Include => "include",
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "the overlay is compared by the EXACT text a gate parses back, and a panic in a test is \
                  the failure report"
    )]

    use super::*;

    #[test]
    fn an_empty_sidecar_contributes_nothing() {
        let overlay = Overlay::from_text(r#"{"schemaVersion":1,"video":{},"agent":{}}"#);
        assert!(overlay.applied().is_empty());
    }

    #[test]
    fn a_file_that_is_not_json_is_a_no_op_rather_than_a_refusal() {
        assert!(Overlay::from_text("not json at all").applied().is_empty());
        assert!(Overlay::from_text("[]").applied().is_empty());
        assert!(
            Overlay::from_file(Path::new("/nonexistent/video-prefs.json"))
                .applied()
                .is_empty()
        );
    }

    #[test]
    fn every_video_field_maps_to_the_key_its_gate_reads() {
        let overlay = Overlay::from_text(
            r#"{"video":{"qpSharp":22,"qpCoarse":44,"qpDecouple":true,"fecM":3,"fecK":8,
                        "pacer":"deadline","playoutMs":40.0,"captureScale":1.0,
                        "displayCapture":"include","virtualDisplay":false,"sharpen":0.25}}"#,
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_QP_SHARP").map(String::as_str),
            Some("22")
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_QP_COARSE").map(String::as_str),
            Some("44")
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_QP_DECOUPLE").map(String::as_str),
            Some("1")
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_FEC_M").map(String::as_str),
            Some("3")
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_FEC_K").map(String::as_str),
            Some("8")
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_PACER").map(String::as_str),
            Some("deadline")
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_DISPLAY_CAPTURE").map(String::as_str),
            Some("include")
        );
        assert_eq!(overlay.values.get("SLOPDESK_VD").map(String::as_str), Some("0"));
    }

    #[test]
    fn an_integral_number_carries_no_decimal_point() {
        let overlay = Overlay::from_text(r#"{"video":{"playoutMs":40.0,"captureScale":1.0}}"#);
        assert_eq!(
            overlay.values.get("SLOPDESK_PLAYOUT_MS").map(String::as_str),
            Some("40"),
            "the read site parses this back with a plain Int/Double — a `40.0` here is noise"
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_CAPTURE_SCALE").map(String::as_str),
            Some("1")
        );
    }

    #[test]
    fn a_raw_override_wins_the_same_key() {
        let overlay = Overlay::from_text(
            r#"{"video":{"qpSharp":22},"rawOverrides":{"SLOPDESK_QP_SHARP":"18","":"ignored"}}"#,
        );
        assert_eq!(
            overlay.values.get("SLOPDESK_QP_SHARP").map(String::as_str),
            Some("18"),
            "the box is the more specific statement, and it folds last"
        );
        assert!(
            !overlay.values.contains_key(""),
            "an empty key is a half-typed row, not a request to set the empty name"
        );
    }

    #[test]
    fn the_agent_table_is_not_this_daemons_to_read() {
        let overlay = Overlay::from_text(r#"{"agent":{"preventSleep":true,"resumeOnRecovery":false}}"#);
        assert!(
            overlay.applied().is_empty(),
            "both agent flags name hostd gates; reading them here would be the second copy"
        );
    }

    #[test]
    fn an_unknown_enum_token_drops_the_whole_file_rather_than_the_field() {
        assert!(
            Overlay::from_text(r#"{"video":{"qpSharp":22,"pacer":"whenever"}}"#)
                .applied()
                .is_empty(),
            "validate-then-drop: a file nobody can parse must not half-apply"
        );
    }

    #[test]
    fn resolve_answers_positionally_in_the_order_asked() {
        let overlay = Overlay::from_text(r#"{"video":{"qpSharp":22,"fecM":3}}"#);
        let resolved = overlay.resolve(&["SLOPDESK_FEC_M", "SLOPDESK_NOT_SET", "SLOPDESK_QP_SHARP"]);
        assert_eq!(resolved[0].as_deref(), Some("3"));
        assert_eq!(resolved[1].as_deref(), None);
        assert_eq!(resolved[2].as_deref(), Some("22"));
    }
}
