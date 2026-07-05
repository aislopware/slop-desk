# Images

## Summary

SlopDesk supports inline images inside the terminal viewport via two protocols: **iTerm2's OSC 1337** and the **Kitty graphics protocol**. Both render bitmap images directly in terminal cell grids with no external viewer. A third protocol — **Sixel** — is planned but not yet implemented.

---

## Behaviors

- Inline images are rendered inside the terminal cell grid at the cursor position (or a specified placement target).
- Two protocols are supported simultaneously: OSC 1337 (iTerm2) and Kitty graphics protocol.
- **OSC 1337 / iTerm2 protocol:**
  - Accepts base64-encoded PNG, JPEG, or GIF payloads delivered via the `\e]1337;File=inline=1:<base64data>\a` escape sequence.
  - The `imgcat` utility (ships with iTerm2 utilities) is the canonical convenience wrapper and works in slopdesk unchanged.
  - Manual invocation: `printf '\e]1337;File=inline=1:%s\a' "$(base64 < ./icon.png)"`
  - Supported parameters: `inline`, `name`, `size`, `width`, `height`, `preserveAspectRatio`.
- **Kitty graphics protocol:**
  - Richer feature set: placement at cursor, cell-based sizing, z-index, replacement, and deletion by image ID.
  - Typical invocation: `kitty +kitten icat ./preview.png` (any Kitty-compatible viewer works).
  - Implemented features:
    - Transmission: direct (`t=d`) — supported.
    - Transmission: file (`t=f` / `t=t`) — supported.
    - Transmission: chunked, zlib — supported.
    - Transmission: shared memory (`t=s`) — planned.
    - Formats: RGB, RGBA, PNG — supported.
    - Placement (cursor, cell size, z-index, placement ID) — supported.
    - Management (delete by id / placement / all, replace) — supported.
    - Query / capability response (`a=q`) — supported.
    - Unicode placeholders (U+10EEEE virtual placement) — supported.
    - Animation (multi-frame, playback control) — planned.
    - Relative placement (parent-child chains) — planned.
- **Sixel protocol:** planned (bitmap-strip protocol used by `lsix`, `chafa`, `mpv -vo sixel`); not yet implemented.
- **Performance / caching:**
  - Images are uploaded once per ID and reused across redraws, even after a `clear` command.
  - A small atlas caches recently-seen images; very large or rare images bypass the atlas.
  - `printf`-based (inline base64) images larger than ~5 MB encoded should use chunked or file transmission mode instead.

---

## Keybindings

No image-specific keybindings are documented on this page.

| Action | Keys |
|--------|------|
| (none documented) | — |

---

## Config keys

No image-specific config keys are documented on this page.

| Key | Default | Effect |
|-----|---------|--------|
| (none documented) | — | — |

---

## Visual spec

### Screenshot: `inline-image.png` — "images in bilibili-tui"

**Overall layout:**
A standard macOS app window with native traffic-light window controls (red/yellow/green) in the top-left. The window title bar shows "bilibili-tui" centered. The window has a white/light background matching a typical macOS app chrome.

**Title bar:**
- Three traffic-light buttons (red #FF5F57, yellow #FFBD2E, green #28C840) in the top-left corner.
- Window title "bilibili-tui" centered in the title bar in black text, medium weight, ~13pt.

**Terminal content area:**
- White/very-light-gray background (#FAFAFA or similar); the terminal is running in a light theme.
- Left sidebar: a narrow vertical strip (~40px wide) with monochrome icon buttons arranged vertically. Icons visible from top to bottom: home/首页, search/搜索, animation/动态 (or similar), history/直播, settings/设置 — each is a compact icon-only button in dark gray on white. The currently selected item ("首页") appears highlighted with a vertical bar accent or slightly bolder treatment.
- Main content area to the right of the sidebar, divided into:
  - A top navigation row: breadcrumb text "首页" in Chinese, left-aligned.
  - A section heading "Bilibili 推荐" (Bilibili Recommendations) centered in the content.

**Image grid:**
- Six thumbnail images arranged in a 3-column × 2-row grid filling the main content area.
- Each cell contains:
  - A rendered inline image (actual bitmap, not a placeholder) — these are video/content thumbnails from Bilibili, varying in subject (anime, documentary, music video, etc.). Image sizes are equal-width columns with consistent height (~80-90px rendered cell height).
  - Below each image: a title in Chinese text (1-2 lines), smaller font (~11-12pt), dark gray/black.
  - A view count (e.g., "439.2万") and duration (e.g., "19:27") displayed below the title in smaller muted gray text.
- Row 1 thumbnails (left to right):
  1. A dark samurai/warrior scene with Chinese title "《归原》19分钟完整演示"; 439.2万 · 19:27
  2. A colorful anime-style image with two characters; "《沧渊》·《青椰萌宠：边缘行者》歌动PV丨随机播放"; 159.8万 · 09:58
  3. A pastel-colored anime girl illustration; "人，屋瓜后就不爱放钱包了——《伊莫》猫瓜测试前妻开启"; 205.1万 · 01:59
- Row 2 thumbnails (left to right):
  1. A dark fantasy/nature scene; "《给神花》第66集 魏国妖民"; 170.4万 · 20:27
  2. A scenic outdoor/game image; "公选定时7月《遥远之海》组长急集播延滚MV「福」遥远之海"; 439.2万 · 03:25
  3. A group of people (dark scene); "评论区感觉大禹之火遍全网的佳作，本期精彩评系列也有些就"; 439.2万 · 02:04 (partial text)

**Bottom status / keybinding bar:**
- A single line at the very bottom of the terminal content area, in small monospace text (~11pt), dark gray on white.
- Content: `[↑↓/hjkl] 导航  [Enter] 播放  [r] 刷新  [q] 退出  [t] 切换主题`
- This is a standard terminal UI hint bar showing the app's own keybindings (not slopdesk keybindings).
- Keys are shown in square brackets `[…]` in slightly lighter or same weight as the label text.

**Typography / spacing:**
- Font: monospace (terminal cells), consistent with a standard terminal grid.
- The inline images occupy exact integer multiples of terminal cell rows/columns.
- Grid spacing between thumbnail cells is 1-2 terminal cell widths of whitespace.
- Chinese characters render at full-width (2-column) cell width as expected.
- No visible pixel artifacts or tearing at image boundaries — images are cleanly composited.

**Color palette visible:**
- Window background / terminal bg: white (#FFFFFF or ~#FAFAFA).
- Sidebar background: slightly off-white or same as terminal bg; icons in #333 or #555.
- Text: dark (~#1A1A1A for titles, ~#888 for metadata).
- Status bar text: ~#555.
- Thumbnail images: full-color bitmaps, each unique.

**Selected/active states:**
- Sidebar: "首页" (home) entry appears to have a subtle highlight (darker icon or left-border accent — hard to distinguish at this resolution, but the icon reads as active).
- No image is selected/focused in the grid (the screenshot shows a default browse state).

---

## Screenshots

- `inline-image.png`

---

## Implementation notes

### Straightforward

- **OSC 1337 (iTerm2 inline images):** libghostty supports OSC 1337 — this passes through the `TerminalSurface` seam unchanged. The host terminal process emits the escape, libghostty decodes and renders it in the terminal cell buffer. No client-side special handling required beyond what ghostty already provides.
- **Kitty graphics protocol:** libghostty (ghostty's terminal engine) implements the Kitty graphics protocol. All currently-supported Kitty features (direct/file/chunked transmission, RGB/RGBA/PNG, placement, management, query, Unicode placeholders) flow through the libghostty render path transparently.
- **Sixel (planned):** When slopdesk ships Sixel support, it will also be a protocol that libghostty can support. Track ghostty upstream for Sixel implementation status.

### What requires attention in the remote architecture

- **File transmission mode (`t=f` / `t=t`):** Kitty `t=f` (file path) and `t=t` (temp file) reference **local filesystem paths** on the machine running the terminal process. In slopdesk's architecture, the terminal process runs on the **macOS host**, so file paths are resolved on the host — this is correct. The slopdesk client receives the already-rendered pixel/cell output via the video path; it never needs to resolve image file paths itself. No special handling needed.
- **Shared memory (`t=s`, planned):** Kitty shared-memory transmission uses POSIX shared memory on the host. This is again host-local and resolved by libghostty on the host machine. The slopdesk client is unaffected. No cross-machine concern.
- **Image atlas / caching ("uploaded once per ID"):** Image upload and atlas management happens entirely inside libghostty on the host, driven by the escape sequences in the terminal data stream. The slopdesk video path encodes the terminal frame output (including rendered images) as HEVC and streams it to the client. The client decodes pixels; it has no awareness of image protocol semantics. This is transparent.
- **`clear` behavior (images persist by ID):** Kitty image persistence after `clear` is libghostty behavior on the host. No client-side implication.
- **Large images / chunked mode:** Performance guidance (>5 MB use chunked/file mode) applies to the app running on the host. Relevant if slopdesk users run image-heavy TUI apps remotely — chunked/file mode reduces the escape-sequence byte volume in the terminal stream, which is beneficial for the slopdesk terminal TCP path.
- **iOS client:** libghostty is compiled for both macOS and iOS targets in slopdesk. The iOS client renders the same TerminalSurface output. Inline images rendered by libghostty on the host appear in the video stream delivered to the iOS client as ordinary pixel frames — no iOS-specific image protocol handling is needed. The iOS client is fully passive here.
- **Animation (planned):** Multi-frame Kitty animation will require libghostty to update cell contents at animation frame rate. This is host-side rendering; the slopdesk video capture path (SCStream) naturally captures the frame updates and delivers them to the client. No special handling beyond ensuring capture framerate is adequate.

### Summary

All image protocol behavior in this feature is terminal-emulator-side (host-side in slopdesk's model) and is provided by libghostty. The slopdesk client is a pixel consumer; it has no protocol-level interaction with OSC 1337 or Kitty graphics. This feature is implemented entirely at the host terminal layer with zero client-side implementation work.
