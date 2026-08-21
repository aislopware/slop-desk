//! The bridge's one-line request protocol, and the pure decisions the ops are made of.
//!
//! One TCP connection, one request. The client writes a single JSON object followed by `\n`; what
//! happens next depends on `op`:
//!
//! | `op` | then |
//! | --- | --- |
//! | `list` | one JSON line back, connection closes |
//! | `boot` / `shutdown` / `console` | one JSON line back, connection closes |
//! | `screenshot` | one JSON line naming a byte count, then that many raw PNG bytes |
//! | `logcat` | one JSON line back, then `logcat` output until the client hangs up |
//! | `open` | one JSON line back, then **raw scrcpy bytes**: the stream down, control up |
//!
//! `open` is the shape worth explaining. After the ack this connection stops being a message
//! protocol: the daemon pumps the device's video socket into it verbatim — codec id, session
//! header, 12-byte frame headers and all — and pumps whatever the client sends back into the
//! device's control socket verbatim. Neither direction is parsed here. That is only sound because
//! [`crate::scrcpy`] disables clipboard autosync, which is what makes the control socket strictly
//! one-way and leaves the downstream direction free for video alone.
//!
//! **No credential.** Same invariant as every other port this project opens: security is the
//! `WireGuard` mesh (`docs/DECISIONS.md`).
//!
//! JSON here and binary on the terminal wire is not an inconsistency: the terminal wire is
//! golden-pinned and hot, this is one line per connection written by a panel.

use serde_json::{Map, Value, json};

use crate::catalog::Device;
use crate::error::BridgeError;

/// One decoded bridge request. Deliberately untyped past `op`: the fields differ per operation, and
/// a tagged union over seven shapes is more ceremony than three accessors.
///
/// Validate-then-drop, like every other decoder in the project that reads bytes it did not write: a
/// malformed request yields `None` and the connection is answered with an error, never a panic.
#[derive(Debug, Clone)]
pub struct Request {
    /// Which operation. Never empty — an empty `op` fails the decode.
    pub op: String,
    fields: Map<String, Value>,
}

impl Request {
    /// Decodes one request line, or `None` for anything that is not an object with a non-empty
    /// `op`.
    #[must_use]
    pub fn decode(line: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(line).ok()?;
        let fields = value.as_object()?.clone();
        let op = fields.get("op")?.as_str()?.to_owned();
        (!op.is_empty()).then_some(Self { op, fields })
    }

    /// A non-empty string field, or `None`. An empty string is `None` on purpose: it reaches an
    /// argument vector, and `adb -s "" shell` is a different command from the one that was meant.
    #[must_use]
    pub fn string(&self, key: &str) -> Option<&str> {
        self.fields
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
    }

    /// An integer field, accepting both spellings.
    ///
    /// JSON decoders decide between integer and float from the literal's own syntax: `5` arrives as
    /// an integer and `5.0` as a double, and a client that wrote a size out with a trailing zero
    /// should not lose it. The float branch is range-checked before it converts, because a `NaN` or
    /// a 1e300 would otherwise become an arbitrary number rather than a rejected field.
    #[must_use]
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the range guard above is exactly what makes the conversion exact; `as` on an                   out-of-range float saturates silently, which is what the guard refuses"
    )]
    pub fn int(&self, key: &str) -> Option<i64> {
        let value = self.fields.get(key)?;
        if let Some(number) = value.as_i64() {
            return Some(number);
        }
        let number = value.as_f64()?;
        (number.is_finite() && number >= f64::from(i32::MIN) && number <= f64::from(i32::MAX))
            // Truncating on purpose, and only inside the range checked above — `as` on an
            // out-of-range float saturates silently, which is the case the guard exists to refuse.
            .then_some(number as i64)
    }
}

/// `{"ok":true, …}` plus a trailing newline.
#[must_use]
pub fn encode_ok(extra: Value) -> String {
    let mut object = Map::new();
    object.insert("ok".to_owned(), Value::Bool(true));
    if let Value::Object(fields) = extra {
        for (key, value) in fields {
            object.insert(key, value);
        }
    }
    Value::Object(object).to_string()
}

/// `{"ok":false,"error":"<sentence>"}`.
#[must_use]
pub fn encode_error(error: BridgeError) -> String {
    json!({ "ok": false, "error": error.message() }).to_string()
}

/// The same, for the two refusals that are not [`BridgeError`] variants because they report a
/// TOOL's silence rather than a decision this daemon made.
#[must_use]
pub fn encode_failure(message: &str) -> String {
    json!({ "ok": false, "error": message }).to_string()
}

/// One device, as the panel's list expects it.
///
/// Absent fields are OMITTED rather than sent as `null`: a phone has no AVD name and a shut-down
/// AVD has no serial, and the panel's row already renders "unknown" for a key it does not find.
#[must_use]
pub fn encode_device(device: &Device) -> Value {
    let mut payload = Map::new();
    payload.insert("state".to_owned(), Value::String(device.state.clone()));
    payload.insert("key".to_owned(), Value::String(device.key()));
    payload.insert("name".to_owned(), Value::String(device.display_name()));
    payload.insert("isEmulator".to_owned(), Value::Bool(device.is_emulator()));

    let mut text = |key: &str, value: Option<&String>| {
        if let Some(value) = value {
            payload.insert(key.to_owned(), Value::String(value.clone()));
        }
    };
    text("serial", device.serial.as_ref());
    text("avd", device.avd_name.as_ref());
    text("manufacturer", device.manufacturer.as_ref());
    text("model", device.model.as_ref());
    text("release", device.release.as_ref());
    text("abi", device.abi.as_ref());
    text("formFactor", device.form_factor.as_ref());

    let mut number = |key: &str, value: Option<i64>| {
        if let Some(value) = value {
            payload.insert(key.to_owned(), Value::from(value));
        }
    };
    number("api", device.api_level);
    number("width", device.width);
    number("height", device.height);
    number("density", device.density);

    Value::Object(payload)
}

/// The emulator's argument vector.
///
/// Boots **headless**. A `SlopDesk` host is a machine nobody is sitting at, so an emulator window
/// there is a window the user will never see that steals focus from whoever is. The panel mirrors
/// it instead.
///
/// ⚠️ **`-gpu host` is the difference between a mirror and a slideshow, and it must be stated.**
/// `-no-window` makes the emulator's `auto` renderer resolve to a SOFTWARE one — measured
/// 2026-08-04, `emulator -avd … -no-window` with no `-gpu` flag settles on `lavapipe` and Android
/// renders its own frames at **113 ms apiece, 98.7% of them janky**, which reaches the panel as
/// **6.4 fps with gaps up to 677 ms**. `-gpu swiftshader_indirect` is barely better (19.5 fps,
/// 99.6% janky). The SAME device, the same drag and the same panel on `-gpu host` — Metal, and
/// headless is no obstacle to it — is **58 fps, 2.6% janky, worst gap 71 ms**. Nothing in
/// `SlopDesk`'s own path was ever the stutter: measured across three vantage points (scrcpy direct,
/// through the bridge on loopback, through the bridge over the mesh) the numbers are the same to
/// within run-to-run noise.
///
/// `SLOPDESK_ANDROID_EMULATOR_ARGS` still appends whatever a host needs, and a `-gpu` of its own
/// REPLACES this one rather than fighting it — a host with no usable GPU is the case that flag
/// exists for.
#[must_use]
pub fn emulator_arguments(avd: &str, extra: &[String]) -> Vec<String> {
    let mut arguments = vec![
        "-avd".to_owned(),
        avd.to_owned(),
        "-no-window".to_owned(),
        "-no-boot-anim".to_owned(),
    ];
    // Stated only when the operator has not stated one. Appending unconditionally would rely on the
    // emulator preferring the later of two `-gpu` flags, which is a behaviour nothing documents;
    // leaving theirs alone is the same decision without the assumption.
    if !extra.iter().any(|argument| argument == "-gpu") {
        arguments.push("-gpu".to_owned());
        arguments.push("host".to_owned());
    }
    arguments.extend_from_slice(extra);
    arguments
}

/// What `adb devices` says about the target → why an `open` cannot proceed, or `None` for a device
/// ready to mirror. Pure. A `None` state is a serial `adb` does not list at all.
#[must_use]
pub fn open_refusal(state: Option<&str>) -> Option<BridgeError> {
    match state {
        Some("device") => None,
        None => Some(BridgeError::UnknownDevice),
        Some("unauthorized") => Some(BridgeError::DeviceUnauthorized),
        // `offline`, `connecting`, `authorizing`, `bootloader`, `recovery`… — every other word is a
        // device that exists but cannot take a mirror YET, and "yet" is the part the client needs.
        Some(_other) => Some(BridgeError::DeviceStarting),
    }
}

/// logcat's priority letters, least severe first. A level outside this set would be interpolated
/// into an argument vector, and `logcat` treats an unparsable filter spec as a fatal error.
///
/// This is also the CLIENT'S MENU, read through `slopdesk_ffi::android_log_level` — one array, not
/// a guarantee here and an offer over there. The Swift copy that used to be the offer had drifted
/// to five letters, dropping `F`, so the one severity a console gets opened to find could not be
/// filtered for. A menu built from anything but the array the spawner validates against can only
/// be a subset that silently withholds a level or a superset that kills the child.
///
/// `S` (silent) is deliberately absent: it is a level `logcat` accepts and it means "print
/// nothing", which is a console that connects and then looks broken. `slopdesk_devicelog`'s parser
/// does accept it, because reading a spec that named it is a different question from offering it.
pub const LOGCAT_LEVELS: [&str; 6] = ["V", "D", "I", "W", "E", "F"];

/// The requested level if it is one logcat knows, else `I`.
#[must_use]
pub fn logcat_level(requested: Option<&str>) -> &str {
    requested
        .filter(|level| LOGCAT_LEVELS.contains(level))
        .unwrap_or("I")
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::json;

    use super::{
        Request, emulator_arguments, encode_device, encode_error, encode_ok, logcat_level, open_refusal,
    };
    use crate::catalog::Device;
    use crate::error::BridgeError;

    fn request(text: &str) -> Option<Request> {
        Request::decode(text.as_bytes())
    }

    #[test]
    fn a_request_needs_an_op_and_nothing_else() {
        assert_eq!(request(r#"{"op":"list"}"#).map(|r| r.op), Some("list".to_owned()));
        assert_eq!(request(r#"{"op":""}"#).map(|r| r.op), None);
        assert_eq!(request(r#"{"serial":"x"}"#).map(|r| r.op), None);
        assert_eq!(request(r#"{"op":7}"#).map(|r| r.op), None);
        // Validate-then-drop: garbage is a `None`, never a panic.
        assert_eq!(request("not json at all").map(|r| r.op), None);
        assert_eq!(request("[1,2,3]").map(|r| r.op), None);
        assert_eq!(request("").map(|r| r.op), None);
    }

    #[test]
    fn an_empty_string_field_reads_as_absent_because_it_reaches_an_argument_vector() {
        let decoded = request(r#"{"op":"open","serial":""}"#).expect("decodes");
        assert_eq!(decoded.string("serial"), None);
        assert_eq!(decoded.string("missing"), None);
    }

    #[test]
    fn both_number_spellings_decode_and_the_unusable_ones_do_not() {
        let decoded = request(r#"{"op":"open","a":1024,"b":1024.0,"c":1e300,"d":"12"}"#).expect("decodes");
        assert_eq!(decoded.int("a"), Some(1024));
        // `1024.0` is the same size a client wrote with a trailing zero, not a different field.
        assert_eq!(decoded.int("b"), Some(1024));
        // Out of range: `as` would saturate silently, which is what the guard refuses.
        assert_eq!(decoded.int("c"), None);
        assert_eq!(decoded.int("d"), None);
    }

    #[test]
    fn the_gpu_flag_is_stated_unless_the_operator_stated_one() {
        // The difference between 58 fps and 6.4 — see the doc comment.
        let defaults = emulator_arguments("Pixel_API36", &[]);
        assert_eq!(defaults, [
            "-avd",
            "Pixel_API36",
            "-no-window",
            "-no-boot-anim",
            "-gpu",
            "host"
        ]);

        let operator = ["-gpu".to_owned(), "swiftshader_indirect".to_owned()];
        let overridden = emulator_arguments("Pixel_API36", &operator);
        assert_eq!(
            overridden.iter().filter(|argument| *argument == "-gpu").count(),
            1,
            "the operator's -gpu replaces ours rather than fighting it"
        );
        assert!(overridden.ends_with(&operator));
    }

    #[test]
    fn extra_arguments_that_are_not_gpu_are_appended_alongside_the_default() {
        let extra = ["-netdelay".to_owned(), "none".to_owned()];
        let arguments = emulator_arguments("Pixel_API36", &extra);
        assert!(arguments.windows(2).any(|pair| pair == ["-gpu", "host"]));
        assert!(arguments.ends_with(&extra));
    }

    #[test]
    fn only_a_ready_device_may_be_mirrored_and_every_other_word_says_yet() {
        assert_eq!(open_refusal(Some("device")), None);
        assert_eq!(open_refusal(None), Some(BridgeError::UnknownDevice));
        assert_eq!(
            open_refusal(Some("unauthorized")),
            Some(BridgeError::DeviceUnauthorized)
        );
        for state in ["offline", "connecting", "authorizing", "bootloader", "recovery"] {
            assert_eq!(
                open_refusal(Some(state)),
                Some(BridgeError::DeviceStarting),
                "{state} is a device that cannot mirror YET"
            );
        }
    }

    #[test]
    fn an_unknown_logcat_level_falls_back_rather_than_reaching_the_argument_vector() {
        assert_eq!(logcat_level(Some("E")), "E");
        assert_eq!(logcat_level(Some("V")), "V");
        assert_eq!(logcat_level(Some("e")), "I");
        assert_eq!(logcat_level(Some("*:S; rm -rf /")), "I");
        assert_eq!(logcat_level(None), "I");
    }

    /// The half of the alphabet the Swift menu used to stop short of. `F` is a level a client may
    /// ask for and this daemon must honour rather than quietly widen to `I` — a fatal-only console
    /// that fills with debug rows is worse than one that refuses.
    #[test]
    fn fatal_is_a_level_a_client_may_ask_for() {
        assert_eq!(logcat_level(Some("F")), "F");
        // Silent is NOT, even though `logcat` would take it: it is a console that prints nothing.
        assert_eq!(logcat_level(Some("S")), "I");
        assert_eq!(
            logcat_level(Some("A")),
            "I",
            "assert is a printed priority, not a filter one"
        );
    }

    #[test]
    fn a_reply_is_one_json_object_and_an_error_carries_its_sentence() {
        assert_eq!(encode_ok(json!({})), r#"{"ok":true}"#);
        // Compared as a decoded object, not as text: the map is sorted, and key order is not
        // something a client's decoder — or this protocol — has an opinion about.
        let acknowledged: serde_json::Value =
            serde_json::from_str(&encode_ok(json!({"device": "Pixel 7"}))).expect("valid JSON");
        assert_eq!(acknowledged, json!({"ok": true, "device": "Pixel 7"}));
        assert!(encode_error(BridgeError::UnknownDevice).contains("no longer attached"));
    }

    #[test]
    fn an_absent_field_is_omitted_rather_than_sent_as_null() {
        // A phone has no AVD name and a shut-down AVD has no serial; the panel renders what it
        // finds, so a `null` would be a field it has to special-case.
        let phone = Device {
            serial: Some("39121FDJH000TR".to_owned()),
            state: "device".to_owned(),
            model: Some("Pixel 7".to_owned()),
            ..Device::default()
        };
        let encoded = encode_device(&phone);
        let object = encoded.as_object().expect("an object");
        assert!(!object.contains_key("avd"));
        assert!(!object.contains_key("width"));
        assert_eq!(object.get("isEmulator"), Some(&json!(false)));
        assert_eq!(object.get("key"), Some(&json!("serial:39121FDJH000TR")));
        assert_eq!(object.get("name"), Some(&json!("Pixel 7")));
    }

    #[test]
    fn an_avd_keeps_one_key_across_its_boot() {
        // What lets a device the user selected stay selected when it acquires a serial.
        let shut_down = Device {
            avd_name: Some("Pixel_API36".to_owned()),
            state: "offline".to_owned(),
            ..Device::default()
        };
        let booted = Device {
            serial: Some("emulator-5554".to_owned()),
            avd_name: Some("Pixel_API36".to_owned()),
            state: "device".to_owned(),
            ..Device::default()
        };
        assert_eq!(
            encode_device(&shut_down).get("key"),
            encode_device(&booted).get("key")
        );
        assert_eq!(encode_device(&shut_down).get("name"), Some(&json!("Pixel API36")));
    }
}
