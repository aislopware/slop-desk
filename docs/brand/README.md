# SlopDesk brand

Mark = **Slopcat**: a stand-less remote screen that grew small cat ears; the face is
the shell prompt itself — `❯` winking eye, `▁` cursor eye. Flat, one colour,
mono/neutral on purpose (chosen 2026-07-31 after the liquid-glass and Signal-S
directions were retired; lineage: otty's glyph-face, neko/kitty's cat, GitHub's
mascot pragmatism).

| File | Role |
|------|------|
| `logo-slopcat.svg` | The mark. `currentColor` with real cutout holes — drop it on any background, invert freely. Also the source for favicon and the macOS menu-bar template image (solid black + alpha). |
| `appicon-slopcat.svg` | Static app-icon mock: paper plate `#F2F1EC`, ink mark `#23262B`. |
| `SlopDesk.icon` | **Ship source** for the dock icon (all three app targets reference it from `Apps/*/project.yml`): Icon Composer bundle — solid paper fill + one flat `slopcat.png` layer (1024²); Tahoe applies its own material/shadow around flat art. Open in Icon Composer (Xcode 26) to preview default/dark/tinted. |

Palette: ink `#23262B` · paper `#F2F1EC`. No accent colour in the mark — colour
stays reserved for live-data semantics inside the app (MERIDIAN L1).

Geometry (viewBox 256): screen `rect x56 y68 w144 h120 rx30`; ears
`M 74 76 L 81 46 Q 98 54 112 70 Z` (+ mirrored), rounded via stroke-join; eye
`M 90 111 L 114 128 L 90 145` (w13, round caps); cursor `rect x140 y134 w34 h11 r5.5`.
Ear/eye/cursor cuts are mask holes, not paint — keep it that way so the mark stays
one-colour and background-agnostic.
