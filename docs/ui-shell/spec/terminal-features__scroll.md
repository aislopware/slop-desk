# Scroll

## Summary

How SlopDesk handles scrollback and the scroll gesture. Everything is configured in the GUI (Settings → Controls → Scroll) — no config file needed. Three behavioral knobs control overscroll at the bottom, overscroll at the top, and pixel-smooth vs. row-snap rendering. Separate keyboard shortcuts handle page-wise, line-wise, and command-jump navigation. New output or any typing snaps the viewport back to the bottom automatically.

## Behaviors

- **Scroll keys**: keyboard shortcuts navigate the scrollback buffer (page, top/bottom, command-jump); see Keybindings table.
- **Auto-snap to bottom**: any new output arriving or any keypress (character input) snaps the viewport back to the bottom of the buffer.
- **Scroll Past Last Line** (disabled by default): allows scrolling beyond the last line of content so the final row (or cursor row) floats up from the window edge. Four options: Disabled (clamp), Last Line With Content (bottom-most text row lands at viewport top), Last Line In Middle (that row at vertical centre), Cursor Line (cursor row lands at top even if on a blank line). Automatically disabled on the alternate screen so full-screen TUIs (vim, htop, less) are unaffected.
- **Scroll Past First Line** (disabled by default): symmetric overscroll at the top of scrollback, pushing the oldest history row down into the viewport. Four options: Disabled (clamp at scrollback top), Same as Scroll Past Last Line (mirrors the other setting so only one knob must be tuned), First Line With Content (topmost history row lands at viewport bottom), First Line In Middle (topmost row lands at vertical centre).
- **Smooth Scroll** (enabled by default): scrolls at sub-row (pixel) granularity during the gesture; snaps back to a row boundary when the gesture ends so glyphs stay pixel-aligned. Disabling reverts to classic whole-row-at-a-time jumping.
- **Shell Integration command-jump** (⌘PageUp / ⌘PageDown): requires Shell Integration to be active; jumps directly to the previous or next command boundary in scrollback.
- **Alternate-screen isolation**: Scroll Past Last Line is automatically suppressed on the alternate screen so full-screen TUI applications (vim, htop, less, etc.) keep their own bottom edge intact.

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

All settings live in **Settings → Controls → Scroll**. There is no config-file key — all values are GUI-only preferences.

| Key (UI label) | Default | Effect |
|---|---|---|
| Scroll Past Last Line | Disabled | Controls overscroll past the last line. Options: Disabled (clamp at buffer bottom), Last Line With Content (prompt row at viewport top), Last Line In Middle (prompt row at vertical centre), Cursor Line (cursor row at top, including blank lines). Suppressed automatically on the alternate screen. |
| Scroll Past First Line | Disabled | Controls overscroll past the first (oldest) line of scrollback. Options: Disabled (clamp at scrollback top), Same as Scroll Past Last Line (mirrors that setting), First Line With Content (topmost history row at viewport bottom), First Line In Middle (topmost row at vertical centre). |
| Smooth Scroll | On (enabled) | When on: pixel-granularity scrolling during gesture, snaps to row boundary on gesture end. When off: whole-row-at-a-time jumping (classic behaviour). |

## Visual spec

### scroll-past-last-line video

**Frame 1 (initial state — normal scroll position):**
A macOS window with native traffic-light close/minimize/zoom buttons (red/yellow/green circles, ~12 px diameter) in the top-left corner. Title bar shows "abner@MacBook-Pro: ~/Workspace/slopdesk" in a muted grey, centred. The terminal surface has a near-white background (~#F9F9F9 / off-white, light theme). The terminal content is a dense `ls -la` listing (directory listing with permissions, owner, size, date, filename columns) occupying the visible area top-to-bottom with no blank rows — all rows used, prompt and cursor at the very bottom-left. No scrollbar visible in this frame. Font is monospaced at approximately 13 px. Filenames include syntax-coloured items: cyan for `.github`, green for `target`, standard dark-grey for everything else. The window has generous rounded corners (~12 px radius) and sits on a light grey macOS desktop backdrop with a soft shadow.

**Frame end (Scroll Past Last Line active — overscroll applied):**
Same window chrome and light theme. After scrolling past the last line, the terminal content has scrolled so that only the **prompt line** (`~/Workspace/slopdesk (main x)●+↑ ▷`) appears near the **top-left** of the terminal surface, with the cursor block visible after the prompt marker. The rest of the viewport below the prompt is **entirely blank** (the off-white background with no text content). A thin vertical scrollbar thumb (~8 px wide, rounded, medium grey ~#B0B0B0) is visible on the **right edge** of the terminal, positioned near the bottom — indicating the user is near the end of the scroll range. This is the "Last Line With Content" variant: the last content row sits at the top of the viewport, leaving the majority of the pane empty below it.

### scroll-past-first-line video

**Frame 1 (normal scroll position):**
Same macOS light-theme window. Terminal surface is densely filled from top to bottom with a `ls -la` directory listing identical in style to the above. All rows occupied, cursor at bottom. Traffic lights at top-left, centred title bar. No overscroll applied.

**Frame end (Scroll Past First Line active — overscroll at top):**
The terminal has been scrolled to the very top of scrollback and then beyond. The **upper portion** of the terminal is blank (near-white background, no text). Partway down the pane, the oldest history rows appear: a shell prompt line `~/Workspace/slopdesk (main x)●+↑ ▷ lsa` then the `lsa` output (`total 232`, `drwxr-xr-x 26 abner staff  8328 Jun  7 14:22 .`, etc.). The blank region above the first content row is the overscroll gap — the oldest history row has been pushed down to either the viewport bottom or centre depending on the mode option. This is the "First Line In Middle" variant: topmost history lands mid-pane, with a blank region filling the space above it. The light-theme colours and monospaced font are identical.

### scroll-smooth-off video

**Frame 1 (Smooth Scroll disabled — mid-scroll):**
macOS light-theme window, traffic-light buttons visible (red/yellow/green but smaller, lighter due to window focus state). Terminal shows markdown-formatted text content — a CREDITS/LICENSE listing showing a table of dependencies (`| Source | Entries | License |` etc.) with `##` headings. Text snaps to exact row boundaries; no partial-row rendering. Mid-scroll position showing roughly 10–12 rows of monospaced text. No motion blur — each frame shows clean row-aligned text.

**Frame end (Smooth Scroll disabled — settled):**
Same content visible, now stably at a row-aligned position. Still showing markdown table rows for a project CREDITS file. Font rendering is crisp with no sub-pixel offset. The lack of pixel-granularity is the defining visual characteristic (though this is motion behaviour observable only in the video).

### scroll-smooth-on video

**Frame 1 (Smooth Scroll enabled — mid-scroll):**
Same macOS light-theme window, traffic-light buttons in top-left. Terminal shows the same CREDITS/dependency listing content — a long list of Swift Package Manager dependencies with GitHub URLs and licence types, formatted as a markdown-style table. The scroll position is mid-buffer. Smooth Scroll is on: during the gesture, rows are visible at sub-pixel offsets (partial top/bottom row clipping at viewport edge), giving fluid motion.

**Frame end (Smooth Scroll enabled — settled at row boundary):**
The viewport has settled. The topmost visible row is pixel-aligned to a row boundary (no clipping). Shows a `ls -la` directory listing at the bottom of scrollback — `drwxr-xr-x 26 abner staff` entries. Content is clean and pixel-sharp, confirming the snap-to-row-boundary behaviour when the gesture ends. This is visually identical to the non-smooth version at rest; the difference is purely kinetic during the gesture.

### Common visual elements across all scroll videos

- **Window chrome**: macOS native window with rounded corners (~12 px), light grey backdrop shadow, traffic-light buttons (red `#FF5F57`, yellow `#FFBD2E`, green `#28C840`) at top-left.
- **Title bar**: Single-line centred title "abner@MacBook-Pro: ~/Workspace/slopdesk" in medium grey, no additional icons.
- **Terminal background**: Off-white / near-white, approximately `#F8F8F8` or `#FAFAFA` — a light theme default.
- **Terminal font**: Monospaced, approximately 13 px, with standard ANSI colour assignments: cyan for paths/directories, green for certain filenames, standard dark grey/black for body text.
- **Scrollbar**: Thin rounded thumb (~8 px wide), medium grey, appears at the right edge only during/after scrolling (macOS overlay scrollbar behaviour — auto-hide when idle).
- **Prompt style**: `~/Workspace/slopdesk (main x)●+↑ ▷` — coloured segments (cyan for path, purple/pink for git branch status characters `●+↑`, green triangle `▷` as prompt chevron). Shell Integration glyphs are active.
- **No visible Settings UI in these videos** — all configuration is shown only as the behavioural result, not as a settings panel.

## Screenshots

Saved files (extracted frames from mp4 videos):
- `scroll-past-last-line-frame1.png` — initial state, dense ls listing, cursor at bottom
- `scroll-past-last-line-frame-end.png` — Scroll Past Last Line active: prompt at viewport top, blank space below, scrollbar thumb visible
- `scroll-past-first-line-frame1.png` — initial state, dense ls listing
- `scroll-past-first-line-frame-end.png` — Scroll Past First Line active: blank space above first content row
- `scroll-smooth-off-frame1.png` — Smooth Scroll off, mid-scroll in markdown/credits content
- `scroll-smooth-off-frame-end.png` — Smooth Scroll off, settled at row boundary
- `scroll-smooth-on-frame1.png` — Smooth Scroll on, mid-scroll, dependency table content
- `scroll-smooth-on-frame-end.png` — Smooth Scroll on, settled at row boundary (ls listing)

Source videos (also saved):
- `scroll-past-last-line.mp4`
- `scroll-past-first-line.mp4`
- `scroll-smooth-off.mp4`
- `scroll-smooth-on.mp4`

## SlopDesk mapping notes

### Mappable 1:1

- **Keybindings (⇧PageUp/Down, ⇧Home/End)**: These are standard VT key sequences (`CSI 5~`, `CSI 6~`, `CSI 1~`, `CSI 4~` with Shift modifier). libghostty handles scrollback natively; the slopdesk client can intercept these before forwarding to the PTY and route them to libghostty's `scrollPageUp`/`scrollPageDown`/`scrollToTop`/`scrollToBottom` scroll APIs. Full 1:1 mapping.

- **Auto-snap to bottom on output/typing**: libghostty's terminal surface already implements scroll-to-bottom on new output and on keypress input. This is default behaviour of any conformant terminal emulator. No extra work needed.

- **Smooth Scroll on/off**: libghostty exposes a `scrollMultiplier` / pixel-scroll API. The macOS client renders via `TerminalRenderingView`; pixel-granular scrolling can be driven by `NSScrollView` or `MTKView` scroll gesture deltas with sub-row fractional offsets. Row-snap on gesture end is implementable via `scrollView.scrollToVisible` rounding to the nearest row boundary. 1:1 mapping possible.

- **Shell Integration command-jump (⌘PageUp/Down)**: Requires OSC 133 shell integration markers to be parsed and stored as command boundaries in the scrollback. slopdesk already has OSC 133 support (per CLAUDE.md). The client needs a `commandBoundaries: [Int]` list and a jump function. These key events must be intercepted client-side (not forwarded to the PTY). 1:1 mapping, but depends on Shell Integration being active in the remote shell.

### Partial mapping / caveats

- **Scroll Past Last Line / First Line (overscroll)**: libghostty may or may not expose a configurable overscroll margin. If it does not, this must be implemented as a client-side scroll offset clamp adjustment on top of libghostty's normal scroll position. The slopdesk client would need to:
  1. Track the scroll position in "logical rows" units.
  2. Allow the position to exceed the normal top/bottom bounds by a computed margin (e.g., `viewportHeight - 1 row` for "Last Line With Content at top").
  3. Render the out-of-bounds region as blank (terminal background colour).
  4. Detect alternate-screen mode (libghostty exposes this as a terminal state flag) and disable overscroll when active.
  
  This is implementable but requires wrapping libghostty's scroll position rather than using it directly. **Not a 1:1 libghostty pass-through** — requires custom scroll-position arithmetic in `TerminalSurface` / `SlopDeskTerminal`.

- **"Same as Scroll Past Last Line" mirror option**: A trivial settings-level enum alias — the effective value is computed at render time. No special implementation needed beyond the settings model.

- **Remote architecture**: All scroll behaviours described here are **client-local** — they affect only how the client terminal viewport renders the scrollback buffer that libghostty holds. No host-side involvement is needed. The remote macOS host is irrelevant to scroll UX. iOS client gets the same implementation via `TerminalRenderingView` on UIKit.

- **Settings persistence**: These are GUI-only preferences with no config file. SlopDesk should store them in `PreferencesStore` (via the `Defaults` product, consistent with the established pattern). Keys: `scrollPastLastLine` (enum: disabled/lastLineWithContent/lastLineInMiddle/cursorLine), `scrollPastFirstLine` (enum: disabled/sameAsLast/firstLineWithContent/firstLineInMiddle), `smoothScroll` (bool, default true).

- **Smooth Scroll snap on gesture end**: On macOS the gesture end is detected via `NSScrollView`'s `scrollViewDidEndLiveScrolling` or `NSEvent`'s `phase == .ended`. On iOS (trackpad/scroll gesture), `UIPanGestureRecognizer.state == .ended`. Both platforms need to round the fractional scroll offset to the nearest row boundary on gesture completion.

### Not directly applicable

- **Settings panel UI** (Settings → Controls → Scroll): SlopDesk uses a different settings architecture (ConfigStore / PreferencesStore). The equivalent UI would live in the macOS Settings window or an in-app preferences panel — implement as a standard SwiftUI `Form`/`Picker` under a "Terminal → Scroll" section.
