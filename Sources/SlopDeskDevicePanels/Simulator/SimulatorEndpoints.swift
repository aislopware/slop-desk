// SimulatorEndpoints — the face over every URL the panel builds against the host's simulator server.
//
// The route table is `slopdesk_devicepanel::sim_routes`'s, reached through ONE door: the routes
// differ only in which of a fixed set of parts they use — a verb, a device, a value, a nonce, two
// capture flags — and a kind plus a record is a table lookup a caller cannot mis-spell. What stays
// here is the named verb per route, so a call site still says `boot` rather than assembling a record.
//
// Plain `http`/`ws` on the WireGuard mesh, by the project's security invariant: there is no
// app-layer auth and TLS would only add a certificate-trust problem to a link that is already the
// boundary. No credentials appear in any of these.
//
// The panel talks to the server DIRECTLY at its mesh address. The loopback relay the workbench needs
// is deliberately not in this path: that relay exists to give a BROWSER a secure context and a
// stable origin for its per-origin storage, and a native panel has neither concern — it has no
// origin, no storage keyed by one, and no secure-context gate on the sockets it opens.

import CSlopDeskFFI
import Foundation
import SlopDeskArena

package enum SimulatorEndpoints {
    /// `GET` — the device set. Never cached: the whole point of a poll is to see a boot land.
    package static func deviceList(host: String, port: UInt16) -> URL? {
        route(SLOPDESK_SIM_ROUTE_DEVICE_LIST, host: host, port: port)
    }

    /// `POST`, empty body — start the device. The UDID lives in the path; there is no payload.
    package static func boot(host: String, port: UInt16, udid: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_BOOT, host: host, port: port, udid: udid)
    }

    /// `POST`, empty body — stop the device.
    package static func shutdown(host: String, port: UInt16, udid: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_SHUTDOWN, host: host, port: port, udid: udid)
    }

    /// `GET` — the device's physical body in the shape the panel draws it: viewport-relative
    /// percentages and ready-made image references. The server also serves `chrome.json`, which is
    /// the same bezel in absolute points; the percentages are what scale to a sidebar's width without
    /// a second layout pass. Answers for a shut-down device too, since it is model data rather than
    /// process state.
    package static func definition(host: String, port: UInt16, udid: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_DEFINITION, host: host, port: port, udid: udid)
    }

    /// `POST` — set the interface orientation. The value rides the query string, matching the
    /// server's own route; the body is empty.
    package static func orientation(
        host: String, port: UInt16, udid: String, value: String,
    ) -> URL? {
        route(SLOPDESK_SIM_ROUTE_ORIENTATION, host: host, port: port, udid: udid, arg: value)
    }

    /// `GET` — one JPEG of the current screen. The cache-buster is the server's own idiom: without it
    /// a second capture inside the same session can come back from `URLSession`'s cache.
    ///
    /// `scale` (an INTEGER downscale divisor) and `quality` (0–1) are the flags `baguette screenshot`
    /// documents for its CLI, and the HTTP route honours both even though nothing on the server's own
    /// page sends them — measured 2026-08-04 against the live server: native is 1206 × 2622 for
    /// 480 KB in 30 ms, `scale=4` is 302 × 656 for 55 KB, and `scale=6&quality=0.5` is 202 × 438 for
    /// **13.5 KB in 22 ms**. That last one is what makes the list's live cards affordable at all: a
    /// fifth of what the idle VIDEO stream costs for the same device (33 KB/s, measured the same day),
    /// where a native-resolution poll would have been seven times more.
    ///
    /// Both are omitted from the query when left at their defaults, so a full-resolution capture
    /// builds the same URL it always did.
    package static func screenshot(
        host: String, port: UInt16, udid: String, nonce: UInt64,
        scale: Int = 1, quality: Double? = nil,
    ) -> URL? {
        route(
            SLOPDESK_SIM_ROUTE_SCREENSHOT, host: host, port: port, udid: udid,
            nonce: nonce, scale: Int32(clamping: scale), quality: quality,
        )
    }

    /// `POST`, JSON body — override or clear the status bar (time, bars, battery).
    package static func statusBar(host: String, port: UInt16, udid: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_STATUS_BAR, host: host, port: port, udid: udid)
    }

    /// `POST` JSON `{latitude, longitude}` — pin the device's simulated GPS position. `DELETE` on
    /// the same route restores live values. The server also accepts a `{waypoints}` route and a
    /// bearing/speed walk on this route; the panel sends neither (see ``SimulatorPlace``).
    package static func location(host: String, port: UInt16, udid: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_LOCATION, host: host, port: port, udid: udid)
    }

    /// The console's websocket. `style=compact` is not a preference — it is the only style whose
    /// line shape ``DeviceLogLine`` can colour by severity. `level` is passed to the server's own
    /// `log stream --level`, so only ``SimulatorLogLevel``'s closed set may reach it: an invented
    /// level still upgrades the socket and then dies when the child refuses it.
    package static func logs(host: String, port: UInt16, udid: String, level: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_LOGS, host: host, port: port, udid: udid, arg: level)
    }

    /// `POST`, raw file bytes — hand the device a file. The server routes on the extension: an
    /// `.app`/`.ipa` is installed, an image or video lands in Photos. The name rides the query string
    /// because the body is the file itself.
    package static func files(host: String, port: UInt16, udid: String, name: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_FILES, host: host, port: port, udid: udid, arg: name)
    }

    /// Resolve a reference the SERVER handed back — a bezel or button image path out of
    /// ``SimulatorChrome``. Joined against the origin rather than re-escaped: the server's references
    /// carry a query (`bezel.png?buttons=false`) and are already escaped, and re-escaping a whole
    /// reference is precisely the double-encoding trap the UDID routes avoid.
    package static func resolve(_ reference: String, host: String, port: UInt16) -> URL? {
        route(SLOPDESK_SIM_ROUTE_RESOLVE, host: host, port: port, arg: reference)
    }

    /// The frame + input websocket. Both directions ride this one socket: H.264 down, gesture JSON
    /// up. `format=avcc` asks for length-prefixed NALs rather than Annex-B, which is what
    /// `CMVideoFormatDescription` wants and saves a start-code rewrite per access unit.
    package static func stream(host: String, port: UInt16, udid: String) -> URL? {
        route(SLOPDESK_SIM_ROUTE_STREAM, host: host, port: port, udid: udid)
    }

    // MARK: - The one door

    /// A degenerate endpoint (no host, or port zero) yields `nil` rather than a URL that would fail
    /// at connect time — the phase machine reads that nil as "not ready", which is the truth. So does
    /// a route the linked build has no case for, which is what stops a kind from falling through to
    /// a neighbour and sending a request nobody asked for.
    private static func route(
        _ kind: Int32, host: String, port: UInt16, udid: String = "", arg: String = "",
        nonce: UInt64 = 0, scale: Int32 = 1, quality: Double? = nil,
    ) -> URL? {
        let text = ffiLend(host) { hostBytes in
            ffiLend(udid) { udidBytes in
                ffiLend(arg) { argBytes in
                    var record = SlopDeskSimRoute(
                        kind: UInt32(kind),
                        host: hostBytes.baseAddress, host_len: hostBytes.count,
                        port: port,
                        udid: udidBytes.baseAddress, udid_len: udidBytes.count,
                        arg: argBytes.baseAddress, arg_len: argBytes.count,
                        nonce: nonce, scale: scale,
                        quality: quality ?? 0, has_quality: quality != nil,
                    )
                    return ffiAnswerText(capacity: 256) { out, cap in
                        slopdesk_sim_route(&record, out, cap)
                    }
                }
            }
        }
        return text.isEmpty ? nil : URL(string: text)
    }
}
