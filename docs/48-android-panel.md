# 48 — Android panel (the second foreign wire, and the one relay that is not optional)

The right panel's **Android** tab mirrors one of the host's Android devices — emulator or a phone on
the desk — and drives it: frames down, touches and keys up. Drawn **natively** (SwiftUI +
`AVSampleBufferDisplayLayer`), like the Simulators tab and for the same reasons.

Everything below the fold is **measured**, not read from a spec. `scrcpy` publishes no wire
document — its own documentation says the control protocol is defined by the unit tests on both
sides — so the dialect was transcribed from `control_msg.c` / `demuxer.c` / `server.c` at **v4.1**
and recorded off a live emulator on 2026-08-04. The byte-level claims here are what
`Tests/SlopDeskClientUITests/Android*Tests.swift` pin. If the Homebrew formula moves, re-measure
before changing the decoder.

Read this before touching anything under `Sources/SlopDeskClientUI/Android` or
`Sources/SlopDeskHost/Android`.

---

## Shape

```
client (SlopDeskClientUI/Android)                       host (SlopDeskHost/Android)
──────────────────────────────────────────────────────────────────────────────────
metadata verb 22  ensureAndroidBridge   ────────────►   HostAndroidPerformer
                  [state][UInt16 BE port] ◄──────────   AndroidBridgeManager
                                                              │ binds (IN hostd)
                                                        AndroidBridgeServer  ── adb ──► device
one TCP connection per operation:
  {"op":"list"}\n            ──► {"ok":true,"devices":[…]}\n              (then close)
  {"op":"boot","avd":…}\n    ──► {"ok":true}\n
  {"op":"shutdown",…}\n      ──► {"ok":true}\n
  {"op":"console",…}\n       ──► {"ok":true,"output":"…"}\n
  {"op":"screenshot",…}\n    ──► {"ok":true,"bytes":N}\n  + N raw PNG bytes
  {"op":"logcat",…}\n        ──► {"ok":true}\n            + logcat text, forever
  {"op":"open","serial":…}\n ──► {"ok":true,"device":…}\n + scrcpy video down / control up
```

### Why the bridge exists at all — and why it is not a child process

`adb forward` binds **127.0.0.1 only**. A mesh client therefore cannot reach the device socket
without something host-side to relay it. That is the bridge's whole job.

`adb -a server -H 0.0.0.0` was considered and **rejected**: it is a machine-wide change to the user's
`adb` and it hands every mesh peer a device shell.

Unlike verb 21's `baguette serve`, the bridge is **inside hostd** — there is no third-party server to
spawn, because the panel speaks `scrcpy-server`'s protocol itself. So `AndroidBridgeManager` has no
port to learn from a log line and no readiness to poll: it either binds or it does not, and `ensure()`
can answer `ready` on the first call.

### Not a fourth transport

Same argument as `docs/47`: this is a **foreign** protocol spoken to a third-party jar the user
installed. It shares no socket, message set or codec with terminal TCP / video UDP / inspector TCP,
and `SlopDeskProtocol` never sees a byte of it. Only discovery (verb 22) rides a SlopDesk wire, and
it carries an address, not frames.

**No auth, by invariant** — the bridge binds `0.0.0.0` with no credential; security is the WireGuard
mesh (`docs/DECISIONS.md`).

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
`AndroidDeviceKind.infer` matches **tokens**, not substrings.

⚠️ **`ro.product.model` is `sdk_gphone64_arm64` for every AVD on the host**, so it cannot name a row;
the AVD name can, and it is what the user typed. A physical device has no AVD name and its model is
exactly right. The headline is per-kind.

⚠️ **`state` is kept as `adb`'s raw word** (`device`, `offline`, `unauthorized`, `authorizing`,
`connecting`, `recovery`, `sideload`, `bootloader`). A closed enum turns a transient state into a
decode failure for the whole list. `unauthorized` is the one state worth designing for: it means a
dialog is waiting on the device's own screen, and the panel can do nothing while the user can fix it
in two seconds — provided they are told. Everything with a serial goes in the **Attached** group,
including that device, because burying it among the switched-off AVDs is where it would hide.

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
| `SLOPDESK_ANDROID_SERVER_JAR` | overrides `scrcpy-server`. Located under Homebrew's `share/scrcpy` otherwise. **The jar is not in this repo** and the host never downloads one: the user runs `brew install scrcpy`. Missing ⇒ devices list and boot, nothing mirrors |
| `SLOPDESK_ANDROID_EMULATOR_ARGS` | extra flags appended to the emulator launch, for a host whose GPU needs them |
| `SLOPDESK_ANDROID_HW` | `=1` enables the hardware tests (`AndroidBridgeHardwareTests`), which need a booted device, an `adb` and the jar. Off ⇒ every one of them is a no-op, so a clean checkout stays green on a machine that has never seen the Android SDK |

---

## Gates

`make test-touched` covers the whole panel: every runtime seam is injectable, so no test opens a
socket or builds a display layer (hang-safety). The **sockets** are exercised only by
`AndroidBridgeHardwareTests` behind `SLOPDESK_ANDROID_HW=1`, with a booted device.
