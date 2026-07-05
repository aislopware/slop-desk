# Scroll

## Summary

Scrollback and scroll-gesture handling. Configured entirely in the GUI (Settings → Controls → Scroll) — no config file. Three knobs: bottom overscroll, top overscroll, pixel-smooth vs. row-snap. Separate keyboard shortcuts cover page/line/command-jump navigation. New output or any typing snaps the viewport back to the bottom.

## Behaviors

- **Scroll keys**: keyboard shortcuts navigate scrollback (page, top/bottom, command-jump); see Keybindings.
- **Auto-snap to bottom**: new output or any character keypress snaps the viewport to the buffer bottom.
- **Scroll Past Last Line** (default off): scroll beyond the last content line so the final/cursor row floats up from the window edge. Options: Disabled (clamp); Last Line With Content (bottom-most text row at viewport top); Last Line In Middle (that row centred); Cursor Line (cursor row at top even if blank). Auto-disabled on the alternate screen so full-screen TUIs (vim, htop, less) are unaffected.
- **Scroll Past First Line** (default off): symmetric top overscroll, pushing the oldest history row down. Options: Disabled (clamp at scrollback top); Same as Scroll Past Last Line (mirrors that knob so only one needs tuning); First Line With Content (topmost history row at viewport bottom); First Line In Middle (topmost row centred).
- **Smooth Scroll** (default on): sub-row (pixel) granularity during the gesture; snaps to a row boundary on gesture end so glyphs stay pixel-aligned. Off = classic whole-row jumping.
- **Shell Integration command-jump** (⌘PageUp / ⌘PageDown): requires active Shell Integration; jumps to the previous/next command boundary.
- **Alternate-screen isolation**: Scroll Past Last Line auto-suppressed on the alternate screen so full-screen TUIs keep their own bottom edge.

## Keybindings

| Action | Keys |
|---|---|
| Scroll one page up | ⇧PageUp |
| Scroll one page down | ⇧PageDown |
| Scroll to top of scrollback | ⇧Home |
| Scroll to bottom of buffer | ⇧End |
| Jump to previous command (Shell Integration required) | ⌘PageUp |
| Jump to next command (Shell Integration required) | ⌘PageDown |

## Config keys

All in **Settings → Controls → Scroll**. GUI-only; no config-file keys.

| Key (UI label) | Default | Effect |
|---|---|---|
| Scroll Past Last Line | Disabled | Overscroll past the last line. Disabled (clamp at buffer bottom), Last Line With Content (prompt row at viewport top), Last Line In Middle (prompt row centred), Cursor Line (cursor row at top, incl. blank lines). Auto-suppressed on the alternate screen. |
| Scroll Past First Line | Disabled | Overscroll past the first (oldest) line. Disabled (clamp at scrollback top), Same as Scroll Past Last Line (mirrors that setting), First Line With Content (topmost history row at viewport bottom), First Line In Middle (topmost row centred). |
| Smooth Scroll | On | On: pixel-granularity during gesture, snaps to row boundary on end. Off: whole-row jumping. |

## Visual spec

### scroll-past-last-line video

**Frame 1 (initial — normal scroll position):**
macOS window, native traffic-light buttons (red/yellow/green, ~12 px) top-left. Centred title "abner@MacBook-Pro: ~/Workspace/slopdesk" in muted grey. Near-white background (~#F9F9F9, light theme). Dense `ls -la` listing fills top-to-bottom, no blank rows, prompt+cursor at bottom-left. No scrollbar. Monospaced ~13 px; syntax colours: cyan `.github`, green `target`, dark-grey rest. Rounded corners (~12 px), light-grey desktop, soft shadow.

**Frame end (Scroll Past Last Line active):**
Same chrome/theme. Only the **prompt line** (`~/Workspace/slopdesk (main x)●+↑ ▷`) shows near **top-left**, cursor block after the prompt marker; the rest of the viewport is blank off-white. Thin vertical scrollbar thumb (~8 px, rounded, medium grey ~#B0B0B0) on the **right edge** near the bottom (near end of range). "Last Line With Content" variant: last content row at viewport top, empty below.

### scroll-past-first-line video

**Frame 1 (normal scroll position):**
Same light-theme window. Dense `ls -la` listing fills top-to-bottom, cursor at bottom, no overscroll.

**Frame end (Scroll Past First Line active):**
Scrolled past the top of scrollback. **Upper portion** blank. Partway down, oldest history appears: prompt `~/Workspace/slopdesk (main x)●+↑ ▷ lsa` then `lsa` output (`total 232`, `drwxr-xr-x 26 abner staff  8328 Jun  7 14:22 .`, etc.). Blank region above = overscroll gap (oldest row pushed to viewport bottom or centre per mode). "First Line In Middle" variant: topmost history mid-pane, blank above.

### scroll-smooth-off video

**Frame 1 (Smooth Scroll off — mid-scroll):**
macOS light-theme window, traffic lights (smaller/lighter, unfocused). Markdown CREDITS/LICENSE listing — dependency table (`| Source | Entries | License |`) with `##` headings. Text snaps to exact row boundaries; no partial rows, no motion blur; ~10–12 rows visible.

**Frame end (Smooth Scroll off — settled):**
Same content, row-aligned. Markdown CREDITS table rows; crisp, no sub-pixel offset. Lack of pixel-granularity is the defining trait (only observable in the video).

### scroll-smooth-on video

**Frame 1 (Smooth Scroll on — mid-scroll):**
Same window. Same CREDITS/dependency listing — SPM dependencies with GitHub URLs and licence types, markdown table. Mid-buffer. Smooth on: rows at sub-pixel offsets (partial top/bottom clipping at viewport edges), fluid motion.

**Frame end (Smooth Scroll on — settled at row boundary):**
Settled; topmost visible row pixel-aligned (no clipping). `ls -la` listing at scrollback bottom — `drwxr-xr-x 26 abner staff` entries. Clean and pixel-sharp: snap-to-row-boundary on gesture end. Visually identical to non-smooth at rest; difference is purely kinetic during the gesture.

### Common visual elements across all scroll videos

- **Window chrome**: macOS window, rounded corners (~12 px), light-grey backdrop shadow, traffic lights (red `#FF5F57`, yellow `#FFBD2E`, green `#28C840`) top-left.
- **Title bar**: single-line centred "abner@MacBook-Pro: ~/Workspace/slopdesk" in medium grey, no icons.
- **Terminal background**: off-white ~`#F8F8F8`/`#FAFAFA`, light-theme default.
- **Terminal font**: monospaced ~13 px; standard ANSI colours: cyan paths/dirs, green some filenames, dark grey/black body.
- **Scrollbar**: thin rounded thumb (~8 px), medium grey, right edge only during/after scrolling (macOS overlay auto-hide when idle).
- **Prompt style**: `~/Workspace/slopdesk (main x)●+↑ ▷` — cyan path, purple/pink git status `●+↑`, green chevron `▷`. Shell Integration glyphs active.
- **No Settings UI shown** — configuration shown only as behavioural result.

## Screenshots

Extracted frames from the mp4 videos:
- `scroll-past-last-line-frame1.png` — initial, dense ls listing, cursor at bottom
- `scroll-past-last-line-frame-end.png` — Scroll Past Last Line active: prompt at top, blank below, scrollbar thumb visible
- `scroll-past-first-line-frame1.png` — initial, dense ls listing
- `scroll-past-first-line-frame-end.png` — Scroll Past First Line active: blank space above first content row
- `scroll-smooth-off-frame1.png` — Smooth off, mid-scroll, markdown/credits content
- `scroll-smooth-off-frame-end.png` — Smooth off, settled at row boundary
- `scroll-smooth-on-frame1.png` — Smooth on, mid-scroll, dependency table content
- `scroll-smooth-on-frame-end.png` — Smooth on, settled at row boundary (ls listing)

Source videos:
- `scroll-past-last-line.mp4`
- `scroll-past-first-line.mp4`
- `scroll-smooth-off.mp4`
- `scroll-smooth-on.mp4`

## SlopDesk mapping notes

### Mappable 1:1

- **Keybindings (⇧PageUp/Down, ⇧Home/End)**: standard VT sequences (`CSI 5~`, `CSI 6~`, `CSI 1~`, `CSI 4~` with Shift). libghostty handles scrollback natively; the client intercepts these before the PTY and routes to libghostty `scrollPageUp`/`scrollPageDown`/`scrollToTop`/`scrollToBottom`. Full 1:1.
- **Auto-snap to bottom on output/typing**: libghostty already scrolls to bottom on new output and keypress — default for any conformant emulator. No extra work.
- **Smooth Scroll on/off**: libghostty exposes a `scrollMultiplier` / pixel-scroll API. macOS client renders via `TerminalRenderingView`; drive pixel-granular scrolling from `NSScrollView`/`MTKView` gesture deltas with sub-row fractional offsets. Row-snap on gesture end via `scrollView.scrollToVisible` rounded to nearest row. 1:1 possible.
- **Shell Integration command-jump (⌘PageUp/Down)**: needs OSC 133 markers parsed and stored as command boundaries. slopdesk already has OSC 133 (per CLAUDE.md). Client needs a `commandBoundaries: [Int]` list + jump function; intercept these keys client-side (not forwarded to PTY). 1:1, but depends on Shell Integration being active in the remote shell.

### Partial mapping / caveats

- **Scroll Past Last Line / First Line (overscroll)**: libghostty may not expose a configurable overscroll margin. If not, implement as a client-side scroll-offset clamp adjustment atop libghostty's normal position. The client would:
  1. Track scroll position in "logical rows".
  2. Allow the position to exceed normal top/bottom bounds by a computed margin (e.g. `viewportHeight - 1 row` for "Last Line With Content at top").
  3. Render out-of-bounds region as blank (terminal background).
  4. Detect alternate-screen mode (libghostty terminal state flag) and disable overscroll when active.

  Implementable but wraps libghostty's scroll position rather than using it directly. **Not a 1:1 pass-through** — requires custom scroll-position arithmetic in `TerminalSurface` / `SlopDeskTerminal`.
- **"Same as Scroll Past Last Line" mirror option**: trivial settings-level enum alias, computed at render time. No extra implementation.
- **Remote architecture**: all scroll behaviours are **client-local** — they affect only how the client renders the scrollback buffer libghostty holds. No host-side involvement; the remote host is irrelevant to scroll UX. iOS client gets the same via `TerminalRenderingView` on UIKit.
- **Settings persistence**: GUI-only, no config file. Store in `PreferencesStore` (via `Defaults`, per the established pattern). Keys: `scrollPastLastLine` (enum: disabled/lastLineWithContent/lastLineInMiddle/cursorLine), `scrollPastFirstLine` (enum: disabled/sameAsLast/firstLineWithContent/firstLineInMiddle), `smoothScroll` (bool, default true).
- **Smooth Scroll snap on gesture end**: macOS detects gesture end via `NSScrollView`'s `scrollViewDidEndLiveScrolling` or `NSEvent` `phase == .ended`; iOS via `UIPanGestureRecognizer.state == .ended`. Both round the fractional offset to the nearest row boundary on completion.

### Not directly applicable

- **Settings panel UI** (Settings → Controls → Scroll): SlopDesk uses a different settings architecture (ConfigStore / PreferencesStore). Equivalent UI lives in the macOS Settings window or an in-app preferences panel — a standard SwiftUI `Form`/`Picker` under a "Terminal → Scroll" section.
