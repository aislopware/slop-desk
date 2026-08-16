//! The free plane a tab lays its panes out on: the document, and every pure operation on it.
//!
//! Where [`crate::split_tree`] partitions a bound, this places panes freely — a flat set of framed
//! items plus a pan-only camera. Flat rather than recursive is the whole point: closing a pane is a
//! filter, moving one is a rewrite of a single frame, and there is no intermediary node to hand a
//! neighbour's space to.
//!
//! ## z is a field, not the array order
//!
//! Stacking is [`CanvasItem::z`]. If the array order carried it, then a dedup, a re-mint or any
//! future reordering of `items` would silently restack the panes — a change nothing in the code
//! reads as a stacking change. With an explicit field the array is free to be in any order.
//!
//! ## Every op is pure
//!
//! Each returns a NEW canvas. That is what makes the plane's behaviour testable without a client,
//! and it is why an operation that needs a fresh identity takes it as an argument: see
//! [`crate::identity`].

use std::collections::{BTreeMap, BTreeSet};

use crate::canvas_arrange;
use crate::canvas_geometry::placement;
use crate::canvas_non_overlap::{Body, BodyId};
use crate::geometry::{CASCADE_STEP, Camera, DEFAULT_ITEM_SIZE, Point, Rect, Size, sanitize};
use crate::identity::{LayoutPresetId, PaneGroupId, PaneId};
use crate::session::PaneSpec;
use crate::split_layout::SolvedLayout;

/// A named collection of panes — pure metadata.
///
/// It holds no member list: membership lives on each [`CanvasItem`] as an optional group id, so
/// closing a pane drops its membership for free and deleting a group only clears the id off its
/// members. Groups are DISJOINT — a pane is in at most one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneGroup {
    /// Its identity.
    pub id: PaneGroupId,
    /// Its display name.
    pub name: String,
}

impl PaneGroup {
    /// A group under a name.
    #[must_use]
    pub const fn new(id: PaneGroupId, name: String) -> Self {
        Self { id, name }
    }
}

/// One pane placed on the plane.
#[derive(Debug, Clone, PartialEq)]
pub struct CanvasItem {
    /// The pane's identity — the same join key the live registry is keyed by.
    pub id: PaneId,
    /// What the pane is: its kind, title and video binding.
    pub spec: PaneSpec,
    /// Its canvas-space rect. The origin may be negative — the plane is unbounded — and the size IS
    /// the pane's one-to-one on-screen size, which is what drives a terminal's column and row
    /// reflow.
    pub frame: Rect,
    /// Its stacking order. HIGHER is frontmost.
    pub z: i64,
    /// The group it belongs to, or `None` when ungrouped.
    pub group: Option<PaneGroupId>,
}

impl CanvasItem {
    /// An item at a frame and a stacking order, ungrouped.
    #[must_use]
    pub const fn new(id: PaneId, spec: PaneSpec, frame: Rect, z: i64) -> Self {
        Self {
            id,
            spec,
            frame,
            z,
            group: None,
        }
    }

    /// The same item in a group.
    #[must_use]
    pub const fn in_group(mut self, group: Option<PaneGroupId>) -> Self {
        self.group = group;
        self
    }
}

/// Which edge or centre an align operation pulls the panes to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AlignEdge {
    /// Left edges flush.
    Left,
    /// Right edges flush.
    Right,
    /// Top edges flush.
    Top,
    /// Bottom edges flush.
    Bottom,
    /// Centres on one vertical line.
    CenterHorizontal,
    /// Centres on one horizontal line.
    CenterVertical,
}

impl AlignEdge {
    /// Every edge, in the order whose POSITION is the byte that crosses the ABI.
    ///
    /// The shim reads a `u8` off the boundary and Swift writes one, so somewhere the case has to
    /// become a number. Here, once — and by the array's own order, which is why adding a case
    /// cannot be half-done: the length below stops matching, and [`Self::index`]'s exhaustive match
    /// stops compiling. `scripts/check-supervisor.sh` counts the cases on both sides, but a count
    /// is blind to a case that was added everywhere except the shim's decoder; that arm used to be
    /// a hand-written `match` ending in `_ => Left`, so the new edge would have aligned LEFT with
    /// every gate green.
    pub const ALL: [Self; 6] = [
        Self::Left,
        Self::Right,
        Self::Top,
        Self::Bottom,
        Self::CenterHorizontal,
        Self::CenterVertical,
    ];

    /// The byte for this edge.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Left => 0,
            Self::Right => 1,
            Self::Top => 2,
            Self::Bottom => 3,
            Self::CenterHorizontal => 4,
            Self::CenterVertical => 5,
        }
    }

    /// The edge a byte names, or `None` when it names none.
    ///
    /// `None` rather than a default, so the caller decides what an unknown byte means: the shim
    /// falls back to `Left` because a hostile datagram must not panic, and a test that wants to
    /// prove the mapping total can tell "unknown" apart from "left".
    #[must_use]
    pub fn from_index(index: u8) -> Option<Self> {
        Self::ALL.get(usize::from(index)).copied()
    }
}

/// The gutter a tidy leaves between packed panes.
pub const TIDY_GUTTER: f64 = 16.0;

/// One tab's plane: its items and its camera.
#[derive(Debug, Clone, PartialEq)]
pub struct Canvas {
    /// The items. The order is NOT the stacking order — see [`CanvasItem::z`].
    pub items: Vec<CanvasItem>,
    /// The pan offset.
    pub camera: Camera,
}

impl Canvas {
    /// A plane holding these items, at the zero camera.
    #[must_use]
    pub const fn new(items: Vec<CanvasItem>) -> Self {
        Self {
            items,
            camera: Camera::ZERO,
        }
    }

    /// A plane holding these items, at a camera.
    #[must_use]
    pub const fn with_items(items: Vec<CanvasItem>, camera: Camera) -> Self {
        Self { items, camera }
    }

    /// Every pane id in a TOTAL, deterministic order: z ascending, ties broken by id.
    ///
    /// This one order drives the reconcile diff, the carousel's page order and the focus cycle, so
    /// all three agree about what "the next pane" means. The tie-break is what makes it total: two
    /// panes at the same z are common — a restore assigns them in a batch — and without it the
    /// cycle would depend on the array order, which nothing else treats as meaningful.
    #[must_use]
    pub fn all_ids(&self) -> Vec<PaneId> {
        let mut ordered: Vec<(i64, PaneId)> = self.items.iter().map(|item| (item.z, item.id)).collect();
        ordered.sort_unstable();
        ordered.into_iter().map(|(_, id)| id).collect()
    }

    /// How many panes are on the plane.
    #[must_use]
    pub const fn item_count(&self) -> usize {
        self.items.len()
    }

    /// Whether the plane holds this pane.
    #[must_use]
    pub fn contains(&self, id: PaneId) -> bool {
        self.items.iter().any(|item| item.id == id)
    }

    /// The whole item for a pane.
    #[must_use]
    pub fn item(&self, id: PaneId) -> Option<&CanvasItem> {
        self.items.iter().find(|item| item.id == id)
    }

    /// A pane's spec.
    #[must_use]
    pub fn spec_for(&self, id: PaneId) -> Option<&PaneSpec> {
        self.item(id).map(|item| &item.spec)
    }

    /// A pane's canvas-space frame.
    #[must_use]
    pub fn frame_of(&self, id: PaneId) -> Option<Rect> {
        self.item(id).map(|item| item.frame)
    }

    /// The highest stacking order in use, or `None` on an empty plane.
    #[must_use]
    pub fn max_z(&self) -> Option<i64> {
        self.items.iter().map(|item| item.z).max()
    }

    /// The stacking order the next frontmost pane takes.
    ///
    /// Saturating rather than wrapping: a file whose z had been driven to the integer ceiling would
    /// otherwise wrap to the BACK, sending the pane the person just raised behind everything.
    #[must_use]
    pub fn next_z(&self) -> i64 {
        self.max_z().map_or(0, |z| z.saturating_add(1))
    }

    /// The frames keyed by pane — the input the focus resolver reads.
    #[must_use]
    pub fn frames_by_id(&self) -> BTreeMap<PaneId, Rect> {
        self.items.iter().map(|item| (item.id, item.frame)).collect()
    }

    /// The solved layout of the plane, in CANVAS space.
    ///
    /// Canvas space rather than screen space on purpose: directional focus then stays stable across
    /// a pan, and a pane scrolled off the viewport is still reachable from the keyboard.
    #[must_use]
    pub fn solved_layout(&self) -> SolvedLayout {
        SolvedLayout {
            frames: self.frames_by_id(),
        }
    }

    /// The frontmost pane whose frame contains a canvas-space point.
    ///
    /// Walks z DESCENDING — the inverse of the render order — so a click on overlapping panes hits
    /// the one drawn on top rather than the one underneath it.
    #[must_use]
    pub fn hit_test(&self, point: Point) -> Option<PaneId> {
        let mut hit: Option<(i64, PaneId)> = None;
        for item in &self.items {
            if !item.frame.contains(point) {
                continue;
            }
            let key = (item.z, item.id);
            if hit.is_none_or(|best| key > best) {
                hit = Some(key);
            }
        }
        hit.map(|(_, id)| id)
    }

    /// The plane with any pane id already seen re-minted to a fresh one.
    ///
    /// The load-time repair for a file that was copy-pasted or hand-edited. The FIRST occurrence in
    /// array order keeps its id and a later duplicate takes a new one, because the live registry is
    /// keyed one-to-one by pane id: a duplicate would collapse two panes onto one session. It is
    /// lossless in practice — a restored pane always starts idle, so there is no live state to
    /// carry over.
    #[must_use]
    pub fn deduping_item_ids(&self, seen: &mut BTreeSet<PaneId>, mint: &mut impl FnMut() -> PaneId) -> Self {
        let mut items = Vec::with_capacity(self.items.len());
        for item in &self.items {
            if seen.insert(item.id) {
                items.push(item.clone());
                continue;
            }
            let mut fresh = mint();
            let mut attempts = 0_u32;
            while !seen.insert(fresh) && attempts < DUPLICATE_MINT_ATTEMPTS {
                fresh = mint();
                attempts += 1;
            }
            let mut replacement = item.clone();
            replacement.id = fresh;
            items.push(replacement);
        }
        Self::with_items(items, self.camera)
    }
}

/// How many times the dedup asks for a replacement id before it takes what it is given.
const DUPLICATE_MINT_ATTEMPTS: u32 = 8;

impl Canvas {
    /// The plane with a new frontmost pane, placed near another one or at the viewport's centre.
    ///
    /// The caller supplies the identity — this crate mints nothing — and gets the placed plane
    /// back.
    #[must_use]
    pub fn adding(
        &self,
        id: PaneId,
        spec: PaneSpec,
        near: Option<PaneId>,
        viewport: Size,
        size: Size,
    ) -> Self {
        let near_frame = near.and_then(|pane| self.frame_of(pane));
        let existing: Vec<Rect> = self.items.iter().map(|item| item.frame).collect();
        let viewport_rect = Rect::new(self.camera.origin, viewport);
        let placed = placement(near_frame, &existing, viewport_rect, size, CASCADE_STEP);
        let mut items = self.items.clone();
        items.push(CanvasItem::new(id, spec, sanitize(placed), self.next_z()));
        Self::with_items(items, self.camera)
    }

    /// [`adding`](Self::adding) at the default pane size.
    #[must_use]
    pub fn adding_default(&self, id: PaneId, spec: PaneSpec, near: Option<PaneId>, viewport: Size) -> Self {
        self.adding(id, spec, near, viewport, DEFAULT_ITEM_SIZE)
    }

    /// The plane with a closed pane re-added at its exact former frame, frontmost.
    ///
    /// The identity is deliberately a FRESH one rather than the closed pane's. The old pane's
    /// session teardown is asynchronous, so reusing its id could race the in-flight bookkeeping —
    /// and the reopened pane is a new session regardless, since its scrollback did not survive. The
    /// menu says "Reopen", not "Undo", for the same reason.
    #[must_use]
    pub fn restoring(&self, id: PaneId, spec: PaneSpec, frame: Rect, group: Option<PaneGroupId>) -> Self {
        let mut items = self.items.clone();
        items.push(CanvasItem::new(id, spec, sanitize(frame), self.next_z()).in_group(group));
        Self::with_items(items, self.camera)
    }

    /// The plane without a pane, or `None` when it was the LAST one.
    ///
    /// `None` is the signal the tab emptied and should close — an empty plane is not a state the
    /// document represents. An absent id leaves the plane unchanged. Survivors keep their z
    /// verbatim: it is an order, not an index, so nothing needs renumbering.
    #[must_use]
    pub fn removing(&self, id: PaneId) -> Option<Self> {
        if !self.contains(id) {
            return Some(self.clone());
        }
        let survivors: Vec<CanvasItem> = self.items.iter().filter(|item| item.id != id).cloned().collect();
        (!survivors.is_empty()).then(|| Self::with_items(survivors, self.camera))
    }

    /// The plane with a pane translated.
    ///
    /// It does NOT raise the pane — the store composes a raise where that is the policy, so the
    /// policy lives in one place rather than inside every mutation.
    #[must_use]
    pub fn moving_by(&self, id: PaneId, dx: f64, dy: f64) -> Self {
        self.map_item(id, |item| item.frame = sanitize(item.frame.offset_by(dx, dy)))
    }

    /// The plane with a pane's origin set.
    #[must_use]
    pub fn moving_to(&self, id: PaneId, origin: Point) -> Self {
        self.map_item(id, |item| {
            item.frame = sanitize(Rect::new(origin, item.frame.size));
        })
    }

    /// The plane with a pane's frame set, floored at the minimum pane size.
    #[must_use]
    pub fn resizing(&self, id: PaneId, frame: Rect) -> Self {
        self.map_item(id, |item| item.frame = sanitize(frame))
    }

    /// The plane with a pane brought to the front.
    ///
    /// A pane that is ALREADY uniquely on top is left alone rather than re-stamped, so a redundant
    /// focus does not churn the document and wake the debounced save for nothing.
    #[must_use]
    pub fn raising(&self, id: PaneId) -> Self {
        let Some(item) = self.item(id) else {
            return self.clone();
        };
        let top = self.max_z();
        if top == Some(item.z) && self.items.iter().filter(|other| Some(other.z) == top).count() == 1 {
            return self.clone();
        }
        let raised = self.next_z();
        self.map_item(id, |item| item.z = raised)
    }

    /// The plane with a pane's spec transformed — a rename, or a video binding filled in.
    #[must_use]
    pub fn updating_spec(&self, id: PaneId, transform: impl FnOnce(&mut PaneSpec)) -> Self {
        self.map_item(id, |item| transform(&mut item.spec))
    }

    /// The plane with one item transformed, or an identical plane when the id is absent.
    fn map_item(&self, id: PaneId, transform: impl FnOnce(&mut CanvasItem)) -> Self {
        let mut items = self.items.clone();
        if let Some(item) = items.iter_mut().find(|item| item.id == id) {
            transform(item);
        }
        Self::with_items(items, self.camera)
    }
}

impl Canvas {
    /// The plane with the named panes aligned to a shared edge or centre of THEIR bounding box.
    ///
    /// Only the moved axis changes: the perpendicular position and every size stay put. Fewer than
    /// two targets is a no-op, because a single pane's bounding box is itself and aligning it to
    /// itself would move nothing while still churning the document.
    #[must_use]
    pub fn aligning(&self, ids: &BTreeSet<PaneId>, edge: AlignEdge) -> Self {
        self.applying_frames(&canvas_arrange::aligned(&self.targets(ids), edge))
    }

    /// The plane with the named panes spread so the GAPS between adjacent ones are equal.
    ///
    /// The two extremes stay put and the interior panes move, which is what makes the operation
    /// feel like an adjustment rather than a re-layout. Fewer than three targets is a no-op —
    /// there is nothing interior to redistribute.
    ///
    /// When the panes are collectively wider than their spread the even gap would be NEGATIVE,
    /// which would overlap them silently. It is clamped at zero instead, so they pack flush and
    /// the trailing extreme shifts rather than the panes overlapping — the plane's own
    /// non-overlap ethos applied to an arrange command.
    #[must_use]
    pub fn distributing(&self, ids: &BTreeSet<PaneId>, horizontal: bool) -> Self {
        self.applying_frames(&canvas_arrange::distributed(&self.targets(ids), horizontal))
    }

    /// The `(id, frame)` pairs the arrange rules read, in this plane's own item order.
    fn targets(&self, ids: &BTreeSet<PaneId>) -> Vec<(PaneId, Rect)> {
        self.items
            .iter()
            .filter(|item| ids.contains(&item.id))
            .map(|item| (item.id, item.frame))
            .collect()
    }

    /// This plane with each named pane at its new frame. A pane nobody named is untouched.
    #[must_use]
    fn applying_frames(&self, moved: &BTreeMap<PaneId, Rect>) -> Self {
        if moved.is_empty() {
            return self.clone();
        }
        let mut items = self.items.clone();
        for item in &mut items {
            if let Some(frame) = moved.get(&item.id) {
                item.frame = *frame;
            }
        }
        Self::with_items(items, self.camera)
    }
}

impl Canvas {
    /// The plane panned by a screen-space delta.
    ///
    /// There is no scale term anywhere on the camera, so a screen-space delta IS the canvas-space
    /// delta and the translation needs no correction.
    #[must_use]
    pub fn panned(&self, dx: f64, dy: f64) -> Self {
        Self::with_items(self.items.clone(), self.camera.translated(dx, dy).sanitized())
    }

    /// The plane at a camera. The ONE funnel every camera set goes through, so a non-finite or
    /// extreme origin can never reach the document.
    #[must_use]
    pub fn with_camera(&self, camera: Camera) -> Self {
        Self::with_items(self.items.clone(), camera.sanitized())
    }

    /// The plane with the viewport centred on a pane, or unchanged when it is absent.
    #[must_use]
    pub fn centered_on(&self, id: PaneId, viewport: Size) -> Self {
        self.frame_of(id).map_or_else(
            || self.clone(),
            |frame| self.with_camera(camera_centered_on(frame.center(), viewport)),
        )
    }

    /// The plane with the viewport centred on the bounding box of every pane.
    ///
    /// It centres and nothing more: with no scale on the camera there is no fit-to-view, so a box
    /// larger than the viewport stays centred and partly off-screen rather than shrinking.
    #[must_use]
    pub fn centered_on_all(&self, viewport: Size) -> Self {
        self.items_bounding_box().map_or_else(
            || self.clone(),
            |bounds| self.with_camera(camera_centered_on(bounds.center(), viewport)),
        )
    }

    /// Whether NO pane intersects the viewport — the person has panned into empty space and the
    /// recentre affordance should appear.
    #[must_use]
    pub fn needs_recenter(&self, viewport: Size) -> bool {
        let viewport_rect = Rect::new(self.camera.origin, viewport);
        !self.items.iter().any(|item| item.frame.intersects(viewport_rect))
    }

    /// The plane packed into a uniform grid and recentred — the tidy command.
    ///
    /// Each pane keeps its own size and stacking order; only the origins move. Cells are filled in
    /// [`all_ids`](Self::all_ids) order, so a tidy of the same plane always produces the same grid.
    #[must_use]
    pub fn tidied(&self, gutter: f64, viewport: Size) -> Self {
        if self.items.len() < 2 {
            return self.centered_on_all(viewport);
        }
        let items: Vec<(PaneId, Rect)> = self
            .all_ids()
            .into_iter()
            .filter_map(|id| self.frame_of(id).map(|frame| (id, frame)))
            .collect();
        self.applying_frames(&canvas_arrange::tidied(&items, gutter))
            .centered_on_all(viewport)
    }

    /// [`tidied`](Self::tidied) at the standard gutter.
    #[must_use]
    pub fn tidied_default(&self, viewport: Size) -> Self {
        self.tidied(TIDY_GUTTER, viewport)
    }

    /// The box containing every pane's frame, or `None` on an empty plane.
    #[must_use]
    pub fn items_bounding_box(&self) -> Option<Rect> {
        let frames: Vec<Rect> = self.items.iter().map(|item| item.frame).collect();
        canvas_arrange::bounding_box(&frames)
    }
}

/// The camera whose viewport is centred on a canvas-space point.
#[must_use]
pub fn camera_centered_on(point: Point, viewport: Size) -> Camera {
    Camera::new(Point::new(
        point.x - viewport.width / 2.0,
        point.y - viewport.height / 2.0,
    ))
}

/// The body identity the plane's collision solver works in.
pub type CanvasBodyId = BodyId<PaneId, PaneGroupId>;

impl Canvas {
    /// Every pane id in a group — or every UNGROUPED pane, for `None` — in the canonical order.
    #[must_use]
    pub fn ids_in_group(&self, group: Option<PaneGroupId>) -> Vec<PaneId> {
        self.all_ids()
            .into_iter()
            .filter(|id| self.item(*id).is_some_and(|item| item.group == group))
            .collect()
    }

    /// The groups actually referenced by at least one pane.
    ///
    /// What prunes dangling group metadata: a group whose every member was closed still exists as a
    /// name until a load or save compares it against this.
    #[must_use]
    pub fn group_ids_in_use(&self) -> BTreeSet<PaneGroupId> {
        self.items.iter().filter_map(|item| item.group).collect()
    }

    /// The tight box around every pane in a group, or `None` when it has no members.
    #[must_use]
    pub fn group_bounding_box(&self, group: PaneGroupId) -> Option<Rect> {
        let mut frames = self
            .items
            .iter()
            .filter(|item| item.group == Some(group))
            .map(|item| item.frame);
        let first = frames.next()?;
        Some(frames.fold(first, Rect::union))
    }

    /// The plane with a pane assigned to a group, or ungrouped for `None`.
    ///
    /// Disjoint by construction: a pane carries one optional group, so re-assigning MOVES it rather
    /// than adding a second membership. Already being in that group is a no-op.
    #[must_use]
    pub fn assigning(&self, id: PaneId, group: Option<PaneGroupId>) -> Self {
        if self.item(id).is_none_or(|item| item.group == group) {
            return self.clone();
        }
        self.map_item(id, |item| item.group = group)
    }

    /// The plane with a group's membership cleared — the model side of deleting a group.
    ///
    /// Its members survive as ungrouped panes. Deleting a group must never delete panes: the group
    /// is a label over them, not a container of them.
    #[must_use]
    pub fn clearing_group(&self, group: PaneGroupId) -> Self {
        if !self.items.iter().any(|item| item.group == Some(group)) {
            return self.clone();
        }
        let mut items = self.items.clone();
        for item in &mut items {
            if item.group == Some(group) {
                item.group = None;
            }
        }
        Self::with_items(items, self.camera)
    }

    /// The collision bodies for a non-overlap drag: every ungrouped pane, plus ONE body per group's
    /// derived box.
    ///
    /// Feeding the group boxes into the same solver is what makes group-versus-group and
    /// pane-versus-group separation fall out for free, with no second code path. The dragged pane
    /// and its own group are excluded — a member colliding with the box derived from itself would
    /// push against its own position. Bounding the sweep to a region keeps the body count
    /// proportional to what is visible rather than to the whole plane.
    #[must_use]
    pub fn collision_bodies(
        &self,
        excluding_pane: Option<PaneId>,
        excluding_group: Option<PaneGroupId>,
        region: Rect,
        groups: &[PaneGroup],
    ) -> Vec<Body<CanvasBodyId>> {
        let mut bodies = Vec::new();
        for item in &self.items {
            if item.group.is_none() && Some(item.id) != excluding_pane && item.frame.intersects(region) {
                bodies.push(Body::new(BodyId::Pane(item.id), item.frame));
            }
        }
        for group in groups {
            if Some(group.id) == excluding_group {
                continue;
            }
            if let Some(box_rect) = self.group_bounding_box(group.id)
                && box_rect.intersects(region)
            {
                bodies.push(Body::new(BodyId::Group(group.id), box_rect));
            }
        }
        bodies
    }

    /// The plane with a solver result applied, in ONE pass.
    ///
    /// A pane body sets that pane's origin — a move only, its size is preserved. A GROUP body
    /// distributes its box's shift rigidly to every member, so the derived box follows for free and
    /// the group's internal layout is untouched, which is the whole reason a group can be dragged
    /// as a unit.
    #[must_use]
    pub fn applying(&self, resolved: &BTreeMap<CanvasBodyId, Rect>) -> Self {
        let mut pane_origin: BTreeMap<PaneId, Point> = BTreeMap::new();
        let mut group_delta: BTreeMap<PaneGroupId, (f64, f64)> = BTreeMap::new();
        for (body, rect) in resolved {
            match body {
                BodyId::Pane(id) => {
                    pane_origin.insert(*id, rect.origin);
                },
                BodyId::Group(group) => {
                    if let Some(box_rect) = self.group_bounding_box(*group) {
                        group_delta.insert(
                            *group,
                            (rect.min_x() - box_rect.min_x(), rect.min_y() - box_rect.min_y()),
                        );
                    }
                },
            }
        }
        if pane_origin.is_empty() && group_delta.is_empty() {
            return self.clone();
        }
        let mut items = self.items.clone();
        for item in &mut items {
            if let Some(origin) = pane_origin.get(&item.id) {
                item.frame = sanitize(Rect::new(*origin, item.frame.size));
            } else if let Some((dx, dy)) = item.group.and_then(|group| group_delta.get(&group)) {
                item.frame = sanitize(item.frame.offset_by(*dx, *dy));
            }
        }
        Self::with_items(items, self.camera)
    }

    /// The plane with every member of a group translated — the group-handle drag.
    #[must_use]
    pub fn moving_group(&self, group: PaneGroupId, dx: f64, dy: f64) -> Self {
        if dx == 0.0 && dy == 0.0 {
            return self.clone();
        }
        let mut items = self.items.clone();
        for item in &mut items {
            if item.group == Some(group) {
                item.frame = sanitize(item.frame.offset_by(dx, dy));
            }
        }
        Self::with_items(items, self.camera)
    }

    // The group-handle RESIZE is not here. It is a rule over frames, so it lives with the other
    // arrange rules in `canvas_arrange::resized_group`, where the FFI shim reaches it without
    // marshalling a whole document across the boundary to get a handful of frames back.
}

/// A frame fitted entirely inside a box.
///
/// The size is CAPPED to the box but never re-floored, so the minimum-size invariant the caller
/// already established survives whenever the box is at least one pane wide; then the origin is
/// pinned so the frame stays inside on both axes.
#[must_use]
pub fn clamping(frame: Rect, box_rect: Rect) -> Rect {
    let width = frame.size.width.min(box_rect.size.width);
    let height = frame.size.height.min(box_rect.size.height);
    let x = frame.min_x().max(box_rect.min_x()).min(box_rect.max_x() - width);
    let y = frame.min_y().max(box_rect.min_y()).min(box_rect.max_y() - height);
    Rect::xywh(x, y, width, height)
}

/// A named snapshot of a plane, restorable later.
///
/// It holds the layout and nothing about the connection: a layout is host-agnostic, and the one
/// app-global connection persists separately. It is never recursive — a preset holds a plane, not
/// other presets.
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutPreset {
    /// Its identity.
    pub id: LayoutPresetId,
    /// Its display name.
    pub name: String,
    /// The plane it restores.
    pub canvas: Canvas,
    /// The groups the plane's members refer to.
    pub groups: Vec<PaneGroup>,
    /// Which pane had focus.
    pub focused_pane: Option<PaneId>,
    /// When set, the preset switches in the moment a host window owned by this app first appears —
    /// matched case-insensitively, so "monitoring" snaps in when Grafana launches. `None` means it
    /// only ever switches by hand.
    pub trigger_app_name: Option<String>,
}

impl LayoutPreset {
    /// A preset over a plane.
    #[must_use]
    pub const fn new(id: LayoutPresetId, name: String, canvas: Canvas, groups: Vec<PaneGroup>) -> Self {
        Self {
            id,
            name,
            canvas,
            groups,
            focused_pane: None,
            trigger_app_name: None,
        }
    }

    /// Whether a host window belonging to this app should switch the preset in.
    ///
    /// The match is case-insensitive because the app name arrives from the host's window list,
    /// where its capitalization is the app's own and not something the person typed.
    #[must_use]
    pub fn triggered_by(&self, app_name: &str) -> bool {
        self.trigger_app_name
            .as_ref()
            .is_some_and(|trigger| trigger.eq_ignore_ascii_case(app_name))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing pane is a test failure with nothing to return"
    )]
    #![expect(
        clippy::float_cmp,
        reason = "these coordinates are exact sums of exact inputs, so an epsilon would only hide a real \
                  drift"
    )]

    use std::collections::{BTreeMap, BTreeSet};

    use super::{AlignEdge, Canvas, CanvasItem, LayoutPreset, PaneGroup};
    use crate::canvas_geometry::collides;
    use crate::canvas_non_overlap::BodyId;
    use crate::geometry::{Camera, MIN_ITEM_SIZE, Point, Rect, Size};
    use crate::identity::{LayoutPresetId, PaneGroupId, PaneId};
    use crate::session::{PaneKind, PaneSpec};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn group(byte: u8) -> PaneGroupId {
        PaneGroupId::from_bytes([byte; 16])
    }

    fn spec() -> PaneSpec {
        PaneSpec::new(PaneKind::Terminal, "shell".to_owned())
    }

    fn item(byte: u8, frame: Rect, z: i64) -> CanvasItem {
        CanvasItem::new(pane(byte), spec(), frame, z)
    }

    fn plane() -> Canvas {
        Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0),
            item(2, Rect::xywh(500.0, 0.0, 400.0, 300.0), 1),
            item(3, Rect::xywh(0.0, 400.0, 400.0, 300.0), 2),
        ])
    }

    fn ids(list: &[u8]) -> BTreeSet<PaneId> {
        list.iter().copied().map(pane).collect()
    }

    #[test]
    fn the_canonical_order_is_z_then_id() {
        let canvas = Canvas::new(vec![
            item(3, Rect::xywh(0.0, 0.0, 400.0, 300.0), 5),
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 5),
            item(2, Rect::xywh(0.0, 0.0, 400.0, 300.0), 1),
        ]);
        assert_eq!(
            canvas.all_ids(),
            vec![pane(2), pane(1), pane(3)],
            "the id breaks a z tie, so the focus cycle cannot depend on the array order",
        );
    }

    #[test]
    fn a_hit_test_lands_on_the_frontmost_pane_under_the_point() {
        let stacked = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0),
            item(2, Rect::xywh(100.0, 100.0, 400.0, 300.0), 7),
        ]);
        assert_eq!(stacked.hit_test(Point::new(150.0, 150.0)), Some(pane(2)));
        assert_eq!(stacked.hit_test(Point::new(20.0, 20.0)), Some(pane(1)));
        assert!(stacked.hit_test(Point::new(-10.0, -10.0)).is_none());
    }

    #[test]
    fn adding_a_pane_puts_it_in_front_and_never_on_top_of_another() {
        let canvas = plane();
        let grown = canvas.adding_default(pane(9), spec(), Some(pane(1)), Size::new(1600.0, 1000.0));
        assert_eq!(grown.item_count(), 4);
        assert_eq!(grown.max_z(), Some(3));
        let Some(added) = grown.frame_of(pane(9)) else {
            panic!("the pane was added");
        };
        let existing: Vec<Rect> = [pane(1), pane(2), pane(3)]
            .into_iter()
            .filter_map(|id| grown.frame_of(id))
            .collect();
        assert_eq!(existing.len(), 3, "the existing panes survive");
        assert!(
            !collides(added, &existing),
            "placement must not drop a pane substantially onto another",
        );
    }

    #[test]
    fn removing_the_last_pane_reports_the_tab_emptied() {
        let single = Canvas::new(vec![item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0)]);
        assert!(
            single.removing(pane(1)).is_none(),
            "None is the signal to close the tab, not a failure",
        );
    }

    #[test]
    fn removing_an_absent_pane_leaves_the_plane_alone() {
        assert_eq!(plane().removing(pane(9)), Some(plane()));
    }

    #[test]
    fn survivors_keep_their_stacking_order_verbatim() {
        let Some(rest) = plane().removing(pane(2)) else {
            panic!("two panes survive");
        };
        assert_eq!(rest.item(pane(3)).map(|item| item.z), Some(2));
    }

    #[test]
    fn raising_a_pane_that_is_already_uniquely_on_top_changes_nothing() {
        let canvas = plane();
        assert_eq!(
            canvas.raising(pane(3)),
            canvas,
            "a redundant focus must not churn the document"
        );
        assert_ne!(canvas.raising(pane(1)), canvas);
    }

    #[test]
    fn raising_a_pane_that_merely_ties_for_top_still_lifts_it() {
        let tied = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 4),
            item(2, Rect::xywh(0.0, 0.0, 400.0, 300.0), 4),
        ]);
        assert_eq!(tied.raising(pane(1)).item(pane(1)).map(|item| item.z), Some(5));
    }

    #[test]
    fn the_next_stacking_order_saturates_rather_than_wrapping_to_the_back() {
        let extreme = Canvas::new(vec![item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), i64::MAX)]);
        assert_eq!(extreme.next_z(), i64::MAX);
    }

    #[test]
    fn a_moved_pane_keeps_its_size_and_a_resized_one_floors() {
        let moved = plane().moving_by(pane(1), 25.0, -10.0);
        assert_eq!(
            moved.frame_of(pane(1)),
            Some(Rect::xywh(25.0, -10.0, 400.0, 300.0))
        );
        let squashed = plane().resizing(pane(1), Rect::xywh(0.0, 0.0, 10.0, 10.0));
        assert_eq!(
            squashed.frame_of(pane(1)).map(|frame| frame.size),
            Some(MIN_ITEM_SIZE)
        );
    }

    #[test]
    fn a_duplicate_pane_id_is_re_minted_and_the_first_one_keeps_its_place() {
        let duplicated = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0),
            item(1, Rect::xywh(500.0, 0.0, 400.0, 300.0), 1),
        ]);
        let mut seen = BTreeSet::new();
        let mut next = 50_u8;
        let repaired = duplicated.deduping_item_ids(&mut seen, &mut || {
            let id = pane(next);
            next += 1;
            id
        });
        assert_eq!(repaired.all_ids(), vec![pane(1), pane(50)]);
        assert_eq!(
            repaired.frame_of(pane(50)),
            Some(Rect::xywh(500.0, 0.0, 400.0, 300.0)),
            "the re-minted pane keeps its own frame, not the first one's",
        );
    }

    #[test]
    fn aligning_moves_one_axis_and_leaves_the_other_and_every_size_alone() {
        let canvas = plane().aligning(&ids(&[1, 2]), AlignEdge::Bottom);
        assert_eq!(canvas.frame_of(pane(1)), Some(Rect::xywh(0.0, 0.0, 400.0, 300.0)));
        assert_eq!(
            canvas.frame_of(pane(2)),
            Some(Rect::xywh(500.0, 0.0, 400.0, 300.0))
        );
        let mixed = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0),
            item(2, Rect::xywh(500.0, 100.0, 200.0, 140.0), 1),
        ]);
        let bottom = mixed.aligning(&ids(&[1, 2]), AlignEdge::Bottom);
        assert_eq!(
            bottom.frame_of(pane(2)),
            Some(Rect::xywh(500.0, 160.0, 200.0, 140.0)),
            "the shorter pane's bottom meets the box's, and its size and x are untouched",
        );
    }

    #[test]
    fn aligning_fewer_than_two_panes_is_a_no_op() {
        let canvas = plane();
        assert_eq!(canvas.aligning(&ids(&[1]), AlignEdge::Left), canvas);
        assert_eq!(canvas.aligning(&BTreeSet::new(), AlignEdge::Left), canvas);
    }

    #[test]
    fn distributing_equalises_the_gaps_and_pins_the_extremes() {
        let row = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 100.0, 100.0), 0),
            item(2, Rect::xywh(150.0, 0.0, 100.0, 100.0), 1),
            item(3, Rect::xywh(700.0, 0.0, 100.0, 100.0), 2),
        ]);
        let spread = row.distributing(&ids(&[1, 2, 3]), true);
        assert_eq!(spread.frame_of(pane(1)).map(Rect::min_x), Some(0.0));
        assert_eq!(spread.frame_of(pane(3)).map(Rect::min_x), Some(700.0));
        assert_eq!(
            spread.frame_of(pane(2)).map(Rect::min_x),
            Some(350.0),
            "two equal gaps of 250 between three 100-wide panes spanning 800",
        );
    }

    #[test]
    fn panes_wider_than_their_spread_pack_flush_rather_than_overlapping() {
        let crowded = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 100.0), 0),
            item(2, Rect::xywh(10.0, 0.0, 400.0, 100.0), 1),
            item(3, Rect::xywh(20.0, 0.0, 400.0, 100.0), 2),
        ]);
        let packed = crowded.distributing(&ids(&[1, 2, 3]), true);
        assert_eq!(packed.frame_of(pane(2)).map(Rect::min_x), Some(400.0));
        assert_eq!(packed.frame_of(pane(3)).map(Rect::min_x), Some(800.0));
    }

    #[test]
    fn distributing_fewer_than_three_panes_is_a_no_op() {
        let canvas = plane();
        assert_eq!(canvas.distributing(&ids(&[1, 2]), true), canvas);
    }

    #[test]
    fn centring_puts_the_pane_in_the_middle_of_the_viewport() {
        let viewport = Size::new(1000.0, 800.0);
        let centred = plane().centered_on(pane(1), viewport);
        assert_eq!(centred.camera.origin, Point::new(200.0 - 500.0, 150.0 - 400.0));
    }

    #[test]
    fn recentring_is_offered_only_once_every_pane_has_left_the_viewport() {
        let viewport = Size::new(1000.0, 800.0);
        assert!(!plane().needs_recenter(viewport));
        assert!(plane().panned(50_000.0, 50_000.0).needs_recenter(viewport));
    }

    #[test]
    fn a_tidy_packs_a_square_grid_in_the_canonical_order() {
        let tidied = plane().tidied(16.0, Size::new(1600.0, 1000.0));
        // Three panes → two columns; the widest pane is 400 and the tallest 300.
        let Some(second) = tidied.frame_of(pane(2)) else {
            panic!("every pane survives a tidy");
        };
        let Some(third) = tidied.frame_of(pane(3)) else {
            panic!("every pane survives a tidy");
        };
        let Some(first) = tidied.frame_of(pane(1)) else {
            panic!("every pane survives a tidy");
        };
        assert_eq!(second.min_x() - first.min_x(), 416.0);
        assert_eq!(third.min_y() - first.min_y(), 316.0);
        assert_eq!(
            third.min_x(),
            first.min_x(),
            "the third pane wraps to the next row"
        );
    }

    #[test]
    fn a_tidy_preserves_every_size_and_stacking_order() {
        let tidied = plane().tidied_default(Size::new(1600.0, 1000.0));
        for byte in [1_u8, 2, 3] {
            assert_eq!(
                tidied.item(pane(byte)).map(|item| (item.frame.size, item.z)),
                plane().item(pane(byte)).map(|item| (item.frame.size, item.z)),
            );
        }
    }

    #[test]
    fn a_group_box_is_derived_from_its_members_and_disappears_with_them() {
        let grouped = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0).in_group(Some(group(1))),
            item(2, Rect::xywh(500.0, 100.0, 400.0, 300.0), 1).in_group(Some(group(1))),
            item(3, Rect::xywh(0.0, 800.0, 400.0, 300.0), 2),
        ]);
        assert_eq!(
            grouped.group_bounding_box(group(1)),
            Some(Rect::xywh(0.0, 0.0, 900.0, 400.0))
        );
        assert!(
            grouped
                .clearing_group(group(1))
                .group_bounding_box(group(1))
                .is_none()
        );
        assert_eq!(
            grouped.clearing_group(group(1)).item_count(),
            3,
            "deleting a group must never delete its panes",
        );
    }

    #[test]
    fn a_group_lists_its_members_and_the_ungrouped_bucket_lists_the_rest() {
        let grouped = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0).in_group(Some(group(1))),
            item(2, Rect::xywh(500.0, 0.0, 400.0, 300.0), 1),
        ]);
        assert_eq!(grouped.ids_in_group(Some(group(1))), vec![pane(1)]);
        assert_eq!(grouped.ids_in_group(None), vec![pane(2)]);
        assert_eq!(grouped.group_ids_in_use(), BTreeSet::from([group(1)]));
    }

    #[test]
    fn assigning_moves_a_pane_between_groups_rather_than_adding_a_second_membership() {
        let grouped = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0).in_group(Some(group(1))),
        ]);
        let moved = grouped.assigning(pane(1), Some(group(2)));
        assert_eq!(moved.item(pane(1)).and_then(|item| item.group), Some(group(2)));
        assert!(moved.group_bounding_box(group(1)).is_none());
        assert_eq!(
            moved.assigning(pane(1), Some(group(2))),
            moved,
            "a re-assign is a no-op"
        );
    }

    #[test]
    fn a_group_body_stands_in_for_its_members_and_the_dragged_ones_are_excluded() {
        let grouped = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0).in_group(Some(group(1))),
            item(2, Rect::xywh(500.0, 0.0, 400.0, 300.0), 1),
            item(3, Rect::xywh(1000.0, 0.0, 400.0, 300.0), 2),
        ]);
        let groups = [PaneGroup::new(group(1), "left".to_owned())];
        let region = Rect::xywh(-1000.0, -1000.0, 5000.0, 5000.0);
        let bodies = grouped.collision_bodies(Some(pane(3)), None, region, &groups);
        let names: Vec<BodyId<PaneId, PaneGroupId>> = bodies.iter().map(|body| body.id).collect();
        assert_eq!(names, vec![BodyId::Pane(pane(2)), BodyId::Group(group(1))]);
        let without_own_group = grouped.collision_bodies(Some(pane(1)), Some(group(1)), region, &groups);
        assert_eq!(
            without_own_group.len(),
            2,
            "the pane's own group box is not a body it collides with"
        );
    }

    #[test]
    fn a_group_body_shift_moves_every_member_rigidly() {
        let grouped = Canvas::new(vec![
            item(1, Rect::xywh(0.0, 0.0, 400.0, 300.0), 0).in_group(Some(group(1))),
            item(2, Rect::xywh(500.0, 0.0, 400.0, 300.0), 1).in_group(Some(group(1))),
        ]);
        let mut resolved = BTreeMap::new();
        resolved.insert(BodyId::Group(group(1)), Rect::xywh(100.0, 50.0, 900.0, 300.0));
        let shifted = grouped.applying(&resolved);
        assert_eq!(
            shifted.frame_of(pane(1)),
            Some(Rect::xywh(100.0, 50.0, 400.0, 300.0))
        );
        assert_eq!(
            shifted.frame_of(pane(2)),
            Some(Rect::xywh(600.0, 50.0, 400.0, 300.0))
        );
    }

    #[test]
    fn a_pane_body_sets_the_origin_and_never_the_size() {
        let mut resolved = BTreeMap::new();
        resolved.insert(BodyId::Pane(pane(1)), Rect::xywh(70.0, 80.0, 9.0, 9.0));
        let moved = plane().applying(&resolved);
        assert_eq!(
            moved.frame_of(pane(1)),
            Some(Rect::xywh(70.0, 80.0, 400.0, 300.0))
        );
    }

    /// The two halves of the ABI byte agree, and the mapping is total both ways.
    ///
    /// `ALL` and [`AlignEdge::index`] are separately written — one an array, one a match — so this
    /// is what ties them together. A case added to the array but not to the match will not compile;
    /// a case added to both in DIFFERENT positions compiles fine and fails here, which is the only
    /// way that mistake is visible at all: the byte would cross the boundary meaning another edge.
    #[test]
    fn every_align_edge_round_trips_through_its_abi_byte() {
        for (position, edge) in AlignEdge::ALL.iter().enumerate() {
            assert_eq!(
                usize::from(edge.index()),
                position,
                "{edge:?} is at position {position}"
            );
            assert_eq!(AlignEdge::from_index(edge.index()), Some(*edge));
        }
        let past_the_end = AlignEdge::ALL
            .last()
            .map_or(0, |edge| edge.index().saturating_add(1));
        assert_eq!(
            AlignEdge::from_index(past_the_end),
            None,
            "a byte naming no case must read as none, not as the last one"
        );
        assert_eq!(AlignEdge::from_index(u8::MAX), None);
    }

    #[test]
    fn a_camera_set_always_goes_through_sanitation() {
        let wild = plane().with_camera(Camera::new(Point::new(f64::NAN, f64::INFINITY)));
        assert_eq!(wild.camera.origin, Point::new(0.0, 0.0));
    }

    #[test]
    fn a_preset_triggers_on_its_app_whatever_the_capitalization() {
        let mut preset = LayoutPreset::new(
            LayoutPresetId::from_bytes([1; 16]),
            "monitoring".to_owned(),
            plane(),
            Vec::new(),
        );
        assert!(
            !preset.triggered_by("Grafana"),
            "no trigger means it only switches by hand"
        );
        preset.trigger_app_name = Some("grafana".to_owned());
        assert!(preset.triggered_by("Grafana"));
        assert!(!preset.triggered_by("Prometheus"));
    }
}
