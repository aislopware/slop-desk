//! The client's workspace file: what a layout looks like on disk, and how a corrupt one comes back.
//!
//! The counterpart to the host's document file. Same rule, opposite half: the host persists the
//! CELLS, this persists the ARRANGEMENT — the plane, the panes on it, the split trees, the presets.
//! [`crate::json`] carries why the format is JSON at all.
//!
//! ## Validate-then-repair, never trap
//!
//! Everything here decodes DEFENSIVELY. A workspace file is the one input a person can open in an
//! editor, and it can also be a file from a build that has moved on. So:
//!
//! - A retired pane kind — `claudeCode`, `web`, `chooser`, `remoteGUI`, `systemDialog` — comes back
//!   as a terminal rather than failing the load. Those panes were all terminals underneath; the
//!   file naming one is a file from before the kind was retired, not a corrupt file.
//! - A frame that is NaN, infinite, or smaller than a pane can be is sanitized on the way in, so
//!   nothing unrenderable ever reaches the layout.
//! - A split tree past the depth cap collapses to its first leaf; a duplicate pane id anywhere in
//!   the tree is re-minted, because the live registry is keyed one-to-one by pane id.
//! - A stacking order is clamped, so a hostile `z` of `i64::MAX` cannot make the next
//!   frontmost-bump overflow.
//!
//! What is NOT repaired is a structurally impossible document — a split node with neither
//! discriminator, a missing pane id. That is a fault, and the caller's answer is the default
//! workspace plus the old file kept aside. Repairing it would mean inventing a layout and claiming
//! it was restored.

use crate::canvas::{Canvas, CanvasItem, LayoutPreset, PaneGroup};
use crate::geometry::{self, Camera, Point, Rect, Size};
use crate::identity::{LayoutPresetId, PaneGroupId, PaneId, SplitNodeId};
use crate::json::{Json, JsonError, Result, object};
use crate::session::{PaneKind, PaneSpec, VideoEndpoint};
use crate::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

/// The magnitude a decoded stacking order is clamped into.
///
/// Far above any real stacking depth — a pane count is dozens — and far below the point where the
/// frontmost-bump `max_z + 1` could overflow. Without it a hand-edited `i64::MAX` survives decode
/// and turns the very next raise into a wrap.
pub const Z_BOUND: i64 = 1_000_000_000;

/// The retired pane-kind discriminators an older file may still carry.
///
/// Every one of them named a pane that was a terminal underneath, so folding them to `terminal` is
/// exactly what the build that retired the kind already did in memory. Any OTHER unknown value is
/// still a fault — that is genuine corruption, and the loader's reset path handles it.
const RETIRED_PANE_KINDS: [&str; 5] = ["claudeCode", "web", "chooser", "remoteGUI", "systemDialog"];

const fn malformed(hint: &'static str) -> JsonError {
    JsonError::from_hint(hint)
}

fn field<'a>(value: &'a Json, key: &'static str) -> Result<&'a Json> {
    value
        .get(key)
        .ok_or_else(|| malformed("a required key is missing"))
}

fn text(value: &Json, key: &'static str) -> Result<String> {
    field(value, key)?
        .string()
        .map(str::to_owned)
        .ok_or_else(|| malformed("a key that must be a string is not one"))
}

/// A number that need not be there, and a value for when it is not.
///
/// Missing and present-but-not-a-number are the same answer on purpose: this is a persisted-data
/// reader, and a `"nan"` where a coordinate belongs means the same thing to the layout as no
/// coordinate at all.
fn number_or(value: &Json, key: &str, fallback: f64) -> f64 {
    match value.get(key) {
        Some(Json::Number(number)) => *number,
        Some(Json::Integer(integer)) => {
            #[expect(
                clippy::cast_precision_loss,
                reason = "a coordinate past 2^53 is already past the coordinate bound the sanitizer clamps \
                          to"
            )]
            let widened = *integer as f64;
            widened
        },
        _ => fallback,
    }
}

// ---------------------------------------------------------------------------------------------- //
// Identity
// ---------------------------------------------------------------------------------------------- //

/// The `{"raw": "<uuid>"}` shape Swift's single-field id structs synthesized.
///
/// Kept rather than flattened to a bare string: every workspace file on disk is written this way,
/// and the format is not worth a migration that could only ever lose somebody's layout.
fn encode_id(raw: [u8; 16]) -> Json {
    object([("raw", Json::String(crate::identity::uuid_text(raw)))])
}

fn decode_id(value: &Json, key: &'static str) -> Result<[u8; 16]> {
    let wrapped = field(value, key)?;
    let raw = text(wrapped, "raw")?;
    crate::identity::parse_uuid(&raw).ok_or_else(|| malformed("an id is not a uuid"))
}

fn decode_optional_id(value: &Json, key: &str) -> Option<[u8; 16]> {
    crate::identity::parse_uuid(value.get(key)?.get("raw")?.string()?)
}

// ---------------------------------------------------------------------------------------------- //
// Pane kind, video endpoint, spec
// ---------------------------------------------------------------------------------------------- //

/// The kind's stable, human-readable discriminator.
#[must_use]
pub const fn pane_kind_name(kind: PaneKind) -> &'static str {
    match kind {
        PaneKind::Terminal => "terminal",
        PaneKind::Desktop => "desktop",
    }
}

/// A kind from its discriminator, folding every retired one to a terminal.
///
/// # Errors
/// [`JsonError`] for a discriminator this build has never had — corruption rather than age.
pub fn decode_pane_kind(raw: &str) -> Result<PaneKind> {
    match raw {
        "terminal" => Ok(PaneKind::Terminal),
        "desktop" => Ok(PaneKind::Desktop),
        retired if RETIRED_PANE_KINDS.contains(&retired) => Ok(PaneKind::Terminal),
        _ => Err(malformed("unknown pane kind")),
    }
}

fn encode_video(endpoint: &VideoEndpoint) -> Json {
    let mut members = vec![
        ("windowID", Json::Integer(i64::from(endpoint.window_id))),
        ("title", Json::String(endpoint.title.clone())),
        ("appName", Json::String(endpoint.app_name.clone())),
    ];
    // Absent rather than `null` when unset, which is what Swift's synthesized encoder wrote for an
    // optional — and it keeps an older file's window-shaped endpoints byte-identical after a save.
    if let Some(display) = endpoint.display_id {
        members.push(("displayID", Json::Integer(i64::from(display))));
    }
    Json::Object(
        members
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

fn decode_video(value: &Json) -> Result<VideoEndpoint> {
    let window_id = value
        .get("windowID")
        .and_then(Json::integer)
        .and_then(|raw| u32::try_from(raw).ok())
        .unwrap_or(0);
    let display_id = value
        .get("displayID")
        .and_then(Json::integer)
        .and_then(|raw| u32::try_from(raw).ok());
    Ok(VideoEndpoint {
        window_id,
        title: text(value, "title")?,
        app_name: value
            .get("appName")
            .and_then(Json::string)
            .unwrap_or_default()
            .to_owned(),
        display_id,
    })
}

/// One pane's intent as JSON.
#[must_use]
pub fn encode_spec(spec: &PaneSpec) -> Json {
    let mut members = vec![
        (
            "kind".to_owned(),
            Json::String(pane_kind_name(spec.kind).to_owned()),
        ),
        ("title".to_owned(), Json::String(spec.title.clone())),
    ];
    if let Some(video) = spec.video.as_ref() {
        members.push(("video".to_owned(), encode_video(video)));
    }
    // Written only when TRUE, so a never-renamed pane's row stays minimal and the absence reads as
    // what it means: nobody has claimed this title.
    if spec.user_renamed {
        members.push(("userRenamed".to_owned(), Json::Bool(true)));
    }
    Json::Object(members.into_iter().collect())
}

/// One pane's intent from JSON.
///
/// # Errors
/// [`JsonError`] for a missing kind or title, or a kind this build has never had.
pub fn decode_spec(value: &Json) -> Result<PaneSpec> {
    let kind = decode_pane_kind(&text(value, "kind")?)?;
    let video = match value.get("video") {
        Some(Json::Null) | None => None,
        Some(present) => Some(decode_video(present)?),
    };
    Ok(PaneSpec {
        kind,
        title: text(value, "title")?,
        video,
        user_renamed: matches!(value.get("userRenamed"), Some(Json::Bool(true))),
    })
}

// ---------------------------------------------------------------------------------------------- //
// Split tree
// ---------------------------------------------------------------------------------------------- //

/// A child's share as the self-describing `{"flex": n}` / `{"fixed": n}` object.
///
/// A discriminated object rather than a bare number so the persisted file says which KIND of share
/// it is — a reviewer reading `{"fixed": 100}` knows it is a hundred points, where `100` alone
/// could be either.
#[must_use]
pub fn encode_weight(weight: SplitWeight) -> Json {
    match weight {
        SplitWeight::Flex(share) => object([("flex", Json::Number(share))]),
        SplitWeight::Fixed(points) => object([("fixed", Json::Number(points))]),
    }
}

/// A child's share, repaired.
///
/// A weight of the WRONG TYPE — a `"nan"` string where a number belongs — folds into the
/// equal-share default rather than failing the load: one bad divider position is not worth losing
/// the whole layout, and the repair puts it exactly where a fresh split would have.
#[must_use]
pub fn decode_weight(value: &Json) -> SplitWeight {
    if value.get("flex").is_some() {
        return SplitWeight::Flex(number_or(value, "flex", f64::NAN)).repaired();
    }
    if value.get("fixed").is_some() {
        return SplitWeight::Fixed(number_or(value, "fixed", 0.0)).repaired();
    }
    SplitWeight::Flex(1.0)
}

/// A split tree as the one-key discriminator shape — `{"leaf": …}` or `{"split": {…}}`.
#[must_use]
pub fn encode_split_node(node: &SplitNode) -> Json {
    match node {
        SplitNode::Leaf(id) => object([("leaf", encode_id(id.bytes()))]),
        SplitNode::Split { id, axis, children } => {
            object([(
                "split",
                object([
                    ("id", encode_id(id.bytes())),
                    (
                        "axis",
                        Json::String(
                            match axis {
                                SplitAxis::Horizontal => "horizontal",
                                SplitAxis::Vertical => "vertical",
                            }
                            .to_owned(),
                        ),
                    ),
                    (
                        "children",
                        Json::Array(
                            children
                                .iter()
                                .map(|child| {
                                    object([
                                        ("weight", encode_weight(child.weight)),
                                        ("node", encode_split_node(&child.node)),
                                    ])
                                })
                                .collect(),
                        ),
                    ),
                ]),
            )])
        },
    }
}

/// A split tree, repaired from the root.
///
/// The RAW shape is read first and the repair runs ONCE over the whole result. Repairing bottom-up
/// per node instead would defeat both halves of it: the depth cap needs to know how far down it is,
/// and the duplicate-id sweep needs the ids accepted everywhere else in the tree, not just in one
/// split.
///
/// `mint` supplies the fresh pane ids a repair needs — for a re-minted duplicate, and for the
/// degenerate case where the whole tree repairs away to nothing.
///
/// # Errors
/// [`JsonError`] for a node with neither discriminator, an id that is not a uuid, or nesting past
/// [`crate::json::MAX_DEPTH`] — the parser refuses that before a value ever exists.
pub fn decode_split_node(value: &Json, mint: &mut impl FnMut() -> PaneId) -> Result<SplitNode> {
    let raw = decode_raw_node(value)?;
    Ok(raw.normalized(mint).unwrap_or_else(|| SplitNode::Leaf(mint())))
}

fn decode_raw_node(value: &Json) -> Result<SplitNode> {
    if value.get("leaf").is_some() {
        return Ok(SplitNode::Leaf(PaneId::from_bytes(decode_id(value, "leaf")?)));
    }
    let Some(split) = value.get("split") else {
        return Err(malformed("a split node has neither a leaf nor a split"));
    };
    // A missing id or axis is FILLED rather than refused: the structure is intact, and a node whose
    // divider group lost its name still describes a real arrangement.
    let id = decode_optional_id(split, "id")
        .map_or_else(|| SplitNodeId::from_bytes([0; 16]), SplitNodeId::from_bytes);
    let axis = match split.get("axis").and_then(Json::string) {
        Some("vertical") => SplitAxis::Vertical,
        _ => SplitAxis::Horizontal,
    };
    let mut children = Vec::new();
    for child in split.get("children").and_then(Json::array).unwrap_or_default() {
        let Some(node) = child.get("node") else {
            return Err(malformed("a split child has no node"));
        };
        children.push(WeightedChild::new(
            child.get("weight").map_or(SplitWeight::Flex(1.0), decode_weight),
            decode_raw_node(node)?,
        ));
    }
    Ok(SplitNode::Split { id, axis, children })
}

// ---------------------------------------------------------------------------------------------- //
// Canvas
// ---------------------------------------------------------------------------------------------- //

fn encode_point(point: Point) -> Json {
    object([("x", Json::Number(point.x)), ("y", Json::Number(point.y))])
}

fn decode_point(value: Option<&Json>) -> Point {
    let Some(value) = value else {
        return Point::ZERO;
    };
    Point::new(number_or(value, "x", 0.0), number_or(value, "y", 0.0))
}

fn encode_rect(rect: Rect) -> Json {
    object([
        ("origin", encode_point(rect.origin)),
        (
            "size",
            object([
                ("width", Json::Number(rect.size.width)),
                ("height", Json::Number(rect.size.height)),
            ]),
        ),
    ])
}

fn decode_rect(value: Option<&Json>) -> Rect {
    let Some(value) = value else {
        return Rect::new(Point::ZERO, geometry::MIN_ITEM_SIZE);
    };
    let size = value.get("size").map_or(geometry::MIN_ITEM_SIZE, |size| {
        Size::new(
            number_or(size, "width", f64::NAN),
            number_or(size, "height", f64::NAN),
        )
    });
    Rect::new(decode_point(value.get("origin")), size)
}

/// The camera as the readable `{"origin": {"x": …, "y": …}}`.
#[must_use]
pub fn encode_camera(camera: Camera) -> Json {
    object([("origin", encode_point(camera.origin))])
}

/// The camera, sanitized.
///
/// A corrupt non-finite or extreme origin is clamped rather than refused, so it can never later
/// overflow a bounding-box union or make the next SAVE write a number the reader would reject.
#[must_use]
pub fn decode_camera(value: Option<&Json>) -> Camera {
    Camera::new(decode_point(value.and_then(|camera| camera.get("origin")))).sanitized()
}

/// One pane on the plane.
#[must_use]
pub fn encode_item(item: &CanvasItem) -> Json {
    let mut members = vec![
        ("id".to_owned(), encode_id(item.id.bytes())),
        ("spec".to_owned(), encode_spec(&item.spec)),
        ("frame".to_owned(), encode_rect(item.frame)),
        ("z".to_owned(), Json::Integer(item.z)),
    ];
    // Omitted entirely for an ungrouped pane, which keeps the file minimal and makes the round trip
    // stable rather than turning every ungrouped pane into a `"groupID": null` line.
    if let Some(group) = item.group {
        members.push(("groupID".to_owned(), encode_id(group.bytes())));
    }
    Json::Object(members.into_iter().collect())
}

/// One pane on the plane, with its frame sanitized and its stacking order clamped.
///
/// # Errors
/// [`JsonError`] for a missing or malformed pane id or spec — the two things a pane cannot be
/// restored without.
pub fn decode_item(value: &Json) -> Result<CanvasItem> {
    let id = PaneId::from_bytes(decode_id(value, "id")?);
    let spec = decode_spec(field(value, "spec")?)?;
    let z = value
        .get("z")
        .and_then(Json::integer)
        .unwrap_or(0)
        .clamp(-Z_BOUND, Z_BOUND);
    let mut item = CanvasItem::new(id, spec, geometry::sanitize(decode_rect(value.get("frame"))), z);
    item.group = decode_optional_id(value, "groupID").map(PaneGroupId::from_bytes);
    Ok(item)
}

/// The whole plane.
#[must_use]
pub fn encode_canvas(canvas: &Canvas) -> Json {
    object([
        (
            "items",
            Json::Array(canvas.items.iter().map(encode_item).collect()),
        ),
        ("camera", encode_camera(canvas.camera)),
    ])
}

/// The whole plane, repaired.
///
/// An EMPTY canvas is a valid state, not a fault: the plane is the single workspace root, so
/// closing the last pane legitimately leaves zero items, and that must round-trip to the empty
/// state rather than resetting somebody's camera. The camera key itself is optional so a
/// hand-authored or older file without one decodes to the un-panned camera.
///
/// # Errors
/// [`JsonError`] when `items` is missing or is not an array, or when any item will not decode.
pub fn decode_canvas(value: &Json) -> Result<Canvas> {
    let Some(items) = field(value, "items")?.array() else {
        return Err(malformed("a canvas's items are not an array"));
    };
    let mut decoded = Vec::with_capacity(items.len());
    for item in items {
        decoded.push(decode_item(item)?);
    }
    Ok(Canvas::with_items(decoded, decode_camera(value.get("camera"))))
}

// ---------------------------------------------------------------------------------------------- //
// Groups and presets
// ---------------------------------------------------------------------------------------------- //

/// A named collection of panes.
#[must_use]
pub fn encode_group(group: &PaneGroup) -> Json {
    object([
        ("id", encode_id(group.id.bytes())),
        ("name", Json::String(group.name.clone())),
    ])
}

/// A named collection of panes.
///
/// # Errors
/// [`JsonError`] for a missing id or name.
pub fn decode_group(value: &Json) -> Result<PaneGroup> {
    Ok(PaneGroup::new(
        PaneGroupId::from_bytes(decode_id(value, "id")?),
        text(value, "name")?,
    ))
}

/// A saved layout.
#[must_use]
pub fn encode_preset(preset: &LayoutPreset) -> Json {
    let mut members = vec![
        // The preset's own id is a BARE uuid string — it was a plain `UUID` where the pane ids were
        // single-field structs, and the file shape follows the type it was written from.
        ("id".to_owned(), Json::String(preset.id.text())),
        ("name".to_owned(), Json::String(preset.name.clone())),
        ("canvas".to_owned(), encode_canvas(&preset.canvas)),
        (
            "groups".to_owned(),
            Json::Array(preset.groups.iter().map(encode_group).collect()),
        ),
    ];
    if let Some(focused) = preset.focused_pane {
        members.push(("focusedPane".to_owned(), encode_id(focused.bytes())));
    }
    if let Some(trigger) = preset.trigger_app_name.as_ref() {
        members.push(("triggerAppName".to_owned(), Json::String(trigger.clone())));
    }
    Json::Object(members.into_iter().collect())
}

/// A saved layout.
///
/// # Errors
/// [`JsonError`] for a missing id, name or canvas, or a canvas that will not decode.
pub fn decode_preset(value: &Json) -> Result<LayoutPreset> {
    let id = LayoutPresetId::from_text(&text(value, "id")?)
        .ok_or_else(|| malformed("a preset id is not a uuid"))?;
    let mut groups = Vec::new();
    for group in value.get("groups").and_then(Json::array).unwrap_or_default() {
        groups.push(decode_group(group)?);
    }
    Ok(LayoutPreset {
        id,
        name: text(value, "name")?,
        canvas: decode_canvas(field(value, "canvas")?)?,
        groups,
        focused_pane: decode_optional_id(value, "focusedPane").map(PaneId::from_bytes),
        trigger_app_name: value
            .get("triggerAppName")
            .and_then(Json::string)
            .map(str::to_owned),
    })
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a refused decode in a round-trip test has nothing to return"
    )]

    use super::{
        Z_BOUND, decode_canvas, decode_group, decode_item, decode_pane_kind, decode_preset, decode_spec,
        decode_split_node, decode_weight, encode_canvas, encode_group, encode_item, encode_preset,
        encode_spec, encode_split_node, encode_weight,
    };
    use crate::canvas::{Canvas, CanvasItem, LayoutPreset, PaneGroup};
    use crate::geometry::{Camera, MIN_ITEM_SIZE, Point, Rect, Size};
    use crate::identity::{LayoutPresetId, PaneGroupId, PaneId, SplitNodeId};
    use crate::json::{Json, object, parse, to_pretty_string};
    use crate::session::{PaneKind, PaneSpec, VideoEndpoint};
    use crate::split_tree::{MAX_DEPTH, MIN_WEIGHT, SplitAxis, SplitNode, SplitWeight, WeightedChild};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    /// A deterministic stand-in for the runtime's entropy — the repair passes only need the ids to
    /// be FRESH, and a counter is fresh enough while staying replayable.
    fn minter() -> impl FnMut() -> PaneId {
        let mut next = 200_u8;
        move || {
            next = next.wrapping_add(1);
            PaneId::from_bytes([next; 16])
        }
    }

    fn spec() -> PaneSpec {
        PaneSpec::new(PaneKind::Terminal, "Terminal")
    }

    fn tree() -> SplitNode {
        SplitNode::Split {
            id: SplitNodeId::from_bytes([9; 16]),
            axis: SplitAxis::Horizontal,
            children: vec![
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
                WeightedChild::new(SplitWeight::Flex(2.0), SplitNode::Split {
                    id: SplitNodeId::from_bytes([8; 16]),
                    axis: SplitAxis::Vertical,
                    children: vec![
                        WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
                        WeightedChild::new(SplitWeight::Fixed(120.0), SplitNode::Leaf(pane(3))),
                    ],
                }),
            ],
        }
    }

    #[test]
    fn a_healthy_tree_round_trips_and_re_encodes_to_the_same_bytes() {
        let original = tree();
        let text = to_pretty_string(&encode_split_node(&original));
        let Ok(parsed) = parse(&text) else {
            panic!("what this module wrote, the parser reads");
        };
        let Ok(back) = decode_split_node(&parsed, &mut minter()) else {
            panic!("a well-formed tree decodes");
        };
        assert_eq!(back, original);
        assert_eq!(
            to_pretty_string(&encode_split_node(&back)),
            text,
            "the round trip is stable"
        );
    }

    #[test]
    fn the_tree_is_written_in_the_shape_already_on_disk() {
        let text = to_pretty_string(&encode_split_node(&SplitNode::Leaf(pane(1))));
        assert!(text.contains("\"leaf\""), "the discriminator names the case");
        assert!(text.contains("\"raw\""), "an id is the single-field struct shape");
        assert!(
            text.contains("01010101-0101-0101-0101-010101010101"),
            "and the uuid is the canonical uppercase text: {text}",
        );
    }

    #[test]
    fn a_node_with_neither_discriminator_is_a_fault_rather_than_a_guess() {
        let Ok(value) = parse("{\"branch\": 1}") else {
            panic!("the json itself is fine; it is the SHAPE that is wrong");
        };
        assert!(decode_split_node(&value, &mut minter()).is_err());
    }

    #[test]
    fn a_duplicate_pane_id_anywhere_in_the_tree_is_re_minted() {
        let aliased = SplitNode::Split {
            id: SplitNodeId::from_bytes([9; 16]),
            axis: SplitAxis::Horizontal,
            children: vec![
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            ],
        };
        let Ok(back) = decode_split_node(&encode_split_node(&aliased), &mut minter()) else {
            panic!("a duplicate is repaired, not refused");
        };
        let leaves = back.all_pane_ids();
        assert_eq!(leaves.len(), 2);
        assert_ne!(
            leaves.first(),
            leaves.last(),
            "the registry is keyed one-to-one by pane id"
        );
    }

    #[test]
    fn a_weight_that_is_not_a_number_folds_to_the_equal_share() {
        assert_eq!(
            decode_weight(&object([("flex", Json::String("nan".to_owned()))])),
            SplitWeight::Flex(MIN_WEIGHT)
        );
        assert_eq!(
            decode_weight(&object([("flex", Json::Number(-3.0))])),
            SplitWeight::Flex(MIN_WEIGHT)
        );
        assert_eq!(
            decode_weight(&object([("nothing", Json::Null)])),
            SplitWeight::Flex(1.0)
        );
        assert_eq!(
            decode_weight(&object([("fixed", Json::Number(-1.0))])),
            SplitWeight::Fixed(0.0)
        );
    }

    #[test]
    fn a_weight_round_trips_through_its_discriminated_shape() {
        for weight in [SplitWeight::Flex(2.5), SplitWeight::Fixed(120.0)] {
            assert_eq!(decode_weight(&encode_weight(weight)), weight);
        }
    }

    #[test]
    fn a_tree_past_the_depth_cap_collapses_rather_than_losing_a_live_pane_later() {
        let mut node = SplitNode::Leaf(pane(1));
        for step in 0..(MAX_DEPTH + 6) {
            let other = pane(u8::try_from(step % 200).unwrap_or(0) + 20);
            node = SplitNode::Split {
                id: SplitNodeId::from_bytes([u8::try_from(step % 250).unwrap_or(0); 16]),
                axis: SplitAxis::Vertical,
                children: vec![
                    WeightedChild::new(SplitWeight::Flex(1.0), node),
                    WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(other)),
                ],
            };
        }
        let Ok(back) = decode_split_node(&encode_split_node(&node), &mut minter()) else {
            panic!("an over-deep tree repairs rather than failing");
        };
        assert!(
            back.depth() <= MAX_DEPTH,
            "the renderer's recursion stays shallow"
        );
    }

    #[test]
    fn every_retired_pane_kind_comes_back_as_a_terminal() {
        for retired in ["claudeCode", "web", "chooser", "remoteGUI", "systemDialog"] {
            assert_eq!(
                decode_pane_kind(retired),
                Ok(PaneKind::Terminal),
                "{retired} was a terminal"
            );
        }
        assert_eq!(decode_pane_kind("terminal"), Ok(PaneKind::Terminal));
        assert_eq!(decode_pane_kind("desktop"), Ok(PaneKind::Desktop));
        assert!(
            decode_pane_kind("nonsense").is_err(),
            "a kind nobody ever had is corruption"
        );
    }

    #[test]
    fn a_spec_round_trips_with_its_video_binding() {
        let mut original = spec();
        original.video = Some(VideoEndpoint {
            window_id: 0,
            title: "Studio Display".to_owned(),
            app_name: String::new(),
            display_id: Some(1),
        });
        original.user_renamed = true;
        let Ok(back) = decode_spec(&encode_spec(&original)) else {
            panic!("a spec round trips");
        };
        assert_eq!(back, original);
    }

    #[test]
    fn a_never_renamed_pane_writes_no_flag_at_all() {
        let text = to_pretty_string(&encode_spec(&spec()));
        assert!(
            !text.contains("userRenamed"),
            "the absence reads as nobody claimed the title"
        );
        let Ok(parsed) = parse(&text) else {
            panic!("it parses")
        };
        let Ok(back) = decode_spec(&parsed) else {
            panic!("it decodes")
        };
        assert!(!back.user_renamed);
    }

    #[test]
    fn a_display_less_endpoint_writes_no_key_rather_than_a_null() {
        let mut original = spec();
        original.video = Some(VideoEndpoint {
            window_id: 4,
            title: "Window".to_owned(),
            app_name: "Xcode".to_owned(),
            display_id: None,
        });
        let text = to_pretty_string(&encode_spec(&original));
        assert!(!text.contains("displayID"));
        let Ok(parsed) = parse(&text) else {
            panic!("it parses")
        };
        assert_eq!(decode_spec(&parsed), Ok(original));
    }

    #[test]
    fn a_canvas_round_trips_with_its_camera_and_groups() {
        let group = PaneGroupId::from_bytes([5; 16]);
        let mut item = CanvasItem::new(pane(1), spec(), Rect::xywh(10.0, 20.0, 640.0, 420.0), 3);
        item.group = Some(group);
        let original = Canvas::with_items(vec![item], Camera::new(Point::new(-40.0, 12.5)));
        let Ok(back) = decode_canvas(&encode_canvas(&original)) else {
            panic!("a canvas round trips");
        };
        assert_eq!(back, original);
    }

    #[test]
    fn an_empty_canvas_is_a_state_rather_than_a_fault() {
        let original = Canvas::with_items(Vec::new(), Camera::new(Point::new(3.0, 4.0)));
        assert_eq!(decode_canvas(&encode_canvas(&original)), Ok(original));
    }

    #[test]
    fn a_canvas_without_a_camera_decodes_to_the_un_panned_one() {
        let Ok(value) = parse(
            "{ \"items\": [ { \"id\": { \"raw\": \"01010101-0101-0101-0101-010101010101\" }, \"z\": 0, \
             \"frame\": { \"origin\": {\"x\":0,\"y\":0}, \"size\": {\"width\":640,\"height\":420} }, \
             \"spec\": { \"kind\": \"terminal\", \"title\": \"t\" } } ] }",
        ) else {
            panic!("the fixture is the shape already on disk");
        };
        let Ok(canvas) = decode_canvas(&value) else {
            panic!("it decodes")
        };
        assert_eq!(canvas.camera, Camera::ZERO);
    }

    #[test]
    fn a_sub_minimum_frame_is_floored_and_its_origin_kept() {
        let Ok(value) = parse(
            "{ \"camera\": { \"origin\": { \"x\": 0, \"y\": 0 } }, \"items\": [ { \"id\": { \"raw\": \
             \"01010101-0101-0101-0101-010101010101\" }, \"z\": 0, \"frame\": { \"origin\": {\"x\": 1, \
             \"y\": 2}, \"size\": {\"width\": 5, \"height\": 5} }, \"spec\": { \"kind\": \"terminal\", \
             \"title\": \"tiny\" } } ] }",
        ) else {
            panic!("the fixture is the shape already on disk");
        };
        let Ok(canvas) = decode_canvas(&value) else {
            panic!("it decodes")
        };
        let Some(item) = canvas.items.first() else {
            panic!("one item")
        };
        assert_eq!(
            item.frame.size, MIN_ITEM_SIZE,
            "nothing unrenderable reaches the layout"
        );
        assert_eq!(item.frame.origin, Point::new(1.0, 2.0), "the origin is preserved");
    }

    #[test]
    fn a_non_finite_frame_never_reaches_the_layout() {
        let hostile = CanvasItem::new(
            pane(1),
            spec(),
            Rect::new(Point::new(f64::NAN, 0.0), Size::new(f64::INFINITY, 400.0)),
            0,
        );
        let Ok(back) = decode_canvas(&encode_canvas(&Canvas::new(vec![hostile]))) else {
            panic!("a corrupt frame is repaired, not refused");
        };
        let Some(item) = back.items.first() else {
            panic!("one item")
        };
        assert!(item.frame.origin.x.is_finite() && item.frame.size.width.is_finite());
    }

    #[test]
    fn a_hostile_stacking_order_cannot_overflow_the_next_raise() {
        let Ok(value) = parse(&format!(
            "{{ \"id\": {{ \"raw\": \"01010101-0101-0101-0101-010101010101\" }}, \"z\": {}, \"frame\": {{ \
             \"origin\": {{\"x\":0,\"y\":0}}, \"size\": {{\"width\":640,\"height\":420}} }}, \"spec\": {{ \
             \"kind\": \"terminal\", \"title\": \"t\" }} }}",
            i64::MAX,
        )) else {
            panic!("the number itself is legal json");
        };
        let Ok(item) = decode_item(&value) else {
            panic!("it decodes")
        };
        assert_eq!(item.z, Z_BOUND, "a raise past this would wrap");
    }

    #[test]
    fn an_item_without_an_id_or_a_spec_is_a_fault() {
        let Ok(no_id) = parse("{ \"z\": 0, \"spec\": { \"kind\": \"terminal\", \"title\": \"t\" } }") else {
            panic!("it parses");
        };
        assert!(decode_item(&no_id).is_err());
        let Ok(no_spec) =
            parse("{ \"id\": { \"raw\": \"01010101-0101-0101-0101-010101010101\" }, \"z\": 0 }")
        else {
            panic!("it parses");
        };
        assert!(decode_item(&no_spec).is_err());
    }

    #[test]
    fn a_group_and_a_preset_round_trip() {
        let group = PaneGroup::new(PaneGroupId::from_bytes([5; 16]), "monitoring".to_owned());
        assert_eq!(decode_group(&encode_group(&group)), Ok(group.clone()));

        let preset = LayoutPreset {
            id: LayoutPresetId::from_bytes([6; 16]),
            name: "wide".to_owned(),
            canvas: Canvas::new(vec![CanvasItem::new(
                pane(1),
                spec(),
                Rect::xywh(0.0, 0.0, 640.0, 420.0),
                0,
            )]),
            groups: vec![group],
            focused_pane: Some(pane(1)),
            trigger_app_name: Some("Grafana".to_owned()),
        };
        let Ok(back) = decode_preset(&encode_preset(&preset)) else {
            panic!("a preset round trips");
        };
        assert_eq!(back, preset);
    }

    #[test]
    fn a_preset_without_its_optional_halves_round_trips_too() {
        let preset = LayoutPreset {
            id: LayoutPresetId::from_bytes([6; 16]),
            name: "bare".to_owned(),
            canvas: Canvas::new(Vec::new()),
            groups: Vec::new(),
            focused_pane: None,
            trigger_app_name: None,
        };
        let text = to_pretty_string(&encode_preset(&preset));
        assert!(!text.contains("focusedPane") && !text.contains("triggerAppName"));
        let Ok(parsed) = parse(&text) else {
            panic!("it parses")
        };
        assert_eq!(decode_preset(&parsed), Ok(preset));
    }

    #[test]
    fn a_preset_id_is_a_bare_uuid_because_that_is_the_type_it_was_written_from() {
        let preset = LayoutPreset {
            id: LayoutPresetId::from_bytes([6; 16]),
            name: "n".to_owned(),
            canvas: Canvas::new(Vec::new()),
            groups: Vec::new(),
            focused_pane: None,
            trigger_app_name: None,
        };
        let text = to_pretty_string(&encode_preset(&preset));
        assert!(
            text.contains("\"id\" : \"06060606-0606-0606-0606-060606060606\""),
            "not the single-field struct shape the pane ids use: {text}",
        );
    }

    #[test]
    fn an_item_round_trips_through_the_written_text_and_not_just_the_value() {
        let item = CanvasItem::new(pane(1), spec(), Rect::xywh(-10.5, 2.25, 800.0, 600.0), -4);
        let text = to_pretty_string(&encode_item(&item));
        let Ok(parsed) = parse(&text) else {
            panic!("it parses")
        };
        assert_eq!(decode_item(&parsed), Ok(item));
    }
}
