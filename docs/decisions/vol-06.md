# DECISIONS vol-06 — 2026-08-03 … 2026-08-11

> Volume 6 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## Every Monokai Pro variant ships, synced from upstream by pin (2026-08-03)

Extends the stock-Monokai-Pro decision above from the two-filter pair to ALL EIGHT variants
the upstream vsix contributes (Monokai Pro + Octagon/Ristretto/Spectrum/Machine filters,
Monokai Pro Light + Filter Sun, Monokai Classic): the workbench's own theme picker (⌘K ⌘T)
now offers the full family, while the seed still boots the classic pair. The vendored
resources stop being a hand-transformed one-off and become REGENERABLE: `scripts/monokai.pin`
records the upstream vsix version, and `scripts/monokai-sync.sh [--latest]` re-downloads,
re-applies the two departures (seam-border retint per dark/light, empty-value drop) and
rewrites `Sources/SlopDeskHost/Resources/` — following upstream is one command + a diff
review, the herdr-sync pattern. The script cross-checks the vsix's contributed theme set
against `CodeServerManager.themeExtensionThemes` (the single source of truth the manifest is
now GENERATED from) and fails loudly on upstream adds/renames. Installing the real
marketplace extension was considered for automatic updates and REJECTED: its activation code
carries the recurring license prompt. The vendored seed takes the theme data only — no code,
no nag (same personal-use posture as before). The extension id/folder stays
`slopdesk.slopdesk-monokai-1.0.0`; the drift-repair seeder rewrites bytes in place and now
also sweeps the two-variant era's differently named theme files.

## Free marketplace extensions install for real; the first one is Material Icon Theme (2026-08-03)

The vendored-data-only rule above exists because the Monokai Pro extension's ACTIVATION CODE
nags for a license — it is not a blanket ban on installing extensions. For fully-free
extensions (no license/purchase prompt anywhere in their activation path) the real install
is strictly better: the workbench's own updater then tracks upstream, nothing is vendored,
nothing needs a sync script. `CodeServerManager.bundledMarketplaceExtensions` lists the ids
the host installs ONCE via `code-server --install-extension` (user-directed 2026-08-03),
checked against the profile registry (`extensions.json` — the installed-set source of truth;
a folder scan lies once the file exists) and run BEFORE the first spawn: ensure answers
`.starting` while the one-shot CLI runs (the client polls ~1 Hz), both so the very first
boot already scans the pack and because install + boot writing the registry concurrently
loses registrations. A failed install (offline host) latches done anyway — the panel is
never held hostage by a nicety; the next hostd launch retries. The first entry is
`pkief.material-icon-theme` (MIT), and seed v15 selects it (`workbench.iconTheme:
"material-icon-theme"`); v14 joins `obsoleteSeeds` so pristine hosts upgrade in place.

## The code panel gets a first-party extension: `slopdesk.slopdesk-bridge` (2026-08-03)

Opening a file in the embedded editor ran `code-server -r <path>`: a fresh Node CLI process
routed through the per-user session socket. Two costs, both measured. It lands in the most
recently registered workbench SESSION, which is not necessarily the window whose folder holds
the file — with two projects open the file could surface in the wrong one. And the session
registers only once some webview has finished booting the workbench, which is why the open
carries a 10 × 2 s retry budget: an 18-second worst case on a cold panel. Even warm the CLI
measured ~160 ms per open (Node boot + IPC), for a command whose payload is one path.

So the host now ships its own extension into the workbench profile, on the same seeding terms
as the Monokai theme (`slopdesk.*` namespace, drift-repaired in place, registered in
`extensions.json` because a folder drop is invisible once that file exists) — except this one
is CODE, not data, which the vendored-theme rule never forbade: it forbade shipping SOMEONE
ELSE's code that nags. `CodeBridgeServer` binds an `AF_UNIX` socket (pid-keyed, 0600, lazily —
a host whose user never opens the panel never creates it), hands the path down through
`childEnvironment` as `SLOPDESK_CODE_BRIDGE_SOCKET`, and every workbench window's extension
host connects back announcing its workspace folder. An open is then one line of NDJSON to the
window whose folder CONTAINS the target, deepest folder first. Verified end to end against a
real code-server 4.112: the extension attached with the right root, and a commanded
`line 3, col 2` open put the caret exactly there.

The CLI arm stays as the fallback and the two are raced on every retry attempt — during a cold
start neither route exists yet, and whichever appears first should win. Nothing changed on the
wire: verb 19's request, response and disposition byte are identical, so an old client and a
new host still agree. The message set is deliberately minimal (hello + open) and versioned by
its own `v` field; this is host-local IPC, not a fourth network path, and it is NOT
golden-pinned.

## The panel's fonts stop riding the injected script (2026-08-03)

The webview's WebContent process cannot see fonts the app registers with `CTFontManager`
(registration is process-scoped), so the panel ships its faces into the page. The first shape
for that was a `data:font/ttf;base64,…` URI per face inside the injected style sheet — which
meant the dressing user script carried 4,069,800 characters of base64 (3,052,348 bytes of TTF
inflated by a third), re-injected and re-parsed on every workbench navigation, once per
pooled webview.

Now the sheet names three short `slopdesk-font://fonts/<face>.ttf` URLs and a
`WKURLSchemeHandler` answers them with the bundle's bytes, memory-mapped. The script drops to
a couple of KB; the faces arrive as ordinary subresources marked `immutable`, so a reload does
not refetch them. A custom scheme rather than http: `setURLSchemeHandler` refuses the standard
schemes, and the fonts are the CLIENT's resources — routing them through the loopback relay in
front of the host's code-server would be wrong on the merits.

Verified with a standalone `WKWebView` probe against a real http origin, reproducing the
cross-origin condition the workbench page creates: the handler served 303,144 bytes and
`document.fonts.check('13px "JetBrains Mono"')` returned true. The negative control was
informative and corrected the comment that shipped first — WebKit loads the face WITHOUT
`Access-Control-Allow-Origin` too, so that header is hygiene against a future tightening, not
the mechanism. It is still sent, and the code says so honestly.

Two riders on the same pass. Verb 20 (`syncCodeFont`) no longer rides every ensure round: an
`.unavailable` host — no code-server binary, polled every ~3.6 s for as long as the panel is
open — was being sent font settings for a workbench that will never boot, and an unchanged
spec was making a round trip whose only possible answer is "nothing changed". `.starting`
still pushes: the seed has to land before the booting workbench reads its settings.

## ⌃` / ⌘` inside the editor reach the terminal PANE (2026-08-03)

The embedded workbench ships VS Code's integrated terminal, and ⌃` opens it. That shell is
outside everything this app exists to provide: no agent detection, no PTY fan-out to the other
clients, no replay buffer, no scrollback journal — a second, worse terminal one muscle-memory
chord away from the good one. Rather than hide it (removing an escape hatch nobody asked to
lose), the chord is spent on the real thing: while the editor holds the keyboard, ⌃` and ⌘`
hand the keyboard back to the terminal pane instead.

They resolve from a PANEL-LOCAL table consulted only inside the webview-yield branch, not from
the chord registry. Keeping them out of the registry is the whole point — the app's at-rest
keyboard is untouched, so AppKit's ⌘` (cycle app windows) and the terminal's own ⌃` keep
working at every other focus, and the cost is paid only where the alternative was worse. ⌘` is
included at the user's direction (2026-08-03); ⌃` is the one VS Code actually binds.

Both spend `.focusCodePanel`, whose hand-back arm fires whenever the webview is the one holding
focus — which inside that branch it always is. The binding is now titled "Switch Editor /
Terminal Focus" in the menu and the palette, which is what it has always done; the id is
unchanged, so no keybinding a user saved moves. ⌘` also came OUT of the webview's reserved-app-
chord list: the NSEvent monitor runs ahead of the whole responder chain, so that case could no
longer run and would have read as a live rule that was not one.

## The editor can type into a real pane — the HOST picks which one (2026-08-03)

The same argument that spent ⌃` on the terminal pane leaves an obvious hole: an editor whose
only way to run the line under the caret is a terminal we just talked the user out of. So the
bridge extension contributes two commands — "Run Selection in SlopDesk Terminal" (editor
context menu) and "Change SlopDesk Terminal Directory Here" (explorer and editor context
menus) — and they type into a genuine SlopDesk pane: agent-detected, fanned out to the other
clients, in the replay buffer, in the scrollback journal.

WHICH pane is decided by the host, not the extension, because focus is a client-side fact the
extension host cannot see and the client that has focus may not even be the one whose editor
issued the command. `CodeBridgeTerminalRouter` is a pure function over the pane set with three
filters, each of which refuses rather than guesses:

* the pane's cwd must be CONTAINED by the workbench root — a command about this project never
  lands in another project's shell;
* no agent may be detected there — typing at Claude Code's prompt does not run a command, it
  sends the agent a message, which is a far worse outcome than doing nothing;
* the foreground process must be a shell — a pane sitting in vim, less or a build is not at a
  prompt, and a stray `npm test\r` there is keystrokes into someone's editor.

Ranking among the survivors is deterministic (most path components shared with the file's
directory, then the deeper cwd, then the lower pane id) so the same gesture keeps landing in
the same pane. Candidates are attached mux sessions only: a detached or agent-spawned control
session is not a terminal the user is looking at. When nothing survives, the extension shows a
warning naming the reason — every project pane busy, or no pane in this project at all.

The `cd` command sends a DIRECTORY, never a command line; the host builds and quotes the `cd`
itself, so shell quoting has one tested home rather than a copy in JavaScript. Requests are
correlated by id and answered either way: the status bar names the pane on success, a warning
the user must dismiss explains a refusal, and a connection that drops takes its pending
requests with it rather than leaving a command that silently never ran.

Verified out of band, in two halves, since neither real sockets nor a real workbench belong in
the unit suite. The socket half ran a probe against the shipping `CodeBridgeServer`: two
windows' hellos, run and cd round trips, the refusal path, malformed/relative/oversized lines
dropped without desyncing the connection, a closed peer not taking the host down. The extension
half drove a real code-server 4.112 under chrome-headless-shell over CDP: both commands appear
in the palette, the selection branch sent exactly the selected characters, the no-selection
branch sent the caret's whole line, the cd carried the resolved directory, and both result arms
(status bar, warning notification) rendered.

## The panel gets a fifth tab: the host's browser, with its own inspector (2026-08-05, REMOVED)

Files, Simulators and Emulators all answer "what is on this machine". Web answers a different
question — "what does this page do" — and it is the one the panel could not answer at all. The
tab drives a browser that runs on the HOST and inspects it with THAT BROWSER'S OWN DevTools
frontend, over Chrome's debugging protocol (metadata verb 23).

The obvious build was the cheap one: the client already embeds WebKit, so render the page
locally and open Safari's Web Inspector on it. It was rejected on two counts that a preview
pane cannot buy back. The page under development is served by the HOST — a dev server on the
host's `localhost`, the host's hosts-file, its certificates and its cookies — so a browser
sitting on the host types `localhost:5173` and is there, while a client-side web view needs a
forwarded port for every service and still breaks on the first absolute link the app emits to
its own origin. And WebKit gives an embedding app no supported way to open its inspector at
all: the private route (`_inspector` / `attach`) is what cmux and muxy both use, is macOS-only,
and cmux's own source warns that a repeated attach can crash inside `platformAttach`. A
SlopDesk client also runs on iPad, where that route does not exist.

Chrome serves its entire frontend over HTTP, which turns the whole problem into a URL. Measured
before any of this was written: that frontend renders and drives a page correctly inside
WKWebView on macOS AND on iPadOS 26.5, with no private API on either. One surface, one
behaviour, every client — and nothing of DevTools vendored, so it can never fall out of step
with the protocol behind it.

Two relays, and neither is optional. Chrome binds its debugging port to loopback and cannot be
talked out of it (`--remote-debugging-address=0.0.0.0` is accepted and ignored), so hostd fronts
it. The frontend then opens its websocket back to `ws://127.0.0.1:*` and admits nothing else, so
the client fronts the mesh endpoint on a stable loopback origin of its own — under its own key,
because DevTools stores its whole layout against that origin.

The address bar navigates the EXISTING page over CDP rather than opening a new one: a new target
means a new DevTools session, which is exactly what an address bar must not cost. It is not a
search box either — prose resolves to nothing rather than being shipped to a search engine, and
a bare loopback host gets `http://`, because that is where the host's dev server is.

Unlike the two device tabs, hostd's shutdown terminates this child. A booted simulator or
emulator is the user's own machine state; a headless browser on a private profile is a process
nobody can see to stop.

## …and loses it again: a screencast is not a browser (2026-08-05)

The tab shipped, was used, and was removed the same day (user-directed). Three complaints came
back from real use, and measuring them separated one architectural verdict from two bugs.

Two were bugs, and both were fixed before the removal: the pointer never changed shape over a
link, because DevTools' screencast simply does not carry the cursor — the panel now asks for it
over the frontend's OWN debugging socket, hijacked at document start; and the pages flagged the
browser, which was three launch flags (`--disable-blink-features=AutomationControlled`, a real
user-agent built from the bundle version, and `--screen-info`, without which every page reads an
800×600 screen).

The third was not a bug. `Page.screencastFrame` ships a WHOLE JPEG per frame and waits for an ack
before the next one, which measured 20–25 fps on loopback and 14–17 over the mesh. Four
independent attempts moved none of it: cutting the payload fivefold bought 3 fps, a trivial page
measured the same as a heavy one, `--disable-gpu-vsync --disable-frame-rate-limit` gave 23, and
the mesh was never the constraint. A coding tool's own browser is scrolled and hovered constantly,
and at that rate the scrolling is what the user feels.

The only native-feeling route left was the app's existing video path — capture a real Chrome
window with ScreenCaptureKit and inject input, which is what the Desktop surface is FOR. Building
a second, browser-shaped copy of it behind a panel tab is not worth a tab, so the feature was
deleted rather than rebuilt: files, tests, its gate script, its dialect doc, and metadata verb 23
(no deprecation shim — this repo does not carry backcompat). What survives is this entry, so the
next person who proposes a CDP-screencast browser panel finds the measurement instead of
repeating it.

## The panel strip stops naming the open file (2026-08-05)

The strip carried the active editor's name, read off the workbench's own document title and
shown next to the tab plates. It is gone, user-directed: a long filename crowded the tabs
beside it, and the workbench already prints the same name in its editor tab an inch below —
the readout was a second copy of a fact the surface underneath never stopped stating.

Deleted whole rather than shortened: the parser, the pooled per-project readout, the KVO
registration on `WKWebView.title`, and its tests. A middle-truncated copy of a nearby label is
still a copy, and it still costs the tabs their width.

The seed follows it down. `window.title` was pinned to
`${dirty}${activeEditorShort}${separator}${rootName}` back when the web title bar was visible,
and stayed because the strip read it; with the title bar clipped off client-side and no reader
left, v17 drops the key and lets the workbench keep its default (v16 joins `obsoleteSeeds`, so
pristine hosts upgrade in place). Nothing renders a title in this panel now — the honest shape
for a string nobody displays is no string at all.

## The code panel moves to code-server 4.131 so mermaid renders itself (2026-08-06)

The panel opens `*.md` in the built-in preview, and a fenced ```mermaid``` block came out as its
own source — the one place the preview-first default read as a downgrade. Two routes were
measured against the real thing, not argued.

`bierner.markdown-mermaid` installs and works on the 4.112 workbench (verified: the preview
editor renders one `<svg>` per fence; the same fixture also showed it disabled — diagram silently
back to source — in a restricted workspace, since its manifest declares no
`capabilities.untrustedWorkspaces`). It is also DEPRECATED: VS Code 1.121 merged it in as the
built-in `mermaid-markdown-features`, and having both installed breaks rendering
(microsoft/vscode#317870). Installing a deprecated extension to get a feature the platform now
ships, and booby-trapping the next upgrade with it, is the worse trade.

So the host requires code-server ≥ 4.121 and runs 4.131 (Code 1.131). Homebrew cannot supply it —
the formula froze at 4.112 and is deprecated ("uses non-FOSS @github/copilot since 4.113.0") — so
the install is the standalone tarball under `~/.local/lib` with a `~/.local/bin` symlink, and
`HostServiceProcess.fallbackBinDirectories` now leads with `~/.local/bin` (a hand-managed copy is
the one an operator meant; hostd is `nohup`'d, so its `PATH` is not a login shell's). The built-in
extension is MIT, `untrustedWorkspaces: supported`, and its default theme follows the workbench
colours — nothing is seeded for mermaid itself.

Two things the newer workbench moved, both measured on a fixture profile carrying the real seed:

The web title bar is **30px**, not 35 — the clip constant would have clipped 5px into the editor tab
row. The number is not a CSS constant to grep (the workbench grid positions its parts with inline
geometry); the honest measurement is the laid-out box, and the comment now says so, because this
constant will move again. It lives at `CodePanelPresentation.clippedTitleBarHeight` since docs/56
increment 51 — it was a `static let` on each of the two mounts, which made one measurement a number
two files carried.

Chat came back. 4.113+ bundles the Copilot chat extension, which re-registers
`chat.disableAIFeatures` — the key v7 had to drop as unregistered on Code-OSS. Seed **v18** turns
it on again (v17 joins `obsoleteSeeds`, so pristine hosts upgrade in place): the AI surfaces stay
off, as they have been seeded since v2. Verified on a fresh profile: chat panel empty and its
secondary side bar closed, title bar 30px, tab row 35px, mermaid rendered.

## The panel's runtime deps are pinned in-repo, not brewed (2026-08-06)

The mermaid round above cost a day for a reason worth naming: the panel had been running Code 1.112
for months, and nothing in the repo recorded — or could enforce — which workbench version its
surgery was written against. `code-server` was "whatever Homebrew installed", the formula froze at
4.112 and was then deprecated, and no gate could see any of it. That is a supply problem, not a
mermaid problem, and it applied equally to `baguette`, `adb` and the `scrcpy-server` jar.

So the four host-side programs the right panel stands on are pinned by URL + SHA-256 in
`ThirdParty/tools/tools.lock` and provisioned by `ThirdParty/tools/provision.sh` (`make provision`)
into `ThirdParty/tools/.prefix/bin`, which `HostServiceProcess.searchDirectories` consults **before
`PATH`**. Inverting the usual "the operator's `PATH` wins" is the entire point: the pinned version
is the one this checkout was measured against, and its bump is a reviewed change with a documented
tail. `SLOPDESK_*_BIN` still outranks the pin, so bisecting a candidate build is unaffected.

Same bargain `ThirdParty/ghostty/` already struck — the recipe is committed, the artifact is not
(`.prefix/` is ~730 MB, gitignored). `VendoredTools` locates the prefix by walking up from the
running binary looking for `tools.lock` rather than baking in `#filePath`, which would record the
machine that COMPILED hostd; a binary copied out of the tree resolves nothing and falls through to
the host's own installs, which is the right answer there.

**hostd never provisions.** Nothing on the runtime path downloads or writes — it stats. A coding
host must not reach the network because someone opened a panel.

Two deliberate exceptions to "everything is fetched":

The **`scrcpy-server` jar is committed** (`ThirdParty/tools/vendor/`, 716 KB), reversing the earlier
"the jar is NEVER in this repo" rule. It is small, and it is the only dependency that is not an
executable — the device's own `app_process` runs it — so it carries no signing, quarantine or
architecture concern. `provision.sh` and `VendoredToolsTests` verify those committed bytes against
upstream's published digest instead of downloading them, which also catches the corrupt-checkout
case that would otherwise surface as a phone problem.

**iOS simulators and the Android emulator are not vendored, and cannot be.** Simulator runtimes and
`simctl` ship inside Xcode under Apple's licence; emulator system images come from `sdkmanager`
behind an interactive licence accept at gigabytes per API level. What IS vendorable is the tooling
that drives them — `baguette` and `adb` — and that is what is pinned. Both panels keep their
existing host-discovery path (Xcode, `AndroidToolchain.sdkRoots`) and report unavailable otherwise.
`AndroidToolchain` passes `vendoredBinDirectory: nil` for the emulator on purpose: a prefix that
accidentally shadowed it would break AVD booting everywhere while looking like it worked.

Dev tooling (swiftlint, swiftformat, shellcheck, shfmt, ruff, prek, xcodegen) stays on Homebrew.
Those shape the gates, not the product — a formula drifting a minor version changes a lint message,
it does not put the panel on a workbench three releases old.

Verified end to end: with Homebrew's 4.112 and a hand-installed `~/.local/bin` copy both still
present on the host, a restarted hostd spawned its workbench from
`ThirdParty/tools/.prefix/code-server/4.131.0/` (read off the child's own `lsof` txt map).

## The code panel's backend boots with the daemon, not with the panel (2026-08-07)

The user reported code-server as "heavy, slow to start" and asked for a thorough startup pass.
Measurement first (nothing in-repo had ever timed this chain): the server's own spawn → listening
is small — ~0.4 s with a warm filesystem cache, ~1.2 s cold — and the browser-side workbench boot
on the real profile is ~2.2 s to interactive. What made the panel FEEL slow was the architecture
around those numbers: the spawn was lazy (first panel expand paid seed + bundled-extension check +
Node boot interactively), the child carried `--idle-timeout-seconds 7200` (two quiet hours reaped
it, so the next expand was cold again — the "sometimes fast, sometimes slow" signature), and the
client polled readiness at a flat 900 ms.

Three changes, no new flags (OFF is not a valid mode for any of them):

- **Prewarm.** `slopdesk-hostd` calls `HostServer.prewarmCodeServer()` right after its listeners
  come up; `CodeServerManager.prewarm()` walks the same locked boot path as `ensure` minus root
  validation. Deliberately NOT inside `HostServer.start()` — unit tests build and start servers
  freely and may never spawn a real Node child; the E2E harness points `SLOPDESK_CODE_SERVER_BIN`
  at a non-executable so its sandboxed hostd stays childless (a SET but non-executable override
  resolving to "no binary" is documented `HostServiceProcess.locate` behavior).
- **No idle reaper.** `--idle-timeout-seconds` is gone from `launchArguments()` (pinned by test):
  a reaper re-imposes the exact cold boot prewarm removes, trading ~300-450 MB of resident Node
  for a panel that is always warm. `shutdown()` is now the child's only stop.
- **Install completion continues the boot.** The one-shot bundled-extension install used to leave
  the spawn to the NEXT ensure round — on a prewarmed host there is none, so
  `finishBundledExtensionInstall()` now re-enters the boot path itself.

Client side, `CodeSidebarModel.poll` ramps: the first 8 `.starting` rounds poll at `interval / 3`
(≈300 ms) before settling at 900 ms — post-prewarm, `.starting` is normally only visible when the
panel expands moments after a hostd restart, and the ramp shaves the wait to find it ready.

Measured but NOT adopted: `NODE_COMPILE_CACHE` (bundled Node 24 supports it; the cache populates —
281 files — but saves only ~70 ms on a ~0.4 s path nobody waits on anymore). Not worth a cache
directory whose staleness would need managing across pin bumps. Also out of scope on purpose: a
workbench-interactive signal back to Swift (the veil still drops at `didFinish`), and any change to
the golden-pinned verb-18 wire — the poll ramp is client-local.

The measurement is now repeatable: `scripts/measure-code-server-start.sh` times spawn → listening
against the resolved binary and warns if a live host child still carries the old idle-timeout flag
(the tell of a pre-prewarm build). Run it when bumping the code-server pin (docs/46's "a pin bump
has a tail").

## The code panel opens a project's workbench on request, never on focus (2026-08-07)

Until now the Files surface booted a workbench for whatever project the active pane belonged to:
focusing one pane of another project was enough to start an ensure poll, bind a loopback relay,
mint a pooled WKWebView and boot a multi-second workbench — and to keep that webview warm for the
rest of the session — whether or not the user ever looked at the panel. With the host side now
prewarmed the remaining cost of a switch is entirely this client-side chain, and it was paid as a
side effect of moving focus.

Opening is now an explicit act (user-directed). A project root the session has not admitted renders
an OPEN GATE — the panel's placeholder anatomy (folder glyph, project name, full root in the
instrument face) plus one text-plate button — and mounts nothing: no poll, no proxy, no webview.
The admitted set lives on `WorkspaceChromeState.openedCodeProjects`, not on the panel's own model,
because the second doorway is the terminal leaf's open-in-editor wiring (verb 19): a file the host
already routed into the workbench must mount it, so the reveal admits the pane's host-pushed root
before expanding the panel. Once admitted, a root keeps the old behavior for the rest of the
session — returning to it is the warm swap it always was. The reload plate hides behind the gate
(a generation bump there would boot the very thing the gate defers).

Session-scoped on purpose, like the panel's tab selection: a relaunch comes back gated (pinned by
test), so a restored many-project session never boots a workbench until asked. The strip, the
ensure RPC, and the host are untouched — the gate is one membership check in front of the surface.

## The open gate's admitted set persists across relaunch (2026-08-07, re-scoping the entry above)

The same-day session-scoped choice lasted one session of real use. In practice the gate charged the
wrong moment twice: every client relaunch (and every reconnect that goes through one) greeted the
projects the user works in daily with the gate again — a click plus a cold workbench boot on the
startup path, for surfaces that had already been explicitly asked for. The whole startup pass
(prewarm at hostd boot, no idle-timeout, poll ramp) exists to make that path fast; re-gating known
projects handed part of the win back.

`WorkspaceChromeState.openedCodeProjects` now seeds from `Defaults[.openedCodeProjects]`
(`shell.openedCodeProjects`, the panel's third persisted flag beside collapse and width) and
`openCodeProject` writes the set back. A project opened once boots straight back into its
workbench on the next launch; a root never opened still gets the gate — the gate's job was always
"never boot what was never asked for", not "ask again every morning". The set is client-side and
grows by explicit opens only; there is no eviction, because a stale root costs nothing until its
project is focused again (the membership check is the only reader). The pin test flipped from
asserting a fresh chrome is empty to asserting the round-trip restores the admitted root.

**Round 14 — the rail becomes an instrument panel (2026-08-08, user-directed via mock round).**
Three visible moves shipped together after a four-variant mock comparison (the blueprint
dot-grid variant was declined): (1) INSTRUMENT ROWS — the active sidebar card carries its
home-abbreviated cwd as a second mono line (the 48pt two-register rung), a working agent row
runs the 1 Hz turn clock in the trailing slot, a finished row dates its receipt with a coarse
one-unit age, an awaiting row ages its question in the attention ink. This REVERSES round 4.2's
"trailing text goes silent": that verdict leaned on the title shimmer, which has since been
retired — the readouts are again the only place duration lives on the rail. (2) COMMAND LADDER —
a per-command tick rail down each terminal pane's trailing edge (evenly pitched on purpose:
blocks carry prompt ordinals, not rows, so a proportional minimap would fabricate geometry),
clicking a tick reuses the navigator's re-anchor jump + landed flash. It fills the seam
`TerminalLeafView` reserved for `TerminalBlocksView`. (3) COCKPIT FOOTER — the connection
footer gains a top hairline and swaps the cpu/mem SF-symbol marks for filling arc gauges in the
reading's own alarm ink; disk keeps its glyph (free-space-only data has no denominator). A
Canario-style hover live-peek of pane content was considered and DECLINED outright in the same
round — do not re-propose it.

## The chrome returns to the pre-islands layout (2026-08-08, user-directed)

The window chrome — sidebar, top bar and panel strip — reverts to the layout it had at
`5283c1c1`, before the islands transition began: the hover-reveal `SlateTitlebar` overlay is
back (reopen plates fade in on top-strip hover; the centred pane-title menu and, while the
sidebar is hidden, the connection cluster stay on the traffic-light row), the sidebar collapses
by HIDING again (the 80pt rail and the `PanelEdgeHandle` drawer pull are deleted), the strip
chips return to `State.selected`-wash rects with the `Line.divider` hairline under the strip,
and the round-14 instrument rows / footer arc gauges leave the sidebar. The chrome files were
copied from `1b20eb74` verbatim (that commit differs from `5283c1c1` only by non-design panel
fixes) rather than re-derived, so the revert cannot drift.

What did NOT revert, by explicit instruction: the Dracula Pro / Alucard theme world and the
whole Slate token layer. The old code's `Surface.ground`/`Surface.face` sites were mapped onto
today's `Surface.field` (the authored chrome floor) and `Surface.terminal` (the glass), the
one-polarity appearance pin and the ink-tint `chromeLine` dividers stay, and the split
controller keeps painting its backing layer in the chrome line colour inside the otherwise-base
implementation. The round-14 command ladder also stays: it rides the terminal pane's trailing
edge and is neither sidebar nor top bar, so it sits outside the requested revert.

The embedded workbench follows the chrome home: the seeded settings return to the Monokai Pro /
Monokai Pro Light trio, and the generated Dracula/Alucard workbench extension is actively swept
from seeded hosts (folders plus the `extensions.json` registry entry). The obsolete-seed list
had to change shape for this: the current seed may never appear in that list (a seed equal to
the current one re-marks every font-synced host as pristine-former and rewrites it each boot),
so the old Monokai entry LEFT the list as it became current again, and the Dracula trio entered
as the newest former seed.

## ONE ISLAND — a single lifted terminal on a cream ground (2026-08-08, user-directed)

The window now holds exactly two tones and exactly one lifted surface.

The ask arrived in two steps on the same day. The first was the floating-island chrome in the
Rio-Canario / JetBrains-Islands register, researched independently rather than patched onto the
flat layout. The literal answer — every column and every pane its own island, separated by
channels of floor — came back as too busy, and the correction named the shape exactly: one big
island in the middle for the terminal, splits inside it parted by a divider, both side panels sunk
into the background, the VS Code background matching that background, and the background itself
the Alucard theme's own bg. The archipelago never shipped; what follows is the whole of it.

**Law 1 — one island.** The terminal canvas is the only lifted surface. It wears the profile's
glass, rounds at 8pt and floats in a uniform moat. The navigator, the code panel, the top band and
the moat are all GROUND: flush, un-rounded, one tone, no seam between them. `View.slateIsland()`
has exactly one call site (`ContentColumn.content`); a second is the clutter coming back.

**Law 2 — inside the island, separation is a line.** Panes tile the island edge-to-edge and are
parted by the `PaneDivider` hairline. A channel between panes would restate at pane level the
distinction the island already draws at window level. `SplitTreeRenderModel` keeps no island
geometry, and the libghostty view keeps `cornerRadius = 0` — only the island clips.

**Law 3 — concentric geometry.** Window 16 (macOS Tahoe's titlebar-only radius) − moat 8 = island
8, which is Apple's own concentricity rule. The same 8 falls out of JetBrains' published
`Island.arc.compact = 16` (an arc WIDTH) and out of measuring Canario (≈7.5): three independent
sources, one number.

**Law 4 — the ground is Alucard's cream `#FFFBEB`, under BOTH profiles.** On Dracula that is the
Canario read: a light frame carrying a dark canvas, ~13:1 apart. It is also the only read
available — a DARKER ground under the Pro face `#22212C` is 1.32:1 even at pure black, so the
entire dark half of the axis cannot separate. This reverses the round-10/15 "no inverted frame"
verdict on explicit instruction. On Alucard the ground and the glass are the same cream, so the
island is drawn by its corner and a 1px `Line.divider` inset stroke alone.

**The consequence that is not a second decision:** `chromeIsLight == true` in every profile, and
`ThemeStore.pinAppAppearance` now pins `NSApp.appearance` from the CHROME polarity rather than the
glass. Semantic ink pinned dark would draw white on cream in the navigator. This is not the
split-tone half-and-half the 2026-08-07 note guarded against — that note was written when the
chrome was dark; every chrome surface including the auxiliary windows now shares one light voice,
and the glass is the single surface outside the pin, opting out via `Slate.glassColorScheme`.

Two supporting moves. The AppKit split view paints its dividers and backing layer in the GROUND
instead of the `chromeLine` seam, so the three columns read as one continuous sunken field, and the
window's own `backgroundColor` gets the same tone (a live resize can expose it for a frame, and the
16pt corners should bite into ground). And the embedded workbench is seeded with a
`workbench.colorCustomizations` block repainting every VS Code surface — editor, empty group,
gutter, sidebar, activity bar, tab strip, panel, status bar, title bar — in the ground cream with
their borders zeroed, with the webviews pinned to the chrome polarity and their
`underPageBackgroundColor` moved off the glass onto the ground. The obsolete-seed rule held: the
previous Monokai seed entered the list as it stopped being current, and the current seed is not in
it.

Verified by pixel in both profiles on the running app: ground sampled `#FFFBEB` in the titlebar
band, the navigator and the moat; the island's rounded corner and hairline edge resolve against it
in Alucard, and the dark glass reads as a floating canvas in Dracula.

## The island takes a window's corner, and selection becomes a compact island (2026-08-08, user-directed)

The island's radius was asked to grow twice more (8 → 14 → **26**), so the number was settled by
measurement instead of another guess. macOS 26 Tahoe gives a window the corner its TITLEBAR asks
for: rendering one `NSWindow` per configuration and reading the alpha profile of its corner gives
16 with no toolbar (this app runs `.hiddenTitleBar`, so that is the frame we actually have), 21
with a `.unifiedCompact` toolbar, and 26 with a `.unified` one — Finder and System Settings both
measure 26. The same method on Tahoe's smaller surfaces: a grouped content card ≈ 11, a selected
sidebar row ≈ 8.

The island now wears 26 — the top of the system's own scale — because it is a window-scale surface
(~880 × 775pt), and a window-scale surface wearing a window's corner reads as a window floating
inside the window, which is the metaphor the whole design is after. The concentricity rule that
produced 8 and then capped 14 does not apply here and never did: the island lives in the CENTRE
column, ~230pt clear of the frame's own corners, so the two corners are never seen beside each
other. Its neighbours are flat dividers and bare ground. (JetBrains' `Island.arc` and Rio Canario's
≈7.5 are small because their islands tile a window edge to edge; ours is one card in a field.)

SELECTION changes with it. The selected TAB — the sidebar tab rows and the panel strip's four
surface tabs — is now stamped out of the island's own material: `Surface.island` fill plus a
divider hairline at a compact 10pt corner, in the shared `SlateCompactIsland` shell. The shell also
flips the chip's colour scheme to `Slate.glassColorScheme`, which is what makes it work rather than
a dozen hand-picked inks: title, mode glyphs, receipts, process labels and the close `×` all keep
reading their semantic tiers and resolve against the plate they actually stand on. Under a dark
profile that is a true invert — a dark chip on the cream ground, light ink — and under the light
profile it is the same cream-on-cream-plus-hairline the big island already is, with the existing
`cardShadow` whisper keeping it off flat.

This REVERSES the 2026-08-07 "no reverse-video, no solid chip" verdict on the sidebar row. That
verdict was reached when the chrome ground was dark and any solid plate meant an off-family grey;
on the cream ground the plate is the island tone, in family by construction. `SlateListRow`
(settings, popovers, generic lists) keeps the semantic raised card — this is a tab gesture, not a
list one — and the accent tint / accent edge / underline takes stay dead.

Verified by pixel on the running app in both profiles: island corner extent measured 21–26 against
Tahoe's 27 for a full-chrome window, terminal content clips cleanly through the corner, and the
selected tab reads as a dark chip with light ink under Dracula and as a hairlined cream chip under
Alucard.

**Follow-up the same day: the moat goes uniform.** The island now rises to the same 8pt inset at the
TOP as it keeps on its other three sides (user-directed), so there is no titlebar band left across
the window — the traffic lights stand on the NAVIGATOR's ground with the island beside them, not
below them. `slateIsland(clearingWindowControls:)` names the one exception: with the navigator
collapsed the content column owns the window's left edge, and an 8pt top moat would slide the island
under the lights, so that case widens the top side back to `bandHeight`. Verified by pixel — island
top edge at y = 8 with the navigator open.

## ONE appearance — the theme picker is deleted, not defaulted (2026-08-08, user-directed)

The app now ships exactly one appearance: the cream ground `#FFFBEB` carrying the dark Dracula Pro
glass `#22212C`. The instruction was to keep a single theme with a permanently light background and
a dark terminal, and the honest reading is that ONE ISLAND had already made the second profile
pointless. Law 4 of that round forces the cream ground under every profile, so choosing the light
profile only repainted the island itself cream — flattening the single contrast the design is built
on into a cream card on a cream field held together by a hairline. A picker whose second setting can
only degrade the design is not a choice, so it goes rather than acquiring a default.

Deleted outright (no deprecation, no migration — the standing no-backcompat rule): the light/dark
slots and the follow-OS resolution (`ThemeResolution`, `AppearancePreferences.theme`/`darkTheme`/
`separateDarkTheme`), the built-in catalogue (`ThemeCatalog`), the runtime store and its
cross-`NSHostingController` repaint notification (`ThemeStore`), the per-theme font map and its
resolver (`FontScopeResolver`, `TerminalConfigBuilder.fontFamilyOverride`, the Light/Dark scopes in
the font settings), the Settings gallery (`ThemeGalleryView`), the palette's Switch Theme verb, the
first-launch theme step (macOS 5 → 4 steps, iOS 3 → 2), and the `theme` CLI noun plus the `theme`
config key (`theme list` / `config set theme` / `ThemeColorFilter`). A stored preferences blob still
carrying the dead keys decodes with them ignored.

What survives is the part the cream ground genuinely needs: `SlateAppearancePin` pins
`NSApp.appearance = .aqua` once, deferred past `App.init` (NSApp is nil there — a trap this codebase
has hit before), and the glass opts out locally through the now-constant
`Slate.glassColorScheme == .dark`. `Slate.theme` stays a `@MainActor` computed property returning the
single `SlateTheme.app` so no token call site changed; `SlateTheme` lost `id`/`isLight`/
`chromeIsLight` because a single value has no polarity to branch on. `AppearanceApplier` is down to
one hook, `resolveTerminalColors`, which the app binds to `SlateTheme.app` so the libghostty CELL
colours still track the profile headlessly-safely (`nil` hook ⇒ the pref's own colours stand).

## TWO TONES everywhere — the paper card and the panel sweep (2026-08-08, user-directed)

ONE ISLAND set the window frame and stopped there. This round carried the same law into the
surfaces that had not been touched, because the instruction was to adopt the new design across
what remained. Two kinds of drift turned out to be hiding, both invisible while the chrome was
still dark, and both a THIRD thing in a design whose whole claim is that there are two.

**A third grey — the device panels.** The Simulators and Emulators surfaces, and the first-launch
window, painted themselves from `underPageBackgroundColor` and `windowBackgroundColor`. Those are
the right semantic choices for an app standing in the system's own tones; this one stands on a
cream it chose. Sampled live, the panel column read `#A1A09F` against the sidebar's `#FFFBEB` — a
column that visibly did not belong to the window it was in. Every one of those surfaces is now
`Slate.Surface.field`.

That also retires MERIDIAN L5's "two surfaces, depth by light" inside the device panels, where the
top bar was housing on `ground` and the device and console were content on the lit `face`. The
argument for lighting the stage does not survive the sweep: the lit thing there is the DEVICE, which
arrives already drawn as an object — its own bezel artwork, or a bare screen inside the panel's
corner — so lighting the band behind it only competed with it. The three bands are now told apart by
the hairlines that were already there. Where something must genuinely lift off the ground inside a
panel — a placeholder plate behind a picture that has not landed, a console strip, a first-launch
card — it takes `Surface.raised`, which is TRANSLUCENT and therefore tints the cream rather than
substituting another palette's grey for it. That is the general rule this round adds: a region of a
surface is a translucent lift of it, never a second opaque tone.

**A third material — the floating family.** The palette, Open Quickly, global search, the cheat
sheet, connect, the pane switcher and the notification card were Liquid Glass. Glass earns its keep
by refracting what varies behind it, and after ONE ISLAND exactly two flat opaque tones lie back
there, so the effect had degraded to a grey slab that additionally flipped relationship halfway
across itself: light-over-cream at the card's edges, light-over-glass in its middle. Apple's own
guidance points the same way — do not stack glass; apply the material once, at the top.

`SlateGlassCard` is therefore `SlatePaperCard`: `Surface.field`, opaque, cut at the island's 26,
edged by the island's hairline, on the `palette` shadow rung. The decision was made by rendering
both candidates at true size rather than by argument, and it was not close. A summoned card lands
CENTRED, which is exactly where the dark island already is, so a card wearing the island's glass
disappeared into it; the cream card reads as a sheet laid on the canvas at ~13:1 and is carried at
its own edges — where it meets the ground — by the hairline and the cast, exactly as the island is.
The card keeps the neutral system-semantic ink (`SlateOverlayInk`) it always had.

The card carries a SCALE, because a corner is read against the surface it cuts and the family spans
two: a 640pt summoned panel takes the island's 26 (Tahoe's own alert panel measures ≈ 30, so 26 is
inside the range the OS uses at that size), and a 320 × 46 notification takes the compact island's
10. One token had to grow with it: `State.overlayShadow` (0.30) is twice `State.shadow`, because a
panel floating over the dark island is separated by tone while a paper card is the ground's own
cream lifted off the ground, and nothing but the cast tells the two apart at its edges.

The overlay host's justification for presenting IN-WINDOW rather than in a `.sheet` was rewritten,
not deleted. The refraction half of it is gone with the material, but the rest survives intact: a
sheet is a separate window, it paints its own ground across its whole frame (which flashed as a pale
panel on open and haloed the inset card), its mask clips the corner to the system's radius instead of
the island's 26, and a shadow presented in its own window falls on nothing the user can see.

**One craft fix found on the way.** `SlateKeycap` set chords in the instrument voice, and the
modifier symbols (⇧ U+21E7, ⌘ U+2318, ⌥, ⌃) are advanced by a monospaced face's CELL rather than by
the glyph — so on any machine without the pinned mono installed, where `Slate.Typeface.instrument`
resolves to SF Mono, "⇧⌘W" rendered as one smear. Rendered side by side at 3×, the three candidate
faces split two-to-one: both proportional faces set the chord cleanly and the mono one collides. The
cap is now the system face, which is also the register macOS draws the same glyphs in in every menu.

Settings is deliberately NOT swept. It stays in pure system semantics (`SettingsInk`) for the reason
that file already gives — a preferences window full of native `Toggle`/`Picker`/`Stepper` controls
that draw themselves from the OS accent no matter what, so it should look like System Settings
rather than half like it. The user confirmed that verdict when it was put to them (2026-08-08):
both alternatives — repaint the ground and keep the native controls, or carry the island vocabulary
all the way into its rows — were offered and declined. Do not propose it again.

## The state transfer carries the shell's prompt marks, and the chip family comes home to the island (2026-08-09)

Two user-reported defects, one session. They are unrelated in mechanism and share only the fact that
both were introduced by a change that was correct about what it *painted*.

**1. After a client reconnect, clicking the command ladder no longer jumped.** The ticks came back,
so the metadata path was fine — `CommandBlockTracker.snapshotForResync` re-emits every held block
(ordinals included) on reattach, exactly as designed. What did not come back was the thing the jump
actually walks. `BlockJump.toPromptOrdinal` is a RELATIVE re-anchor over libghostty's prompt-row
iterator: `jump_to_prompt:-32000` to pin the oldest retained prompt, then `ordinal − 1` downward
hops. A prompt ROW exists only where the shell emitted OSC 133 `A` — and `TerminalSnapshotRenderer`,
which replaced byte-history replay with a state transfer (2026-07-25), emitted content only. Its
model skipped every OSC body wholesale, so the marks were not merely unrendered, they were never
recorded. A cold reattach therefore delivered a complete-looking scrollback containing ZERO prompt
rows: the anchor found nothing, every hop found nothing, and the click ran a bare `scroll_to_bottom`
and looked broken. The navigator's per-row jump and Jump-to-Failed were dead the same way — the same
primitive, the same silence.

`TerminalScreenModel` now keeps a per-row prompt flag beside its soft-wrap flag (shifted by every
scroll/insert/delete, cleared with the rows an erase blanks, rebuilt by RIS and `ED 3`), fed by a
5-byte matcher over the OSC body that recognises `133;A` and `133;A;<params>` and nothing else — not
`133;B/C/D`, not another OSC, not a DCS that spells the same thing. The renderer re-emits
`ESC ] 133 ; A BEL` ahead of each marked logical line. Because the model PARSES what the renderer
EMITS, the canonicalization proof extends unchanged: the flags are compared in `assertRoundTrip`, so
the existing curated corpus and the 300-seed fuzz now pin mark placement too, and
`render(feed(render(A))) == render(A)` still holds byte-exact.

Two boundaries are deliberate. The host's snapshot scrollback budget (10 000 lines) equals the
client's own scrollback cap, so the prompt window after a transfer is the window the client would
have held live — the ordinal base does not shift and jumps land exactly, with no new long-session
degradation beyond the ring-eviction case the jump already documents. And `renderTranscript` (PATH B,
the journal restore) emits NO marks: those bytes front a brand-new shell whose segmenter restarts its
ordinals at 1, so an inherited mark would make ordinal #1 a dead session's prompt and mis-land every
jump in the new life. Marks are re-emitted where the ordinal space is CONTINUOUS with them, and
nowhere else.

**2. The transient chips were unreadable, and standing in the wrong place.** `NoticeChip` /
`CopyReceiptChip` / the connection indicator drew in the semantic chrome tiers — `Slate.Text.*` over
`Slate.Surface.raised`. Those tiers are PINNED ON THE LIGHT SIDE (the ink ladder re-solved against
the cream ground), and the stack was mounted on the window root, which never flips to the glass
scope the pane tree sets. So over `#22212C` the chip drew `#585751` ink on a `.quaternarySystemFill`
plate: present, and invisible. The token doc had already written the rule down — everything inside
the island reads `Slate.Terminal.*` — the chips were simply a third subtree nobody had counted.

They now draw in the glass's own vocabulary, the same set `CommandLadderPeek` uses, and they have
moved off the window root onto the pane canvas (`IslandChipStack`, mounted by `ContentColumn`). That
answers the placement half: bottom-centre of the WINDOW includes the navigator and the code panel, so
the stack drifted off the canvas it was describing, and its 16pt window-measured inset parked it on
the island's bottom edge, over the live prompt line — the exact failure this family's own header
comment forbids ("can occlude the prompt line"). Centred on the island and standing off its foot by
`Metric.islandChipInset` (24), there is a clear channel of glass under it. User-directed 2026-08-09;
window-centred and pane-corner mounts were both offered and declined.

⚠️ The hit-transparency stays PER CHIP. A flag on the stack would deafen the connection chip's
`Button` — the same ancestor-suppression lesson `OverlayHostView`'s two-layer note records.

## The island's rim is the glass's own edge, so the boundary is not on loan from the ground (2026-08-10)

User-directed: give the surfaces whose fill IS the dark glass a light tinted edge, so that a darker
ground later would still leave the island standing off it — the platform's own treatment of a lifted
dark surface.

The two call sites that paint `Surface.island` — `View.slateIsland()` and the selected tab's
`SlateCompactIsland` — stroked `Slate.Line.divider`. That token dates from the two-profile era, where
a light profile put cream on cream and the hairline was the only thing that could say where the glass
began. Under ONE APPEARANCE it is the system separator resolved on the LIGHT side (the app pins
`.aqua`), which lands near-black at a tenth ON `#22212C`: measured off the render, the old rim drew
`(31,29,40)` against a `(34,32,44)` face — **1.05:1**, a hairline that was there and did nothing. The
island's entire boundary was the ground's 13:1 tone step, i.e. a property of the CREAM, not of the
island. Repaint the ground dark and the island loses its edge along with the contrast.

Both rims are now `Slate.Terminal.edge` (`#454158`, the profile's selection tone — a published value,
not an invented chrome hex). Measured on the same render: `(70,63,87)`, **1.63:1** against the glass,
and 1.6–2.2:1 against any plausible dark ground. That is the direction the platform draws a separator
on a dark surface — the hairline LIGHTENS — and it is the same line the panes inside the island are
already parted by (`NativePaneColor.separator`), so the window has one line vocabulary inside and out
rather than a chrome rule outside and a glass rule inside.

Scope is exactly the surfaces made of the glass. The paper family (`SlatePaperCard`,
`slateSheetSurface`) keeps `Line.divider`: those are the GROUND raised, their edge answers to the
chrome polarity, and they would need re-solving with the ground itself, not ahead of it.

## The command ladder is removed WHOLE (2026-08-10)

User-directed, no conditions attached: drop the command ladder entirely. It was the trailing-edge
tick rail on every terminal pane — one mark per OSC-133 block, a foot rung home to the live prompt,
and a hover-dwell peek card carrying a coloured excerpt of what each command printed. Four rounds of
fixes went into it (`fa53e746` gutter mount + glass inks + quantized pitch, `e6e17c9f` the peek mode,
`e9af5786` the wider rail + coloured excerpt, `f36d3f1c` the nerd-font cascade, `9860c56d`/`74e0367f`/
`a4425add` the foot rung). All of it is gone; this entry is the record so no future round re-derives it
by accident.

Deleted: `CommandLadderOverlay`, `CommandLadderPeek` (layout, entry, card), `SlateAnsiInk`
(`Slate.Ansi.ink` + `Slate.Typeface.terminalFace`'s Core Text cascade), `BlockOutputPreview` +
`BlockOutputPreviewBuilder`, every `Slate.Metric.ladder*` token, the pane-addressed store verbs
`jumpToBlock(index:pane:)` and `scrollPaneToLivePrompt(pane:)` (the ladder was the only caller of
either), the opt-in `SLOPDESK_LADDER_SNAPSHOT_DIR` renders, and the four test files that pinned the
rail's fit, the card's placement, the excerpt rule and the font chain.

WHAT STAYS, and why each is not the ladder:
- **`AnsiStyledText`** — `BlockOutputSanitizer.plainText` was rewritten as a wrapper of this pass in
  `e9af5786`, so it is now the CLIPBOARD's skimmer. Rewriting it back to a style-blind one would put
  22 sanitizer pins at risk to delete code nothing else depends on.
- **`Slate.Terminal.ok` / `.err`** — a token-layer rule ("anything saying clean/failed INSIDE the
  island is dealt the profile's own ANSI green/red, never `Slate.Status`"), with its own test. Tokens
  legitimately outlive one consumer; the rule does not stop being true because the ladder stopped
  being drawn.
- **Block navigation** — `⌘PageUp`/`⌘PageDown`, jump-to-failed, the Command Navigator's rows, the
  prompt-jump landed flash, and `b151fb18`'s state-transfer replay of the OSC-133 `A` mark all serve
  the keyboard and navigator paths. The reconnect fix was diagnosed through the ladder but is not the
  ladder's: without it the navigator has no prompt rows to jump to either.

The pane's side padding goes back to the 8pt grid (`Slate.Metric.paneGutter` deleted). It was widened
to 12 in `e9af5786` for one reason — a rail worth aiming a pointer at — and with the rail gone the
gutter carries nothing, so the terminal takes back the ~1 column per side it was paying.

## The rail's row titles drop a rung, and the git line's hues come back (2026-08-10, user-directed)

Two user-directed corrections to the sidebar, one commit.

**The pane title was one rung too loud.** It sat at `Typeface.body` (13) — the OVERLAY family's
reading size — which put it a full step above the `footnote` (11) project header that names the group
it belongs to, and a step above `base` (12), the app's own default UI label size, for a string that is
a label. It moves to `base`; the inline rename field follows so opening the field never resizes the
text. Nothing else in the rail may now out-rank it, which took three more sites: the ⌘-held digit hint
(it stands in for the ROW, not for the 10pt metadata it covers), the empty-list label, and the "New
Tab" drop slot. Row geometry is untouched — `heightTabRow` is `heightRow`, never derived from the type
size. The `footnote` token's doc-comment claim of "tab titles" was wrong even before this and is
corrected.

The rail's ladder is now: **row title 12 · project header 11 semibold · git line / process label /
badge 10 mono.** The overlay family (palette, ⌃⇥ switcher, open-quickly, command navigator) keeps 15
over 13 — a summoned card is a READING surface and the rail is a LABEL surface, and that is the line
between the two scales.

**The git line goes back to a hue per role**, reversing `1b289043` (round 17's palette had been folded
to two registers on 2026-07-30). The reversal is the user's call and the reason is that the constraint
that motivated the fold — the rail held monochrome — no longer applies. Restored exactly:
`+staged` green → `!modified` yellow → `?untracked` orange → `~conflicted` red is a RAMP ("how far
this work is from being committed"), running in the same left-to-right order the sigils already
appear; `↑↓` divergence takes the accent and `$` stash the system purple, both cool, both off the warm
sweep because neither is a worktree state; the branch keeps the secondary ink because it is identity,
not a count. The weight ladder returns with it — counts semibold, `~conflicted` bold — because the
palette ranks the states backwards by contrast (a mid-tone red under a bright yellow) and weight is
the channel that is free of the palette, and of the protanopia collapse between `+` and `~`.

The hues cannot collide with what they stand on: `ProjectTint`'s beds are solved to the 195°–340° arc
precisely so red / amber / green stay the status vocabulary's alone.

Three neighbours had documented themselves as borrowing "the git line's two-register answer" — the
command-outcome ink, the status-mark note, the connection footer's alarm ladder. Their BEHAVIOUR is
unchanged and correct on its own terms (a command has two outcomes; a footer of numbers has no sigil
to hang a palette on); only the prose that pointed at a register the git line no longer has was
re-anchored.

Untouched: `shedLadder`, the tight form's pinned sigil cluster, the tooltip, and the accessibility
line — the readout's LAYOUT was never what was being argued about.

## The identity bed drops to 0.08 so the status runs are the loudest colour in the rail (2026-08-10, user-directed)

`Slate.Opacity.bed` 0.10 → 0.08. It is the alpha behind BOTH sunken islands — a project group's
identity bed (`ProjectTint.wash`) and the connection island's neutral (`ProjectTint.neutralBed`) — so
one token carries the whole round.

The complaint is a ranking, not a colour: a bed is coloured everywhere at once, while the status
vocabulary (the git line's ramp, the attention marks) is coloured in a few glyphs, and at 0.10 the
beds were spending more of the eye's colour budget than the runs standing on them. Measured on the
composite, 0.08 takes ~21 % of the bed's a\*b\* displacement off the cream — the loudest entry
(magenta) 14.51 → 11.39, the quietest (teal) 5.73 → 4.66 — and lifts the whole set ~1.2 L\*.

What it costs, stated plainly: the register's hexes were solved for maximum minimum separation AT
0.10 (worst pair ΔE2000 7.00), and every pairwise distance scales toward the cream with the alpha —
the worst pair now measures ≈5.5 by the same yardstick. That is still well above the ~2.3 where two
large flat fields stop reading as different colours at all, and the hexes are deliberately NOT
re-solved: re-optimising would buy back exactly the separation this round decided to spend, and
`ProjectTint.Deal` already guarantees the case the eye actually meets — two ADJACENT islands never
share a hue.

What it does not cost: `Text.tertiary` is pinned to this alpha because a tinted bed is a different
ground, but the pin only binds upward. The alpha fell, so every bed lightened and the quiet rung
gained margin (4.46 → 4.60 on the deepest bed). `#6C6B64` is kept as solved rather than walked back
up — it is the cream's own colour at depth, and the ladder reads by its steps, not by its floor.

Honest about the size of the win: the WCAG contrast of a status hue against its bed barely moves
(green 1.77 → 1.82). The gain is not contrast, it is chroma budget — with the bed spending a fifth
less colour, the saturated things left in the sidebar are the ones that mean something.

The beds now have a headless render (`testRenderProjectBeds` → `project-beds.png`). They had none:
the bed is mounted only by `NavigatorColumn` / `WorkspaceTabStrip` / `ConnectionCluster`, so every
other opt-in render draws the rail with no bed under it and this alpha could have moved unseen.
Verified by sampling the PNG — teal composites to `#EBF4E4` and rose to `#FEEEE5`, both exactly the
0.08 arithmetic over `#FFFBEB`.

## The status vocabulary gets an INK cut (`Slate.StatusInk`), and `Slate.Chroma` is deleted

The bed alpha above was the second half of a question the user asked directly: what else is there,
besides taking colour away from the ground, to make a status indicator carry? The honest answer was
that the loudest lever had not been pulled yet — the status colours themselves were the wrong
colours for the job they were doing.

Measured as INK on this chrome's cream, the system palette lands at **2.05** (systemGreen) and
**2.12** (systemOrange), under even the 3.0 floor for non-text, while `Text.tertiary` — the rung
whose entire purpose is to be ignorable — measures **5.16**. The rail was drawing its loudest
vocabulary two and a half times fainter than its quietest: a `+3` staged count read weaker than the
`zsh` label beside it. That palette is not wrong, it is simply tuned for what Apple uses it for —
filled controls, and a dark UI. Every place this app FILLS with it (toasts, hint plates, the drop
overlay, the alert chip's dot) still reads perfectly, which is exactly the split `Accent.deep`
already makes in the other direction.

Two more faults fell out of the audit. `Status.warn` and `Chroma.orange` were BOTH `systemOrange`,
so the git line's documented four-rung ramp — `+staged` → `!modified` → `?untracked` →
`~conflicted` — rendered `!` and `?` in one identical colour; the ramp had three rungs, not four.
And `Chroma.purple` sat 12.6° in Lab hue from the accent the neighbouring `↑↓` run used, so those
two were near-indistinguishable too.

`Slate.StatusInk` is six hue angles solved **iso-lightness** on each side: one L\*, maximum in-gamut
chroma at that L\* for every angle. Iso-lightness is the point of the whole exercise — equal contrast
BY CONSTRUCTION, so no role can out-shout another by accident, and hue is left doing the only thing
it is good at, which is naming which state this is.

- **Light** — solved on the DEEPEST project bed rather than the bare cream, because that is the
  worst ground a git run ever stands on: L\* 37.75, every entry ≥ 6.02 there and ≈6.77 on the plain
  cream, which is `Text.secondary`'s own level (6.24 / 6.99). A count is now never quieter than the
  branch name beside it, and its hue and weight put it above.
- **Dark** — solved on the glass face `#22212C`, the one dark surface in this app (the selected
  row's compact island): L\* 63.0, every entry ≥ 5.52, a clear step over the dark quiet rung's 4.51.

Closest pair 32 ΔE76 light / 41 dark. `notice` exists as its own role precisely so `?untracked`
stops being a second spelling of `warn`, and `info` moved from the accent to a true blue — the
accent means SELECTION here, and a run wearing it read as one.

`Slate.Chroma` is deleted whole (`orange` / `purple` / `blue` / `magenta`). Only the git line ever
drew from it, and a second unstructured palette sitting beside the status vocabulary offered
nothing but a way to collide with it by accident — which is exactly what happened. Anything genuinely
outside the status vocabulary should earn a named token rather than take a system hue out of a drawer.

Two things deliberately NOT done. The mark's geometry is untouched: `StatusDot`'s 14 pt footprint
and 10 pt ring are a transcription of otty's artwork with a magnified render pinning them, and the
ink change already buys 3.3× (1.82 → 6.04 on the bed) — spending the area channel on top of that
would overshoot, and area is still there if the ink alone is not enough. And the island alert chip
keeps the system hues: its tint is a FILL, and its subtree does not flip `colorScheme`, so a
dynamic light/dark pair would resolve its LIGHT half onto dark glass — the same trap that made
those chips invisible on `d00d4e8c`.

The weight ladder's rationale is restated rather than changed. It claimed the extra bold rung on
`~conflicted` was correcting a ranking hue got backwards (a mid-tone red pulling less eye than a
bright yellow) — true when measured on the dark sidebar this chrome replaced, false on the cream,
and impossible under an iso-lightness set. The rung stays, for the reason that actually holds: one
of the seven states is the one that stops work, said in a channel free of the palette, which also
survives the protanopia collapse `+` and `~` have.

Verified by pixel, not by argument: `testRenderStatusInk` → `status-ink.png` draws all six roles on
all three grounds (the dark block is the only place in the suite that flips `colorScheme`, so that
half could otherwise drift green). The render's grounds sample to `(255,251,235)`, `(241,237,236)`
and `(34,33,44)`, all eighteen inks land exactly on the solved hexes, and the measured contrasts are
6.75–6.81 / 6.02–6.07 / 5.52–5.55 — iso to within 0.05. `project-beds.png` confirms the git line now
carries six distinct inks with zero pixels of any system hue left.

## The island comes back to the frame's own corner, 26 → 16 (2026-08-10, user-directed)

`Slate.Metric.islandRadius` is now 16 — equal to `windowRadius`, by intent. The glass and the window
holding it speak one corner, and the island stops being rounder than its own frame.

Settled on a BOARD, not on an argument. 26 / 21 / 16 were rendered at the reference 1280 × 800
(`.defaultSize`) from this token layer — real ground, real glass, real `Terminal.edge` rim, real moat
of 8 and `bandInset` of 8, the frame clipped to its own 16 — at `ImageRenderer` scale 2, then read at
1:1 alongside a three-abreast crop of the top-left corner. At 26 the arc begins before the eye
reaches the edge and an ~880 × 775pt canvas reads soft.

What the 2026-08-08 round got wrong was not the SCALE but the SOURCE. 26 is what Tahoe measures on a
window carrying a `.unified` toolbar; the island carries no chrome at all. Spending the top of the
system's scale on the one surface with the least chrome to wrap around it is what read as
over-rounded. The island is still a window-scale surface — it now wears THIS window's corner rather
than a bigger window's.

Apple's macOS 26 guidance publishes no radius table, and that is deliberate: the new design system
gives three shape RELATIONS — fixed, capsule (radius = half the height), and concentric
(`inner = outer − padding`) — expressed as `ConcentricRectangle` / `.rect(corner: .containerConcentric)`
in SwiftUI and `borderShape` / `NSGlassEffectView.cornerRadius` in AppKit, with window radius
explicitly varying by titlebar style (larger with a toolbar, scaling to it; smaller titlebar-only).
Numbers exist only in the design-resource kits or by measurement. Strict concentricity would put this
island at 16 − 8 = 8, the number the first two rounds already rejected as boxy; the 2026-08-08
observation that the two corners are never seen together (centre column, ~230pt clear of the frame's)
is why 8 is not owed. It never licensed going PAST the frame, which is the one direction the relation
forbids.

Reach is one token: `SlateOverlayCard` and the whole floating family keep `radiusPanel` (12) — they
were briefly re-pointed at `islandRadius` in the 26 round and pointed back — and selection keeps
`islandRadiusCompact` (10). History: 8 → 14 → 26 → 16. Supersedes "The island takes a window's corner"
above, in the radius only; the compact-island half of that entry stands.

## Sidebar projects sort A→Z (2026-08-10, user-directed)

Section order in the navigator was first-appearance in `session.tabs` — a project's slot was a fact
about WHEN you happened to open it, so the list read as unordered and moved for reasons the user had
no reason to model. Sections now sort alphabetically; rows inside a section still follow creation
order (`tabOrder` then pane pre-order), which is the one place chronology is the honest answer.

The sort lives in `TabOrderingEngine.bucketedByProject` — the bucketing primitive itself, not in
`RailRowsBuilder.sectionedByProject` — because three surfaces read it and they must agree: the
navigator column, the horizontal `WorkspaceTabStrip`, and, at TAB granularity, the close rule
(`projectGroupedTabOrder` → `successorAfterClose`) plus the ⌘1…⌘9 numbering
(`displayOrderedPaneIDs`). "Focus the neighbouring tab" and "the third row down" have to mean
adjacent/third ON SCREEN; sorting one reading and not the other is precisely how focus lands
somewhere the sidebar never drew.

Ordering is on the DISPLAYED header (`projectSectionHeader`, the key's basename), not the whole key:
`/w/zeta/alpha` reads "alpha" in the sidebar and belongs under A. `localizedStandardCompare` — the
Finder's comparison, case- and diacritic-insensitive, digit runs read as numbers (`app2` before
`app10`). The KEY breaks a header tie, which makes the comparator a TOTAL order (`sorted(by:)` is not
documented stable, and two same-basename worktrees would otherwise shuffle between renders) and
happens to be the order their parent-qualified headers read in — `headerDisambiguated` runs after the
sort, so colliding worktrees stay adjacent under their shared basename instead of scattering to
wherever their parent folders fall in the alphabet.

The keyless "Other" bucket sorts LAST rather than under O: it is the absence of a name, not a name.
Supersedes the "always creation order" half of the 2026-07-10 grouping entry; the rest of it — no
sort UI, no recency, no manual drag-reorder, host-pushed key — stands unchanged.

## The thinking mark becomes herdr's spinner, drawn (2026-08-10, user-directed)

Round 23 gave the working agent the PLATFORM's indeterminate indicator — otty's own answer, an
`NSProgressIndicator` scaled into the mark column. Replaced by `AgentSpinner`, on the user's
instruction to take herdr's spinner but REDRAW it rather than type it.

**What herdr actually draws.** One terminal cell of braille, advanced one frame per 8 ticks of a
60 Hz loop (`ui.rs: SPINNERS` / `spinner_frame`). ⚠️ It ships TWO sets and the mark went to the wrong
one twice. `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` is three LIT dots walking the perimeter of an otherwise empty cell; the set
the user was pointing at is `⣾⣽⣻⢿⡿⣟⣯⣷`, which is the INVERSE — every frame is `0xFF` with exactly
one bit cleared, so the cell is fully lit and a single dark HOLE steps round it. Decoded bit by bit
the hole runs dots 1·2·3·7 then 8·6·5·4 — down the left column, up the right, anticlockwise — one lap
per eight frames (`8 × 8/60` ≈ 1.07 s).

**⚠️ Both of those transcribed facts were then overruled on hardware, and both corrections point the
same way: a spinner is judged by EYE, not derived from a bitmask.** The direction is REVERSED — the
hole now runs down the RIGHT column and up the LEFT, clockwise, the way every other spinner on the
machine turns; a mark running against that reads as wrong before it reads as anything. And the tempo
is SLOWER: `8 × 8/60` is herdr's loop rate, not a design decision, and as the ONLY tempo it read as a
hurry. The band it was replaced by — herdr's 1.07 s as the QUICK END, out to 2.6 s — is unchanged and
still `StatusDot.lapPeriodRange`; what changed twice is HOW a mark moves through it. First each mount
ROLLED one lap time from it and held it for life (an experiment: a spread of tempos judged at once).
⚠️ **That roll is SUPERSEDED by the wander below** — a rolled tempo is still a constant tempo, just a
different one per pane.

**⚠️ The tempo WANDERS as the mark runs (2026-08-10, user-directed, second cut).** *"Let the speed be
random AS IT RUNS — sometimes quick, sometimes slow, like it is really thinking, not turning evenly."*
A wheel at a constant rate reports that something is SWITCHED ON; the thing this mark reports is an
agent THINKING, and thinking is not evenly paced. So the spread that used to be spent across panes is
now spent inside every mark: the speed drifts over the whole band, hurrying and dwelling, and never
sits at either end.

- **It is a function of the CLOCK, integrated in closed form** — `AgentSpinner.rate(at:seed:)` is a
  sine sum on the SPEED, `phase(at:seed:)` is its integral (sine on speed ⇒ cosine on position). ⚠️
  Not accumulated frame by frame: `phase += rate × Δt` would depend on when the view mounted and on
  which frames it was drawn on, so two panes showing one agent would drift apart and a scrolled-away
  row would come back holding a stale position. Analytic integration is what keeps the wall clock
  load-bearing, which is the property this mark has had since it was drawn.
- **`StatusDot.tempoWanders` — three swells, shares summing to EXACTLY 1.** That sum is the safety
  argument: the speed touches the slow end and turns back, so the mark can dwell but can never stall
  or reverse (a spinner that runs backwards reads as a bug, not as a pause). ⚠️ The periods are in
  non-integer ratios on purpose — swells that divide each other resynchronise, and a rhythm you can
  count is the mechanism being designed away. *(Retuned by the third cut below; it shipped as
  13.1 / 5.9 / 2.7 s at 0.5 / 0.3 / 0.2.)*
- **The wander is symmetric in RATE, not in period** — speed is laps per second and the period is its
  reciprocal, so an even-looking swing in seconds-per-lap would spend far longer crawling than
  hurrying. The consequence is the one real change to how FAST the mark looks: the mean lap is the
  harmonic middle of the two ends rather than the 1.8 s that shipped as the single settled tempo.
  `StatusDot.lapPeriod` is that middle, derived — it is still what every still, every test and every
  frozen mark is drawn at.
- **Each mount still rolls ONE number, but it is an OFFSET into the shared wander, not a tempo**
  (`StatusDot.tempoSeedSpan`). Every mark now has the same average speed and the same law; without the
  offset a whole rail would hurry and dwell in lockstep, which reads as the application hitching
  rather than as agents thinking. Unison stays broken, deliberately, and for a different reason than
  the roll broke it.
- Pinned in `TabBadgePresentationTests`: the rate never leaves `[slowRate, quickRate]` over 10 min,
  the phase differenced at 120 Hz equals the rate (the two are written separately — a sign slip would
  leave a mark turning smoothly at the WRONG times, which no still can show) and always advances, the
  band is covered inside 30 s while the long-run mean is the middle, two seeds are out of step, and
  the phase is still pure in the clock and non-negative before the epoch. `SlateSnapshotRender` gains
  a second filmstrip sampled at EQUAL wall-clock steps (250 ms) beside the per-lap one: read as
  SPACING, not shape — even steps there would mean the wander has been flattened back to a constant.

**⚠️ The wander is SQUARED and the slow end widens to 3.2 s (2026-08-11, user-directed, third cut).**
*"The speed is random now, but the difference is not noticeable — how do I make it clearly read as
sometimes fast, sometimes slow?"*
The second cut was true and illegible, and the two are not the same claim. Measured before touching
anything, the shipped wander said why on both counts:

| | shipped | now |
| --- | --- | --- |
| lap p25 / p50 / p75 | 1.33 / 1.51 / 1.76 s | 1.31 / 1.60 / 2.04 s |
| time spent near an end (\|wander\| > ⅔) | 13% | 23% |
| contrast visible inside any 4 s (median) | 1.47× | 2.12× |
| median handover, slow end → quick end | 5.97 s | 1.75 s |

- **The handover was the real defect, not the band.** 2.44× is a wide band; the mark never showed it.
  A sum of sines is bell-distributed, so it sat in the middle almost always — but the killer is that
  the 13.1 s fundamental took ~6 s to cross, and the eye RENORMALISES a ramp that slow into "the
  current speed". Speed perception needs a transition short enough to catch or two states held long
  enough to compare, and a six-second glide is neither: the mark was never seen to change, only to be.
- **Squaring, without leaving the sine basis.** The long swell is spent on its ODD HARMONICS —
  `sin θ + sin 3θ/3 + sin 5θ/5` at periods P, P/3, P/5 (`TempoWander.squared`). Every term is still a
  plain sine, so `phase(at:seed:)` stays the closed-form integral that makes the wall clock
  load-bearing; nothing about `rate`/`phase` changed. ⚠️ `tanh`-style soft clipping would shape it
  better and has no closed-form integral — that is why this route and not that one.
- **The safety proof survives verbatim, one level up.** That partial sum peaks at EXACTLY 14/15 (at
  θ = 5π/6 the terms read ½, ⅓, ¹⁄₁₀), so a squared swell's fundamental is scaled by 15/14 and the
  swell still tops out at its declared share. `tempoWanders` = 0.56 (squared, 7.9 s) + 0.31 (4.3 s) +
  0.13 (1.9 s) = 1.00 exactly. ⚠️ The FLATTENED `tempoSwells` shares sum to 1.36 and prove nothing —
  the bound is read off the declared swells, and the test says so.
- **`slowestLapPeriod` 2.6 → 3.2.** The 2.6 judged the day before was the floor for a tempo the mark
  might sit at INDEFINITELY; a shaped wander only dwells there a second or two, which is a different
  question. Shaping alone got 1.47× → 1.85×; this end takes it to 2.12×. The quick end stays herdr's
  own 1.067 s. The mean lap moves 1.51 → 1.60 s — nearly free, because the mean is taken in rate.
- **What it cost, stated because it is the thing the non-integer periods exist to prevent:** the flips
  are MORE REGULAR — the gap between direction changes spanned 0.6–7.3 s (p10–p90) and now spans
  1.5–4.4 s. The two shorter swells carry 44% of the swing, up from a 0.5 dominant, precisely to keep
  the crossings off a grid. Squaring buys legibility partly out of the irregularity budget; cut those
  swells further to sharpen the handover and the mark reads as a metronome.
- Pinned by `testTheWanderIsSeenToChangeSpeedAndNotJustToHaveOne`: ≥55% of the time away from the
  middle third, and a median handover under 2.6 s. ⚠️ This is the assertion that fails first if anyone
  flattens the squared swell back to a plain sine because the maths is simpler — covering the band,
  which the old one did to 99%, is exactly the guarantee that turned out not to be worth anything.

**⚠️ TWO cuts were rejected on sight, both from the wrong set.** The first read the frames as an ARC
ON A CIRCLE (at six samples they are geometrically close) and drew a comet on the resting ring's own
circle — *"not this indicator — the one with the dots in a line going round a rectangle"*. The
silhouette is the recognisable thing about the artwork; a turning arc is the spinner every
application already has, so transcribing the geometry and discarding the shape transcribed the wrong
half. The second cut took that correction literally and walked three dots round a rounded rectangle —
still the empty-track set. The mark is a FILLED BLOCK WITH A HOLE IN IT, not a line of dots on a
track.

**The shape.** A 2 × 4 braille cell, all eight dots lit in the ink, one of them dark and travelling.
Dots Ø2.6 on a 4.4 × 3.4 pitch, centred in the 14pt mark footprint — wider across than down, as a
real cell is, so the two columns stay legible as columns while the four rows read as one run. What
the redraw buys over the typed frames is the ONE lie in the original: the hole no longer teleports
between eight discrete dots, it GLIDES. Each dot's ink is linear in its circular distance from the
hole's continuous position and clamped at one step, so with the hole half a step along, the two dots
it lies between are half-dark each and the darkness slides at whatever rate the display can draw.
The hole floor is ZERO — braille has no half-lit dot, and a gap that is merely dimmer is not a gap.

**The ink is herdr's own YELLOW** (`StatusInk.warn`), user-directed after seeing both on hardware.
`info` blue shipped first, on the argument that the attention ramp (amber question / green finish /
red failure) all means *come here* while a thinking agent means the opposite — and it simply did not
carry across the rail. ⚠️ That puts the working mark on the SAME hue as the waiting question. What
keeps them apart is silhouette and motion, not colour: a question is a still HAND, a thinking agent
is a lit BLOCK with a hole running round it. A third yellow reading in this column is the collision
to watch for. The
accent was rejected on the same pass (the compact glyph used to wear it): in this app the accent
means SELECTION, so a purple mark on an unselected row reads as a row half-selecting itself.

**One working mark, everywhere.** `StatusGlyph`'s `working` reading — the typed pulse `· ✢ ✳ ✶ ✻ ✽`
that the iOS toolbar and the Peek & Reply header have spoken since MERIDIAN — now mounts the same
`AgentSpinner`, and `StatusPresentation.agentTint(.working)` takes `thinkingMark.ink` by reference
rather than spelling a second ink. One pane could previously be spinning in the sidebar and blooming
in the header at the same instant. `StatusGlyph`'s other three readings stay typed. The `\u{FE0E}`
variation-selector trap dies with the frames it guarded (it still applies to the title's `✳` marker).

Three properties are load-bearing, all pinned:
- **Phase comes off the WALL CLOCK from a fixed epoch**, not from an animation started at mount — so
  a re-render lands the hole mid-lap rather than snapping it back to the start, and at the tempo the
  wander is currently at rather than restarting the wander too (⚠️ rows walked in STEP as well until
  the tempo stopped being one shared number). `AgentSpinner.phase(at:seed:)` is pure and static; its
  pins are listed with the wander above. `AgentSpinner.lit(_:hole:)` and `BrailleCell` are
  pure too, and pinned as VALUES — exactly one dark dot at a time with every other at FULL ink, a
  half-step hole splitting evenly across the pair it lies between (including across the seam, or the
  lap would visibly stutter once per turn), the walk order down-RIGHT-then-up-LEFT (a sign slip there
  silently restores the rejected direction), a tempo band whose ends stay positive with the settled
  middle inside them, and the block centred in the footprint with its dots' radius inside it.
- **Pure SwiftUI**, so `ImageRenderer` can rasterize it — the platform indicator could not be
  rendered at all, which meant the one mark that moved was the one mark no test could look at.
  `SlateSnapshotRender` now lays one lap out flat as a phase-pinned filmstrip (`pinnedPhase`) at the
  EIGHT points the braille set itself has, so the strip can be read against `⣾⣽⣻⢿⡿⣟⣯⣷` directly, and
  `sidebar-section.png` gains a SELECTED working row so the mark is checked on the island's dark
  glass too — the ground where a light/dark pair can resolve on the wrong side.
- **Reduce Motion freezes it** — the platform used to own that call. A frozen cell is still a
  distinct silhouette (a lit block with one corner missing), so the state is never lost.

**The hole is TWO dots wide** (user-directed) — ⚠️ **REVERSED the same day, see the entry at the foot
of this file; the shipping width is ONE.** The argument here was that one dark dot in a cell of eight
is a small thing to notice at rail size, and this is where the mark stopped being a transcription of
`⣾⣽⣻⢿⡿⣟⣯⣷` and became a drawing — no frame of that set clears two bits. `StatusDot.holeWidth` carries
it and `AgentSpinner.lit(_:hole:)` is the only reader, so `1` restores the literal set. The width is
CONSERVED at every instant (pinned): parked between two dots the hole is exactly those two, fully
out, everything else at full ink; rolled onto a dot, that dot is out with half a dot's worth spilling
each side. A gap that gained and lost darkness as it travelled would read as a mark BREATHING, which
is another state's vocabulary in this column.

**The RESTING mark is recut in the same pass** (user-directed): the agent-presence ring was lucide
`circle-dashed`, stroked with an eight-segment 0.6-fill dash pattern, and is now eight round DOTS
standing further apart than those dashes did (`DottedRing`, Ø1.8 on the same Ø10 circle, ≈2.13 of air
between neighbours against the dashes' 1.57). A dash is a fragment of a line that happens to be
curved; a dot is its own shape, and at this size that is the difference between a ring that looks
BROKEN and a ring that looks MADE OF PARTS. The dots ride on the circle and spill half their width
outside it exactly as the stroke did, so the ring's visual diameter — matched by eye to a 12pt
`checkmark.circle.fill`, so a row that finishes does not change size — is unchanged. Ø1.8 also keeps
it under the thinking cell's Ø2.6: a PRESENT agent must never out-weigh a WORKING one, and size is
half of how the column says so. The gap is pinned as a value, because shrinking it turns the mark
quietly back into a dashed ring with short dashes.

**The FINISH mark goes to 13pt** (`StatusDot.finishSymbolSize`, user-directed 2026-08-10) — ⚠️ the
first place this column stops taking otty's own number (12). It was reported as reading SMALLER than
the resting ring, so it was MEASURED first, by rendering the shipping `StatusDotView` into a 16×
bitmap and taking the ink's bounding box: at 12pt the check was **12.12pt** across against the ring's
**11.88**, with **five times** the ink (105.6 pt² of disc against 20.1 pt² of eight Ø1.8 dots). It was
never the smaller mark — it read small because a ring of separate dots claims the air between them as
part of the object while a filled disc is only as big as itself. ⚠️ **So the fix is to what it READS
as, and that is only legitimate BECAUSE the measurement came first** — the same complaint about a mark
that measured genuinely small would have been a different bug with a different fix. 13pt puts it at
**13.12pt**, a point clear of the ring and still inside the 14pt box. Its one cost: the old promise
that a row does not change size when it finishes is now approximate rather than exact.

`WorkingSpinner` survives as what it now only is: the PLATFORM's generic "this control is waiting"
affordance (the Android device list's boot button), where matching every other spinner on the machine
is the point.

## The urgent pair recolours the row title, and attention outranks active in weight (2026-08-10, user-directed)

Rounds 9–10 retired the ink dialect on titles: every state renders as the same mark, only the HUE
names it, and the title keeps the neutral ladder with a `.medium` weight bump for attention (the
mail-unread idiom). That rule is now PARTLY reversed on the user's instruction, in the two places
where it cost the most.

**Hue, for the urgent pair only.** A BLOCKED agent (amber) and a FAILED command (red) wear the mark's
own ink across the whole title (`StatusPresentation.urgentInk`, derived from `attentionInk` so the two
cannot spell the hue differently). The argument that retired the dialect still holds for everything
else — but it was written when the loudest thing in the rail was an unread finish, and it put the news
that a run just broke into a 10 pt ring at the far right edge of a row whose title is the widest thing
on it. A FINISH deliberately stays neutral: green is the calm end of the ramp, and recolouring for it
would leave the urgent pair nothing louder to be. The mark column is unchanged — this adds a second
voice for two states, it does not take the state away from the marks.

**Weight, above the active card.** Attention steps to `StatusPresentation.attentionWeight`
(`.semibold`) instead of sharing the active row's `.medium`. Sharing one step meant a row that needs
you and a row you are standing on read identically; on one scale, "needs you" has to outrank "you are
here". Both rails spend it — the sidebar row and the split strip — but only the sidebar takes the hue:
the strip names the splits of the tab you are already inside, and its rows sit a line from the mark
that carries the colour.

## The status detector stops announcing things nobody did (2026-08-10, user-reported)

Three false edges, reported together, with three different causes. The comparison against herdr
(pin `83c7bde`, `scripts/herdr.pin`) is part of the finding: herdr does not have the first two
BY CONSTRUCTION, and it DOES have the third.

**Hovering an `AskUserQuestion` re-rang the blocked cue.** `PaneInputClassifier` read the X10/UTF-8
mouse report (`CSI M Cb Cx Cy`) as a keystroke: no private marker, a final byte the switch did not
know, and three raw position bytes riding BEHIND the final byte that then re-entered the scan as
text. libghostty encodes mouse in whatever scheme the program asked for, and motion reporting means
merely moving the pointer over the pane floods that path. `M` and `t` are now unconditionally
reports (no keyboard encoding produces either), and the X10 form's trailing bytes are consumed with
it.

**Arrowing between the options did too.** The unblock demoted a standing block on ANY keystroke,
and the still-visible dialog immediately re-raised it — one blocked→idle→blocked lap, and one cue,
per keypress. The signal is now CANCEL-ONLY (`containsCancelKeystroke`: Esc in every encoding —
bare `0x1B`, `ESC ESC`, and kitty's `CSI 27 u`, which is what Claude Code's own keyboard mode
actually sends — plus `Ctrl-C`). Nothing is lost: an Esc-cancel is the ONE resolution that fires no
hook; every other way out of a dialog re-promotes through `PreToolUse`/`PostToolUse`.
⚠️ herdr has no keystroke unblock path at all, which is exactly why it never flaps here — the flap
was ours, invented along with the feature.

**`/compact` announced a finished turn.** Claude Code ends a compaction the way it ends any turn,
with `Stop`, which minted `.done` and rang the finish cue for housekeeping the user ran themselves
and watched complete. `PreCompact` is now installed (reversing its old "no status meaning"
exclusion) and ARMS a one-shot marker: a `Stop` that arrives with it still armed lands on `.idle`,
and any turn activity in between disarms it, so an AUTOMATIC mid-turn compaction still ends on a
genuine `.done`.

⚠️ **That fix is only half a fix on its own, and the half that is easy to miss is the client's.**
`.working → .idle` is itself the hook-less COMPLETION edge (`AttentionEdge.isCompletion`, herdr's
rule for agents that have no Stop hook at all), so the client would have re-announced exactly what
the host just decided not to announce. The boundary therefore travels: the type-27 `kind` byte —
until now the notification class, meaningful only while blocked and `0` otherwise — gains `4 =
QUIET`, "display this, do not announce it". No new wire field, so no golden-vector change, and the
byte was already forward-tolerant on both ends, so an older peer reads `4` as a plain status and
behaves as before. `setAgentStatus(quiet:)` suppresses the FIRE only: the status commits, the dots
move, and the coalescing memory is still re-armed so the pane's next real finish notifies.

⚠️ **herdr shares the `/compact` symptom** — its `claude.toml` has no compaction rule, and its
Claude state is 100 % screen detection (`install_claude` explicitly REMOVES every state hook and
installs only `SessionStart → session`, an identity report), so a compaction there goes
Working → Idle → completion transition → done sound. There was no upstream fix to port; this is a
place where the port is now ahead of its source.

## A border that matches its own fill is not a border — `Terminal.rim` and `Line.overlayRim` (2026-08-10, user-reported)

Reported as "the terminal notices — copied N chars, tab closed — have no border tint, so they are hard
to read on a dark background". The cause was literal: `terminalEdge` and `terminalRaised` were the
SAME value (`glass.edge`, `#454158`), so `InstrumentChipShell` stroked its border in exactly the colour
it filled the plate with. Every chip on the glass had been drawing an invisible border.

**`Slate.Terminal.rim`** is the fix: the plate lifted HALFWAY toward the profile's comment ink
(`mix(glass.edge, glass.ink2)` → `#5F5880` on Dracula Pro), derived from the profile rather than picked,
so it follows every terminal theme instead of pinning one. The chip shells and the connection chip take
it; `edge` keeps its own job (the line BETWEEN things on the glass).

**`Slate.Line.overlayRim`** is the light-side twin, for the surfaces that COVER the workspace — the
notification/toast card and every summoned sheet. They were using the system separator (~1.25:1 on the
cream ground), which is right for a line inside a form and wrong for the only thing saying where a
floating object ends. It is polarity-INVERTING by construction (`slateDynamicLight: 0x000000, dark:
0xFFFFFF` at `Opacity.rim` 0.20), which is the rule the user stated: a light surface takes a dark rim,
a dark surface takes a light one.

## The thinking mark's hole goes back to ONE dot (2026-08-10, user-directed)

A same-day reversal of the two-dot hole recorded above. Two dark dots out of eight is a QUARTER of
the cell gone at once, and at rail size the block then reads as a cell that is broken rather than as
a lit cell with something travelling round it. The silhouette is half of what this mark says — the
column has to be readable as "thinking" at a glance without waiting for the motion — so a gap that
costs the silhouette is not paid for by being easier to spot.

`StatusDot.holeWidth = 1`. Nothing else changes: `AgentSpinner.lit(_:hole:)` is still the only
reader, the walk, the tempo wander and the wall-clock phase are untouched, and the width stays
CONSERVED (the pin loops over the whole lap). What flips is which frames are the whole-dot ones —
parked ON a dot it is that dot alone fully out with every other at full ink, and on the seam between
two the pair is half dark each, which is the mirror of how the two-dot hole parked.

⚠️ The mark is a TRANSCRIPTION again: every parked frame is one `⣾⣽⣻⢿⡿⣟⣯⣷` actually draws (`0xFF`
with exactly one bit cleared), so `SlateSnapshotRender`'s eight-phase filmstrip can once more be read
straight against that set — which is what it always claimed to be for.

## The detector stops reading half-painted frames (2026-08-11, user-reported)

**Report.** With an `AskUserQuestion` on screen, Tab-switching between the questions walked the pane's
mark `idle → blocked → idle → blocked`, one lap per press. Same *shape* as the three false edges of
2026-08-10 (the hover, the arrow keys, the `/compact` finish) and a completely different cause: those
were ours, invented with a feature; this one is the screen engine reading a grid the program had
explicitly told it not to read yet.

**Evidence, not inference.** A real session was recovered from the scrollback JOURNAL
(`~/Library/Application Support/SlopDesk/scrollback/<uuid>.scrollback` — raw PTY bytes, so every frame
Claude Code painted is still there) and replayed through the actual `PaneScreenScanner` +
`ClaudePaneDetector`. 54 KB, 344 synchronized-update frames, 14 Tab repaints. Sweeping the PTY chunk
size from 256 B to 8 KiB: **7 blocked → idle → blocked laps** at the worst size, **0** after the fix.

**The chain.**
1. Claude Code wraps every repaint in a synchronized update (`CSI ? 2026 h … CSI ? 2026 l`) and
   ERASES each line (`CSI K`) before rewriting it. Mode 2026 is the program saying *this grid is
   inconsistent until I close the frame*.
2. `PaneScreenScanner` fed `TerminalScreenModel` whatever the PTY read loop had handed over and read
   the grid immediately. `TerminalScreenModel` does not implement 2026 at all, and
   `SyncUpdateFrameCollapser` — which does understand it — is wired only into the scrollback REPLAY
   transform, never the detection path. So a chunk boundary inside a repaint = a torn read.
3. Torn, the dialog has no footer, so `live_blocked_form` (980, region `after_last_horizontal_rule`)
   stops matching.
4. ⚠️ The next rule down is `live_prompt_box` (950) — and it MATCHES a dialog. The dialog's focused
   option renders `❯ 1. …`, satisfying `^\s*❯`, while every needle that would veto it
   (`enter to select`, `esc to cancel`, `tab/arrow keys`) sits BELOW the last horizontal rule, i.e.
   OUTSIDE `prompt_box_body`. Verdict: `idle` + **`visible_idle`**.
5. `visible_idle` is the one screen verdict strong enough to clear even an authoritative HOOK block
   (`ClaudeStatusMachine.applyScreen`, past the 1 s paint grace). So a single bad read unblocked a
   pane that a `PreToolUse(AskUserQuestion)` hook had blocked.
6. And `needsPermission → idle` is herdr's hook-less COMPLETION edge — `AttentionEdge.isCompletion`
   AND `MuxChannelSession.isCompletionTransition`. So every lap did not merely churn the mark: it
   **minted a finished turn**, bumping `_completionEpoch` for every attached client, badge and sound
   included. Announcing something nobody did, again, by a new route.

**Fix, two guards, neither of them herdr's.**

- **Never read a grid the program has not finished painting.** `AgentSyncFrameTracker` is a
  byte-at-a-time DECSET/DECRST 2026 parser — byte-at-a-time because an opener SPLIT across two PTY
  reads is exactly the case that tears the grid, and a whole-buffer scanner is blind to it. String
  bodies are skipped opaquely (an OSC title spelling `?2026h` opens nothing), `ESC c` closes,
  parameters are bounded. `PaneScreenScanner` feeds it precisely what it feeds the model, and while a
  frame is open it publishes NOTHING and rechecks at 100 ms. Deferring is free: the model is
  cumulative, so the next scan sees a whole frame, and the last verdict stands meanwhile — a repaint
  changes what is on screen, not what the agent is doing. Bounded by `syncFrameHoldCap` (1 s) so a
  program that dies mid-paint defers detection rather than freezing it. The frame-granularity sibling
  of `awaitingRepaintAfterRebuild`.
- **Leaving a block takes three reads.** `AgentDetectionHold.shouldHoldBlockedToIdle` mirrors the
  ported working→idle hold with its OWN counters (upstream's stays byte-identical). ⚠️ Deliberately
  STRICTER than its sibling: a VISIBLE idle does not bypass it, because the visible idle is the false
  verdict. Costs ≤ ~300 ms on a genuine unblock, and the one unblock with no other announcement — an
  Esc-cancelled dialog — never comes through here at all (`PaneInputClassifier.containsCancelKeystroke`
  → `ClaudeSignal.userInput` is instant).

**Deliberately NOT fixed: the manifest.** `live_prompt_box` claiming a modal is a genuine modelling
error and a `not` guard on `^\s*❯\s+\d+\.` would kill it — but the bundled manifests are a 1:1 herdr
port whose `matched_rule` / `visible_idle` / `not_count` are diffed against upstream by
`scripts/herdr-differential.py`, so the edit buys defence-in-depth at the cost of the parity harness.
Unreachable behind both guards; recorded here so the next person finds the reasoning rather than the
rule. **↯ SUPERSEDED the same day** — the user released parity and the rule was fixed properly, with
a cross-region gate rather than the `^\s*❯\s+\d+\.` guard sketched here (that one alone would veto a
human typing `1. foo`). See "herdr parity stops being the ceiling" below.

## Two tiers: the agent's word outranks our reading of its screen (2026-08-11, user-directed)

**Report.** "Không chỉ blocked status, mà cần nghĩ lại toàn bộ architecture … để kết hợp giữa hook
và tty parse để làm sao cho tốt nhất." The morning's fix stopped the detector reading half-painted
frames; this is the round that stopped the question being decidable by a screen read at all.

The full contract now lives in **`docs/50-agent-detection-architecture.md`** — read that before
touching detection. What follows is why it looks like that.

**The category error.** The machine had a precedence list, which answers *who wins a collision*. It
never answered *should this signal be in the argument*. The screen engine is a heuristic reading of
pixels an agent drew FOR A HUMAN — a good one, a verified herdr port, but herdr has no hook feed, so
for herdr every heuristic must be load-bearing. Ours does not have to be. `PreToolUse
(AskUserQuestion)` is not evidence about the pane's state; it IS the pane's state. Ranking a rule
ladder above it was the mistake, and both the morning's flap and the false finished turns were
downstream of it.

**Tiers, keyed on the FEED and never on the agent's name.** Tier 1 is the agent describing itself;
tier 2 is us inferring from what it drew. Under coverage tier 2 may corroborate and nothing else.
⚠️ The load-bearing detail is what confers coverage: the Claude hook socket, AND the ctl `report`
verb — which any process in any pane can call. So a codex / gemini / bespoke wrapper that reports
its own state is first-class on the same code path, with no per-agent branch anywhere in the
machine. Keying this on `AgentKind` would have made "support another agent" a code change; keying
it on the feed makes it a one-line wrapper.

**Coverage is not a recency window.** A pane blocked on a question for ten minutes emits no traffic,
and that silence is the block working as intended. Timing out on it would have reinstated the same
bug at a ten-minute period. Coverage runs from a session's first authoritative event to its end.

**The watchdog, asymmetric.** Hooks are best-effort, so the screen keeps a stopwatch on UNBROKEN
disagreement — one agreeing read resets it, which is precisely why a repaint (blocked, blocked,
torn, blocked) can never accumulate. 3 s to RAISE an unannounced block (a human waiting is the
expensive failure), 10 s to release one. Nothing correct waits on that 10 s: every legitimate way
out of a block — answered, approved, denied, finished, Esc-cancelled, exited — announces itself on
tier 1 in the same millisecond. The window exists only for the case where the feed itself stopped
being true, and what it produces is marked as a correction, not an event.

**A block is a LEDGER, not a flag.** Claude Code emits tool calls in BATCHES. An assistant turn
carrying `[AskUserQuestion, Bash]` fires both `PreToolUse` hooks, and Bash's result then cleared the
block — handing the pane back to a human who was still being asked something, and minting a finished
turn on the way out. Entries are keyed by `tool_use_id`; a question is resolved only by its OWN
`PostToolUse`. A permission entry keeps the looser rule (any `PreToolUse` clears it — a permission
dialog is modal, and that is what covers a DENIED permission, the one resolution Claude Code
announces with no hook of its own).

⚠️ `HookParser` mints a UUID when `tool_use_id` is absent — a DIFFERENT one per event. Carried
through as identity it would make a call unresolvable forever, so `ToolUseBlock` now records
`idIsFromPayload` and the adapter passes `stableID`; nil degrades to the id-less rule.

**Two bugs found while building it, neither reported.** A mid-block hook that was not itself a block
— a sibling call's `PostToolUse`, an `auth_success` — overwrote the standing block's wire `kind`,
shipping a type-27 that said the block had changed class when nothing had changed; with the ledger
holding panes blocked through exactly that traffic it would have become the common case
(`ClaudePaneDetector.blockKind`). And the host's `_completionEpoch` never consulted the quiet byte
the client already honoured, so every `/compact` and every dismissed dialog still minted an unread
finish for every attached client.

**Esc is now quiet.** Dismissing a dialog is not a finished turn — but `needsPermission → idle` is
the hook-less completion shape, so pressing Esc rang a banner, a sound and an unread badge at the
person who had just pressed it, about a pane they were looking at. Third member of the quiet family
after the `/compact` boundary and the watchdog correction.

**Kept deliberately.** The 1 s paint grace and the blocked→idle confirmation hold stay, unreachable
under coverage — a hook-free pane has no tier 1, and for that pane they ARE the protection. The
`live_prompt_box` manifest gap stayed unfixed for one more round, for herdr parity — see the next
entry, where that constraint was lifted.

## herdr parity stops being the ceiling — cross-region gates (2026-08-11, user-directed)

✅ **Decided.** "không cần parity với herdr nữa, cứ làm thế nào ngon hơn herdr là được." The screen
engine has been a 1:1 port since it landed, and twice today a real bug was left standing because
fixing the rule would cost the differential harness. That trade is now off.

**The bug the port carried.** `live_prompt_box` has five `not` needles naming a modal dialog's
footer — `enter to select`, `esc to cancel`, `tab/arrow keys`, … — and **not one of them can ever
match**. A `not` gate is evaluated against the rule's own region, which here is `prompt_box_body`;
a dialog's footer sits below the LAST horizontal rule, outside that region by construction. So the
veto never saw what it was written to stop, while the dialog's focused option `❯ 1. …` satisfied
the rule's `^\s*❯` caret. An `AskUserQuestion` on screen therefore read as an idle prompt box with
`visible_idle` — the strongest idle the engine can produce — for a pane blocked on a human. Dead
code that looked like a safeguard is worse than no safeguard.

**The fix is a capability, not a patch.** A nested gate may now carry its own `region`
(`AgentManifest.Gate.region` → `CompiledGate.region` → `ManifestRuleEngine.matches`), overriding
the rule's for that gate alone. herdr has no syntax for this. `live_prompt_box`'s veto now reads
`after_last_horizontal_rule` — exactly `live_blocked_form`'s region — so the two rules became
strict complements: if a live form footer is on screen, the prompt box cannot fire, whatever the
caret above it looks like.

**Two vetoes, because they fail in different places.** The cross-region one covers a WHOLE dialog.
A TORN one has no footer in any region — the repaint erases before it rewrites — so a second veto
reads the option LIST, which survives because it is what the caret sits in: `❯ 1. …` **with** a
sibling `  2. …`. Requiring the sibling is what keeps a human typing `1. foo` at a real prompt from
being vetoed, and even then the cost is only `visible_idle`.

**The harness now names its exceptions.** `scripts/herdr-differential.py` grew `DIVERGED_LABELS`,
today `{"claude"}`: excluded as a target, still seeding the corpus, with the reason written above
the set. The other eighteen agents stay pinned — 10 301 cases, PARITY OK. A parity harness whose
exclusions are undocumented is worth nothing, so adding a label needs a reason there and a test
pinning what the divergence buys (`ManifestCrossRegionGateTests`).

**What this changes about the tiers.** Nothing — the two-tier machine already made the torn read
unreachable for a hook-covered pane. This fixes the pane that has no hooks at all, where the screen
IS the answer. Defence in depth means each layer being right on its own, not one layer covering for
another's known-wrong verdict. → [50 §9]

## A pane belongs to one session, and a call can end without a result (2026-08-11, audit)

✅ **Decided.** Two more holes found by auditing the hook feed against the SHIPPED CLI (2.1.227)
rather than against our own model of it. Both were reachable, both were proved with a failing test
before anything was changed.

**1. The relay routes by an ENVIRONMENT VARIABLE.** `SLOPDESK_PANE_ID` is inherited by every
descendant of the pane's shell, so a `claude -p …` — from a script, a Makefile, or the pane agent's
own Bash tool — posts its whole hook set to the pane that spawned it. With no gate its
`SessionStart` cleared the pane agent's block, its `Stop` minted a finished turn for a turn that
never finished, its `SessionEnd` blanked the pane and armed the post-exit lockout, and its prompt
re-titled the session. The pane's real agent was waiting on a human throughout.

Fixed with ownership: the first id-carrying event claims the pane, a foreign session is dropped
whole, an unattributed event always applies and never claims. `session_id` rides the hook envelope
rather than the tool, so `HookParser.sessionID(_:)` reads it off the raw body and
`ClaudeHookEvent.attributed(to:)` stamps it in before the fold — the payload cases that model a
CALL never carried it, and those are exactly the events a nested run would have used.

**Safe for `/clear` and `/resume` for one verified reason:** `clearConversation` AWAITS the
`SessionEnd` hook (`reason: "clear"`) before doing anything else; `/resume` does the same. A
replacement says goodbye because it had the pane; a nested run never does, because it never had it.
Released, besides that, by presence absence and by the dissent watchdog — the watchdog is what
recovers a pane whose agent died without a `SessionEnd` and was replaced inside one presence poll.
NOT released on a timer: a nested run can hold the terminal for minutes while the owner is silent
(its `PostToolUse` cannot arrive until the nested claude exits), so any useful window is also short
enough to hand the pane to the process this exists to ignore.

**2. `PostToolUseFailure` is emitted INSTEAD of `PostToolUse`.** It is invoked from the tool loop's
`catch` and carries the same `tool_use_id`. We neither installed nor parsed it. Because an `.ask`
ledger entry is deliberately immune to any OTHER call's `PreToolUse`, a failed or interrupted
`AskUserQuestion` had nothing that could resolve it: the hand stayed up over a vanished dialog for
the rest of the turn. `PermissionDenied` was the same shape of miss, one degree less severe — the
next `PreToolUse` did clear the block on the reasoning that a permission dialog is modal, which is
an inference standing in for an announcement that exists. Both are now in
`AgentInstaller.installedEvents` and both map to the same "this call is over" resolution.

**3. `Elicitation` / `ElicitationResult`** — an MCP server asking the human — were reachable only
by classifying a `Notification` message as `elicitation_dialog`. Same block, same ledger, now
keyed on `elicitation_id`: a different id namespace doing the same job.

**The lesson worth keeping.** A hook we do not register cannot be a signal, and a hook we register
but do not parse is a silent drop — so the two lists are now diffed against the CLI's own emitters,
not against memory. Auditing that way is what found both of these. → [50 §5, §5b]
