# 35 — Non-overlapping windows & groups (smart-layout QoL)

> **Historical session log. Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

> **STATUS: SUPERSEDED / HISTORICAL.** Canvas-era QoL for free-floating panes. Canvas layout retired → Session→Tab→split ([30](30-infinite-canvas.md), [DECISIONS.md](DECISIONS.md)).

Default-ON QoL setting (`canvas.nonOverlap`): window/group boundaries never overlap on the infinite canvas. Dragging a window **slides flush** along neighbours instead of overlapping; dropping into a cluster **parts the neighbours** to make room. Groups move/resize as a unit and shove other groups clear. Hold **⌘** while dragging to bypass (free-overlap stack). Toggle lives in Settings → Canvas, the View menu, and the pane pill.

## The core insight

The two behaviours need **opposite mass models**, so they are split rather than forced into one weighted-relaxation knob (judged mushy at the boundary, where intuition is strongest):

- **SLIDE** — the dragged thing YIELDS. Live-drag default, every frame.
- **MAKE-SPACE** — the NEIGHBOURS yield. Commit-only (single `.onEnded`), behind an insert-intent gate.

The split also dodges a single weighted-relaxation design's two fatal flaws: no "pinned box re-overlaps a wall" (slide is closed-form flush), and no per-frame whole-canvas re-render (only the dragged box moves live; neighbours move on commit).

## The solver — `CanvasNonOverlap` (pure, deterministic, no SwiftUI)

Sibling of `CanvasSnap` / `CanvasGeometry`. Runs **strictly after** `CanvasSnap`, consuming its snapped frame as the dragged body's target, and **shares the 16pt gutter** so a gutter-snapped box is already at the non-overlap boundary → slide is a no-op at a snap line (the solvers reinforce, never fight).

- **`slide(snapped, from, bodies, config)`** — swept-AABB collide-and-slide (the game "slide along a wall" technique): sweep the box centre (Minkowski-expanded by half-extents + gutter) from the persisted origin to the snapped target; on earliest contact, cancel the into-face velocity component and re-sweep the tangential remainder (≤4 passes, 0.1pt skin back-off, MTV depenetration pre-pass + safety pass). Pure function of `(target, origin, bodies)` — **path-independent**, so `preview ≡ commit` (no mouse-up jump), like `CanvasSnap`.
- **`makeSpace(target, draggedID, bodies, config)`** — intent gate (centre over a neighbour, or wedged between opposing neighbours, with ≥0.5 Muuri-normalized coverage) → `separate`. Returns `nil` when the drop just rests flush (caller commits the slid frame).
- **`separate(pinnedID, pinnedRect, bodies, config)`** — gate-free minimal-movement relaxation: pins the dragged body, flows every other body apart (Jacobi/Gauss-Seidel split by inverse mass, ≤32 iterations). The infinite plane always has room, so it converges. Used by make-space (gated) AND the resize-push (always).
- **`clampResize(frame, anchor, bodies, minSize, config)`** — a resize's growing edge stops one gutter short of any neighbour (slide analogue for resize; the pane yields). Shrinking is never constrained.

Determinism: bodies sorted by a stable `BodyID` key → output independent of input order. Every output frame is sanitized (finite, within `±coordinateBound`, size preserved/floored).

## Groups

Collision bodies = **{ungrouped panes} ∪ {one rigid body per group = its derived bounding box}**, so group-vs-group / pane-vs-group non-overlap falls out of feeding group boxes into the SAME solver. A group body's solved shift is distributed rigidly to all members (`Canvas.applying`). Members of one group are kept non-overlapping by a scoped within-group reflow pass after any member moves/resizes.

`CanvasGroupView` makes the formerly-decorative group box **interactive**: the name-chip is a move handle (whole group slides/parts as a unit), and four corner grips in the clear 16pt padding ring resize the group's footprint (members affinely remapped, then shoved-neighbour + within-group reflow). The dashed frame stays `allowsHitTesting(false)` so panes inside stay fully interactive.

## Integration / invariants

- **preview ≡ commit**: live slide and the `.onEnded` recompute use the same pure inputs (pane drag and group handle move both fold the slide into the live preview). Make-space is commit-only by design (neighbours-part-on-release feel), spring-softened.
- **Per-frame budget**: only the dragged pane re-renders during a pane drag (item-local `@GestureState`); cohort/group-handle members re-render only during their deliberate drag (the established `groupDragOffset` precedent). No new per-pan/scroll whole-canvas dependency.
- **Animation**: non-focused panes spring to their new slot (`.animation(value: pos)`); the focused dragged pane and any live-offset cohort/handle member commit **instant** (non-animated transaction) so the gesture-offset→frame handoff never flashes.
- **⌘ / setting-off**: `Config.disabled` short-circuits every entry point → byte-identical to the prior snap-only behaviour.

## Tests

`CanvasNonOverlapTests` (pure: slide flush/tangential/corner-tuck/path-independence, make-space symmetry, intent gate, order-independence, dense-pack termination, clampResize, group ops, gutter-row slide regression) + `CanvasNonOverlapStoreTests` (move/group/within-group commit paths). All green.

## Known gaps / follow-ups (HW-gated)

Feel-tuning of the constants (insert coverage 0.5, the 120ms neighbour spring, skin/gutter) needs a real rig. Ad-hoc multi-select cohort drag still commits raw (no slide/make-space) — only the first-class PaneGroup handle is non-overlap-aware.
