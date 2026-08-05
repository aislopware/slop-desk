# 49 — Web panel (the host's browser, and its own inspector)

The right panel's **Web** tab drives a browser that runs on the **host**, and inspects the page in
it with **that browser's own DevTools frontend**. It is the panel's first surface whose subject is
not a device and not a project: it is a page.

Everything below is **measured** against Chrome 150 on 2026-08-05, not read from a spec. Chrome's
debugging endpoints are documented loosely and have changed behaviour twice in ways that break a
naive integration (`--remote-allow-origins` in 111, the default-profile refusal in 136), so the
claims here are what `scripts/check-web.sh` re-proves against a real browser and what
`Tests/SlopDeskHostTests/WebBrowserManagerTests.swift` +
`Tests/SlopDeskClientUITests/Web*Tests.swift` pin.

Read this before touching anything under `Sources/SlopDeskHost/Web` or
`Sources/SlopDeskClientUI/Web`.

---

## Shape

```
client (SlopDeskClientUI/Web)                        host (SlopDeskHost/Web)
────────────────────────────────────────────────────────────────────────────────────
metadata verb 23  ensureWebBrowser   ────────────►   HostWebPerformer
                  [state][UInt16 BE port] ◄───────   WebBrowserManager
                                                            │ spawns
                                                     Google Chrome --headless=new
                                                            │ 127.0.0.1:<ephemeral>
                                                     WebDebugRelay (hostd, 0.0.0.0:<relay>)
                                                            ▲
CodeSidebarProxyPool(key: web)  ── mesh TCP ────────────────┘
  127.0.0.1:<stable>
      │
      ├── WKWebView loads  /devtools/inspector.html?ws=127.0.0.1:<stable>/devtools/page/<id>
      ├── GET  /json/list                     (the tab menu)
      ├── PUT  /json/new?<url>                (open a tab)
      ├── GET  /json/close/<id>               (close a tab)
      └── ws   /devtools/page/<id>            (one Page.navigate, then closed — the address bar)
```

### Why the browser runs on the HOST

The client already embeds WebKit, so rendering the page locally was the cheaper build. Two things it
cannot buy back:

1. **The page under development is served by the host.** A dev server bound to the host's
   `localhost`, the host's `/etc/hosts`, the host's certificates and cookies. A browser sitting ON
   the host types `localhost:5173` and is there; a client-side web view needs a forwarded port for
   every service, and an absolute link the app emits to its own origin still breaks.
2. **Inspection.** WebKit exposes no supported way for an embedding app to open its Web Inspector.
   The private route (`_setDeveloperExtrasEnabled:` / `_inspector` / `attach`) exists, is what cmux
   and muxy both use, is **macOS-only**, and cmux's own source warns that a repeated `attach` can
   crash inside `WebInspectorUIProxy::platformAttach`. A SlopDesk client also runs on iPad, where
   that route does not exist at all. Chrome serves its ENTIRE frontend over HTTP, and that frontend
   was measured rendering and driving a page correctly inside WKWebView on **macOS and iPadOS 26.5**,
   with no private API on either. One surface, one behaviour, every client.

### Not a fifth transport

Same argument as `docs/47` and `docs/48`: CDP and the `/json/*` endpoints are a **foreign** protocol
spoken to a third-party binary the user installed. They share no socket, message set or codec with
terminal TCP / video UDP / inspector TCP, and `SlopDeskProtocol` never sees a byte of them. Only
discovery (verb 23) rides a SlopDesk wire, and it carries an address.

**No auth, by invariant** — the relay binds `0.0.0.0` with no credential; security is the WireGuard
mesh (`docs/DECISIONS.md`). Note what that port grants: a browser fetches and runs whatever it is
pointed at, so this is host-user code execution — the same authority verb 22's `adb` bridge already
hands a mesh peer, resting on the same invariant.

---

## ⚠️ TWO relays, and neither is optional

This is the part that is easy to get wrong twice.

**Host side.** Chrome binds `--remote-debugging-port` to `127.0.0.1` and cannot be talked out of it:
`--remote-debugging-address=0.0.0.0` is **accepted on the command line and ignored** — the socket
still comes up on loopback (measured). So `WebDebugRelay` (Network.framework, in hostd) fronts it on
all interfaces. It is **retargetable** and outlives any one child, so a browser respawn does not move
the address the client knows.

**Client side.** The DevTools frontend opens its debugging websocket back to `ws://127.0.0.1:*` and
its own policy admits nothing else. A frontend loaded straight from the mesh address renders in full
and then reports *"Debugging connection was closed"* — it looks like a broken browser, it is a
refused origin. So `CodeSidebarProxyPool` fronts the mesh endpoint on a stable loopback port, under
its **own key** (`CodeSidebarProxyPorts.webProxyKey`), because DevTools stores its whole layout
against that origin and the workbench's relay retargets on a different schedule.

---

## The child, flag by flag

`WebBrowserManager.launchArguments` — every one of these is load-bearing:

| flag | why |
| --- | --- |
| `--headless=new` | The user is looking at the client; the browser must put no window on the host's screen. Measured: new headless screencasts at 75 fps, ~3 KB/frame, and `--use-angle=metal` / `--enable-gpu` change nothing — **unlike** the Android emulator, whose software renderer cost 10× (`docs/48`). There is no GPU trap here. |
| `--remote-debugging-port=0` | Learn the real port from the child's own announce line — the no-pre-bind-race pattern `SimulatorServerManager` uses. |
| `--remote-allow-origins=*` | **REQUIRED since Chrome 111.** The frontend is loaded from the client's loopback origin, so its websocket upgrade carries an `Origin` header, and Chrome closes any such connection that is not allow-listed. Symptom without it: a frontend that renders completely and then says the connection closed. Not a security boundary — reaching the port already means crossing the mesh. |
| `--user-data-dir=…` | **Mandatory, not tidy.** Chrome 136+ REFUSES remote debugging on the OS-default profile, and a Chrome the user is running holds that directory's lock anyway. Persistent (under the app-support container), so logins survive a respawn. |
| `--no-first-run`, `--no-default-browser-check` | First-run state and a default-browser prompt would dirty a profile nobody ever looks at. |
| `about:blank` | Start with a page target, so the client always has something to attach to. |

Announce line, parsed by `parseDevToolsPort`:

```
DevTools listening on ws://127.0.0.1:59123/devtools/browser/6f0f1c0e-…
```

`port > 0` is enforced, for `SimulatorServerManager`'s reason: a server that echoes the port it was
ASKED for would latch the instance on `0`.

**Shutdown terminates the child** — the one manager of the four that does. A booted simulator or
emulator is the user's own machine state; this is a headless browser on a private profile, invisible
on the host's screen, and leaving it running strands a process the user cannot see to stop.

---

## The endpoints the panel uses

Measured shapes (2026-08-05, Chrome 150):

- `GET /json/list` → a JSON array. It carries extension background pages and service workers as well
  as tabs; only `type == "page"` reaches the tab menu.
- `PUT /json/new?<percent-encoded url>` → the one target it made. **PUT, not GET**: Chrome answers a
  GET with `Using unsafe HTTP verb GET to invoke /json/new. This action supports only PUT verb.`
- `GET /json/close/<id>` → closes a tab.
- `ws /devtools/page/<id>` + `{"id":1,"method":"Page.navigate","params":{"url":…}}` → the address
  bar. There is **no HTTP endpoint that points an existing page somewhere**, and a new target means a
  new DevTools session — which is exactly what an address bar must not cost. The socket is opened per
  navigation and closed after the reply; a reply carrying `error` is a refusal and must not read as
  success.
- `GET /devtools/inspector.html?ws=<host:port>/devtools/page/<id>` → the frontend itself. The `ws`
  query carries **no scheme** — the frontend prepends `ws://`, and a full URL there yields a frontend
  that loads and never connects.

---

## The client surface

`CodeSidebarColumn`'s fifth tab. Machine-scoped like Simulators and Emulators — one host, one
browser, one set of tabs — and lazy the same way: the `.task`s live on the surface, so a user who
never opens this tab never makes the host start a browser at all.

- **`WebSidebarModel`** — two loops (ensure, then a slower `/json/list` poll), the phase machine, and
  the pure builders. The address field is an input first and a readout second: it follows a page that
  navigates on its own, EXCEPT while it has focus, so a redirect cannot take a URL out from under a
  cursor mid-type.
- **Address normalisation** is deliberately not a search box. A bare host on the loopback family gets
  `http://` (that is where the host's dev server is), anything else that looks like a host gets
  `https://`, an address that names its own scheme is taken as written, and **prose resolves to
  nothing** rather than being shipped to a search engine.
- **`WebInspectorWebViewPool`** — ONE pooled web view, re-pointed on a tab switch. Minting one per
  page would pay the frontend's boot every time. It seeds DevTools' dark theme into the frontend
  origin's `localStorage` on first load only, so the user's own later choice is never overwritten.
- The strip's reload plate reloads the **frontend**; the page has its own reload inside DevTools.

### ⚠️ The theme key is `ui-theme`, kebab-case

DevTools renamed its setting keys, and the old camelCase names are still **writable while being read
by nobody**. Seeding `uiTheme` therefore fails in the most confusing way available: the key is
present in `localStorage` afterwards, so the seed looks like it worked, and the frontend still comes
up light. Measured on Chrome 150 — `ui-theme` puts `theme-with-dark-background` on the root element,
`uiTheme` changes nothing. Same rename hit the screencast split
(`inspector-view.screencast-split-view-state`). `WebInspectorThemeSeedTests` pins the key.

### Width, measured

At a **1200pt** panel the frontend lays out as a full DevTools: page screencast on the left, Elements
and its styles sidebar on the right. At the panel's **380–420pt** minimum the screencast column falls
to ~170pt and the page inside it is a thumbnail — and seeding the split wider barely moves it,
because the screencast letterboxes the page's own aspect (a 1440×900 viewport in a narrow column is
short no matter how much width it is given). That is inherent to a screencast, not a layout bug, and
the fix is the panel's own divider: `codeSidebarMinWidth` is a minimum with **no maximum**, so web
work is done with the panel dragged wide. DevTools' built-in screencast address bar collapses to a
few characters at that width, which is the second reason `WebAddressBar` sits above the frontend
rather than deferring to it.

---

## Gate

`scripts/check-web.sh` (`SLOPDESK_WEB_HW=1`). It needs a Chrome-family browser and nothing else;
the browser it starts is headless, on a throwaway profile under the temp directory, and terminated at
the end — a Chrome the user has open is never touched. It proves the two things no unit test can: the
flags still produce a debugging port, and the relay carries the browser's bytes untouched
(`/json/version`, `/json/list`, the frontend HTML, and a relay port that survives a real kill and
respawn).

Everything pure — flags, announce parse, locator, profile resolution, lifecycle against fake seams,
verb-23 routing, target selection, address normalisation, the `/json` decode — is under `make test`.

## Environment

| variable | effect |
| --- | --- |
| `SLOPDESK_WEB_BROWSER_BIN` | Names the browser executable exactly. Set-but-not-executable resolves to `nil` rather than falling through to the search — an operator who named a binary meant that one. |
| `SLOPDESK_WEB_PROFILE_DIR` | Moves the `--user-data-dir`. Otherwise `web-profile` inside the app-support container (which `SLOPDESK_APP_SUPPORT_DIR` can move). |
| `SLOPDESK_WEB_HW` | The hardware gate above. |

Search order without an override: `/Applications` then `$HOME/Applications` (from the ENVIRONMENT's
`HOME`, never `NSHomeDirectory()`), for Chrome → Chromium → Brave → Edge → Chrome Canary; then `PATH`
+ the Homebrew bin directories for `google-chrome` / `chromium` / `chrome`. Any Blink browser serves
the same frontend, so the fallbacks are real; Chrome leads because the pages under test are written
for it.
