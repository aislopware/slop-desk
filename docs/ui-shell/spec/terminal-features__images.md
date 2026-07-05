# Images

## Summary

SlopDesk renders inline images in the terminal viewport (no external viewer) via two protocols: **iTerm2 OSC 1337** and the **Kitty graphics protocol**. **Sixel** is planned, not yet implemented.

---

## Behaviors

- Images render in the terminal cell grid at the cursor (or a specified placement target), at exact integer multiples of cell rows/columns.
- OSC 1337 and Kitty are supported simultaneously.
- **OSC 1337 / iTerm2 protocol:**
  - Base64-encoded PNG, JPEG, or GIF via `\e]1337;File=inline=1:<base64data>\a`.
  - `imgcat` (iTerm2 utilities) is the canonical wrapper; works unchanged.
  - Manual: `printf '\e]1337;File=inline=1:%s\a' "$(base64 < ./icon.png)"`
  - Parameters: `inline`, `name`, `size`, `width`, `height`, `preserveAspectRatio`.
- **Kitty graphics protocol** (richer: cursor placement, cell sizing, z-index, replace, delete by ID):
  - Typical: `kitty +kitten icat ./preview.png` (any Kitty-compatible viewer works).
  - Supported: direct transmission (`t=d`); file (`t=f` / `t=t`); chunked + zlib; formats RGB/RGBA/PNG; placement (cursor, cell size, z-index, placement ID); management (delete by id/placement/all, replace); query (`a=q`); Unicode placeholders (U+10EEEE virtual placement).
  - Planned: shared memory (`t=s`); animation (multi-frame, playback control); relative placement (parent-child chains).
- **Sixel:** planned (bitmap-strip protocol used by `lsix`, `chafa`, `mpv -vo sixel`); not implemented.
- **Performance / caching:**
  - Images upload once per ID and reuse across redraws, even after `clear`.
  - A small atlas caches recently-seen images; very large or rare images bypass it.
  - Inline base64 images >~5 MB encoded should use chunked or file transmission instead.

---

## Keybindings

No image-specific keybindings on this page.

| Action | Keys |
|--------|------|
| (none documented) | — |

---

## Config keys

No image-specific config keys on this page.

| Key | Default | Effect |
|-----|---------|--------|
| (none documented) | — | — |

---

## Visual spec

### Screenshot: `inline-image.png` — "images in bilibili-tui"

macOS app window, native traffic-light controls (red #FF5F57, yellow #FFBD2E, green #28C840) top-left; title "bilibili-tui" centered (black, medium, ~13pt).

**Terminal content area (light theme, bg white/~#FAFAFA):**
- Left sidebar (~40px): vertical monochrome icon-only buttons (dark gray #333/#555 on white), top→bottom home/首页, search/搜索, animation/动态, history/直播, settings/设置. Selected "首页" reads active (subtle highlight / left-border accent).
- Main area: top nav breadcrumb "首页" (left-aligned); section heading "Bilibili 推荐" centered.

**Image grid** — six inline bitmap thumbnails in 3-col × 2-row, equal-width columns, ~80-90px cell height. Each cell: rendered thumbnail, then Chinese title (1-2 lines, ~11-12pt, dark), then view count + duration (muted gray ~#888).
- Row 1: (1) dark samurai scene, "《归原》19分钟完整演示", 439.2万 · 19:27; (2) anime-style two characters, "《沧渊》·《青椰萌宠：边缘行者》歌动PV丨随机播放", 159.8万 · 09:58; (3) pastel anime girl, "人，屋瓜后就不爱放钱包了——《伊莫》猫瓜测试前妻开启", 205.1万 · 01:59.
- Row 2: (1) dark fantasy/nature, "《给神花》第66集 魏国妖民", 170.4万 · 20:27; (2) scenic outdoor/game, "公选定时7月《遥远之海》组长急集播延滚MV「福」遥远之海", 439.2万 · 03:25; (3) group of people (dark), "评论区感觉大禹之火遍全网的佳作，本期精彩评系列也有些就", 439.2万 · 02:04 (partial).

**Bottom status bar:** single line, small monospace (~11pt), dark gray on white — `[↑↓/hjkl] 导航  [Enter] 播放  [r] 刷新  [q] 退出  [t] 切换主题`. This is the app's own hint bar (not slopdesk keybindings); keys in `[…]`.

**Typography / spacing:** monospace terminal cells; grid spacing 1-2 cell widths of whitespace; Chinese chars render full-width (2-column); no artifacts/tearing — images cleanly composited.

**Color palette:** terminal bg white (#FFFFFF/~#FAFAFA); sidebar bg off-white, icons #333/#555; title text ~#1A1A1A, metadata ~#888; status bar ~#555; thumbnails full-color unique bitmaps.

**States:** sidebar "首页" active (darker icon / left-border accent, hard to distinguish at this resolution); no grid image selected (default browse state).

---

## Screenshots

- `inline-image.png`

---

## Implementation notes

### Straightforward

All image protocol behavior is terminal-emulator-side and provided by libghostty, flowing through the `TerminalSurface` seam unchanged.
- **OSC 1337:** libghostty decodes and renders in the cell buffer; no client-side handling.
- **Kitty graphics:** all supported features (direct/file/chunked transmission, RGB/RGBA/PNG, placement, management, query, Unicode placeholders) flow through the libghostty render path transparently.
- **Sixel (planned):** also a libghostty-supported protocol when shipped; track ghostty upstream for status.

### What requires attention in the remote architecture

The terminal process runs on the **macOS host**; the client is a pixel consumer receiving already-rendered output over the video path. It never resolves image protocol semantics.
- **File transmission (`t=f` / `t=t`):** paths resolve on the host (correct — that's where the terminal runs). No client handling.
- **Shared memory (`t=s`, planned):** POSIX shm is host-local via libghostty. No cross-machine concern.
- **Atlas / caching ("uploaded once per ID"):** happens inside libghostty on the host; the video path encodes the rendered frame (images included) as HEVC to the client. Transparent.
- **`clear` (images persist by ID):** host-side libghostty behavior; no client implication.
- **Large images / chunked mode:** the >5 MB chunked/file guidance applies host-side; it reduces escape-sequence byte volume in the terminal stream, benefiting the slopdesk terminal TCP path for image-heavy remote TUIs.
- **iOS client:** libghostty compiles for macOS and iOS; the iOS client renders the same TerminalSurface output. Host-rendered images arrive as ordinary pixel frames — no iOS-specific handling; the iOS client is fully passive.
- **Animation (planned):** multi-frame Kitty updates cells at frame rate (host-side render); SCStream captures the updates to the client. Only needs adequate capture framerate.

### Summary

All image behavior is host-side, provided by libghostty. The slopdesk client is a pixel consumer with no protocol-level interaction — zero client-side implementation work.
