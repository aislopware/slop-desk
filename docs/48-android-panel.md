# 48 — Android panel (the second foreign wire, and the one relay that is not optional)

The right panel's **Android** tab mirrors one of the host's Android devices — emulator or a phone on
the desk — and drives it: frames down, touches and keys up. Drawn **natively** (SwiftUI +
`AVSampleBufferDisplayLayer`), like the Simulators tab and for the same reasons.

Everything below the fold is **measured**, not read from a spec. `scrcpy` publishes no wire
document — its own documentation says the control protocol is defined by the unit tests on both
sides — so the dialect was transcribed from `control_msg.c` / `demuxer.c` / `server.c` at **v4.1**
and recorded off a live emulator on 2026-08-04. The byte-level claims here are what
`Tests/SlopDeskDevicePanelsTests/Android*Tests.swift` and `rust/slopdesk-androidd`'s own suite pin. If the
Homebrew formula moves, re-measure before changing the decoder.

Read this before touching anything under `Sources/SlopDeskPhoneUI/Panel/Android` or
`rust/slopdesk-androidd`.

> **2026-08-12 — the bridge left hostd.** It is `rust/slopdesk-androidd` now, a separate binary held
> by superd, and the Swift original (`AndroidBridgeServer`, `AndroidToolchain`, `AndroidScrcpySession`,
> `AndroidDeviceCatalog`, `AndroidEmulatorConsole`, `AndroidSocketIO`, `AndroidBridgeManager`) was
> DELETED in the same change — there is no fallback and no mirror. **Nothing about the wire changed**:
> the client already dialled the bridge port directly, so the panel, the reassembler and the control
> encoder are untouched. What changed is which process pumps the H.264, and what a `make host-restart`
> costs. Sections below that still read "inside hostd" have been rewritten; the measurements are the
> same ones, taken against the same dialect.

---

## Shape

```
client (SlopDeskClientUI/Android)                       host
──────────────────────────────────────────────────────────────────────────────────
metadata verb 22  ensureAndroidBridge   ────────────►   HostAndroidPerformer   (hostd)
                  [state][UInt16 BE port] ◄──────────   AndroidServiceManager
                                                              │ spawn-or-adopt via superd
                                                        slopdesk-androidd  ── adb ──► device
                                                              ▲
one TCP connection per operation, DIRECT to androidd ─────────┘ (hostd is not in this path):
  {"op":"list"}\n            ──► {"ok":true,"devices":[…]}\n              (then close)
  {"op":"boot","avd":…}\n    ──► {"ok":true}\n
  {"op":"shutdown",…}\n      ──► {"ok":true}\n
  {"op":"console",…}\n       ──► {"ok":true,"output":"…"}\n
  {"op":"screenshot",…}\n    ──► {"ok":true,"bytes":N}\n  + N raw PNG bytes
  {"op":"logcat",…}\n        ──► {"ok":true}\n            + logcat text, forever
  {"op":"open","serial":…}\n ──► {"ok":true,"device":…}\n + scrcpy video down / control up
```

### Why the bridge exists at all — and why it is its own process

`adb forward` binds **127.0.0.1 only**. A mesh client therefore cannot reach the device socket
without something host-side to relay it. That is the bridge's whole job.

`adb -a server -H 0.0.0.0` was considered and **rejected**: it is a machine-wide change to the user's
`adb` and it hands every mesh peer a device shell.

Unlike verb 21's `baguette serve` there is no third-party SERVER to spawn — the panel speaks
`scrcpy-server`'s protocol itself — but the relay is still a child, and for the reasons the file-drop
service moved (`docs/53`):

- **hostd owns every keystroke.** A mirror is a few megabits a second pumped on threads competing
  with the terminal wire, for a surface most sessions never open.
- **A host restart took every mirror with it.** `make host-restart` is a ~0.2 s hiccup for panes,
  which superd holds. The bridge, being in-process, died with the daemon and each mirror had to
  re-push the jar, re-forward, re-handshake and re-key. It is a superd pane now (`service:androidd`),
  so a rebuild costs the mirror nothing.
- **Blast radius.** The bridge is the one part that ran on raw BSD sockets, and it is the part that
  talks to whatever `adb` and the device do next. See the `SIGPIPE` section below for what that used
  to be able to do to a terminal session.

So `AndroidServiceManager` is shaped like `SimulatorServerManager` rather than like the old in-process
one: it spawns-or-adopts through superd, learns the port from the daemon's own announce line
(`androidd: listening on 0.0.0.0:<port> …`, replayed from offset 0 of the pane's ring), probes it
once, and reports `starting` until then. `ensure()` still never waits — it answers on a metadata queue
whose client-side timeout is 5 s.

The port is **ephemeral** and is NOT verified against a wanted one, unlike dropd's `terminalPort + 2`:
one host has one `adb` server and one set of AVDs, so an adopted survivor's port is simply the port,
and it is by construction one something is listening on.

That same line carries the RUNNING build's version, first in the parenthetical
(`… :<port> (v0.1.0, adb …)`). hostd compares it against `slopdesk-androidd --version` on disk and
**ends** a stale one — only ends it, because the port is the OS's: the next `ensure()` round finds
the child gone and boots the installed binary, and starting a second one here would race that round
for the panel's endpoint (`docs/49`).

`HostServer.stop()` **relinquishes** it. That line used to be a `shutdown()`, which is the regression
`rust/slopdesk-invariants` now ratchets alongside the code and simulator backends.

### Not a fourth transport

Same argument as `docs/47`: this is a **foreign** protocol spoken to a third-party jar the user
installed. It shares no socket, message set or codec with terminal TCP / video UDP / inspector TCP,
and `SlopDeskProtocol` never sees a byte of it. Only discovery (verb 22) rides a SlopDesk wire, and
it carries an address, not frames.

**No auth, by invariant** — the bridge binds `0.0.0.0` with no credential; security is the WireGuard
mesh (`docs/DECISIONS.md`).

### ⚠️⚠️ `SO_NOSIGPIPE` — the bug that is now structurally absent

Kept because it is the sharpest illustration of what moving this out of hostd bought, and because the
same trap is still live for anything else in Swift that opens a raw socket.

The bridge was the one part of hostd written on blocking BSD sockets rather than Network.framework,
which made it the one part that could be killed by a signal. A pump writes to its peer long after that
peer may have gone — a client that quit, a mesh link that dropped, a device unplugged mid-frame — and
the default disposition of `SIGPIPE` **terminates the process**. hostd ignores `SIGINT` and `SIGTERM`;
it did not ignore this one.

The failure was total and gave nothing to read: hostd vanishes, every terminal pane on the machine
dies with it, and there is **no crash report**, because a signal death is not a crash. It presented as
"the Android panel stopped working, and so did everything else". Demonstrated 2026-08-04 on a bare
socket pair — a one-byte write to a closed peer exits `141` (`128 + SIGPIPE`) before it can print, and
with the option set returns `-1`/`EPIPE` and the pump ends cleanly.

Two things changed it. The pump is no longer in the process that owns the panes, so the blast radius
is one mirror. And Rust's `std::net` sets `SO_NOSIGPIPE` on every socket it creates, so the ~230 lines
of `setsockopt`/`withUnsafePointer` that `AndroidSocketIO` was are simply gone — the whole class of
bug with them. `CodeBridgeServer`, which learned this on its own accept loop first, is still Swift and
still has to set it by hand.

---

## The bridge's own dialect

One line of JSON up, one line of JSON down, then — for three of the seven ops — **raw bytes on the
same socket**.

⚠️ **The ack line and the stream's first bytes arrive in the same `receive`.** `logcat` starts
printing and the encoder starts emitting the moment the host acks. A read-until-newline that discards
its remainder loses the head of the stream; for `open` that is the codec id and the parameter sets,
i.e. a permanently black rectangle with no error to explain it. The split lives in exactly one place
(`AndroidBridgeSocket.consume`) and is pinned.

⚠️ **The host reads its request line byte at a time** for the mirror of that reason: the bytes right
after the newline may already be the client's first control messages, and a buffered read would
swallow them into a buffer it is about to discard.

**`screenshot` answers `{"ok":true,"bytes":N}` then N raw bytes** rather than base64-in-JSON: a
tablet capture is multi-megabyte, and base64 would inflate it by a third and force the client to
buffer a whole line before learning the length. `adb exec-out`, never `adb shell` — the shell's pty
translates `\n` → `\r\n` and corrupts the PNG.

---

## scrcpy v4.1, as measured

### Launch order

```
adb -s S push <jar> /data/local/tmp/scrcpy-server.jar
adb -s S forward tcp:0 localabstract:scrcpy_<scid>       → prints the allocated port
adb -s S shell CLASSPATH=… app_process / com.genymobile.scrcpy.Server 4.1 scid=<scid> …
connect 127.0.0.1:<port> → read ONE dummy byte                     (video socket)
connect 127.0.0.1:<port>                                           (control socket)
read 64 bytes off the video socket                                 (device name)
adb -s S forward --remove tcp:<port>
```

⚠️ **The 64-byte device name is written only after EVERY expected socket has connected.** Reading it
straight after the dummy byte hangs forever against a *healthy* server, and looks exactly like a
server that failed to start.

⚠️ **`connect` succeeding proves nothing.** The `adb forward` tunnel completes a TCP handshake whether
or not anything listens on the device. The dummy byte is the only proof. Measured: first socket at
0.23 s, first keyframe at 0.60 s; the dial budget is ~5 s.

⚠️ **The `scid` must have its top bit CLEAR.** The server parses it with `Integer.parseInt(s, 16)`,
which is **signed**, so anything from `80000000` up dies with `NumberFormatException` on the device,
into a log the bridge discards. A full-width `UInt32` fails for half of all sessions — which reads as
a flaky panel, not a bug.

⚠️ **Push the jar every session.** It costs milliseconds and it is the only defence against a stale
optimised-dex cache in `/data/local/tmp/oat`, which makes `app_process` die with the single word
`Aborted` — no stack, no scrcpy log line, nothing in `logcat`.

⚠️ **The version string is pinned (`4.1`).** The server refuses to run unless it matches exactly.
That is a feature: a Homebrew upgrade that moves the jar fails loudly instead of decoding as garbage.

### `clipboard_autosync=false` is load-bearing, not a preference

The bridge gives the client **ONE full-duplex connection**: video down, control up. That is sound only
while the control channel is strictly client→device. scrcpy's server has exactly three device→client
messages — clipboard, clipboard-ack, UHID output — and each is reachable only from a request this
panel never makes:

- autosync (**disabled**),
- an explicit `GET_CLIPBOARD` (**not modelled at all**),
- a `SET_CLIPBOARD` with a **non-zero sequence** (the encoder always writes `0`),
- UHID (**not modelled at all**).

Leave autosync on and the device spontaneously writes a clipboard message into a stream the client is
parsing as H.264. The omissions in `AndroidControlMessage` are the invariant, not a gap.

### Video framing

```
[4 bytes] codec id — "h264" / "h265" / "\0av1"   (once, at the head)
then repeatedly a 12-byte header:

  MSB SET   → session packet, no payload:  width u32 BE @4, height u32 BE @8
  MSB CLEAR → media packet:  bit62 = config, bit61 = keyframe, low 61 bits = PTS
                             size u32 BE @8, then <size> payload bytes
```

**Payloads are Annex-B, not AVCC.** `scrcpy` forwards raw `MediaCodec` output, so every access unit is
rewritten with 4-byte BE length prefixes for CoreMedia (`AndroidAnnexB`). The simulator panel asks its
server for `format=avcc` to avoid this; scrcpy offers no such option. **Both** start-code lengths
occur in one stream — 4-byte before the parameter sets and the first slice, 3-byte between slices of
one frame — and handling only the long form yields NALs with `00 00 00 01` buried in them, which
decode as corruption rather than failing.

**Rotation is a size change and nothing more.** `scrcpy` rotates on the DEVICE: the server tears down
its encoder and starts a new session with the axes swapped. There is no `rotationEffect` and therefore
no un-rotation of scroll deltas — the whole class of bug `SimulatorScreenLayout` has to defend against
does not exist here.

### ⚠️⚠️ A positional message is DROPPED on a size mismatch, never rescaled

The panel shipped believing the opposite — that a touch could be sent in the fitted rect's own space
paired with that rect's size, and the server would scale it — and the result was a mirror whose
toolbar worked and whose screen did not respond to anything. Nothing reports it: `PositionMapper` in
the 4.1 jar compares the pair on the wire against the size it is encoding, and on any difference logs
one **`VERBOSE`** line and returns null. The client never hears about it, and keycodes carry no
geometry, so the failure presents as "touch is broken" with a control path that is provably alive.

Measured against this host's emulator, 2026-08-04, driving the server by hand:

```
→ touch paired with 300x667 (panel points)
   [server] VERBOSE: Ignore positional event generated for size 300x667 (current size is 460x1024)
→ touch paired with 460x1024 (video pixels)
   (accepted, no line)
```

So **every** positional message — touch, drag, the scroll gesture's synthetic contacts, both pinch
contacts, and `INJECT_SCROLL_EVENT` if it is ever used — must be in the video's own pixel grid, paired
with the video's exact size. `AndroidScreenLayout.Surface` is the only way to build one, and it holds
the fitted rect and the video size together so the two cannot be paired by accident.

**And the size must come from the SESSION PACKET**, not from the decoder. Two other numbers are within
easy reach and both are wrong:

- the DEVICE's screen (`1080×2400` here) — `max_size` scales the encode down, so it is never the video
  size on a device larger than the cap;
- the SPS dimensions off `CMVideoFormatDescription` — a decoder's reading of the bitstream, which a
  codec may round up to its macroblock grid and carry the true size in a cropping rectangle.

The session packet is the server's own arithmetic, literally the value `PositionMapper` compares
against, and it arrives at the head of the stream — before the parameter sets. `AndroidSidebarModel`
therefore has exactly one writer for `streamSize`; a second one is a mirror that silently stops
accepting fingers.

### Measured numbers (this host's emulator, 2026-08-04)

| Thing | Number | What it decided |
|---|---|---|
| `max_size` 1080×2400 → 460×1024 | 13.7 → **25.3 fps** | the flag genuinely bites (unlike the simulator server's ignored `scale`); an emulator is encoder-bound on software encoders |
| H.265 vs H.264, same size | 11.3 vs **25.3 fps** | default **h264**; `c2.android.hevc.encoder` is software and costs more than the bytes it saves. A hardware-HEVC phone would flip that, which is why it is a field |
| bit rate under a continuous drag | ~2.4 Mbit/s | default target 4 Mbit/s |
| idle floor, quiet screen | **547 B/s**, ONE keyframe for the whole session | the frame sink's replay is mandatory: a view that mounts a beat late has missed the only keyframe there will be |
| first keyframe, warm | 0.83 s | the stage's veil delay is 600 ms — it DOES appear on an ordinary selection here, unlike the simulator's 0.09 s |
| 202 touch messages | 1.0 ms total (5 µs each, write only) | no message is acknowledged; nothing upstream may ever be written as a request expecting a reply |
| `adb exec-out screencap -p` | 300 KB, ~250 ms | **no thumbnail polling on cards** — against the simulator server's 13.5 KB / 22 ms scaled JPEG, a 2 s poll per device would be ~150 KB/s and a real slice of the device's CPU |
| raw `screencap` | 10.4 MB, 755 ms | why `-p` |

### ⚠️⚠️⚠️ The emulator's RENDERER decides whether the panel is smooth. Nothing in this repo does.

Reported as "scrolling stutters, and I can't tell whether it's input or output" (2026-08-04). It was
neither: an emulator booted headless renders in **software** unless told otherwise, and the panel was
faithfully mirroring a device that was itself running at six frames a second.

`-no-window` makes the emulator's `auto` renderer resolve to a software one. Measured on this host,
same AVD, same synthetic drag through `Settings`, same 460×1024 stream:

| `-gpu` | fps at the client | gap p90 | worst gap | device's own janky frames |
|---|---|---|---|---|
| *(none — `auto` + `-no-window` → `lavapipe`)* | **6.4** | 436 ms | 677 ms | **98.7%**, 113 ms/frame |
| `swiftshader_indirect` | 19.5 | 102 ms | 216 ms | **99.6%**, 97 ms/frame |
| **`host`** (Metal, and headless is no obstacle) | **58.1** | **28 ms** | **71 ms** | **2.6%**, 22 ms/frame |

The device-side column is `dumpsys gfxinfo <pkg>` and it is the one that settles the question: at
98.7% janky the device never produced the frames, so no transport could have carried them.

**SlopDesk's own path adds nothing measurable.** The same drag, measured at three vantage points with
one probe:

| Vantage | fps | gap p90 | worst |
|---|---|---|---|
| scrcpy direct over `adb`, on the host | 19.5\* | 102 ms | 216 ms |
| through the bridge, loopback | 19.5\* | 102 ms | 216 ms |
| through the bridge, over the mesh from the client machine | 59.0† | 27 ms | 72 ms |

\* software renderer. † hardware renderer — the mesh row is identical to the loopback row taken under
the same renderer (58.1 / 28 ms / 71 ms). The host's byte pump, the WireGuard hop and the client's
decoder are all inside the noise.

So `protocol::emulator_arguments` states `-gpu host` outright, and `SLOPDESK_ANDROID_EMULATOR_ARGS`
replaces it rather than fighting it if a host needs something else.

⚠️ **An emulator the panel did not boot keeps whatever flag it was started with.** Android Studio's
own launches, and anything with `-gpu swiftshader_indirect` in it, land in the 19.5 fps row and look
exactly like a panel bug. The guest cannot tell you which: `ro.hardware.egl` is `emulation` either
way. `adb shell dumpsys SurfaceFlinger | grep GLES:` can — it names the HOST's renderer
(`… (Apple M1 Max), OpenGL ES 3.0 (4.1 Metal - 90.5)` against
`… (SwiftShader Device (LLVM 10.0.0)), ANGLE 2.1.1`).

---

## The list, and the fact Android has that iOS does not

`docs/47` records that a shut-down iOS simulator knows only name/runtime/state/udid, and that the
geometry available for it is chrome data that silently falls back to a lookalike — wrong for **4 of
11** devices. Android is the inverse: an AVD's `config.ini` is its **definition**, so `hw.lcd.width`,
`hw.lcd.height`, `hw.lcd.density`, the device profile, the ABI and the API level are exact on a row
that has never booted.

The panel is designed around that difference:

- an Android row **carries figures** where the iOS row could carry only a name;
- the running **card draws the device's true aspect ratio** instead of a live thumbnail (see the
  measurement above) — a phone comes out 92 points wide at the card's art height and a tablet 150,
  side by side and unmistakable;
- it claims the **shape**, which is known, and not the **size**, which is not: nothing here knows a
  device's physical inches, and density is a rendering bucket rather than a ruler.

### Traps in the list

⚠️ **`ro.build.characteristics` is `emulator,nosdcard` on most emulators, and `nosdcard` contains
`car`.** A substring search classifies every phone AVD as an automotive head unit.
`slopdesk_devicepanel::android::device_kind` matches **tokens**, not substrings, and pins the trap
by name (`an_ordinary_emulator_is_not_an_automotive_head_unit`). `AndroidDeviceKind.infer` is the face
over it.

⚠️ **`ro.product.model` is `sdk_gphone64_arm64` for every AVD on the host**, so it cannot name a row;
the AVD name can, and it is what the user typed. A physical device has no AVD name and its model is
exactly right. The headline is per-kind.

⚠️ **`state` is kept as `adb`'s raw word** (`device`, `offline`, `unauthorized`, `authorizing`,
`connecting`, `recovery`, `sideload`, `bootloader`). A closed enum turns a transient state into a
decode failure for the whole list. `unauthorized` is the one state worth designing for: it means a
dialog is waiting on the device's own screen, and the panel can do nothing while the user can fix it
in two seconds — provided they are told. Everything with a serial goes in the **Attached** group,
including that device, because burying it among the switched-off AVDs is where it would hide.

The grouping itself is `slopdesk_devicepanel::sections`, shared with the simulator panel (docs/47):
the running group first and not cut by family, the families after it in rank order, and the platform
version lifted into a heading only where every member states the same one — an ABSENT version counts
as a disagreement. `slopdesk_android_version_label` is the one spelling of `Android 16` / `API 36`,
so a heading can never claim a version the grouping did not compare.

---

## `logcat`

`-v time`, `-T 200`, `*:<level>` with the level validated against a **closed set** (`V D I W E`) —
the letter is interpolated into an argument vector, and `logcat` treats an unparsable filter spec as
a fatal error, which reads as a console that connects and immediately dies.

⚠️ **The pid is right-aligned into a fixed-width field**, so its width decides where the header ends:
`( 1234):` carries a space and splits the header across two whitespace tokens, while `(12345):`
closes inside the first one. A parser that handles only the narrow case drops the entire message of
every wide-pid line. Both shapes are pinned.

⚠️ **The priority letter is always followed by `/`** (`%c/%-8s(%5d): `). Without checking for it, any
prose whose third word starts with a letter in `VDIWEFAS` — "Everything is fine" — parses as an error
row with a tag cut out of the middle of the word.

A line that does not match is kept **verbatim**: `logcat`'s own banners (`--------- beginning of
crash`) are exactly what someone reading a crash is looking for.

---

## Env

| Flag | Notes |
|---|---|
| `SLOPDESK_ADB_BIN` | overrides `adb`. Absent ⇒ located under the SDK's `platform-tools`; without it there is no panel at all (`unavailable`) |
| `SLOPDESK_ANDROID_EMULATOR_BIN` | overrides the `emulator` binary. Missing is NOT `unavailable` — a host with a phone plugged in still has devices to list |
| `SLOPDESK_ANDROID_SERVER_JAR` | overrides `scrcpy-server`. **The jar IS in this repo now** — committed at `ThirdParty/tools/vendor/scrcpy-server` (716 KB), pinned in `ThirdParty/tools/tools.lock` against upstream's own v4.1 digest, which `VendoredToolsTests` re-verifies. It is the one dependency small enough to commit and the only one that is not an executable (the device's `app_process` runs it), so it carries no signing or architecture concern. Homebrew's `share/scrcpy` stays as the fallback for a hostd running outside a checkout. The HOST still never downloads one — `slopdesk-provision` verifies the committed bytes. Missing ⇒ devices list and boot, nothing mirrors |
| `SLOPDESK_ANDROID_EMULATOR_ARGS` | extra flags appended to the emulator launch, for a host whose GPU needs them |
| `SLOPDESK_ANDROID_HW` | `=1` enables the hardware tests (`rust/slopdesk-androidd/tests/hardware.rs`), which need a booted device, an `adb` and the jar. Off ⇒ every one of them prints why it proved nothing and passes, so a clean checkout stays green on a machine that has never seen the Android SDK |
| `SLOPDESK_ANDROIDD_BIN` | overrides which `slopdesk-androidd` hostd spawns. Absent ⇒ `RustServicePaths` (installed copy, then the crate's cargo target). None found ⇒ the panel reports `unavailable` |

---

## Gates

`make test-touched` covers the whole panel, on both sides of the socket: the client half in Swift
(reassembler, control encoder, layout, scroll machine, logcat parser, device decode) and the bridge
half as `rust/slopdesk-androidd`'s unit tests (catalogue, toolchain locator, console, argument
vectors, refusals, request decode). Every runtime seam is injectable, so no test opens a device socket
or builds a display layer (hang-safety). The **sockets** are exercised only by
`rust/slopdesk-androidd/tests/hardware.rs` behind `SLOPDESK_ANDROID_HW=1`, with a booted device —
`slopdesk-gate android` is what sets it, having first resolved the same `adb` and jar production
would.

`rust/slopdesk-invariants` ratchets what is typed on both sides of the wire: every `op` the
panel can send has an arm in `server.rs`, every device field it decodes is one `protocol.rs` encodes,
the announce marker matches, and no Swift Android bridge has come back.
