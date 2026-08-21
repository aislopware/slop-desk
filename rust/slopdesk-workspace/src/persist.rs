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
//! - A split with no `id` is given one derived from its place in the tree and the panes under it,
//!   never a constant: two unnamed seams sharing a name would be ONE divider to every resize.
//! - A stacking order is clamped, so a hostile `z` of `i64::MAX` cannot make the next
//!   frontmost-bump overflow.
//!
//! What is NOT repaired is a structurally impossible document — a split node with neither
//! discriminator, a missing pane id. That is a fault, and the caller's answer is the default
//! workspace plus the old file kept aside. Repairing it would mean inventing a layout and claiming
//! it was restored.

use std::collections::BTreeMap;

use crate::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
use crate::json::{Json, JsonError, Result, object, parse, to_pretty_string};
use crate::session::{DetachedPane, PaneKind, PaneSpec, Session, Tab, VideoEndpoint};
use crate::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};
use crate::workspace::{CURRENT_SCHEMA_VERSION, TreeWorkspace};

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

/// A kind from its persisted discriminator, folding every retired one to a terminal.
///
/// The name and the fold are [`PaneKind::raw`] and [`PaneKind::from_raw`], not a pair spelled again
/// here. They WERE spelled again here, under different names, and the copy is the exact shape that
/// rots: a kind retired in the vocabulary is a kind this file keeps rejecting, and the failure is a
/// workspace that refuses to load rather than a test that goes red.
///
/// # Errors
/// [`JsonError`] for a discriminator this build has never had — corruption rather than age.
fn decode_pane_kind(raw: &str) -> Result<PaneKind> {
    PaneKind::from_raw(raw).ok_or_else(|| malformed("unknown pane kind"))
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
pub(crate) fn encode_spec(spec: &PaneSpec) -> Json {
    let mut members = vec![
        ("kind".to_owned(), Json::String(spec.kind.raw().to_owned())),
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
pub(crate) fn decode_spec(value: &Json) -> Result<PaneSpec> {
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
fn encode_weight(weight: SplitWeight) -> Json {
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
fn decode_weight(value: &Json) -> SplitWeight {
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
pub(crate) fn encode_split_node(node: &SplitNode) -> Json {
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
/// degenerate case where the whole tree repairs away to nothing. It is asked for PANE ids only: a
/// split the file did not name gets an id derived from the node instead, so that decoding one file
/// twice names its dividers the same way both times (`derived_split_id` carries why).
///
/// # Errors
/// [`JsonError`] for a node with neither discriminator, an id that is not a uuid, or nesting past
/// [`crate::json::MAX_DEPTH`] — the parser refuses that before a value ever exists.
pub(crate) fn decode_split_node(value: &Json, mint: &mut impl FnMut() -> PaneId) -> Result<SplitNode> {
    let raw = decode_raw_node(value, ROOT_PATH)?;
    Ok(raw.normalized(mint).unwrap_or_else(|| SplitNode::Leaf(mint())))
}

/// The FNV-1a 128 offset basis, which is also the hash of the empty path — the root's place.
const ROOT_PATH: u128 = 0x6C62_272E_07BB_0142_62B8_2175_6295_C58D;

/// The FNV-1a 128 prime.
const PATH_PRIME: u128 = 0x0000_0000_0100_0000_0000_0000_0000_013B;

/// The UUID version nibble (byte 6, high) and variant bits (byte 8, top two), as a mask over the
/// 128-bit value those big-endian bytes are read from.
const UUID_VERSION_AND_VARIANT: u128 = (0xF0 << (9 * 8)) | (0xC0 << (7 * 8));

/// One byte into the running hash.
///
/// FNV-1a, and deliberately not a cryptographic hash: the property asked for is that two different
/// inputs give two different ids on inputs nobody is choosing to collide, not that a collision is
/// hard to construct. A file that spelled one out by hand has already named the same divider twice.
fn fold(hash: u128, byte: u8) -> u128 {
    (hash ^ u128::from(byte)).wrapping_mul(PATH_PRIME)
}

fn fold_all(hash: u128, bytes: impl IntoIterator<Item = u8>) -> u128 {
    bytes.into_iter().fold(hash, fold)
}

/// The id an id-less split is given: DERIVED from where it is and what it holds, never invented.
///
/// This used to hand every id-less split in a file the all-zero uuid, which made them all ONE
/// divider group: `set_divider_weight` moved two seams at once, and the document wrote a single
/// `splitNode/<nil>/weight` cell for two independent dividers. Swift does not have THAT bug — its
/// `?? SplitNodeID()` mints a fresh id per split — so the fill here had to beat both languages at
/// once: no collision, the way Swift already manages, and stable across loads, which Swift does not
/// (`## Owed` below — the divergence is live, not closed).
///
/// Minting a random one was rejected: [`crate::identity`]'s header is "the same inputs give the
/// same tree, forever", and this crate holds no entropy for exactly that reason. A random id would
/// mean one file decoded twice named the same seam two different things — unpinnable by a test, and
/// a second reader of the same file would disagree with the first. Threading a second closure in
/// from the caller would have bought the same non-determinism at the cost of a wider signature.
///
/// So the id is a function of the node itself, in two parts, each covering what the other cannot:
///
/// - the PATH from the root, so two splits in one tree differ even when they cover the same panes —
///   which is the pre-repair single-child chain, the one case where an ancestor's leaf set equals a
///   descendant's;
/// - the axis and every pane id BENEATH it, so two splits in different trees differ — a per-tree
///   path alone would give every tab's root split the same name.
///
/// The version and variant nibbles are zeroed, which no v4 uuid the runtime mints ever has, so a
/// derived id cannot collide with a minted one.
///
/// ## Settled, 2026-08-20
///
/// This crate and Swift used to disagree about the SECOND property, and the user paid for it every
/// time they quit. `SplitNodeID.init` defaults to `UUID()`, so Swift's `?? SplitNodeID()` fill was
/// RANDOM: one file decoded twice named the same seam two different things. Every load renamed
/// every unnamed split, so a `splitNode/<id>/weight` cell written before a relaunch was orphaned
/// after it — drag a divider, quit, reopen, and it is back at the default, with no `.corrupt`
/// sidecar to explain it because nothing failed. It bit exactly the two kinds of file whose splits
/// carry no id: a hand-edited one, and one written before the id existed.
///
/// What closed it was not a second minting rule written in Swift. It was [`decode_file`] — this
/// module grown to the whole document and published as `slopdesk_ws_workspace_file_decode` — after
/// which `SplitNode+Codable.swift` did nothing this module does not already do, so it went
/// entirely. That is the one-implementation rule finishing, rather than a fix bolted onto the
/// second copy.
fn derived_split_id(path: u128, axis: SplitAxis, children: &[WeightedChild]) -> SplitNodeId {
    let mut hash = fold(path, match axis {
        SplitAxis::Horizontal => 0,
        SplitAxis::Vertical => 1,
    });
    for child in children {
        for pane in child.node.all_pane_ids() {
            hash = fold_all(hash, pane.bytes());
        }
    }
    SplitNodeId::from_bytes((hash & !UUID_VERSION_AND_VARIANT).to_be_bytes())
}

/// `path` is the hash of this node's position: the root's is [`ROOT_PATH`], a child's is its
/// parent's folded with the child's index. It names nothing on its own — it is only the seed
/// [`derived_split_id`] uses for a split the file did not name.
fn decode_raw_node(value: &Json, path: u128) -> Result<SplitNode> {
    if value.get("leaf").is_some() {
        return Ok(SplitNode::Leaf(PaneId::from_bytes(decode_id(value, "leaf")?)));
    }
    let Some(split) = value.get("split") else {
        return Err(malformed("a split node has neither a leaf nor a split"));
    };
    // A missing or unreadable axis is FILLED rather than refused: the structure is intact, and a
    // node whose divider group lost its name still describes a real arrangement.
    let axis = match split.get("axis").and_then(Json::string) {
        Some("vertical") => SplitAxis::Vertical,
        _ => SplitAxis::Horizontal,
    };
    let mut children = Vec::new();
    for (index, child) in split
        .get("children")
        .and_then(Json::array)
        .unwrap_or_default()
        .iter()
        .enumerate()
    {
        let Some(node) = child.get("node") else {
            return Err(malformed("a split child has no node"));
        };
        children.push(WeightedChild::new(
            child.get("weight").map_or(SplitWeight::Flex(1.0), decode_weight),
            decode_raw_node(
                node,
                fold_all(path, u64::try_from(index).unwrap_or(u64::MAX).to_be_bytes()),
            )?,
        ));
    }
    // The id is filled the same way — but from the node, not from a constant. See
    // [`derived_split_id`] for why an invented one is not an option here.
    let id = decode_optional_id(split, "id").map_or_else(
        || derived_split_id(path, axis, &children),
        SplitNodeId::from_bytes,
    );
    Ok(SplitNode::Split { id, axis, children })
}

// ---------------------------------------------------------------------------------------------- //
// The file
// ---------------------------------------------------------------------------------------------- //

/// Why a workspace file would not load.
///
/// Three arms because the caller's answer differs across them, and the numbering lives HERE rather
/// than in the shim that exports it: a door that invented these bytes would be `docs/55` §5's "no
/// error mapped to a different error", and it would be the second place the taxonomy is written
/// down. The same shape [`slopdesk_wire::document::state_file::FileError`] already has for the
/// host's half of the pair, deliberately, so a reader of one recognises the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileError {
    /// The bytes are not the file this build writes — not UTF-8, not JSON, or JSON with no
    /// workspace shape in it. The caller mints the default and keeps the old file aside.
    Malformed,
    /// The file is from a different shape of this document. Not migrated: the standing rule is that
    /// stale data degrades to the default rather than being carried forward.
    VersionMismatch(i64),
    /// More panes than a launch will materialize.
    ///
    /// Its own arm rather than a silent truncation: the store allocates one session per pane on the
    /// main actor, so a file claiming a hundred thousand of them is a freeze at launch — and half a
    /// workspace restored is a workspace whose missing half nobody can name.
    TooManyPanes,
}

/// The byte a load that WORKED reports, so a caller reading the status has one value for "nothing
/// refused" rather than an absence it has to infer.
pub const NO_REFUSAL: u8 = 0;

impl FileError {
    /// The byte this refusal crosses a C boundary as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Malformed => 1,
            Self::VersionMismatch(_) => 2,
            Self::TooManyPanes => 3,
        }
    }

    /// The version the file CLAIMED, for the one arm that names one.
    ///
    /// An `Option` rather than a number with a reserved absence: every `i64` is a version somebody
    /// could have typed into the file by hand, including `0`, so no in-band value could have meant
    /// "this refusal is not about a version".
    #[must_use]
    pub const fn claimed_version(self) -> Option<i64> {
        match self {
            Self::VersionMismatch(version) => Some(version),
            _ => None,
        }
    }
}

/// The most panes a file may describe.
///
/// A file naming more is refused rather than trimmed. The store materializes one session PER pane
/// on the main actor at launch, so an enormous list is a freeze rather than a big workspace, and
/// real ones are dozens.
pub const MAX_PANES: usize = 1024;

/// The identities a re-seed spends on a workspace with nothing in it: a session, its tab, its pane.
const EMPTY_WORKSPACE_IDS: usize = 3;

/// The identities a re-seed spends on a session the file left with no tab: the tab and its pane.
const TABLESS_SESSION_IDS: usize = 2;

/// A pane the person pulled out into its own window.
fn encode_detached(entry: DetachedPane) -> Json {
    let mut members = vec![("pane".to_owned(), encode_id(entry.pane.bytes()))];
    // Absent rather than `null` when there is no origin tab, which is what Swift's synthesized
    // encoder wrote for an optional.
    if let Some(origin) = entry.origin_tab {
        members.push(("originTab".to_owned(), encode_id(origin.bytes())));
    }
    Json::Object(members.into_iter().collect())
}

fn decode_detached(value: &Json) -> Result<DetachedPane> {
    Ok(DetachedPane {
        pane: PaneId::from_bytes(decode_id(value, "pane")?),
        origin_tab: decode_optional_id(value, "originTab").map(TabId::from_bytes),
    })
}

/// One tab: its identity, its title and its tree.
fn encode_tab(tab: &Tab) -> Json {
    let mut members = vec![
        ("id".to_owned(), encode_id(tab.id.bytes())),
        ("title".to_owned(), Json::String(tab.title.clone())),
        ("root".to_owned(), encode_split_node(&tab.root)),
    ];
    if let Some(active) = tab.active_pane {
        members.push(("activePane".to_owned(), encode_id(active.bytes())));
    }
    if let Some(zoomed) = tab.zoomed_pane {
        members.push(("zoomedPane".to_owned(), encode_id(zoomed.bytes())));
    }
    Json::Object(members.into_iter().collect())
}

/// One tab, repaired.
///
/// The focus and the zoom are FILLED from absence rather than refused, including when the file
/// spells one as something that is not an id: both name a pane, and a selection nobody can read is
/// a selection nobody made. [`TreeWorkspace::normalizing_active`] then drops either that does not
/// name a leaf this tab holds, so nothing here has to know the tree it is reading.
///
/// # Errors
/// [`JsonError`] for a missing id or title, or a `root` that is not a split tree.
fn decode_tab(value: &Json, mint: &mut impl IdSource) -> Result<Tab> {
    let id = TabId::from_bytes(decode_id(value, "id")?);
    let title = text(value, "title")?;
    let root = decode_split_node(field(value, "root")?, &mut || mint.pane())?;
    Ok(Tab {
        id,
        title,
        root,
        active_pane: decode_optional_id(value, "activePane").map(PaneId::from_bytes),
        zoomed_pane: decode_optional_id(value, "zoomedPane").map(PaneId::from_bytes),
    })
}

/// One session, with its spec side table written as a sorted array of `{pane, spec}` rows.
///
/// An array rather than an object keyed by uuid, because that is the shape already on disk: Swift's
/// `[PaneID: PaneSpec]` could not be a JSON object without a `CodingKey` conformance nobody wrote.
/// The order is the map's own, which is the ids' byte order — and byte order over a uuid is the
/// same order as over its uppercase text, so the rows land exactly where Swift's
/// `sorted { $0.pane.raw.uuidString < … }` put them.
fn encode_session(session: &Session) -> Json {
    let specs = session
        .specs
        .iter()
        .map(|(pane, spec)| object([("pane", encode_id(pane.bytes())), ("spec", encode_spec(spec))]))
        .collect();
    let mut members = vec![
        ("id".to_owned(), encode_id(session.id.bytes())),
        ("name".to_owned(), Json::String(session.name.clone())),
        (
            "tabs".to_owned(),
            Json::Array(session.tabs.iter().map(encode_tab).collect()),
        ),
        (
            "activeTabIndex".to_owned(),
            Json::Integer(i64::try_from(session.active_tab_index).unwrap_or(0)),
        ),
        ("specs".to_owned(), Json::Array(specs)),
    ];
    // Only when non-empty, so a detach-free session's bytes stay identical to a file from before
    // the field existed.
    if !session.detached.is_empty() {
        members.push((
            "detached".to_owned(),
            Json::Array(session.detached.iter().copied().map(encode_detached).collect()),
        ));
    }
    Json::Object(members.into_iter().collect())
}

/// A persisted list: a TOLERANT container around STRICT elements.
///
/// The container is tolerant because a value the type refuses — `"specs": 5`, `"detached": {}` —
/// named no panes to begin with, so reading it as no list loses nothing the file still described.
/// The elements are not, because a `try?` per row would drop one pane out of an arrangement the
/// rest of which decoded and report success: a `desktop` pane coming back as a blank terminal is
/// worse than a load that visibly refuses.
fn tolerant_array<'a>(value: &'a Json, key: &str) -> &'a [Json] {
    value.get(key).and_then(Json::array).unwrap_or_default()
}

/// One session, repaired.
///
/// `activeTabIndex` is FILLED to `0` from anything unreadable, which is the same answer the field's
/// own normalizer already gives an out-of-range one — and a value of the wrong type carries
/// strictly less information than `900` does.
///
/// # Errors
/// [`JsonError`] for a missing id or name, a `tabs` key that is not an array, or a malformed tab,
/// spec row or detached record.
fn decode_session(value: &Json, mint: &mut impl IdSource) -> Result<Session> {
    let id = SessionId::from_bytes(decode_id(value, "id")?);
    let name = text(value, "name")?;
    // The tab list is the ARRANGEMENT, not a side table: a session whose tabs cannot be read is not
    // a session with fewer tabs, so this list is strict where `specs` and `detached` are not.
    let rows = field(value, "tabs")?
        .array()
        .ok_or_else(|| malformed("a session's tabs are not an array"))?;
    let mut tabs = Vec::with_capacity(rows.len());
    for row in rows {
        tabs.push(decode_tab(row, mint)?);
    }
    let mut specs = BTreeMap::new();
    for row in tolerant_array(value, "specs") {
        specs.insert(
            PaneId::from_bytes(decode_id(row, "pane")?),
            decode_spec(field(row, "spec")?)?,
        );
    }
    let mut detached = Vec::new();
    for row in tolerant_array(value, "detached") {
        detached.push(decode_detached(row)?);
    }
    Ok(Session {
        id,
        name,
        tabs,
        active_tab_index: value
            .get("activeTabIndex")
            .and_then(Json::integer)
            .and_then(|index| usize::try_from(index).ok())
            .unwrap_or(0),
        specs,
        detached,
    })
}

/// The whole workspace as the file's own JSON, ending in a newline.
///
/// The version written is the VALUE's, not this build's, so a caller that means to re-stamp a file
/// says so by setting it — an encoder that quietly claimed the current shape would make the
/// no-migration rule a lie told by the writer.
#[must_use]
pub fn encode_file(workspace: &TreeWorkspace) -> String {
    let mut members = vec![
        (
            "schemaVersion".to_owned(),
            Json::Integer(workspace.schema_version),
        ),
        (
            "sessions".to_owned(),
            Json::Array(workspace.sessions.iter().map(encode_session).collect()),
        ),
    ];
    if let Some(active) = workspace.active_session_id {
        members.push(("activeSessionID".to_owned(), encode_id(active.bytes())));
    }
    to_pretty_string(&Json::Object(members.into_iter().collect()))
}

/// The whole workspace from a file's bytes, repaired, or the one refusal that stopped it.
///
/// The repair runs HERE rather than in the caller, because it is what makes the answer sayable at
/// all: a decoded file can hold a session with no tab and a leaf with no spec, and neither is a
/// shape the document's cell encoding — the way this answer crosses to Swift — can spell. So the
/// decode ends where [`TreeWorkspace::normalized`] ends, which is also where the launch path
/// already ended.
///
/// `mint` supplies the identities a re-seed needs; [`minted_ids_for`] sizes the pool from the same
/// bytes. The ids it hands out must be FRESH rather than derived, and that is the opposite ruling
/// from [`derived_split_id`] one section up: a re-seeded pane is a pane the file did not contain,
/// so no persisted cell is keyed by it and a stable name has nothing to keep pointing at — while a
/// `PaneId` IS the join to the registry that owns a process, so a name derived from the file's own
/// contents is one two launches, or two clients reading one document, could both produce.
///
/// # Errors
/// [`FileError`] for bytes that are not this file, a version this build does not speak, or a file
/// naming more than [`MAX_PANES`] panes.
pub fn decode_file(bytes: &[u8], mint: &mut impl IdSource) -> core::result::Result<TreeWorkspace, FileError> {
    let Ok(text) = core::str::from_utf8(bytes) else {
        return Err(FileError::Malformed);
    };
    let Ok(value) = parse(text) else {
        return Err(FileError::Malformed);
    };
    // The version is read BEFORE anything else is believed. A file from another shape decodes
    // "successfully" against the keys this shape still recognises, and the next autosave would then
    // rewrite it without whatever the old shape carried.
    let Some(version) = value.get("schemaVersion").and_then(Json::integer) else {
        return Err(FileError::Malformed);
    };
    if version != CURRENT_SCHEMA_VERSION {
        return Err(FileError::VersionMismatch(version));
    }
    let Some(rows) = value.get("sessions").and_then(Json::array) else {
        return Err(FileError::Malformed);
    };
    let mut sessions = Vec::with_capacity(rows.len());
    for row in rows {
        let Ok(session) = decode_session(row, mint) else {
            return Err(FileError::Malformed);
        };
        sessions.push(session);
    }
    let workspace = TreeWorkspace::new(
        sessions,
        decode_optional_id(&value, "activeSessionID").map(SessionId::from_bytes),
    );
    // Counted before the repair, so the bound is on what the FILE claimed rather than on what a
    // re-seed happened to add to it.
    if workspace.all_pane_ids().len() > MAX_PANES {
        return Err(FileError::TooManyPanes);
    }
    Ok(workspace.normalized(mint))
}

/// How many identities a [`decode_file`] of these bytes can spend.
///
/// Asked rather than guessed, because a pool one short does not fail — it REPEATS an identity, and
/// two panes sharing one is a pane that reattaches to a process it never opened. The count is exact
/// rather than a bound off the byte length: every id is attributable to something the file names,
/// so it costs one parse of a file that is read once per launch and answers a number a reader can
/// check against the passes that spend it.
///
/// Bytes that are not a file answer the re-seed's own three, which is what the caller will need if
/// it decides to mint the default itself.
#[must_use]
pub fn minted_ids_for(bytes: &[u8]) -> usize {
    let Ok(text) = core::str::from_utf8(bytes) else {
        return EMPTY_WORKSPACE_IDS;
    };
    let Ok(value) = parse(text) else {
        return EMPTY_WORKSPACE_IDS;
    };
    let mut needed = EMPTY_WORKSPACE_IDS;
    for session in tolerant_array(&value, "sessions") {
        needed = needed.saturating_add(TABLESS_SESSION_IDS);
        for tab in tolerant_array(session, "tabs") {
            // One for a tree that repairs away to nothing, and one per leaf, since every leaf can
            // be the duplicate of an earlier one.
            let leaves = tab.get("root").map_or(0, leaf_count);
            needed = needed.saturating_add(leaves.saturating_add(1));
        }
    }
    needed
}

/// How many leaves a raw node describes, before any repair.
fn leaf_count(node: &Json) -> usize {
    if node.get("leaf").is_some() {
        return 1;
    }
    node.get("split")
        .map(|split| tolerant_array(split, "children"))
        .unwrap_or_default()
        .iter()
        .map(|child| child.get("node").map_or(0, leaf_count))
        .sum()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a refused decode in a round-trip test has nothing to return"
    )]

    use std::collections::BTreeSet;

    use super::{
        EMPTY_WORKSPACE_IDS, FileError, MAX_PANES, NO_REFUSAL, decode_file, decode_pane_kind, decode_spec,
        decode_split_node, decode_weight, encode_file, encode_spec, encode_split_node, encode_weight,
        minted_ids_for,
    };
    use crate::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
    use crate::json::{Json, object, parse, to_pretty_string};
    use crate::session::{DetachedPane, PaneKind, PaneSpec, Session, Tab, VideoEndpoint};
    use crate::split_tree::{MAX_DEPTH, MIN_WEIGHT, SplitAxis, SplitNode, SplitWeight, WeightedChild};
    use crate::workspace::{CURRENT_SCHEMA_VERSION, TreeWorkspace};

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

    /// Every split id in the tree, in pre-order — one entry per surviving divider group.
    fn split_ids(node: &SplitNode) -> Vec<SplitNodeId> {
        match node {
            SplitNode::Leaf(_) => Vec::new(),
            SplitNode::Split { id, children, .. } => {
                let mut ids = vec![*id];
                for child in children {
                    ids.extend(split_ids(&child.node));
                }
                ids
            },
        }
    }

    /// A file with two splits and no `id` on either — a hand-written layout, or one from a build
    /// that predates the id.
    const UNNAMED_SPLITS: &str = r#"{
      "split": {
        "axis": "horizontal",
        "children": [
          { "node": { "leaf": { "raw": "01010101-0101-0101-0101-010101010101" } } },
          { "node": { "split": {
            "axis": "vertical",
            "children": [
              { "node": { "leaf": { "raw": "02020202-0202-0202-0202-020202020202" } } },
              { "node": { "leaf": { "raw": "03030303-0303-0303-0303-030303030303" } } }
            ]
          } } }
        ]
      }
    }"#;

    /// RUST had this one and SWIFT was HALF right. Swift mints a fresh `SplitNodeID()` per id-less
    /// split, so it never had the collision this pins: where this module handed every one of them
    /// the all-zero uuid, two independent seams shared a name — `set_divider_weight` moved both at
    /// once, and the document wrote one `splitNode/<nil>/weight` cell for two dividers.
    ///
    /// The other half is the next test, and there it is SWIFT that is wrong: a random mint is not
    /// stable across loads. `derived_split_id`'s `## Owed` section carries what that costs a user
    /// and what closing it takes.
    #[test]
    fn two_unnamed_splits_are_two_dividers_rather_than_one() {
        let Ok(value) = parse(UNNAMED_SPLITS) else {
            panic!("the fixture is json; it is the missing ids that are the point");
        };
        let Ok(tree) = decode_split_node(&value, &mut minter()) else {
            panic!("a split with no id is repaired, not refused");
        };
        let ids = split_ids(&tree);
        assert_eq!(ids.len(), 2, "both splits survive the repair");
        assert_ne!(
            ids.first(),
            ids.last(),
            "two seams a drag can move independently need two names"
        );
        assert!(
            !ids.contains(&SplitNodeId::from_bytes([0; 16])),
            "the all-zero uuid was the collision, not a valid fill"
        );
    }

    /// The other half of the same fix: the fill is DERIVED, so it is the same on every read. A
    /// random mint would pass the test above and fail this one — which is precisely what Swift's
    /// `?? SplitNodeID()` does today, so this is a property this crate holds ALONE until that call
    /// site is replaced by the derivation (`derived_split_id`, `## Owed`).
    #[test]
    fn the_same_file_names_the_same_dividers_every_time_it_is_read() {
        let Ok(value) = parse(UNNAMED_SPLITS) else {
            panic!("the fixture is json");
        };
        let (Ok(first), Ok(second)) = (
            decode_split_node(&value, &mut minter()),
            decode_split_node(&value, &mut minter()),
        ) else {
            panic!("both reads decode");
        };
        assert_eq!(
            split_ids(&first),
            split_ids(&second),
            "the id is a function of the file, not of when it was read"
        );
    }

    /// And a split the file DOES name keeps that name — the derivation is the fill, never an
    /// override, or a restored divider position would land on a seam nobody dragged.
    #[test]
    fn a_split_that_carries_an_id_keeps_it() {
        let original = tree();
        let Ok(back) = decode_split_node(&encode_split_node(&original), &mut minter()) else {
            panic!("a well-formed tree decodes");
        };
        assert_eq!(split_ids(&back), split_ids(&original));
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
        for retired in PaneKind::RETIRED_RAW_VALUES {
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

    // ------------------------------------------------------------------------------------------ //
    // The file
    // ------------------------------------------------------------------------------------------ //

    /// A deterministic stand-in for the runtime's entropy, at every kind. The repair only needs the
    /// ids to be FRESH, and a counter is fresh enough while staying replayable.
    struct Counter(u8);

    impl Counter {
        fn take(&mut self) -> [u8; 16] {
            self.0 = self.0.wrapping_add(1);
            [self.0; 16]
        }
    }

    impl IdSource for Counter {
        fn pane(&mut self) -> PaneId {
            PaneId::from_bytes(self.take())
        }

        fn tab(&mut self) -> TabId {
            TabId::from_bytes(self.take())
        }

        fn session(&mut self) -> SessionId {
            SessionId::from_bytes(self.take())
        }

        fn split(&mut self) -> SplitNodeId {
            SplitNodeId::from_bytes(self.take())
        }
    }

    fn ids() -> Counter {
        Counter(200)
    }

    fn workspace() -> TreeWorkspace {
        let mut session = Session::single_pane(
            SessionId::from_bytes([1; 16]),
            "work",
            TabId::from_bytes([2; 16]),
            pane(4),
            spec(),
        );
        session.tabs.push(Tab::new(TabId::from_bytes([3; 16]), tree()));
        for leaf in [pane(1), pane(2), pane(3)] {
            session.specs.insert(leaf, spec());
        }
        TreeWorkspace::new(vec![session], Some(SessionId::from_bytes([1; 16])))
    }

    fn read(text: &str) -> Result<TreeWorkspace, FileError> {
        decode_file(text.as_bytes(), &mut ids())
    }

    #[test]
    fn a_healthy_file_round_trips_and_re_encodes_to_the_same_bytes() {
        let original = workspace();
        let text = encode_file(&original);
        let Ok(back) = read(&text) else {
            panic!("what this module wrote, this module reads");
        };
        assert_eq!(back, original);
        assert_eq!(encode_file(&back), text, "the round trip is stable");
    }

    #[test]
    fn the_file_is_written_in_the_shape_already_on_disk() {
        let text = encode_file(&workspace());
        for spelling in [
            "\"schemaVersion\" : 12",
            "\"sessions\"",
            "\"activeSessionID\"",
            "\"activeTabIndex\" : 0",
            "\"specs\"",
            "\"raw\"",
        ] {
            assert!(text.contains(spelling), "{spelling} is missing from: {text}");
        }
        assert!(
            !text.contains("\"detached\""),
            "a detach-free session writes no list at all"
        );
    }

    #[test]
    fn a_detached_pane_survives_the_round_trip_with_its_origin() {
        let mut original = workspace();
        let detached = pane(9);
        if let Some(session) = original.sessions.first_mut() {
            session.specs.insert(detached, spec());
            session.detached.push(DetachedPane {
                pane: detached,
                origin_tab: Some(TabId::from_bytes([2; 16])),
            });
        }
        let Ok(back) = read(&encode_file(&original)) else {
            panic!("a detached pane is part of the arrangement");
        };
        assert_eq!(back, original);
    }

    /// A whole file whose one split carries no `id` — a hand-written layout, or one from a build
    /// that predates the id. The schema version is spelled out because a file that claimed another
    /// one would never reach the tree at all.
    const UNNAMED_SPLIT_FILE: &str = r#"{
      "schemaVersion": 12,
      "sessions": [
        {
          "id": { "raw": "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A" },
          "name": "work",
          "activeTabIndex": 0,
          "tabs": [
            {
              "id": { "raw": "0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B" },
              "title": "",
              "root": { "split": {
                "axis": "horizontal",
                "children": [
                  { "node": { "leaf": { "raw": "01010101-0101-0101-0101-010101010101" } } },
                  { "node": { "leaf": { "raw": "02020202-0202-0202-0202-020202020202" } } }
                ]
              } }
            }
          ],
          "specs": [
            { "pane": { "raw": "01010101-0101-0101-0101-010101010101" },
              "spec": { "kind": "terminal", "title": "one" } },
            { "pane": { "raw": "02020202-0202-0202-0202-020202020202" },
              "spec": { "kind": "terminal", "title": "two" } }
          ]
        }
      ]
    }"#;

    /// **The defect this whole port exists to close.** Swift's `?? SplitNodeID()` minted a fresh
    /// uuid per unnamed split, so one file read twice named the same seam two different things —
    /// and a `splitNode/<id>/weight` cell written before a relaunch was orphaned after it. The
    /// derivation is a function of the FILE, so two reads agree.
    #[test]
    fn the_same_file_names_the_same_dividers_on_every_load() {
        let (Ok(first), Ok(second)) = (read(UNNAMED_SPLIT_FILE), read(UNNAMED_SPLIT_FILE)) else {
            panic!("both reads decode");
        };
        let seams = |workspace: &TreeWorkspace| -> Vec<SplitNodeId> {
            workspace
                .sessions
                .iter()
                .flat_map(|session| session.tabs.iter().flat_map(|tab| split_ids(&tab.root)))
                .collect()
        };
        assert!(!seams(&first).is_empty(), "the fixture has a divider in it");
        assert_eq!(
            seams(&first),
            seams(&second),
            "a divider's name is a function of the file, not of when it was read",
        );
    }

    #[test]
    fn a_version_this_build_does_not_speak_names_itself_in_the_refusal() {
        let text = encode_file(&workspace()).replace("\"schemaVersion\" : 12", "\"schemaVersion\" : 99");
        assert_eq!(read(&text), Err(FileError::VersionMismatch(99)));
        assert_eq!(
            FileError::VersionMismatch(99).claimed_version(),
            Some(99),
            "the caller cannot log a shape it was not told"
        );
        assert_eq!(FileError::Malformed.claimed_version(), None);
    }

    #[test]
    fn bytes_that_are_not_a_file_refuse_rather_than_decode_to_nothing() {
        for hostile in ["", "not json", "{}", "[]", "{\"schemaVersion\" : 12}"] {
            assert_eq!(read(hostile), Err(FileError::Malformed), "{hostile:?}");
        }
        assert_eq!(
            decode_file(&[0xFF, 0xFE], &mut ids()),
            Err(FileError::Malformed),
            "bytes that are not UTF-8 are not a file either",
        );
    }

    #[test]
    fn a_file_naming_more_panes_than_a_launch_can_hold_is_refused_whole() {
        let mut session = Session::single_pane(
            SessionId::from_bytes([1; 16]),
            "work",
            TabId::from_bytes([2; 16]),
            pane(1),
            spec(),
        );
        // One tab per pane, so the count is the panes rather than one enormous tree.
        for step in 0..=MAX_PANES {
            let ordinal = u128::from(u64::try_from(step).unwrap_or(0));
            let leaf = PaneId::from_bytes(ordinal.to_be_bytes());
            session.tabs.push(Tab::new(
                TabId::from_bytes((ordinal | (1 << 120)).to_be_bytes()),
                SplitNode::Leaf(leaf),
            ));
            session.specs.insert(leaf, spec());
        }
        let text = encode_file(&TreeWorkspace::new(vec![session], None));
        assert_eq!(read(&text), Err(FileError::TooManyPanes));
    }

    #[test]
    fn every_refusal_has_a_byte_of_its_own_and_none_of_them_is_the_load_that_worked() {
        let codes = [
            FileError::Malformed.code(),
            FileError::VersionMismatch(0).code(),
            FileError::TooManyPanes.code(),
        ];
        assert!(!codes.contains(&NO_REFUSAL), "a refusal reads as a load");
        let distinct: BTreeSet<u8> = codes.iter().copied().collect();
        assert_eq!(distinct.len(), codes.len(), "two refusals share a byte");
    }

    /// A session the file left with no tab keeps its NAME and gets a tab, where the document's own
    /// ingest would have dropped it. This is the repair that could not cross as cells, which is why
    /// it happens on this side of the boundary.
    #[test]
    fn a_session_with_no_tab_is_re_seeded_rather_than_dropped() {
        let text = format!(
            "{{\"schemaVersion\" : {CURRENT_SCHEMA_VERSION}, \"sessions\" : [{{\"id\" : {{\"raw\" : \
             \"01010101-0101-0101-0101-010101010101\"}}, \"name\" : \"kept\", \"tabs\" : [], \"specs\" : \
             []}}]}}"
        );
        let Ok(back) = read(&text) else {
            panic!("an empty session is a repair, not a fault");
        };
        assert_eq!(back.sessions.len(), 1);
        let Some(session) = back.sessions.first() else {
            panic!("the session survives");
        };
        assert_eq!(session.name, "kept", "the name is the part worth keeping");
        assert_eq!(session.tabs.len(), 1, "and it is given somewhere to live");
        assert_eq!(session.specs.len(), 1, "the re-seeded leaf carries a spec");
    }

    #[test]
    fn a_side_table_that_is_not_a_list_costs_the_titles_and_not_the_arrangement() {
        let text = encode_file(&workspace()).replace("\"specs\" : [", "\"specs\" : 5, \"unused\" : [");
        let Ok(back) = read(&text) else {
            panic!("a value that named no pane is not a fault");
        };
        assert_eq!(
            back.all_pane_ids().len(),
            workspace().all_pane_ids().len(),
            "every pane the file still described is where the file left it",
        );
        assert!(
            back.invariant_holds(),
            "the repair re-seeds a default spec for every leaf"
        );
    }

    #[test]
    fn a_spec_row_with_no_spec_is_still_a_fault() {
        let text = encode_file(&workspace()).replacen("\"spec\" : {", "\"nospec\" : {", 1);
        assert_eq!(
            read(&text),
            Err(FileError::Malformed),
            "a pane quietly turning into a different pane is worse than a refusal",
        );
    }

    #[test]
    fn a_tabs_key_that_is_not_a_list_is_a_fault_where_a_side_table_is_not() {
        let text = encode_file(&workspace()).replace("\"tabs\" : [", "\"tabs\" : 5, \"unused\" : [");
        assert_eq!(read(&text), Err(FileError::Malformed));
    }

    /// The pool must be big enough for every repair the file can force. A pool one short does not
    /// fail — it repeats an identity — so this asserts the COUNT against a decode that records what
    /// it actually spent.
    #[test]
    fn the_pool_is_sized_for_every_identity_a_decode_can_spend() {
        // A file whose every leaf is the same pane: every repair path at once, in one document.
        let text = encode_file(&workspace()).replace(
            "02020202-0202-0202-0202-020202020202",
            "01010101-0101-0101-0101-010101010101",
        );
        let mut counter = Counter(0);
        let Ok(_) = decode_file(text.as_bytes(), &mut counter) else {
            panic!("a duplicated leaf is a repair");
        };
        assert!(
            usize::from(counter.0) <= minted_ids_for(text.as_bytes()),
            "the decode spent {} identities and the pool was sized for {}",
            counter.0,
            minted_ids_for(text.as_bytes()),
        );
        assert!(
            minted_ids_for(b"not a file") >= EMPTY_WORKSPACE_IDS,
            "bytes that are not a file still cost the default's own three"
        );
    }

    #[test]
    fn a_duplicate_leaf_across_two_tabs_is_re_minted_from_the_pool() {
        let text = encode_file(&workspace()).replace(
            "02020202-0202-0202-0202-020202020202",
            "01010101-0101-0101-0101-010101010101",
        );
        let Ok(back) = read(&text) else {
            panic!("a duplicate is repaired, not refused");
        };
        let panes = back.all_pane_ids();
        let unique: BTreeSet<PaneId> = panes.iter().copied().collect();
        assert_eq!(
            panes.len(),
            unique.len(),
            "the registry is keyed one-to-one by pane id"
        );
    }
}
