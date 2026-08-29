//! How the simulator panel ASKS — the verb, the budget, the cache policy and the body for every
//! non-streaming call it makes.
//!
//! [`crate::sim_routes`] answers WHERE a request goes. This answers everything else about it, and
//! the two are separate for the reason they were separate in Swift: a route is a string a test can
//! read, and a request is a table nobody had written down. What lived at the call sites instead was
//! eleven `URLSession` invocations, each spelling its own method, its own timeout and its own cache
//! policy inline — four of which are the same three values, two of which are not, and none of which
//! any test could see.
//!
//! ## The three that are decisions rather than plumbing
//!
//! - **`status-bar` and `location` are ONE route with TWO verbs.** Clearing is a `DELETE`, not a
//!   flag in the body: measured 2026-08-04, the server answers an empty or flag-only `POST` to
//!   `status-bar` with `400 set at least one status-bar field`, so an override-shaped clear does
//!   not merely no-op — it fails. `location` is the same shape, and its own `400` names the three
//!   body forms it accepts.
//! - **The device list must NOT be cached and the bezel artwork MUST be.** The whole point of a
//!   poll is to see a boot land, and a cached list shows the state the panel already believed.
//!   Artwork is per MODEL and never changes, so re-fetching it per selection is bytes over the mesh
//!   for a picture that cannot have moved. Those are opposite answers to one question, which is why
//!   the answer is in a table rather than in a default.
//! - **An upload gets its own budget.** An `.app` bundle is megabytes over the mesh; timing it out
//!   at the control budget would abort every install that is actually working.
//!
//! ## Why the BODIES are here too
//!
//! Both are JSON the panel writes rather than reads, and both were `JSONSerialization` calls on the
//! near side — the encoder that RAISES an Objective-C exception rather than throwing, which is the
//! same hazard `crate::android_bridge`'s request line was moved for. The status bar's preset is
//! eight key/value pairs the server rejects WHOLE on one bad field, so a plausible synonym costs
//! the entire request: `batteryState` is `discharging`, never "unplugged". A body that is written
//! once, beside the rule that says which verb carries it, is the only shape in which a test can
//! pin both.
//!
//! ## What is NOT here
//!
//! The nonce. It is a clock reading, and a door that read a clock would be a door whose second call
//! disagrees with its first — which `docs/55` §4's retry is not allowed to survive. It stays a
//! scalar the caller passes to [`crate::sim_routes::screenshot`], as it already did.

use crate::sim_place;

/// The non-streaming calls the panel makes against the simulator server.
///
/// [`Operation::Screenshot`] and [`Operation::Thumbnail`] are one ROUTE and two operations on
/// purpose: they have opposite budgets — one is captured once and kept, the other arrives every
/// couple of seconds for as long as the list is on screen — so the divisor and the quality that
/// make the second affordable belong to it and not to a parameter someone can forget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum Operation {
    /// `GET` the device set.
    Devices = 0,
    /// `POST` — start a device.
    Boot = 1,
    /// `POST` — stop a device.
    Shutdown = 2,
    /// `GET` the device's physical body.
    Chrome = 3,
    /// `GET` one artwork reference the body named.
    Resource = 4,
    /// `POST` — set the interface orientation.
    Orientation = 5,
    /// `GET` one full-resolution JPEG.
    Screenshot = 6,
    /// `GET` one SMALL JPEG, for a card in the device list.
    Thumbnail = 7,
    /// `POST` overrides, or `DELETE` to restore.
    StatusBar = 8,
    /// `POST` raw file bytes.
    Files = 9,
    /// `POST` a point, or `DELETE` to restore live values.
    Location = 10,
}

impl Operation {
    /// The value the C door takes.
    #[must_use]
    pub const fn as_code(self) -> u32 {
        self as u32
    }

    /// The operation for `code`, or `None` for a value no build of this crate wrote.
    #[must_use]
    pub const fn from_code(code: u32) -> Option<Self> {
        match code {
            0 => Some(Self::Devices),
            1 => Some(Self::Boot),
            2 => Some(Self::Shutdown),
            3 => Some(Self::Chrome),
            4 => Some(Self::Resource),
            5 => Some(Self::Orientation),
            6 => Some(Self::Screenshot),
            7 => Some(Self::Thumbnail),
            8 => Some(Self::StatusBar),
            9 => Some(Self::Files),
            10 => Some(Self::Location),
            _ => None,
        }
    }
}

/// The HTTP method a request carries.
///
/// A closed set rather than a string, because the whole point of the table is that no call site
/// spells one: `DELETE` appears on exactly two routes and appears there for a measured reason, and
/// a typo'd verb is a `405` nobody reads as a client bug.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Method {
    /// A read.
    Get,
    /// A write, with or without a body.
    Post,
    /// The clear half of the two routes that have one.
    Delete,
}

impl Method {
    /// The word that goes on the request line.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Delete => "DELETE",
        }
    }
}

/// How long a control call may take before it is abandoned, in seconds.
///
/// SHORT on purpose. These calls sit behind a poll loop that will simply ask again, so a request
/// hanging on a wedged server costs a round of freshness rather than a stuck panel — and
/// `URLSession`'s own default of sixty would keep a dead endpoint looking alive for a minute.
pub const TIMEOUT_SECONDS: f64 = 8.0;

/// The budget an upload gets instead.
///
/// An `.app` bundle is megabytes over the mesh, and [`TIMEOUT_SECONDS`] would abort an install that
/// is simply still running.
pub const UPLOAD_TIMEOUT_SECONDS: f64 = 300.0;

/// The integer downscale divisor a list card is captured at.
///
/// Chosen by MEASURING the server, not by taste — see [`crate::sim_routes::screenshot`] for the
/// three points on that curve. One rung finer would triple the bytes for pixels a card's 176-point
/// box cannot show.
pub const THUMBNAIL_SCALE: i32 = 6;

/// The JPEG quality a list card is captured at, `0`–`1`.
pub const THUMBNAIL_QUALITY: f64 = 0.5;

/// Everything about a request that is not its URL.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Plan {
    /// The verb.
    pub method: Method,
    /// The `Content-Type` header, or `None` for a request that carries no body.
    ///
    /// Absent rather than empty: sending the header without a body would describe bytes that are
    /// not there, and most of these routes read the UDID from the path and no body at all.
    pub content_type: Option<&'static str>,
    /// How long the caller may wait, in seconds.
    pub timeout_seconds: f64,
    /// Whether the request must bypass any local cache.
    ///
    /// Only meaningful for a `GET`; the two write verbs answer `false`, which is the protocol
    /// default they already ran under.
    pub ignores_cache: bool,
}

/// The plan for one operation.
///
/// `has_payload` is read by the two routes that have both a set form and a clear form, and ignored
/// by every other operation. It is what the CALLER knows and this module cannot: whether the user
/// asked to pin a position or to release it.
#[must_use]
pub const fn plan(operation: Operation, has_payload: bool) -> Plan {
    match operation {
        // The reads. Everything but the artwork must bypass the cache: a poll that can be answered
        // from a copy of its own previous answer is not a poll.
        Operation::Devices | Operation::Chrome | Operation::Screenshot | Operation::Thumbnail => {
            Plan {
                method: Method::Get,
                content_type: None,
                timeout_seconds: TIMEOUT_SECONDS,
                ignores_cache: true,
            }
        },
        Operation::Resource => {
            Plan {
                method: Method::Get,
                content_type: None,
                timeout_seconds: TIMEOUT_SECONDS,
                ignores_cache: false,
            }
        },
        // The bodiless writes. The UDID is in the path and the value, where there is one, is in the
        // query — so an unwanted body would be ignored at best.
        Operation::Boot | Operation::Shutdown | Operation::Orientation => {
            Plan {
                method: Method::Post,
                content_type: None,
                timeout_seconds: TIMEOUT_SECONDS,
                ignores_cache: false,
            }
        },
        // The two routes with a clear form. See the module header for the measured `400`.
        Operation::StatusBar | Operation::Location => {
            if has_payload {
                Plan {
                    method: Method::Post,
                    content_type: Some("application/json"),
                    timeout_seconds: TIMEOUT_SECONDS,
                    ignores_cache: false,
                }
            } else {
                Plan {
                    method: Method::Delete,
                    content_type: None,
                    timeout_seconds: TIMEOUT_SECONDS,
                    ignores_cache: false,
                }
            }
        },
        Operation::Files => {
            Plan {
                method: Method::Post,
                content_type: Some("application/octet-stream"),
                timeout_seconds: UPLOAD_TIMEOUT_SECONDS,
                ignores_cache: false,
            }
        },
    }
}

/// Whether the server's status line means the request succeeded.
///
/// A non-2xx answer is a failure even when the body parses: the server reports a refused boot that
/// way, and treating it as success would leave the panel claiming a device is starting when nothing
/// happened. The window is the whole 2xx class rather than `200` alone — `files` answers `201` for
/// an install.
#[must_use]
pub const fn status_is_ok(status: u16) -> bool {
    status >= 200 && status < 300
}

/// The status-bar override body: Apple's marketing status bar.
///
/// 9:41, full signal, full battery, no charging bolt. The only reason anyone overrides a status bar
/// is a clean capture, so the panel ships that one preset rather than a form nobody wants to fill
/// in twice.
///
/// **Every value here is one the SERVER accepts, measured against a live one on 2026-08-04 rather
/// than guessed from what the status bar shows.** It rejects the whole body on one bad field, so a
/// plausible synonym costs the entire preset: `batteryState` is `discharging`, never "unplugged".
///
/// Written out rather than assembled from a map, because the ORDER is then this function's and a
/// test can pin the whole string — the same reason [`crate::sim_input`] writes its envelopes with
/// an ordered map.
#[must_use]
pub fn status_bar_body() -> String {
    serde_json::json!({
        "time": "9:41",
        "dataNetwork": "wifi",
        "wifiMode": "active",
        "wifiBars": "3",
        "cellularMode": "active",
        "cellularBars": "4",
        "batteryState": "discharging",
        "batteryLevel": "100",
    })
    .to_string()
}

/// The location body for a pinned position, `{"latitude":…,"longitude":…}`.
///
/// The rounding is [`crate::sim_place::rounded`]'s, applied HERE rather than by the caller, so the
/// body and the readout cannot disagree about what was sent: six decimals is roughly a tenth of a
/// metre, and past that the digits describe nothing a simulator can act on.
///
/// The server also accepts a `{waypoints:[…]}` route and a bearing/speed walk. Neither is offered —
/// both are motion over time and want a map to draw the path on.
#[must_use]
pub fn location_body(latitude: f64, longitude: f64) -> String {
    serde_json::json!({
        "latitude": sim_place::rounded(latitude),
        "longitude": sim_place::rounded(longitude),
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::{
        Method, Operation, THUMBNAIL_QUALITY, THUMBNAIL_SCALE, TIMEOUT_SECONDS, UPLOAD_TIMEOUT_SECONDS,
        location_body, plan, status_bar_body, status_is_ok,
    };

    /// The reads are `GET`, and only the ARTWORK may be answered from a cache.
    ///
    /// The device list is the sharp end: the whole point of the poll is to see a boot land, so a
    /// cached answer would show the state the panel already believed for as long as the server's
    /// own headers allowed.
    #[test]
    fn only_the_artwork_may_come_from_a_cache() {
        for read in [
            Operation::Devices,
            Operation::Chrome,
            Operation::Screenshot,
            Operation::Thumbnail,
        ] {
            let plan = plan(read, false);
            assert_eq!(plan.method, Method::Get, "{read:?}");
            assert!(plan.ignores_cache, "{read:?}");
            assert_eq!(plan.content_type, None, "{read:?}");
        }
        let artwork = plan(Operation::Resource, false);
        assert_eq!(artwork.method, Method::Get);
        assert!(!artwork.ignores_cache);
    }

    /// The two routes that have a clear form answer `DELETE` for it, and carry no content type when
    /// they do — the measured `400` in the module header is what makes this a rule rather than a
    /// preference.
    #[test]
    fn clearing_is_a_delete_on_both_routes_that_have_one() {
        for route in [Operation::StatusBar, Operation::Location] {
            let clear = plan(route, false);
            assert_eq!(clear.method, Method::Delete, "{route:?}");
            assert_eq!(clear.content_type, None, "{route:?}");

            let set = plan(route, true);
            assert_eq!(set.method, Method::Post, "{route:?}");
            assert_eq!(set.content_type, Some("application/json"), "{route:?}");
        }
    }

    /// `has_payload` is read by exactly those two routes and by nothing else — a boot does not
    /// become a `DELETE` because nobody handed it a body.
    #[test]
    fn the_payload_flag_moves_nothing_else() {
        for operation in [
            Operation::Devices,
            Operation::Boot,
            Operation::Shutdown,
            Operation::Chrome,
            Operation::Resource,
            Operation::Orientation,
            Operation::Screenshot,
            Operation::Thumbnail,
            Operation::Files,
        ] {
            assert_eq!(
                plan(operation, true),
                plan(operation, false),
                "{operation:?} must not read the payload flag"
            );
        }
    }

    /// An upload gets its own budget, and it is the ONLY operation that does.
    #[test]
    fn only_an_upload_gets_the_long_budget() {
        let upload = plan(Operation::Files, true);
        assert_eq!(upload.method, Method::Post);
        assert_eq!(upload.content_type, Some("application/octet-stream"));
        assert!((upload.timeout_seconds - UPLOAD_TIMEOUT_SECONDS).abs() < f64::EPSILON);
        for operation in [
            Operation::Devices,
            Operation::Boot,
            Operation::Shutdown,
            Operation::Chrome,
            Operation::Resource,
            Operation::Orientation,
            Operation::Screenshot,
            Operation::Thumbnail,
            Operation::StatusBar,
            Operation::Location,
        ] {
            let plan = plan(operation, true);
            assert!(
                (plan.timeout_seconds - TIMEOUT_SECONDS).abs() < f64::EPSILON,
                "{operation:?} must run on the control budget"
            );
        }
    }

    /// Every operation survives the code it crosses as, and a code no build wrote is refused rather
    /// than falling through to a neighbour — which would send a request nobody asked for.
    #[test]
    fn every_operation_survives_the_code_it_crosses_as() {
        for operation in [
            Operation::Devices,
            Operation::Boot,
            Operation::Shutdown,
            Operation::Chrome,
            Operation::Resource,
            Operation::Orientation,
            Operation::Screenshot,
            Operation::Thumbnail,
            Operation::StatusBar,
            Operation::Files,
            Operation::Location,
        ] {
            assert_eq!(Operation::from_code(operation.as_code()), Some(operation));
        }
        assert_eq!(Operation::from_code(11), None);
        assert_eq!(Operation::from_code(u32::MAX), None);
    }

    /// The whole 2xx class succeeds and nothing else does. `201` is a real answer here — `files`
    /// gives it for an install — so a window written as `== 200` would fail every upload.
    #[test]
    fn the_success_window_is_the_whole_2xx_class() {
        assert!(status_is_ok(200));
        assert!(status_is_ok(201));
        assert!(status_is_ok(204));
        assert!(status_is_ok(299));
        assert!(!status_is_ok(199));
        assert!(!status_is_ok(300));
        assert!(!status_is_ok(400));
        assert!(!status_is_ok(500));
        assert!(!status_is_ok(0));
    }

    /// The preset is the eight pairs the server accepts, as STRINGS and in one fixed order.
    ///
    /// The WHOLE string is pinned, [`crate::sim_input`]'s way: the server rejects the body on one
    /// bad field, so the assertion that catches a drift is the one that reads every field. Every
    /// value is text because the server reads them as text — a battery level written as the number
    /// `100` is a rejected body, and a JSON literal is where that would happen silently.
    ///
    /// `discharging` is the field that costs the preset if it is wrong: `unplugged` is what the
    /// status bar SHOWS, and it is not what the route takes.
    #[test]
    fn the_status_bar_preset_is_the_eight_pairs_the_server_takes() {
        assert_eq!(
            status_bar_body(),
            r#"{"batteryLevel":"100","batteryState":"discharging","cellularBars":"4","cellularMode":"active","dataNetwork":"wifi","time":"9:41","wifiBars":"3","wifiMode":"active"}"#
        );
    }

    /// The location body carries the ROUNDED position, so what was sent and what the header echoes
    /// cannot disagree — and it carries TWO fields, because a `bearing` or a `speed` beside them
    /// would ask the server for the WALK, which this route is not.
    #[test]
    fn the_location_body_carries_the_rounded_position_and_nothing_else() {
        assert_eq!(
            location_body(37.334_886_123_4, -122.008_988_123_4),
            r#"{"latitude":37.334886,"longitude":-122.008988}"#
        );
        assert_eq!(location_body(0.0, 0.0), r#"{"latitude":0.0,"longitude":0.0}"#);
    }

    /// The card's capture settings are the measured ones. A test rather than a comment, because
    /// they are what makes a live list affordable at all.
    #[test]
    fn the_card_captures_at_the_measured_operating_point() {
        assert_eq!(THUMBNAIL_SCALE, 6);
        assert!((THUMBNAIL_QUALITY - 0.5).abs() < f64::EPSILON);
    }
}
