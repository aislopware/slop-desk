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

use crate::identity::{PaneId, SplitNodeId};
use crate::json::{Json, JsonError, Result, object};
use crate::session::{PaneKind, PaneSpec, VideoEndpoint};
use crate::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

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

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a refused decode in a round-trip test has nothing to return"
    )]

    use super::{
        decode_pane_kind, decode_spec, decode_split_node, decode_weight, encode_spec, encode_split_node,
        encode_weight,
    };
    use crate::identity::{PaneId, SplitNodeId};
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
}
