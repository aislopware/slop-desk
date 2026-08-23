//! A generic element, and a bounded walk over one — the two things a search of the tree needs that
//! a window-shaped API cannot express.
//!
//! [`window`](crate::window) speaks in windows because every caller there already knows the window
//! it means. A search does not: it starts at a window or a menu bar and descends through groups,
//! toolbars, splitters and menus looking for a node it can only recognise by attribute. So this
//! module hands out an untyped [`Element`] and the attribute reads a searcher needs, and nothing
//! else — WHICH node counts, and what to conclude from finding one, is
//! `slopdesk_video::nav_history`'s, per `docs/57` §2.
//!
//! [`walk`] is the one thing here that is neither a read nor a decision. It is the mechanical part
//! — descend, count, stop — and it lives beside the IPC because every node it touches is a round
//! trip, so the bound and the traversal have to be the same loop. It takes both bounds as plain
//! numbers rather than a policy type, which is what keeps the policy one crate over.

use std::time::Instant;

use objc2_application_services::AXUIElement;
use objc2_core_foundation::CFRetained;

use crate::attribute;
use crate::window::{App, Window};

/// `AXChildren` — an element's children, as an array of elements.
const CHILDREN: &str = "AXChildren";
/// `AXMenuBar` — an application's menu bar element.
const MENU_BAR: &str = "AXMenuBar";
/// `AXRole` — what kind of thing an element is, as a `CFString`.
const ROLE: &str = "AXRole";
/// `AXIdentifier` — a stable, unlocalized name an app may put on a control.
const IDENTIFIER: &str = "AXIdentifier";
/// `AXEnabled` — whether a control would do anything if activated, as a `CFBoolean`.
const ENABLED: &str = "AXEnabled";
/// `AXMenuItemCmdChar` — the character of a menu item's key equivalent, as a `CFString`.
const CMD_CHAR: &str = "AXMenuItemCmdChar";
/// `AXMenuItemCmdModifiers` — the modifier mask of that key equivalent, as a `CFNumber`.
const CMD_MODIFIERS: &str = "AXMenuItemCmdModifiers";

/// What a walk should do below the node it was just handed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Step {
    /// Visit this node's children.
    Descend,
    /// Do not visit this node's children, but keep walking the rest of the tree.
    Prune,
    /// End the whole walk now.
    Stop,
}

/// Any element of the accessibility tree, capped at the messaging timeout it was read out with.
///
/// Deliberately untyped: a searcher meets groups, toolbars, splitters, menus and buttons on the way
/// down, and giving each a Rust type would be modelling a hierarchy the framework describes with a
/// string attribute anyway.
/// `Clone` is a CF retain, which is what lets a walk KEEP the node it just found without the
/// borrow outliving the traversal that produced it. The clone is the same accessibility object, so
/// two clones compare equal and read the same live state — copying an element does not snapshot it.
#[derive(Clone, Debug)]
pub struct Element {
    element: CFRetained<AXUIElement>,
    timeout: f32,
}

impl Element {
    /// The element's `AXRole`, or `None` when it does not publish one.
    #[must_use]
    pub fn role(&self) -> Option<String> {
        attribute::text(&self.element, ROLE)
    }

    /// The element's `AXIdentifier`, or `None` when it does not publish one.
    ///
    /// Most elements do not. An identifier is something an app sets deliberately, which is exactly
    /// why it is worth matching on: unlike a description, it does not change with the locale.
    #[must_use]
    pub fn identifier(&self) -> Option<String> {
        attribute::text(&self.element, IDENTIFIER)
    }

    /// Whether the control would do anything if activated, or `None` when it does not say.
    ///
    /// This is the reading the whole search exists to reach, and it is the only one that is re-run
    /// on a cached element — a full scan costs 25–180 ms of blocking IPC and this costs about
    /// 0.05 ms.
    #[must_use]
    pub fn enabled(&self) -> Option<bool> {
        attribute::flag(&self.element, ENABLED)
    }

    /// The character of the item's key equivalent, or `None` when it has none.
    #[must_use]
    pub fn cmd_char(&self) -> Option<String> {
        attribute::text(&self.element, CMD_CHAR)
    }

    /// The modifier mask of the item's key equivalent, or `None` when it has none.
    #[must_use]
    pub fn cmd_modifiers(&self) -> Option<i64> {
        attribute::number(&self.element, CMD_MODIFIERS)
    }

    /// The element's children, each capped at this element's messaging timeout.
    ///
    /// The cap is re-applied rather than inherited because it is not inheritable: an element copied
    /// out of an attribute carries the framework's ~6 second default no matter which element it was
    /// read from, so a walk that skipped this would leave one uncapped reference per level and a
    /// beachballing target would stall on the first of them.
    #[must_use]
    pub fn children(&self) -> Vec<Self> {
        attribute::elements(&self.element, CHILDREN, self.timeout)
            .into_iter()
            .map(|element| {
                Self {
                    element,
                    timeout: self.timeout,
                }
            })
            .collect()
    }
}

impl App {
    /// The application's menu bar, or `None` when it publishes none.
    ///
    /// A background-only app has no menu bar; so does one that is still launching. Both are the
    /// ordinary answer rather than a failure.
    #[must_use]
    pub fn menu_bar(&self) -> Option<Element> {
        attribute::element(&self.element, MENU_BAR, self.timeout).map(|element| {
            Element {
                element,
                timeout: self.timeout,
            }
        })
    }
}

impl Window {
    /// The window as an untyped element, so a search can start at it.
    ///
    /// Retains rather than moves: the caller usually keeps the [`Window`] as well, because a
    /// per-window search has to remember which window it searched.
    #[must_use]
    pub fn as_element(&self, timeout_seconds: f32) -> Element {
        Element {
            element: self.element.clone(),
            timeout: timeout_seconds,
        }
    }
}

/// Depth-first over `root`'s subtree, bounded three ways, with the verdict supplied by the caller.
///
/// `visit` is called for every node the bounds allow, with the node and its depth below `root`
/// (`root` itself is depth zero), and answers what to do below it. The bounds are:
///
/// * `max_depth` — the deepest node visited. `root` is depth 0, so `max_depth` of 8 visits nine
///   levels.
/// * `node_budget` — how many nodes may be visited in total, across the whole tree rather than per
///   level. Each visit costs several out-of-process round trips, so this is the bound that actually
///   caps the work.
/// * `deadline` — wall clock, checked before each visit. The other two bound the call COUNT, and a
///   target that answers slowly-but-successfully stays under both forever.
///
/// Returns the number of nodes visited, which is what a caller needs to tell "found nothing" from
/// "ran out of allowance before it could look".
pub fn walk(
    root: &Element,
    max_depth: u32,
    node_budget: u32,
    deadline: Instant,
    visit: &mut impl FnMut(&Element, u32) -> Step,
) -> u32 {
    let mut spent = 0_u32;
    descend(root, 0, max_depth, node_budget, deadline, &mut spent, visit);
    spent
}

/// One level of [`walk`], carrying the counter the whole traversal shares.
///
/// The `bool` is "the WALK may continue", not "this branch had children". The distinction is the
/// one bug this shape invites: a node past `max_depth` ends its own branch, and its siblings are at
/// that same depth so they end too — but its parent's siblings are one level SHALLOWER and must
/// still be visited. Answering `false` for a depth stop would abort them, quietly turning a bound
/// on how deep the walk goes into a bound on how much of the tree it sees at all.
fn descend(
    node: &Element,
    depth: u32,
    max_depth: u32,
    node_budget: u32,
    deadline: Instant,
    spent: &mut u32,
    visit: &mut impl FnMut(&Element, u32) -> Step,
) -> bool {
    if depth > max_depth {
        return true;
    }
    if *spent >= node_budget || Instant::now() > deadline {
        return false;
    }
    *spent += 1;
    match visit(node, depth) {
        Step::Stop => return false,
        Step::Prune => return true,
        Step::Descend => {},
    }
    for child in node.children() {
        if !descend(&child, depth + 1, max_depth, node_budget, deadline, spent, visit) {
            return false;
        }
    }
    true
}
