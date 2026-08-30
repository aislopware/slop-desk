//! The PURE parsers behind the Android panel's device list.
//!
//! Everything here is a function from captured tool output to a value. Nothing spawns a process, so
//! the whole catalogue is testable against recorded `adb`/`emulator` output — which matters more
//! here than usual, because these formats are conventions rather than contracts and a recorded
//! fixture that stops matching is the only warning we get that one has moved.
//!
//! ## The one fact Android has that iOS does not
//!
//! `docs/47` records that for a SHUT-DOWN iOS simulator the server knows exactly four things and
//! that `definition.json`'s geometry is chrome data which silently falls back to a near model —
//! measured wrong for four of eleven devices. Android is the opposite case, and the panel is
//! designed around the difference: an AVD that has never been booted still has an exact
//! `config.ini` carrying `hw.lcd.width`, `hw.lcd.height`, `hw.lcd.density`, its device profile, its
//! ABI and its API level. Those are the AVD's DEFINITION, not a lookup against a table of
//! lookalikes.
//!
//! ## Naming
//!
//! An emulator's `ro.product.model` is `sdk_gphone64_arm64` for every AVD on the host, so it cannot
//! name a row. The AVD name can, and it is what the user typed when they created it. A physical
//! device has no AVD name and its `ro.product.model` is exactly right ("Pixel 7 Pro").

use std::collections::HashMap;

/// One device the panel can list — a running `adb` target, an AVD that is not booted, or an AVD
/// that is booted (in which case the two records are FOLDED into one carrying both halves).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Device {
    /// The `adb` transport id (`emulator-5554`, `39121FDJH000TR`). `None` for an AVD that is not
    /// running — it has no transport until it boots.
    pub serial: Option<String>,
    /// The AVD's id (`Pixel_API36`). `None` for a physical device.
    pub avd_name: Option<String>,
    /// `adb`'s own word: `device`, `offline`, `unauthorized`, `booting`… Kept as the RAW string
    /// because `adb` has more states than the ones seen here, and a closed enum would turn a
    /// transient one into a decode failure for the whole list.
    pub state: String,
    /// `ro.product.manufacturer`, or the AVD's `hw.device.manufacturer`.
    pub manufacturer: Option<String>,
    /// `ro.product.model` for a physical device; the AVD's device profile otherwise.
    pub model: Option<String>,
    /// The Android version as a marketing string ("16").
    pub release: Option<String>,
    /// The API level (36). Named `api_level` rather than `sdk` because `sdk` reads like a path.
    pub api_level: Option<i64>,
    /// `ro.product.cpu.abi`, or the AVD's `abi.type`.
    pub abi: Option<String>,
    /// Measured (`wm size`) for a running device, declared (`hw.lcd.width`) for a shut-down AVD.
    pub width: Option<i64>,
    /// Measured (`wm size`) for a running device, declared (`hw.lcd.height`) for a shut-down AVD.
    pub height: Option<i64>,
    /// Measured (`wm density`) for a running device, declared (`hw.lcd.density`) otherwise.
    pub density: Option<i64>,
    /// The form-factor hint, kept as the platform's RAW word: `ro.build.characteristics` for a
    /// running device, `tag.id` for an AVD on disk. Passed through rather than resolved here
    /// because the panel is where a hint becomes a glyph.
    pub form_factor: Option<String>,
}

impl Device {
    /// A bare record — what a target `adb` listed but nothing could be asked of looks like.
    #[must_use]
    pub fn bare(serial: Option<String>, avd_name: Option<String>, state: &str) -> Self {
        Self {
            serial,
            avd_name,
            state: state.to_owned(),
            ..Self::default()
        }
    }

    /// Whether the device can take a mirror right now.
    #[must_use]
    pub fn is_running(&self) -> bool {
        self.serial.is_some() && self.state == "device"
    }

    /// An AVD is an emulator; a serial with no AVD name is a phone.
    #[must_use]
    pub const fn is_emulator(&self) -> bool {
        self.avd_name.is_some()
    }

    /// What the row is titled. An AVD is titled by the name the user gave it, with the underscores
    /// `avdmanager` forces in it spelled back out as spaces; a physical device by its model.
    #[must_use]
    pub fn display_name(&self) -> String {
        if let Some(ref avd) = self.avd_name {
            return avd.replace('_', " ");
        }
        if let Some(ref model) = self.model
            && !model.is_empty()
        {
            return model.clone();
        }
        self.serial.clone().unwrap_or_else(|| "Android device".to_owned())
    }

    /// The key the panel selects on. An AVD keeps ONE identity across a boot — its name — so a
    /// device the user opened stays selected when it acquires a serial.
    #[must_use]
    pub fn key(&self) -> String {
        self.avd_name.as_ref().map_or_else(
            || format!("serial:{}", self.serial.as_deref().unwrap_or("?")),
            |avd| format!("avd:{avd}"),
        )
    }
}

/// One row of `adb devices -l`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listing {
    /// The transport id.
    pub serial: String,
    /// `adb`'s word for its state.
    pub state: String,
}

/// Parses `adb devices -l`, minus the header and the daemon chatter.
///
/// ```text
/// List of devices attached
/// emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 …
/// 39121FDJH000TR         unauthorized
/// ```
///
/// The qualifiers after the state are deliberately ignored: `model:` there is the same
/// `sdk_gphone64_arm64` that cannot name an emulator row, and the properties read separately are
/// both richer and the same round trip.
#[must_use]
pub fn parse_devices(output: &str) -> Vec<Listing> {
    let mut devices = Vec::new();
    for raw in output.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with("List of devices") || line.starts_with('*') {
            continue;
        }
        let mut fields = line.split_whitespace();
        let (Some(serial), Some(state)) = (fields.next(), fields.next()) else {
            continue;
        };
        devices.push(Listing {
            serial: serial.to_owned(),
            state: state.to_owned(),
        });
    }
    devices
}

/// Parses a whole `getprop` dump into a bag. Lines are `[key]: [value]`; anything else is skipped
/// rather than treated as an error, because `getprop` interleaves warnings on some builds.
///
/// One dump instead of one `getprop <key>` per field: eight round trips over `adb` cost eight
/// process spawns and eight USB/loopback exchanges, and this panel polls.
#[must_use]
pub fn parse_properties(output: &str) -> HashMap<String, String> {
    let mut properties = HashMap::new();
    for raw in output.lines() {
        let line = raw.trim();
        let Some(rest) = line.strip_prefix('[') else {
            continue;
        };
        let Some(separator) = rest.find("]: [") else {
            continue;
        };
        let Some(tail) = rest.strip_suffix(']') else {
            continue;
        };
        let Some(key) = rest.get(..separator) else {
            continue;
        };
        // The value runs from just past `]: [` to the closing bracket `strip_suffix` removed.
        let Some(value) = tail.get(separator + 4..) else {
            continue;
        };
        if key.is_empty() {
            continue;
        }
        properties.insert(key.to_owned(), value.to_owned());
    }
    properties
}

/// `Physical size: 1080x2400` — and `Override size: …` when the user has resized the display, which
/// WINS, because the override is what is actually being rendered and therefore what the stream will
/// carry.
#[must_use]
pub fn parse_display_size(output: &str) -> Option<(i64, i64)> {
    let mut physical = None;
    for raw in output.lines() {
        let line = raw.trim();
        let Some((label, value)) = line.split_once(':') else {
            continue;
        };
        let Some((left, right)) = value.trim().split_once('x') else {
            continue;
        };
        let (Ok(width), Ok(height)) = (left.parse::<i64>(), right.parse::<i64>()) else {
            continue;
        };
        if width <= 0 || height <= 0 {
            continue;
        }
        if label.starts_with("Override size") {
            return Some((width, height));
        }
        if label.starts_with("Physical size") && physical.is_none() {
            physical = Some((width, height));
        }
    }
    physical
}

/// `Physical density: 420`, with `Override density:` winning for the same reason.
#[must_use]
pub fn parse_density(output: &str) -> Option<i64> {
    let mut physical = None;
    for raw in output.lines() {
        let line = raw.trim();
        let Some((label, value)) = line.split_once(':') else {
            continue;
        };
        let Ok(density) = value.trim().parse::<i64>() else {
            continue;
        };
        if density <= 0 {
            continue;
        }
        if label.starts_with("Override density") {
            return Some(density);
        }
        if label.starts_with("Physical density") && physical.is_none() {
            physical = Some(density);
        }
    }
    physical
}

/// Folds a running target's properties into a device record.
#[must_use]
#[expect(
    clippy::implicit_hasher,
    reason = "the bag is built by this crate's own parser, never handed in with another hasher"
)]
pub fn running_device(
    serial: &str,
    state: &str,
    properties: &HashMap<String, String>,
    size: Option<(i64, i64)>,
    density: Option<i64>,
) -> Device {
    // `ro.boot.qemu.avd_name` is what maps a bare `emulator-5554` back to the AVD the user knows;
    // `ro.kernel.qemu` alone would say "an emulator" without saying WHICH.
    let avd_name = properties
        .get("ro.boot.qemu.avd_name")
        .or_else(|| properties.get("ro.kernel.qemu.avd_name"))
        .filter(|name| !name.is_empty())
        .cloned();
    Device {
        serial: Some(serial.to_owned()),
        avd_name,
        state: state.to_owned(),
        manufacturer: properties.get("ro.product.manufacturer").cloned(),
        model: properties.get("ro.product.model").cloned(),
        release: properties.get("ro.build.version.release").cloned(),
        api_level: properties
            .get("ro.build.version.sdk")
            .and_then(|value| value.parse().ok()),
        abi: properties.get("ro.product.cpu.abi").cloned(),
        width: size.map(|(width, _height)| width),
        height: size.map(|(_width, height)| height),
        density,
        form_factor: properties.get("ro.build.characteristics").cloned(),
    }
}

/// `emulator -list-avds` — one bare name per line. The binary prints unrelated warnings to the same
/// stream on some hosts, so a line with whitespace in it is chatter rather than a name.
#[must_use]
pub fn parse_avd_names(output: &str) -> Vec<String> {
    output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.contains(' ') && !line.starts_with('['))
        .map(str::to_owned)
        .collect()
}

/// An AVD's `config.ini`: plain `key=value`, no sections, no quoting.
#[must_use]
pub fn parse_config(output: &str) -> HashMap<String, String> {
    let mut config = HashMap::new();
    for raw in output.lines() {
        let line = raw.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        config.insert(key.to_owned(), value.trim().to_owned());
    }
    config
}

/// The record for an AVD that is not running, built from its `config.ini` alone.
#[must_use]
#[expect(
    clippy::implicit_hasher,
    reason = "the bag is built by this crate's own parser, never handed in with another hasher"
)]
pub fn avd_device(avd_name: &str, config: &HashMap<String, String>) -> Device {
    let number = |key: &str| config.get(key).and_then(|value| value.parse::<i64>().ok());
    Device {
        serial: None,
        avd_name: Some(avd_name.to_owned()),
        state: "offline".to_owned(),
        manufacturer: config.get("hw.device.manufacturer").cloned(),
        // `hw.device.name` is a profile id (`pixel_7`), so it is spelled out the same way the AVD
        // name is — the row shows "pixel 7" as a fact under a title of "Pixel API36".
        model: config.get("hw.device.name").map(|name| name.replace('_', " ")),
        release: None,
        api_level: api_level_from_system_image(config.get("image.sysdir.1").map(String::as_str)),
        abi: config.get("abi.type").cloned(),
        width: number("hw.lcd.width"),
        height: number("hw.lcd.height"),
        density: number("hw.lcd.density"),
        form_factor: config.get("tag.id").cloned(),
    }
}

/// The `avd name` console reply → the AVD's name, or `None`.
///
/// This is how a BOOTING emulator gets its name: `adbd` inside the guest answers no shell until
/// well into the boot (measured 2026-08-07: ~21 s of `offline` on a cold start), but the QEMU
/// console on the host side is up from process launch. The reply is the name on its own line
/// followed by a bare `OK`; anything refused says `KO: …`.
#[must_use]
pub fn parse_console_avd_name(reply: Option<&str>) -> Option<String> {
    let reply = reply?;
    // The console speaks CRLF; `lines()` splits on `\n` and the `\r` comes off in the trim.
    for raw in reply.lines() {
        let line = raw.trim();
        if line.is_empty() || line == "OK" {
            continue;
        }
        if line.starts_with("KO") {
            return None;
        }
        // An AVD name never contains whitespace (`avdmanager` refuses it); a line with any is
        // console chatter, not a name.
        if line.contains(char::is_whitespace) {
            continue;
        }
        return Some(line.to_owned());
    }
    None
}

/// `system-images/android-36/google_apis/arm64-v8a/` → `36`.
///
/// The system-image path is the only place a non-running AVD records its API level — `config.ini`
/// has no `ro.build.version.sdk` because nothing has booted to produce one. A preview release names
/// its directory after a letter (`android-Baklava`), which yields `None` rather than a wrong
/// number.
#[must_use]
pub fn api_level_from_system_image(directory: Option<&str>) -> Option<i64> {
    directory?
        .split('/')
        .find_map(|component| component.strip_prefix("android-"))
        .and_then(|level| level.parse().ok())
}

/// The list the panel draws: every running target, plus every AVD on disk that is not among them.
///
/// A booted AVD appears ONCE, as its running record — that record has measured display metrics and
/// a live state, which strictly dominate the declared ones. The `config.ini` fallback fills only
/// the fields a running device does not report, which for a healthy device is nothing; it is
/// written as a merge anyway so a device whose `getprop` timed out still shows its declared size
/// instead of an empty row.
#[must_use]
pub fn merge(running: Vec<Device>, avds: Vec<Device>) -> Vec<Device> {
    let mut declared: HashMap<String, Device> = HashMap::new();
    for avd in &avds {
        if let Some(ref name) = avd.avd_name {
            declared.entry(name.clone()).or_insert_with(|| avd.clone());
        }
    }

    let booted: Vec<String> = running.iter().filter_map(|d| d.avd_name.clone()).collect();
    let mut devices: Vec<Device> = running
        .into_iter()
        .filter_map(|device| {
            if let Some(ref name) = device.avd_name {
                let filled = declared
                    .get(name)
                    .map_or_else(|| device.clone(), |declaration| filling(&device, declaration));
                return Some(filled);
            }
            // An emulator serial that cannot yet say WHICH AVD it is: for the first beat of a boot
            // the serial registers with `adb` before the QEMU console accepts, so the name lookup
            // comes back empty. Without a name the row has no `is_emulator`, no identity and no AVD
            // to fold into — it would render as a physical phone that is "Not responding" for a
            // second or two. Hold it back; the next poll names it. (The cost: an emulator whose
            // console never answers stays hidden while offline — a row that would have been an
            // unusable stranger anyway.)
            if device.state != "device"
                && device
                    .serial
                    .as_ref()
                    .is_some_and(|serial| serial.starts_with("emulator-"))
            {
                return None;
            }
            Some(device)
        })
        .collect();

    for avd in avds {
        let name = avd.avd_name.clone().unwrap_or_default();
        if !booted.contains(&name) {
            devices.push(avd);
        }
    }
    devices
}

/// A running record with its gaps filled from the AVD's declared definition.
///
/// Live facts win — only the fields the probe could not produce fall back, which is the whole list
/// for a device still booting: it answers no shell, but its `config.ini` was exact before it ever
/// booted.
#[must_use]
pub fn filling(device: &Device, avd: &Device) -> Device {
    Device {
        serial: device.serial.clone(),
        avd_name: device.avd_name.clone(),
        state: device.state.clone(),
        manufacturer: device.manufacturer.clone().or_else(|| avd.manufacturer.clone()),
        model: device.model.clone().or_else(|| avd.model.clone()),
        release: device.release.clone().or_else(|| avd.release.clone()),
        api_level: device.api_level.or(avd.api_level),
        abi: device.abi.clone().or_else(|| avd.abi.clone()),
        width: device.width.or(avd.width),
        height: device.height.or(avd.height),
        density: device.density.or(avd.density),
        form_factor: device.form_factor.clone().or_else(|| avd.form_factor.clone()),
    }
}

#[cfg(test)]
mod tests {
    // Fixtures are REAL output, captured 2026-08-04 from `adb` 1.0.41 / emulator 36 against a
    // booted `Pixel_API36` AVD on mac-studio, and carried over verbatim from the Swift
    // catalogue this replaces. These formats are conventions rather than contracts, and a
    // recorded fixture that stops matching is the only warning we get that one has moved.
    use std::collections::HashMap;

    use super::{
        Device, api_level_from_system_image, avd_device, merge, parse_avd_names, parse_config,
        parse_console_avd_name, parse_density, parse_devices, parse_display_size, parse_properties,
        running_device,
    };

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn devices_parse_and_the_header_is_skipped() {
        let output = "List of devices attached\nemulator-5554          device product:sdk_gphone64_arm64 \
                      model:sdk_gphone64_arm64\n39121FDJH000TR         unauthorized\n";
        let devices = parse_devices(output);
        assert_eq!(devices.len(), 2);
        assert_eq!(devices.first().map(|d| d.serial.as_str()), Some("emulator-5554"));
        assert_eq!(devices.first().map(|d| d.state.as_str()), Some("device"));
        assert_eq!(devices.get(1).map(|d| d.state.as_str()), Some("unauthorized"));
    }

    #[test]
    fn daemon_chatter_is_skipped() {
        let output = "* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList \
                      of devices attached\nemulator-5554\tdevice";
        assert_eq!(
            parse_devices(output)
                .into_iter()
                .map(|d| d.serial)
                .collect::<Vec<_>>(),
            vec!["emulator-5554".to_owned()]
        );
    }

    #[test]
    fn a_property_dump_parses_and_an_empty_value_is_a_real_value() {
        let output = "[ro.product.model]: [sdk_gphone64_arm64]\n[ro.product.manufacturer]: \
                      [Google]\n[ro.build.version.sdk]: [36]\n[ro.boot.qemu.avd_name]: \
                      [Pixel_API36]\n[persist.sys.locale]: []\ngarbage line without brackets";
        let properties = parse_properties(output);
        assert_eq!(
            properties.get("ro.product.model").map(String::as_str),
            Some("sdk_gphone64_arm64")
        );
        assert_eq!(
            properties.get("ro.boot.qemu.avd_name").map(String::as_str),
            Some("Pixel_API36")
        );
        // An empty value is a real value, not an absent key — a device with no locale set must not
        // read as a device whose property dump was truncated.
        assert_eq!(properties.get("persist.sys.locale").map(String::as_str), Some(""));
        assert!(!properties.contains_key("garbage line without brackets"));
    }

    #[test]
    fn physical_display_metrics_are_read() {
        assert_eq!(parse_display_size("Physical size: 1080x2400"), Some((1080, 2400)));
        assert_eq!(parse_density("Physical density: 420"), Some(420));
    }

    #[test]
    fn an_override_beats_the_physical_value() {
        // An override is what is actually being rendered, so it is what the stream will carry.
        assert_eq!(
            parse_display_size("Physical size: 1080x2400\nOverride size: 720x1600"),
            Some((720, 1600))
        );
        assert_eq!(
            parse_density("Physical density: 420\nOverride density: 320"),
            Some(320)
        );
    }

    #[test]
    fn a_shut_down_device_is_built_from_its_config() {
        // Joined rather than written as one long literal on purpose: `format_strings` reflows a
        // literal at the column it reaches, and a break that lands between the `\` and the `n` of
        // an escape silently rewrites the fixture into a different one. A line per line is
        // also how the file being imitated actually looks.
        let config = parse_config(
            &[
                "abi.type=arm64-v8a",
                "hw.device.manufacturer=Google",
                "hw.device.name=pixel_7",
                "hw.lcd.density=420",
                "hw.lcd.height=2400",
                "hw.lcd.width=1080",
                "image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/",
            ]
            .join("\n"),
        );
        let device = avd_device("Pixel_API36", &config);
        // The fact the iOS panel could not have: an AVD that has never booted still knows its exact
        // screen (`docs/47` records the opposite for CoreSimulator).
        assert_eq!(device.width, Some(1080));
        assert_eq!(device.height, Some(2400));
        assert_eq!(device.density, Some(420));
        assert_eq!(device.abi.as_deref(), Some("arm64-v8a"));
        assert_eq!(device.api_level, Some(36));
        assert_eq!(device.model.as_deref(), Some("pixel 7"));
        assert!(!device.is_running());
        assert!(device.is_emulator());
    }

    #[test]
    fn the_api_level_comes_from_the_system_image_path() {
        assert_eq!(
            api_level_from_system_image(Some("system-images/android-36/google_apis/arm64-v8a/")),
            Some(36)
        );
        // A preview release names its directory after a letter. `None` beats a wrong number.
        assert_eq!(
            api_level_from_system_image(Some("system-images/android-Baklava/google_apis/arm64-v8a/")),
            None
        );
        assert_eq!(api_level_from_system_image(None), None);
    }

    #[test]
    fn avd_names_parse_and_warnings_are_rejected() {
        let output = "INFO    | Storing crashdata in: /tmp/foo\nPixel_API36\nTablet_API34";
        assert_eq!(parse_avd_names(output), vec![
            "Pixel_API36".to_owned(),
            "Tablet_API34".to_owned()
        ]);
    }

    #[test]
    fn an_emulator_is_titled_by_its_avd_not_its_model() {
        // `ro.product.model` is `sdk_gphone64_arm64` for EVERY AVD on the host, so it cannot title
        // a row; the AVD name can, and it is what the user typed.
        let device = running_device(
            "emulator-5554",
            "device",
            &map(&[
                ("ro.product.model", "sdk_gphone64_arm64"),
                ("ro.boot.qemu.avd_name", "Pixel_API36"),
            ]),
            Some((1080, 2400)),
            Some(420),
        );
        assert_eq!(device.display_name(), "Pixel API36");
        assert!(device.is_emulator());
    }

    #[test]
    fn a_physical_device_is_titled_by_its_model() {
        let device = running_device(
            "39121FDJH000TR",
            "device",
            &map(&[("ro.product.model", "Pixel 7 Pro")]),
            None,
            None,
        );
        assert_eq!(device.display_name(), "Pixel 7 Pro");
        assert!(!device.is_emulator());
        assert_eq!(device.key(), "serial:39121FDJH000TR");
    }

    #[test]
    fn a_booted_avd_does_not_also_appear_as_available() {
        let running = running_device(
            "emulator-5554",
            "device",
            &map(&[("ro.boot.qemu.avd_name", "Pixel_API36")]),
            Some((1080, 2400)),
            Some(420),
        );
        let on_disk = vec![
            avd_device("Pixel_API36", &map(&[("hw.lcd.width", "1080")])),
            avd_device("Tablet_API34", &map(&[("hw.lcd.width", "1600")])),
        ];
        let merged = merge(vec![running], on_disk);
        assert_eq!(merged.len(), 2);
        assert_eq!(
            merged
                .iter()
                .filter(|d| d.avd_name.as_deref() == Some("Pixel_API36"))
                .count(),
            1
        );
        assert!(merged.first().is_some_and(Device::is_running));
        assert!(merged.get(1).is_some_and(|d| !d.is_running()));
    }

    #[test]
    fn an_avd_key_is_stable_across_a_boot() {
        let off = avd_device("Pixel_API36", &HashMap::new());
        let on = running_device(
            "emulator-5554",
            "device",
            &map(&[("ro.boot.qemu.avd_name", "Pixel_API36")]),
            None,
            None,
        );
        assert_eq!(off.key(), on.key());
    }

    #[test]
    fn the_console_avd_name_is_the_line_before_the_verdict() {
        assert_eq!(
            parse_console_avd_name(Some("Pixel_API36\r\nOK\r\n")).as_deref(),
            Some("Pixel_API36")
        );
    }

    #[test]
    fn the_console_avd_name_rejects_refusals_and_silence() {
        assert_eq!(parse_console_avd_name(None), None);
        assert_eq!(parse_console_avd_name(Some("KO: unknown command\r\n")), None);
        assert_eq!(parse_console_avd_name(Some("OK\r\n")), None);
    }

    #[test]
    fn a_booting_emulator_folds_into_its_avd_row_with_declared_facts() {
        let booting = Device::bare(
            Some("emulator-5554".to_owned()),
            Some("Pixel_API36".to_owned()),
            "offline",
        );
        let on_disk = avd_device(
            "Pixel_API36",
            &map(&[
                ("hw.lcd.width", "1080"),
                ("hw.lcd.height", "2400"),
                ("tag.id", "google_apis"),
            ]),
        );
        let merged = merge(vec![booting], vec![on_disk]);
        assert_eq!(merged.len(), 1);
        let first = merged.first();
        assert_eq!(first.and_then(|d| d.serial.as_deref()), Some("emulator-5554"));
        assert_eq!(first.map(|d| d.state.as_str()), Some("offline"));
        assert_eq!(first.and_then(|d| d.width), Some(1080));
        assert_eq!(first.and_then(|d| d.height), Some(2400));
    }

    #[test]
    fn a_nameless_booting_emulator_serial_is_held_back_not_shown_as_a_phone() {
        // Observed live 2026-08-07: the serial registers with `adb` before the QEMU console
        // accepts, so for a poll or two the emulator cannot say WHICH AVD it is.
        let nameless = Device::bare(Some("emulator-5554".to_owned()), None, "offline");
        let on_disk = avd_device("Pixel_API36", &HashMap::new());
        let merged = merge(vec![nameless], vec![on_disk]);
        assert_eq!(merged.iter().map(Device::key).collect::<Vec<_>>(), vec![
            "avd:Pixel_API36".to_owned()
        ]);
    }

    #[test]
    fn an_offline_physical_device_still_lists() {
        // The hold-back is for EMULATOR serials alone: an offline phone is a real state the user
        // can see and fix, and it has no console to wait on.
        let phone = Device::bare(Some("R58M123ABC".to_owned()), None, "offline");
        let merged = merge(vec![phone], Vec::new());
        assert_eq!(
            merged.into_iter().filter_map(|d| d.serial).collect::<Vec<_>>(),
            vec!["R58M123ABC".to_owned()]
        );
    }

    #[test]
    fn live_facts_win_the_fold() {
        let live = running_device(
            "emulator-5554",
            "device",
            &map(&[("ro.boot.qemu.avd_name", "Pixel_API36")]),
            Some((1080, 2400)),
            Some(420),
        );
        let on_disk = avd_device(
            "Pixel_API36",
            &map(&[("hw.lcd.width", "999"), ("hw.lcd.density", "160")]),
        );
        let merged = merge(vec![live], vec![on_disk]);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged.first().and_then(|d| d.width), Some(1080));
        assert_eq!(merged.first().and_then(|d| d.density), Some(420));
    }
}
