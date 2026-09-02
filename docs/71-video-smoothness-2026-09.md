# 71 — The GUI video path measured for smoothness, 2026-09-02

The question was Parsec's: does the remote window move the way the source window moves? Nothing in
the tree could answer it — `slopdesk-guigate video` proves one frame reaches a drawable, and
`slopdesk-framewatch` measured one window at a time. This doc records the harness that answers it,
every number it produced on 2026-09-02, and what those numbers changed. Read
`docs/46-gates-env-paths.md` for the harness's row and `docs/11-absolute-latency.md` for the
latency budget the numbers sit inside.

Everything below is LOOPBACK on one Mac Studio (M-series, 1920×1080 at 60 Hz): host, client, source
and instrument on the same machine. `macbook-pro` was unreachable, so the mesh case is not measured
here, and "as smooth as Parsec" is judged against the envelope in `docs/decisions/vol-01.md`
§"FPS / latency" — 52.8–60.2 fps on the continuous-scroll workload — until it is.

## 1. The harness — `just gui-smooth`

`slopdesk-guigate smooth` opens a Chrome `--app` page that scrolls itself under
`requestAnimationFrame` (6 px a frame, bouncing; 1280×800; title `SRCSCROLL`), serves it through a
RELEASE `slopdesk-videohostd` to one SlopDesk client (`SDREMOTE`), and puts ONE `slopdesk-framewatch`
on both windows for the span (`--title-a`/`--title-b`; two framewatch processes cannot coexist —
a second `SCShareableContent` enumeration beside a live stream answers "nothing shareable"). It
reads back, per window: new frames (deliveries less identical re-deliveries), new frames a second,
deliveries, interval p50/p90/p99/max, and the 1-slot/2-slot/>60 ms stall bins. It then reads the
host's and the client's debug logs over the SAME span — encoded and decoded frame ids, capture
delivery gaps, encoder drops, encode-load pacer steps, backpressure skips, send gaps, present gaps —
counted from the moment the watch started, so the connect-time keyframe's backpressure and the
teardown's last gap never read as steady-state hitches.

`--latency` swaps in a 500 ms flasher and framewatch's pair-the-flips mode: compositor-to-compositor
glass-to-glass, p50/p90/min/max. `--fps`/`--scale` reach the daemon; every `SLOPDESK_*` in the
environment reaches host and client, so an A/B is one environment variable.

Two traps the harness carries in its own text: framewatch matches titles by SUBSTRING (hence
`SRCSCROLL` vs `SDREMOTE`), and a client presenting WITHOUT vsync makes both windows read ~80
deliveries a second for a 60 fps source — the extra deliveries are identical re-deliveries, which is
why the table leads with NEW frames and the ratio is over those.

## 2. The numbers

Fifteen-second cadence spans; three or more runs per row where a range is given. "steps" are
encode-load pacer steps; "gaps" are the host's send gaps (>2 frame intervals between sends) over the
span; "stalls" are the remote window's 1-slot bin.

| configuration | remote new/s | remote/source | stalls | steps | gaps | encode wall |
| --- | --- | --- | --- | --- | --- | --- |
| default (`--fps 30`, capture 60 Hz, vsync off) | 57–59 | 0.93–0.96 | 1–4 | 0 | 9–20 | 11.0–13.1 ms |
| `--fps 60` (capture 120 Hz), pacer as shipped | 49–54 | 0.85–0.91 | 3–8 | 2–4 | 45–133 | 11–15 ms |
| `--fps 60` + `SLOPDESK_CAPTURE_HZ=60`, pacer as shipped | 55–57 | 0.92–0.95 | 2–5 | 0–2 | 8–51 | 11–19 ms |
| `--fps 30` + `SLOPDESK_CAPTURE_HZ=120` | 60 | 0.97 | 0 | 0 | 4 | 11.6 ms |
| `SLOPDESK_VSYNC=1` (fps 30) | 60.0 exactly | 0.96–0.98 | 0–3 | 0 | — | — |
| `SLOPDESK_PACER=deadline` (fps 30) | 30 | 0.50 | — | 0 | — | — |
| **`--fps 60`, pacer RECALIBRATED (§3)** | **59.0–59.4** | **0.98** | **0–1** | **0** | **1–3** | 10.5–12.6 ms |

Glass-to-glass (`--latency`, 500 ms flasher, ~38 pairs a run):

| configuration | p50 | p90 |
| --- | --- | --- |
| default, vsync off | 28.1 ms | 40.4 ms |
| `SLOPDESK_VSYNC=1` | 34.4 ms | 50.4 ms |
| `--fps 60`, vsync off | 27.2 ms | — |

The source page itself, alone, reads 59.9–60.8 new frames a second with 1–3 one-slot stalls a span:
the remote's 0–1 stalls under the recalibrated pacer is the source's own cadence, not a ceiling the
pipe adds. The encode wall is the same 11–13 ms with framewatch running and before it starts (the
first "encode wall" line lands before the watch), so the instrument is not what the pacer was
reading.

## 3. What the numbers showed, and what changed

**The `--fps 30` default is nominal.** `EncodeCadenceGate` engages only when the governed rate is
UNDER `shape.fps`, and it starts equal, so nothing gates the encode at the announced rate: every
changed frame the capture delivers (ceiling 2×fps = 60 Hz) is encoded, and the "30 fps" stream
runs at 57–59. Everything that reads the number — the bitrate budget, `ExpectedFrameRate`, the
`streamCadence` announcement, the client's cold-start content fps, the deadline pacer's interval —
believes 30 while 60 flows. The deadline pacer row above is that mismatch made visible: it paces
to the announced 30 and halves the stream. This is recorded here and NOT yet changed; the truthful
default (60, with the client's cold start and the docs to match) is the next change, and it waits
on the pacer below because `--fps 60` as shipped was WORSE than 30.

**`--fps 60` was a trap, and the encode-load pacer was the trap.** `EncodeLoadPacer` stepped a rung
down (60 → 30) once the encode-wall EWMA passed 0.85 × the budget for THREE frames, and back up
after 45 clean ones. The wall at 1280×800 is 11–13 ms — 72% of the 16.7 ms budget, with spikes to
15–19 — so at 60 fps the 14.2 ms threshold tripped on the spikes, halved the rate for a second and
a half, stepped back, and tripped again: 45–133 send gaps a span, 49–54 fps delivered. At 30 the
budget was 33 ms and it never fired, which is why the nominal default looked fine. The same wall
at the 60 fps floor every DISPLAY session runs at (`display_fps_from_env`) means desktop panes were
oscillating too.

The recalibration (`EncodeLoadPacerConfig::default`): step down only when the average EXCEEDS the
budget (`down_fraction` 1.0 — the backlog builds only when an encode takes longer than the interval
it has), only after thirty consecutive over-budget frames (half a second at 60 — a step halves the
rate for seconds, so it answers a sustained overrun and a burst costs a few ragged drops instead),
and step back up after 120 clean frames rather than 45, so a rate that steps up is not about to
step down again. Three `--fps 60` runs after: 0 steps, 1–3 send gaps, 59.0–59.4 new frames a
second, remote/source 0.98 — the source's own cadence. The unit tests pin the measured trap (a
12 ms wall with 19 ms spikes never steps) and the burst case.

**Vsync on reads the cleanest cadence at +6 ms.** `SLOPDESK_VSYNC=1` presents exactly 60.0 with
3–6 present gaps against 11–24 without, no tearing, and costs 6 ms at p50 glass-to-glass. The
renderer's comment claims Parsec presents without vsync by default; Parsec's own documentation says
`client_vsync` defaults ON. Not flipped in this change — the flip, its escape hatch and its docs
row are the next change with the fps default.

## 4. How to re-run this

```
just gui-smooth                       # cadence, 15 s, the daemon's defaults
just gui-smooth --fps 60              # the recalibrated pacer's case
just gui-smooth --latency             # glass-to-glass
SLOPDESK_VSYNC=1 just gui-smooth      # an A/B is one variable
```

Needs Screen Recording for `slopdesk-videohostd` AND `slopdesk-framewatch`, and an unlocked Aqua
session; `SLOPDESK_VIDEO_DEBUG=1` is set by the harness, which is where the host's "encode wall"
and "encode-load pacer" lines come from.
