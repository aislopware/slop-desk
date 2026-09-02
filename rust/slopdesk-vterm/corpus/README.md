# The recorded corpus

Five real programs, run once each under `slopdesk-ttyrec`, with everything they wrote kept exactly
as the pty handed it over and everything that was sent at them kept as the encoder produced it.
`src/conformance/dynamic.rs` replays them; `slopdesk-termrender` paints every frame of them.
`docs/68` §6.4–6.5 is the argument for why they exist.

**These are inputs, not golden files.** No *frame* in a `.sdrec` is an expected answer — every frame
is recomputed on each run and checked against the engine — so a pin bump has no frame to re-bless,
and the golden-vector rule in `CLAUDE.md` does not reach them.

The recorded BYTES are the exception, and they are pinned on purpose: `Event::Input`, `Event::Mouse`,
`Event::Paste` and `Event::Focus` each carry what the encoder produced at that point in the stream,
and `Event::Reply` carries the answer the engine gave a DA/DSR/XTGETTCAP query. If an engine bump
changes a key encoding, a mouse report format, the paste framing or a query answer, then
`a_recorded_session_reproduces_every_byte_of_its_input_path` fails **honestly** — that is the
integration being tested, not a flake. The fix is to re-record with the commands below and read the
diff.

## What each recording is for

| File | What it is | Why it is here |
| --- | --- | --- |
| `opentui.sdrec` | `opentui-demo.ts` on `@opentui/core` | the framework OpenCode ships on: full-screen repaint on a 60 ms timer, truecolor per row per frame, synchronized updates, a kitty graphics probe at startup |
| `nvim.sdrec` | `nvim -u NONE -i NONE` | the editor everything else is compared against: alternate screen, a status line redrawn in place, multi-byte and wide text typed in, and the **kitty keyboard protocol** |
| `fzf.sdrec` | `fzf --height=100%` | a filter redrawing its whole list on every keystroke, and the interactive case where output and input alternate; carries the **wheel** |
| `lazygit.sdrec` | `lazygit` in this repo | a Go TUI with panes and borders, kitty keyboard on, and the session that caught the **cursor-read bug** in `docs/68` §6.5 by hiding and showing its cursor around a redraw |
| `less.sdrec` | `less` paging `docs/68` | the program that subscribes to NOTHING: 30-odd screens of scrolling, and a pointer event, a focus change and a paste that all reach a program which never asked for any of them |

### The refusals are load-bearing

`less`'s pointer event and focus change both recorded EMPTY bytes, because it never asked to hear
about either, and its paste recorded the text BARE, because it never asked for bracketing. Those are
the discriminating negatives for the whole input path: an encoder that ignored the tracking, focus
and paste modes entirely passes every other event in the corpus and fails only these. Any
replacement for `less` has to bring them along — `dynamic.rs` floors at four refusals and one bare
paste, so a corpus that lost them fails rather than silently narrowing.

`less` is also the only recording whose *content* is a file in this repository, which is the point:
the earlier holder of this slot was `top`, whose frames were the recording machine's process list
and user name. **Never record a program that prints machine state.** The recorder hands the child
its whole environment, so record only under an environment you would publish — the commands below
do that with `env -i`, plus `LESSHISTFILE=-` and `LESSSECURE=1` so the child writes nothing and
cannot be driven out of the pager by the unbracketed paste.

## Re-recording

Only needed if a recording is deliberately replaced. Build the recorder first:

```sh
cd rust/slopdesk-ttyrec && cargo build --release
```

The four input flags — `--send`, `--send-mouse`, `--paste`, `--focus` — share **one order**, the
order they appear on the command line. That is deliberate and it is the content: a click before a
program enables mouse tracking encodes to nothing and the same click after it encodes to a report.

Then, from the repo root, with `$REC` pointing at the built binary. `env -i` is not decoration: the
recorder passes its environment straight to the child, and a developer shell exports credentials.

```sh
rec() { env -i PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
        HOME="$(mktemp -d)" LANG=en_US.UTF-8 "$REC" "$@"; }

rec --out rust/slopdesk-vterm/corpus/opentui.sdrec --title opentui \
    --cols 100 --rows 30 --startup-ms 1200 --settle-ms 250 \
    --focus off --focus on \
    --send '<Down>' --send-mouse 'left@40,10' --send '<Down>' \
    --send-mouse 'left@20,6 motion:left@30,6 release:left@30,6' \
    --paste 'pasted text' --send '<Up>' --send 'q' \
    -- "$(command -v bun)" run rust/slopdesk-vterm/corpus/opentui-demo.ts

rec --out rust/slopdesk-vterm/corpus/nvim.sdrec --title nvim \
    --cols 100 --rows 30 --startup-ms 1500 --settle-ms 300 \
    --send 'ihello <lt>conformance> 世界' --paste 'bracketed?' \
    --send '<Escape>' --send 'yyp' \
    --send-mouse 'left@10,3' --focus off --focus on \
    --send ':q!<Enter>' \
    -- "$(command -v nvim)" -u NONE -i NONE

rec --out rust/slopdesk-vterm/corpus/fzf.sdrec --title fzf \
    --cols 100 --rows 30 --startup-ms 1200 --settle-ms 250 \
    --send 'ma' --send-mouse 'left@5,8' --send '<Down>' \
    --send-mouse '5@5,8 4@5,8' --paste 'rs' --focus off \
    --send '<C-c>' \
    -- "$(command -v fzf)" --height=100%

rec --out rust/slopdesk-vterm/corpus/lazygit.sdrec --title lazygit \
    --cols 100 --rows 30 --startup-ms 1800 --settle-ms 300 \
    --send '<Down>' --send-mouse 'left@30,12' --send '2' \
    --send-mouse 'motion:@30,13 left@30,13 release:left@30,13' \
    --focus off --focus on --send '<Escape>' --send 'q' \
    -- "$(command -v lazygit)"

rec --out rust/slopdesk-vterm/corpus/less.sdrec --title less \
    --cols 100 --rows 30 --startup-ms 800 --settle-ms 200 \
    --send-mouse 'left@10,4' --focus on --send 'jjj' \
    $(for i in $(seq 1 24); do printf -- '--send <C-d> '; done) \
    $(for i in $(seq 1 6);  do printf -- '--send <C-u> '; done) \
    --send '/conformance<Enter>' --send 'n' --send 'n' \
    --paste 'jjkk' --send 'G' --send 'g' --send 'q' \
    -- /usr/bin/less docs/68-terminal-surface-in-rust.md
```

`less` needs `LESSHISTFILE=-` and `LESSSECURE=1` added to `rec`'s environment (see above). The
pasted text is `jjkk` on purpose: with bracketing off it arrives as four live pager commands, which
is exactly the hazard the mode exists to prevent — so it must stay something harmless. Never paste
text containing `q` or `s` into it.

`opentui-demo.ts` needs `@opentui/core` resolvable — `bun add @opentui/core` in a scratch directory
and run the demo from there, or install it beside the file. It is not a build dependency: the demo
is committed so the recording's provenance is readable, and nothing in the tree runs it.

## Reading a re-recording

A re-recording is a real diff, and the floors in `dynamic.rs` are there to catch the way it usually
goes wrong — a dropped flag. Every recording must carry at least one pointer event, and the corpus as
a whole at least 12 keystrokes, 6 pointer events, 3 pastes (2 of them bracketed and 1 of them bare),
6 focus changes, 8 replies and 4 refusals. A recording that grew by a hundred kilobytes usually means
a longer settle, not a better test.

What the corpus holds today, for reading a re-record's diff against:

| | opentui | nvim | fzf | lazygit | less |
| --- | --- | --- | --- | --- | --- |
| pty reads | 140 | 29 | 100 | 58 | 134 |
| keystrokes | 4 | 4 | 3 | 4 | 37 |
| pointer | 2 | 1 | 2 | 2 | 1 |
| pastes | 1 | 1 | 1 | 0 | 1 (bare) |
| focus | 2 | 2 | 1 | 2 | 1 |
| replies | 2 | 4 | 1 | 3 | 0 |
| refusals | 1 | 1 | 1 | 1 | 2 |
