//! Every URL the simulator panel builds against the host's simulator server, in one place so the
//! route table is pinned by tests rather than spelled out at four call sites.
//!
//! Plain `http`/`ws` on the mesh, by the project's security invariant: there is no app-layer auth
//! and TLS would only add a certificate-trust problem to a link that is already the boundary. No
//! credentials appear in any of these.
//!
//! The panel talks to the server DIRECTLY at its mesh address. The loopback relay the workbench
//! needs is deliberately not in this path: that relay exists to give a BROWSER a secure context and
//! a stable origin for its per-origin storage, and a native panel has neither concern.
//!
//! ## A degenerate endpoint answers nothing
//!
//! No host, or port zero, answers `None` rather than a URL that would fail at connect time — the
//! phase machine reads that as "not ready", which is the truth.

use core::fmt::Write as _;

use percent_encoding::{AsciiSet, utf8_percent_encode};

/// The version token on the stream socket.
///
/// Pinned per the project's no-negotiation rule — the value is the server's own `v2` dialect tag,
/// sent as a constant, never negotiated.
pub const STREAM_DIALECT: &str = "v2";

/// The characters a PATH component may carry unescaped: RFC 3986's `pchar` set, minus the
/// separator.
///
/// Minus the separator because the value is interpolated INTO a path: the day the server accepts a
/// device-set-relative name, an unescaped slash in it would silently address a different route.
/// Escaping the whole alphabet instead would send `%2D` for every dash in a UDID and hand the
/// server a string it may compare raw.
const PATH_COMPONENT: &AsciiSet = &percent_encoding::CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'/')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

/// The characters a QUERY value may carry unescaped: the path set, MINUS the two the query
/// component itself permits (`/` and `?`), PLUS the four that would end the value early.
///
/// `&` and `=` are the sub-delimiters the query is split on, so a build named `My App&Co.ipa` sent
/// raw arrives as `name=My App` beside a parameter the server never defined. `+` is read as a space
/// by enough servers that a filename carrying one must not gamble on this one, and `;` is the
/// legacy separator some still honour. Each of those is a route that works until the day a name
/// contains the character, which is the failure this set exists to make impossible.
const QUERY_VALUE: &AsciiSet = &percent_encoding::CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'&')
    .add(b'+')
    .add(b';')
    .add(b'=')
    .add(b'<')
    .add(b'>')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

/// `GET` — the device set. Never cached: the whole point of a poll is to see a boot land.
#[must_use]
pub fn device_list(host: &str, port: u16) -> Option<String> {
    Some(format!("{}/simulators.json", origin("http", host, port)?))
}

/// `POST`, empty body — start the device. The UDID lives in the path; there is no payload.
#[must_use]
pub fn boot(host: &str, port: u16, udid: &str) -> Option<String> {
    action(host, port, udid, "boot")
}

/// `POST`, empty body — stop the device.
#[must_use]
pub fn shutdown(host: &str, port: u16, udid: &str) -> Option<String> {
    action(host, port, udid, "shutdown")
}

/// `GET` — the device's physical body in the shape the panel draws it: viewport-relative
/// percentages and ready-made image references.
///
/// The server also serves `chrome.json`, which is the same bezel in absolute points; the
/// percentages are what scale to a sidebar's width without a second layout pass. Answers for a
/// shut-down device too, since it is model data rather than process state.
#[must_use]
pub fn definition(host: &str, port: u16, udid: &str) -> Option<String> {
    action(host, port, udid, "definition.json")
}

/// `POST`, JSON body — override or clear the status bar (time, bars, battery).
#[must_use]
pub fn status_bar(host: &str, port: u16, udid: &str) -> Option<String> {
    action(host, port, udid, "status-bar")
}

/// `POST` JSON `{latitude, longitude}` — pin the device's simulated GPS position. `DELETE` on the
/// same route restores live values.
#[must_use]
pub fn location(host: &str, port: u16, udid: &str) -> Option<String> {
    action(host, port, udid, "location")
}

/// `POST` — set the interface orientation. The value rides the query string, matching the server's
/// own route; the body is empty.
#[must_use]
pub fn orientation(host: &str, port: u16, udid: &str, value: &str) -> Option<String> {
    let base = action(host, port, udid, "orientation")?;
    Some(format!("{base}?value={}", query(value)))
}

/// `GET` — one JPEG of the current screen.
///
/// The `t` cache-buster is the server's own idiom: without it a second capture inside the same
/// session can come back from the URL cache. `scale` (an INTEGER downscale divisor) and `quality`
/// (0–1) are the flags the server's CLI documents and the HTTP route honours; both are OMITTED at
/// their defaults, so a full-resolution capture builds the URL it always did.
#[must_use]
pub fn screenshot(
    host: &str,
    port: u16,
    udid: &str,
    nonce: u64,
    scale: i32,
    quality: Option<f64>,
) -> Option<String> {
    let base = action(host, port, udid, "screenshot.jpg")?;
    let mut url = format!("{base}?t={nonce}");
    // Both writes are into a `String`, whose `Write` never fails; the result is dropped rather than
    // unwrapped because a `deny(unwrap_used)` crate may not spell the impossible case with a panic.
    if scale > 1 {
        let _ = write!(url, "&scale={scale}");
    }
    if let Some(quality) = quality {
        let _ = write!(url, "&quality={quality}");
    }
    Some(url)
}

/// The console's websocket.
///
/// `style=compact` is not a preference — it is the only style whose line shape the shared log
/// grammar can colour by severity. `level` is passed to the server's own `log stream --level`, so
/// only the closed set of levels may reach it: an invented one still upgrades the socket and then
/// dies when the child refuses it.
#[must_use]
pub fn logs(host: &str, port: u16, udid: &str, level: &str) -> Option<String> {
    let base = device_path("ws", host, port, udid, "logs")?;
    Some(format!("{base}?level={}&style=compact", query(level)))
}

/// `POST`, raw file bytes — hand the device a file.
///
/// The server routes on the extension: an `.app`/`.ipa` is installed, an image or video lands in
/// Photos. The name rides the query string because the body is the file itself.
#[must_use]
pub fn files(host: &str, port: u16, udid: &str, name: &str) -> Option<String> {
    let base = action(host, port, udid, "files")?;
    Some(format!("{base}?name={}", query(name)))
}

/// The frame + input websocket.
///
/// Both directions ride this one socket: H.264 down, gesture JSON up. `format=avcc` asks for
/// length-prefixed NALs rather than Annex-B, which is what a format description wants and saves a
/// start-code rewrite per access unit.
#[must_use]
pub fn stream(host: &str, port: u16, udid: &str) -> Option<String> {
    let base = device_path("ws", host, port, udid, "stream")?;
    Some(format!("{base}?format=avcc&version={STREAM_DIALECT}"))
}

/// Resolve a reference the SERVER handed back — a bezel or button image path out of its own chrome
/// description.
///
/// Relative resolution rather than this module's builder on purpose: the server's references carry
/// a query (`bezel.png?buttons=false`) and are already escaped, and re-escaping a whole reference
/// is precisely the double-encoding trap the UDID routes avoid. The base has an empty path, so RFC
/// 3986 resolution against it is the three cases below and nothing more.
#[must_use]
pub fn resolve(reference: &str, host: &str, port: u16) -> Option<String> {
    let base = origin("http", host, port)?;
    if reference.contains("://") {
        return Some(reference.to_owned());
    }
    if reference.starts_with('/') {
        return Some(format!("{base}{reference}"));
    }
    Some(format!("{base}/{reference}"))
}

/// `http://host:port`, or `None` for an endpoint that could never connect.
fn origin(scheme: &str, host: &str, port: u16) -> Option<String> {
    if host.is_empty() || port == 0 {
        return None;
    }
    Some(format!("{scheme}://{host}:{port}"))
}

fn action(host: &str, port: u16, udid: &str, verb: &str) -> Option<String> {
    device_path("http", host, port, udid, verb)
}

fn device_path(scheme: &str, host: &str, port: u16, udid: &str, verb: &str) -> Option<String> {
    let base = origin(scheme, host, port)?;
    Some(format!("{base}/simulators/{}/{verb}", path(udid)))
}

fn path(component: &str) -> String {
    utf8_percent_encode(component, PATH_COMPONENT).to_string()
}

fn query(value: &str) -> String {
    utf8_percent_encode(value, QUERY_VALUE).to_string()
}

#[cfg(test)]
mod tests {
    use super::{
        boot, definition, device_list, files, location, logs, orientation, resolve, screenshot, shutdown,
        status_bar, stream,
    };

    const HOST: &str = "10.0.0.2";
    const UDID: &str = "8A1B-22";

    /// The whole route table, pinned. Each of these is typed into a live server, so a wrong path is
    /// a 404 the panel reports as a dead device.
    #[test]
    fn every_route_is_the_one_the_server_serves() {
        assert_eq!(
            device_list(HOST, 8080).as_deref(),
            Some("http://10.0.0.2:8080/simulators.json")
        );
        assert_eq!(
            boot(HOST, 8080, UDID).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/boot")
        );
        assert_eq!(
            shutdown(HOST, 8080, UDID).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/shutdown")
        );
        assert_eq!(
            definition(HOST, 8080, UDID).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/definition.json")
        );
        assert_eq!(
            status_bar(HOST, 8080, UDID).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/status-bar")
        );
        assert_eq!(
            location(HOST, 8080, UDID).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/location")
        );
        assert_eq!(
            orientation(HOST, 8080, UDID, "landscape-left").as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/orientation?value=landscape-left")
        );
        assert_eq!(
            files(HOST, 8080, UDID, "app.ipa").as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/files?name=app.ipa")
        );
    }

    /// The two sockets are `ws`, not `http` — a scheme that is only wrong at connect time, and only
    /// on the one path that is hardest to reach in a test.
    #[test]
    fn both_sockets_upgrade() {
        assert_eq!(
            stream(HOST, 8080, UDID).as_deref(),
            Some("ws://10.0.0.2:8080/simulators/8A1B-22/stream?format=avcc&version=v2")
        );
        assert_eq!(
            logs(HOST, 8080, UDID, "debug").as_deref(),
            Some("ws://10.0.0.2:8080/simulators/8A1B-22/logs?level=debug&style=compact")
        );
    }

    /// Both capture flags are OMITTED at their defaults, so the full-resolution URL is the one it
    /// always was and no server has to learn a new query.
    #[test]
    fn the_capture_flags_appear_only_when_they_change_something() {
        assert_eq!(
            screenshot(HOST, 8080, UDID, 7, 1, None).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/screenshot.jpg?t=7")
        );
        assert_eq!(
            screenshot(HOST, 8080, UDID, 7, 6, Some(0.5)).as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/screenshot.jpg?t=7&scale=6&quality=0.5")
        );
    }

    /// A slash in a path component would silently address a different route, so it is escaped —
    /// and a dash is NOT, because the server may compare the value raw.
    #[test]
    fn a_path_component_is_escaped_but_not_over_escaped() {
        assert_eq!(
            boot(HOST, 8080, "a/b c").as_deref(),
            Some("http://10.0.0.2:8080/simulators/a%2Fb%20c/boot")
        );
        assert!(boot(HOST, 8080, "A-B_C.D~E").is_some_and(|url| url.ends_with("/A-B_C.D~E/boot")));
    }

    /// A query VALUE may not end its own parameter. The body of a file upload is the file, so the
    /// name rides here — and a build called `My App&Co.ipa` sent raw arrives as `name=My App`
    /// beside a parameter the server never defined, which is a 400 nobody can trace back to the
    /// filename.
    #[test]
    fn a_query_value_cannot_end_its_own_parameter() {
        assert_eq!(
            files(HOST, 8080, UDID, "My App&Co=1;2+3.ipa").as_deref(),
            Some("http://10.0.0.2:8080/simulators/8A1B-22/files?name=My%20App%26Co%3D1%3B2%2B3.ipa")
        );
    }

    /// A reference the server handed back is already escaped and carries its own query, so it is
    /// joined rather than rebuilt — re-escaping it is the double-encoding trap.
    #[test]
    fn a_server_reference_is_joined_not_rebuilt() {
        assert_eq!(
            resolve("bezel.png?buttons=false", HOST, 8080).as_deref(),
            Some("http://10.0.0.2:8080/bezel.png?buttons=false")
        );
        assert_eq!(
            resolve("/devices/x%2Fy.png", HOST, 8080).as_deref(),
            Some("http://10.0.0.2:8080/devices/x%2Fy.png")
        );
        assert_eq!(
            resolve("https://cdn.example/x.png", HOST, 8080).as_deref(),
            Some("https://cdn.example/x.png")
        );
    }

    /// An endpoint that could never connect answers nothing, which the phase machine reads as "not
    /// ready" — the truth — rather than as a URL that fails later and further from the cause.
    #[test]
    fn a_degenerate_endpoint_builds_no_url() {
        assert_eq!(device_list("", 8080), None);
        assert_eq!(device_list(HOST, 0), None);
        assert_eq!(stream(HOST, 0, UDID), None);
        assert_eq!(resolve("bezel.png", "", 8080), None);
    }
}
