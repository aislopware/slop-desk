//! The physical device around the screen, as `/simulators/<udid>/definition.json` describes it.
//!
//! The panel drew the stream as a bare rectangle on grey before this. That is what an iOS screen is
//! NOT: a phone has a body, the body has side buttons, and the screen has rounded corners that clip
//! the content. `baguette serve` already knows all of it — the route hands back `DeviceKit`'s own
//! bezel artwork plus the geometry to place it — so drawing a real device is a decode away, and
//! inventing the proportions locally would be both wrong and a per-model maintenance job forever.
//!
//! ## Percentages, not points
//!
//! Every button box is a fraction of the VIEWPORT, so one decode scales to any panel width without
//! a second layout pass. Boxes legitimately fall OUTSIDE 0–100%: side buttons protrude from the
//! body (`leftPct` is negative on the left rail, past 100 on the right), which is also why they
//! draw UNDER the bezel image — the bezel's own edge is what makes a protruding button look seated
//! rather than pasted on. [`Chrome::bleed`] is the rect that keeps the protrusion on screen; laying
//! out to the viewport alone clips a side button at the panel's edge.
//!
//! ## Untrusted, like every other foreign decoder in this crate
//!
//! Validate then drop. A degenerate viewport or screen rect fails the WHOLE decode — there is
//! nothing to draw, and every consumer divides by those numbers. One unusable button is dropped
//! alone, because a model whose button art the server cannot produce still gets a correct screen in
//! the right place.
//!
//! ## Two places this is deliberately stricter than the Swift it replaces
//!
//! `JSONSerialization` hands a JSON `true` over as an `NSNumber`, so `as? Double` accepted it as
//! `1.0`; [`serde_json`] does not, and a boolean where a width belongs is not a width. And an
//! array whose elements are not all objects reads as NO buttons rather than as the objects among
//! them — that IS the Swift behaviour (`as? [[String: Any]]` is all-or-nothing over the elements)
//! and it is kept, because a server that has changed the element shape is not one to guess with.

use serde_json::{Map, Value};
use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

/// Where the live pixels sit inside the body, and the artwork that surrounds them.
#[derive(Debug, Clone, PartialEq)]
pub struct Screen {
    /// The bezel image's own pixel size, and the coordinate space every other number here is in.
    pub viewport: VideoSize,
    /// Where the live pixels go inside that viewport.
    pub rect: VideoRect,
    /// The screen's corner radius, in viewport units. Not cosmetic: unclipped video overhangs the
    /// body's rounded corners and reads as a rendering bug.
    pub clip_radius: f64,
    /// The body WITHOUT its side buttons drawn in. The panel wants this one — it draws the buttons
    /// itself so they can move under a press.
    pub bare_path: String,
    /// The same body with the buttons baked in, for a still preview where nothing is pressable.
    pub rest_path: String,
}

/// One side button: where it sits, what it looks like, and what to send when it is clicked.
#[derive(Debug, Clone, PartialEq)]
pub struct Button {
    /// The server's own identifier for the button.
    pub id: String,
    /// Fraction of the viewport width, 0–100, and deliberately allowed outside that range.
    pub left_percent: f64,
    /// Fraction of the viewport height, 0–100, and deliberately allowed outside that range.
    pub top_percent: f64,
    /// Fraction of the viewport width. Always positive — a zero-area button is dropped at decode.
    pub width_percent: f64,
    /// Fraction of the viewport height. Always positive, for the same reason.
    pub height_percent: f64,
    /// The artwork for the button at rest.
    pub rest_path: String,
    /// The artwork for the button held down.
    pub pressed_path: String,
    /// What to send when it is clicked — the server's own button name, taken from the envelope it
    /// supplies rather than assumed to equal [`Button::id`].
    pub envelope_button: String,
}

impl Button {
    /// The button's frame inside a viewport drawn at `viewport`.
    ///
    /// The multiply comes before the divide, and stays two operations: this is the transform the
    /// renderer and the hit test both invert, and a reassociation here is a click landing beside
    /// the pixel it was drawn for.
    #[must_use]
    pub fn frame(&self, viewport: VideoSize) -> VideoRect {
        VideoRect::xywh(
            viewport.width * self.left_percent / 100.0,
            viewport.height * self.top_percent / 100.0,
            viewport.width * self.width_percent / 100.0,
            viewport.height * self.height_percent / 100.0,
        )
    }
}

/// One decoded device body.
#[derive(Debug, Clone, PartialEq)]
pub struct Chrome {
    /// `DeviceKit`'s model name, or the empty string when the envelope carries no identity.
    pub model: String,
    /// The screen and the artwork around it.
    pub screen: Screen,
    /// The side buttons, in the server's own order, minus any that cannot be drawn.
    pub buttons: Vec<Button>,
}

impl Chrome {
    /// Decode one `definition.json`, or `None` when there is no drawable device in it.
    #[must_use]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let root: Value = serde_json::from_slice(bytes).ok()?;
        let root = root.as_object()?;
        let screen = decode_screen(root.get("screen"))?;
        let model = root
            .get("identity")
            .and_then(Value::as_object)
            .and_then(|identity| identity.get("model"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        Some(Self {
            model,
            screen,
            buttons: decode_buttons(root.get("buttons")),
        })
    }

    /// The whole viewport including whatever protrudes past it.
    ///
    /// Side buttons stick out of the body, so laying out to the viewport alone would clip them at
    /// the panel's edge. Every rect folded in here has a positive extent — the viewport because the
    /// decode refused a degenerate one, each button because a zero-area box was dropped — so the
    /// union needs no standardising pass.
    #[must_use]
    pub fn bleed(&self) -> VideoRect {
        let viewport = VideoRect::new(VideoPoint::new(0.0, 0.0), self.screen.viewport);
        self.buttons.iter().fold(viewport, |bleed, button| {
            union(bleed, button.frame(self.screen.viewport))
        })
    }
}

/// The smallest rect containing both. NaN-ignoring, the way `f64::min`/`max` are everywhere else in
/// this repository — a NaN percentage must not swallow the viewport.
fn union(one: VideoRect, other: VideoRect) -> VideoRect {
    let min_x = one.min_x().min(other.min_x());
    let min_y = one.min_y().min(other.min_y());
    let max_x = one.max_x().max(other.max_x());
    let max_y = one.max_y().max(other.max_y());
    VideoRect::xywh(min_x, min_y, max_x - min_x, max_y - min_y)
}

/// The screen half, which either decodes whole or fails the envelope.
fn decode_screen(value: Option<&Value>) -> Option<Screen> {
    let screen = value?.as_object()?;
    let viewport = screen.get("viewport")?.as_object()?;
    let live = screen.get("rect")?.as_object()?;
    let images = screen.get("bezelImage")?.as_object()?;
    let bare = images.get("bare")?.as_str()?;
    let rest = images.get("rest")?.as_str()?;
    if bare.is_empty() || rest.is_empty() {
        return None;
    }
    let size = VideoSize::new(number(viewport, "width"), number(viewport, "height"));
    let frame = VideoRect::xywh(
        number(live, "x"),
        number(live, "y"),
        number(live, "width"),
        number(live, "height"),
    );
    // A zero anywhere here means there is no drawable device, and every consumer divides by these.
    // Written as a positive test so a NaN — which compares false against everything — is refused
    // rather than let through by a negated one.
    if !(size.width > 0.0 && size.height > 0.0 && frame.size.width > 0.0 && frame.size.height > 0.0) {
        return None;
    }
    Some(Screen {
        viewport: size,
        rect: frame,
        clip_radius: 0.0_f64.max(number(screen, "clipRadius")),
        bare_path: bare.to_owned(),
        rest_path: rest.to_owned(),
    })
}

/// The button list. An array that is not wholly objects reads as none — see the module header.
fn decode_buttons(value: Option<&Value>) -> Vec<Button> {
    let Some(entries) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    if !entries.iter().all(Value::is_object) {
        return Vec::new();
    }
    entries.iter().filter_map(decode_button).collect()
}

/// One button, or `None` for one that cannot be drawn or hit.
fn decode_button(entry: &Value) -> Option<Button> {
    let entry = entry.as_object()?;
    let id = entry.get("id")?.as_str()?;
    if id.is_empty() {
        return None;
    }
    let box_ = entry.get("box")?.as_object()?;
    let images = entry.get("images")?.as_object()?;
    let rest = images.get("rest")?.as_str()?;
    let pressed = images.get("pressed")?.as_str()?;
    if rest.is_empty() || pressed.is_empty() {
        return None;
    }
    let width = number(box_, "widthPct");
    let height = number(box_, "heightPct");
    // A button with no area cannot be drawn or hit. Dropping it alone keeps the other three.
    if !(width > 0.0 && height > 0.0) {
        return None;
    }
    let envelope = entry
        .get("envelope")
        .and_then(Value::as_object)
        .and_then(|envelope| envelope.get("button"))
        .and_then(Value::as_str)
        .unwrap_or(id);
    Some(Button {
        id: id.to_owned(),
        left_percent: number(box_, "leftPct"),
        top_percent: number(box_, "topPct"),
        width_percent: width,
        height_percent: height,
        rest_path: rest.to_owned(),
        pressed_path: pressed.to_owned(),
        envelope_button: envelope.to_owned(),
    })
}

/// A JSON number reaches this decoder as an integer or a float depending only on how it was
/// written, and every field here is legitimately either — `"x": 18` beside `"leftPct": -1.15` in
/// the same object. One accessor covers both rather than a pair of casts at each field. Anything
/// that is not a number — absent, a string, a boolean — is zero.
fn number(object: &Map<String, Value>, key: &str) -> f64 {
    object.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::{VideoRect, VideoSize};

    use super::Chrome;

    /// A trimmed copy of what the server answers for an iPhone 17 Pro, measured 2026-08-04.
    const SCREEN: &str = r#"{
      "bezelImage": { "bare": "/simulators/U/bezel.png?buttons=false",
                      "rest": "/simulators/U/bezel.png" },
      "clipRadius": 62,
      "rect": { "x": 18, "y": 18, "width": 400, "height": 872 },
      "viewport": { "width": 436, "height": 908 }
    }"#;

    /// The one button that envelope carries.
    const POWER: &str = r#"{ "id": "power",
      "box": { "leftPct": 97.0, "topPct": 28.8, "widthPct": 3.6, "heightPct": 11.1 },
      "images": { "rest": "/simulators/U/chrome-button/power.png",
                  "pressed": "/simulators/U/chrome-button/power-down.png" },
      "envelope": { "button": "power", "type": "button" } }"#;

    fn decode(buttons: &str, screen: &str) -> Option<Chrome> {
        let text = format!(
            r#"{{ "identity": {{ "model": "iPhone 17 Pro" }},
                  "screen": {screen}, "buttons": [{buttons}] }}"#
        );
        Chrome::decode(text.as_bytes())
    }

    fn measured() -> Option<Chrome> {
        decode(POWER, SCREEN)
    }

    /// The screen geometry lands in viewport units, and the BARE body is the reference the panel
    /// keeps — it draws the buttons itself so they can move under a press.
    #[test]
    fn the_screen_geometry_decodes_in_viewport_units() {
        let chrome = measured();
        assert_eq!(
            chrome.as_ref().map(|chrome| chrome.model.as_str()),
            Some("iPhone 17 Pro")
        );
        assert_eq!(
            chrome.as_ref().map(|chrome| chrome.screen.viewport),
            Some(VideoSize::new(436.0, 908.0))
        );
        assert_eq!(
            chrome.as_ref().map(|chrome| chrome.screen.rect),
            Some(VideoRect::xywh(18.0, 18.0, 400.0, 872.0))
        );
        assert_eq!(
            chrome.as_ref().map(|chrome| chrome.screen.bare_path.as_str()),
            Some("/simulators/U/bezel.png?buttons=false")
        );
        let radius = chrome.map(|chrome| chrome.screen.clip_radius).unwrap_or_default();
        assert!((radius - 62.0).abs() < f64::EPSILON);
    }

    /// A box is a fraction of the viewport and may lie outside it — a side button protrudes from
    /// the body on purpose.
    #[test]
    fn a_button_box_is_a_fraction_of_the_viewport_and_may_lie_outside_it() {
        let chrome = measured();
        assert_eq!(
            chrome
                .as_ref()
                .and_then(|chrome| chrome.buttons.first())
                .map(|button| button.id.clone()),
            Some("power".to_owned())
        );
        let frame = chrome
            .as_ref()
            .and_then(|chrome| {
                chrome
                    .buttons
                    .first()
                    .map(|button| button.frame(chrome.screen.viewport))
            })
            .unwrap_or(VideoRect::xywh(0.0, 0.0, 0.0, 0.0));
        assert!((frame.min_x() - 436.0 * 0.970).abs() < 0.01);
        assert!((frame.size.height - 908.0 * 0.111).abs() < 0.01);
        // Past the viewport's right edge on purpose: a side button protrudes from the body.
        assert!(frame.max_x() > 436.0);
    }

    /// Laying out to the viewport alone would clip the side buttons at the panel's edge, which is
    /// the bug the bleed exists to prevent.
    #[test]
    fn the_bleed_covers_what_protrudes_past_the_body() {
        let bleed = measured().map_or(VideoRect::xywh(-1.0, -1.0, -1.0, -1.0), |chrome| chrome.bleed());
        assert!((bleed.min_x() - 0.0).abs() < f64::EPSILON);
        assert!(bleed.size.width > 436.0);
    }

    /// A left-rail button extends the bleed to a NEGATIVE x rather than being clipped.
    #[test]
    fn a_left_rail_button_extends_the_bleed_below_zero() {
        let left = r#"{ "id": "action",
          "box": { "leftPct": -1.15, "topPct": 17.6, "widthPct": 3.67, "heightPct": 3.74 },
          "images": { "rest": "/a.png", "pressed": "/b.png" },
          "envelope": { "button": "action", "type": "button" } }"#;
        let min_x = decode(left, SCREEN)
            .map(|chrome| chrome.bleed().min_x())
            .unwrap_or_default();
        assert!(min_x < 0.0);
    }

    /// The envelope name comes from the SERVER, and falls back to the id when the server omits it.
    /// They match for every button seen so far; reading the id instead would be a silent mismatch
    /// the first time one is named differently.
    #[test]
    fn the_envelope_name_is_the_servers_and_falls_back_to_the_id() {
        let renamed = r#"{ "id": "side",
          "box": { "leftPct": 0, "topPct": 0, "widthPct": 1, "heightPct": 1 },
          "images": { "rest": "/a.png", "pressed": "/b.png" },
          "envelope": { "button": "side-button", "type": "button" } }"#;
        assert_eq!(envelope_name(renamed), Some("side-button".to_owned()));
        let bare = r#"{ "id": "home",
          "box": { "leftPct": 0, "topPct": 0, "widthPct": 1, "heightPct": 1 },
          "images": { "rest": "/a.png", "pressed": "/b.png" } }"#;
        assert_eq!(envelope_name(bare), Some("home".to_owned()));
    }

    fn envelope_name(button: &str) -> Option<String> {
        decode(button, SCREEN).and_then(|chrome| {
            chrome
                .buttons
                .first()
                .map(|button| button.envelope_button.clone())
        })
    }

    /// A degenerate screen fails the WHOLE decode, because there is nothing to draw and every
    /// consumer divides by these numbers.
    #[test]
    fn a_degenerate_screen_fails_the_whole_decode() {
        let zero_rect = r#"{ "bezelImage": { "bare": "/a.png", "rest": "/b.png" }, "clipRadius": 4,
          "rect": { "x": 0, "y": 0, "width": 0, "height": 872 },
          "viewport": { "width": 436, "height": 908 } }"#;
        assert_eq!(decode(POWER, zero_rect), None);
        let zero_viewport = r#"{ "bezelImage": { "bare": "/a.png", "rest": "/b.png" },
          "rect": { "x": 0, "y": 0, "width": 400, "height": 872 },
          "viewport": { "width": 0, "height": 908 } }"#;
        assert_eq!(decode(POWER, zero_viewport), None);
        // A reference the server left blank is no reference at all.
        let blank_art = r#"{ "bezelImage": { "bare": "", "rest": "/b.png" }, "clipRadius": 4,
          "rect": { "x": 0, "y": 0, "width": 400, "height": 872 },
          "viewport": { "width": 436, "height": 908 } }"#;
        assert_eq!(decode(POWER, blank_art), None);
    }

    /// Nothing that is not an object carrying a screen is a device body.
    #[test]
    fn a_root_that_is_not_a_body_is_refused() {
        assert_eq!(Chrome::decode(b"{}"), None);
        assert_eq!(Chrome::decode(b"[]"), None);
        assert_eq!(Chrome::decode(b"not json"), None);
        assert_eq!(Chrome::decode(b""), None);
        assert_eq!(Chrome::decode(&[0xFF, 0xFE]), None);
    }

    /// One unusable button is dropped ALONE rather than failing the body — the body is what
    /// matters, and a model whose button art the server cannot produce still gets a correct screen
    /// in the right place.
    #[test]
    fn one_unusable_button_is_dropped_alone() {
        let mixed = format!(
            r#"{{ "id": "bad", "box": {{ "leftPct": 0, "topPct": 0, "widthPct": 0, "heightPct": 0 }},
                  "images": {{ "rest": "/a.png", "pressed": "/b.png" }} }}, {POWER}"#
        );
        let ids = decode(&mixed, SCREEN).map(|chrome| {
            chrome
                .buttons
                .iter()
                .map(|button| button.id.clone())
                .collect::<Vec<_>>()
        });
        assert_eq!(ids, Some(vec!["power".to_owned()]));
    }

    /// A button missing its id, its box or either half of its artwork is dropped the same way.
    #[test]
    fn a_button_missing_a_required_part_is_dropped() {
        for broken in [
            r#"{ "box": { "widthPct": 1, "heightPct": 1 },
                 "images": { "rest": "/a.png", "pressed": "/b.png" } }"#,
            r#"{ "id": "", "box": { "widthPct": 1, "heightPct": 1 },
                 "images": { "rest": "/a.png", "pressed": "/b.png" } }"#,
            r#"{ "id": "x", "images": { "rest": "/a.png", "pressed": "/b.png" } }"#,
            r#"{ "id": "x", "box": { "widthPct": 1, "heightPct": 1 } }"#,
            r#"{ "id": "x", "box": { "widthPct": 1, "heightPct": 1 },
                 "images": { "rest": "", "pressed": "/b.png" } }"#,
            r#"{ "id": "x", "box": { "widthPct": 1, "heightPct": 1 },
                 "images": { "rest": "/a.png", "pressed": "" } }"#,
        ] {
            let count = decode(broken, SCREEN).map(|chrome| chrome.buttons.len());
            assert_eq!(count, Some(0), "{broken} should have been dropped");
        }
    }

    /// A `buttons` value that is not wholly objects reads as NO buttons — the Swift
    /// `as? [[String: Any]]` behaviour, kept because a server that has changed the element shape is
    /// not one to guess with.
    #[test]
    fn a_button_array_that_is_not_wholly_objects_reads_as_none() {
        let count = decode(&format!("7, {POWER}"), SCREEN).map(|chrome| chrome.buttons.len());
        assert_eq!(count, Some(0));
        let not_an_array = format!(r#"{{ "screen": {SCREEN}, "buttons": 7 }}"#);
        let count = Chrome::decode(not_an_array.as_bytes()).map(|chrome| chrome.buttons.len());
        assert_eq!(count, Some(0));
    }

    /// A field that is not a number is ZERO rather than a decode failure, and a negative corner
    /// radius floors at zero rather than reaching a clip path.
    #[test]
    fn a_non_number_is_zero_and_a_negative_radius_floors() {
        let negative = SCREEN.replace(r#""clipRadius": 62"#, r#""clipRadius": -8"#);
        let radius = decode(POWER, &negative).map_or(-1.0, |chrome| chrome.screen.clip_radius);
        assert!((radius - 0.0).abs() < f64::EPSILON);
        let worded = SCREEN.replace(r#""clipRadius": 62"#, r#""clipRadius": "large""#);
        let radius = decode(POWER, &worded).map_or(-1.0, |chrome| chrome.screen.clip_radius);
        assert!((radius - 0.0).abs() < f64::EPSILON);
        // …but a non-number where an EXTENT belongs is a degenerate device, and that still fails.
        let worded_width = SCREEN.replace(r#""width": 436"#, r#""width": "wide""#);
        assert_eq!(decode(POWER, &worded_width), None);
    }

    /// A missing identity is an empty model, not a refusal: the geometry is what the panel needs.
    #[test]
    fn a_missing_identity_is_an_empty_model() {
        let text = format!(r#"{{ "screen": {SCREEN}, "buttons": [] }}"#);
        let chrome = Chrome::decode(text.as_bytes());
        assert_eq!(chrome.as_ref().map(|chrome| chrome.model.as_str()), Some(""));
        assert_eq!(chrome.map(|chrome| chrome.buttons.len()), Some(0));
    }
}
