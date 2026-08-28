//! Two text-only ratchets over the client UI: raw design literals, and a menu that owns no chord.
//!
//! Ported from the `check-ds-leaks.sh` and `check-menu-shortcutless.sh` that used to sit in
//! `scripts/`, the last two standalone `grep` gates in `just lint`. Both were the same three lines:
//! one `grep -rnE` for the banned shape, one `grep -vE` dropping comment-only lines so the prose
//! explaining the ban did not fire it, and one `[[ -d ]]` / `[[ -f ]]` guard so a renamed target
//! failed loudly instead of reporting "intact" over nothing.
//!
//! All three parts come across as claims. The comment filter is [`View::Code`], which strips
//! exactly what the shell's `^[^:]+:[0-9]+:[[:space:]]*(//|\*)` did; the fail-closed guard is a
//! [`Claim::Populated`] floor on one side and a [`Claim::Exists`] on the other. What the shell
//! could not do, and this can, is say WHICH files leaked without re-running the grep by hand.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The client view tree the token scale governs.
const PHONE_UI: &str = "Sources/SlopDeskPhoneUI";

/// The menu file, which is discoverability and nothing else.
const MENU: &str = "Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift";

/// The banned literal shapes, as one alternation — the `SwiftUI` three, and the `UIKit` three each
/// of them acquires when a view is ported (docs/62 stage C).
///
/// Both spellings of each, so a leak cannot dodge the pattern by dropping a space:
///
/// * font — `.font(.system(size: N…))`, `size: ?` covering the canonical and unspaced forms;
/// * radius — the labelled argument `cornerRadius: N` (which is also `.rect(cornerRadius: N)` and
///   `RoundedRectangle(cornerRadius: N)`) AND the `View` modifier `.cornerRadius(N)`, both reached
///   by `[(:]`;
/// * height — `.frame(height: N)`, anchored on `height` as the FIRST argument, because
///   `.frame(width: N, height: M)` is a square glyph box and not the vertical rhythm.
///
/// ⚠️ The `UIKit` half is why this rule is §4.8's headline case: EVERY spelling above is
/// SwiftUI-only, so the day the phone's design floor became `UIView` subclasses the ratchet would
/// have gone silently vacuous — still green, still in `just lint`, and no longer able to see a
/// single leak. The three that carry the same dimensions in `UIKit` are:
///
/// * font — `UIFont.systemFont(ofSize: N)` and its siblings (`monospacedSystemFont`,
///   `boldSystemFont`, `italicSystemFont`), reached by `[A-Za-z]*[sS]ystemFont`;
/// * radius — `layer.cornerRadius = N`, an ASSIGNMENT, which `cornerRadius[(:]` cannot match;
/// * height/width — the Auto Layout constant, `constraint(equalToConstant: N)` and the
///   `NSLayoutConstraint(…, constant: N)` argument, both reached by `[Cc]onstant: ?[0-9]`. This is
///   the `UIKit` spelling of a fixed rhythm, and it covers the horizontal one the `SwiftUI` clause
///   deliberately left out — Auto Layout has no square-glyph-box idiom to spare.
///
/// What is deliberately NOT matched is the token system itself: `.font(.system(size: size))` has no
/// digit, `UIFont.systemFont(ofSize: Slate.Typeface.body)` has no digit, and
/// `static let radiusCard: CGFloat = 8` is not `cornerRadius`-prefixed.
const RAW_LITERALS: &str = r"\.font\(\.system\(size: ?[0-9]|cornerRadius[(:] *[0-9]|\.frame\(height: ?[0-9]|UIFont\.[A-Za-z]*[sS]ystemFont\(ofSize: ?[0-9]|\.cornerRadius *= *[0-9]|[Cc]onstant: ?[0-9]";

/// Every font size, corner radius and fixed height in the client UI rides the `Slate` scale.
///
/// `Sources/SlopDeskPhoneUI` drives all three through the token layer
/// (`DesignSystem/SlateDesign.swift`: `Slate.Typeface.*`, `Slate.Metric.radius*`,
/// `Slate.Metric.height*`), so a raw literal in that view tree is a dimension that bypassed the
/// scale. It is a RATCHET rather than a one-time cleanup: the tree is clean today and the rule
/// exists so the next one is caught on the day it is written, when the token to use instead is
/// obvious, rather than in an audit six months later.
///
/// (History: an earlier ratchet was retired in the native-SwiftUI rewrite when its token target was
/// deleted; the rebuild re-introduced a token layer, so the ratchet is back — now on `Slate.*`.)
///
/// The floor underneath it is not decoration. The shell version reported "intact" and exited 0 when
/// its target directory was unreachable, which is the one failure a gate's output cannot show you.
///
/// ⚠️ THE FLOOR IS A TRIPWIRE, NOT A RATCHET, and `3f11c6e6` is why the distinction had to be
/// written down. It was pinned at 60 against the `SwiftUI` phone; the `UIKit` demolition took the
/// tree to 24 and the floor went red for a reason that was not a leak and not an unreachable
/// directory. A floor set just under the live count re-fails on every legitimate deletion, so it is
/// pinned WELL under instead: 15 says "the design system is still here", which is the only thing
/// the ban below needs to be true (docs/62 stage C).
#[must_use]
pub fn design_tokens_are_not_bypassed(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Populated {
            roots: &[PHONE_UI],
            extensions: SWIFT,
            minimum: 15,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI — the design-token ban below \
                      reads an empty tree and passes (DESIGN.md, the Slate scale)",
        },
        Claim::NoneUnder {
            roots: &[PHONE_UI],
            extensions: SWIFT,
            pattern: RAW_LITERALS,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "RAW design-token literals in Sources/SlopDeskPhoneUI — use the Slate scale instead: \
                      font size → Slate.Typeface.{display,body,base,footnote,small}; cornerRadius → \
                      Slate.Metric.radius{Card,Tab,Control,Item,Small,Pill}; frame height → \
                      Slate.Metric.height{Control,Bar,Row,Strip,RowTall,Input} (or hairline). Leaked in: \
                      {files}",
        },
    ])
}

/// The menu bar carries no `.keyboardShortcut`, because it does not own chord dispatch.
///
/// `WorkspaceCommands.swift` is a DISCOVERABILITY-ONLY menu over the binding registry. The
/// app-level `NSEvent` `.keyDown` monitor (`WorkspaceKeyDispatcher`) owns dispatch — including the
/// multi-key tmux/zellij prefix a `.keyboardShortcut` cannot express — so a shortcut on a menu item
/// breaks it two ways at once: it DOUBLE-FIRES alongside the monitor for a single chord, and it
/// SWALLOWS a prefix sequence's follow-up key before the terminal first responder (libghostty) ever
/// sees it. Neither shows up as a build failure; both show up as a key that does the wrong thing.
///
/// The glyph goes on as a hint `Text` instead — see `menuTitle(for:)`. The file's own prose names
/// the banned token, which is why this reads [`View::Code`] rather than the raw file.
///
/// See `docs/DECISIONS.md` (the E1 menu-bar entry).
#[must_use]
pub fn the_menu_bar_owns_no_chord(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Exists {
            path: MENU,
            message: "the menu file is gone or renamed — the shortcut-less ban below has nothing to read \
                      (docs/DECISIONS.md, E1 menu bar)",
        },
        Claim::Lacks {
            path: MENU,
            pattern: r"\.keyboardShortcut\(",
            view: View::Code,
            message: "`.keyboardShortcut(` is back in WorkspaceCommands.swift — the menu MUST stay \
                      shortcut-less. WorkspaceKeyDispatcher owns chord dispatch; a menu shortcut \
                      double-fires alongside it and swallows a multi-key prefix tail before libghostty. \
                      Append the glyph as a hint Text instead (menuTitle(for:)) (docs/DECISIONS.md, E1 menu \
                      bar)",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Enough files to clear the floor, none of them leaking.
    fn phone_tree(fixture: &Fixture) {
        for index in 0..60 {
            fixture.write(
                &format!("{}/View{index}.swift", super::PHONE_UI),
                "Text(\"x\").font(Slate.Typeface.body)\n",
            );
        }
    }

    #[test]
    fn a_raw_literal_in_the_client_tree_is_a_leak() {
        let fixture = Fixture::new("design-ratchets-leaks");
        phone_tree(&fixture);
        assert!(super::design_tokens_are_not_bypassed(&fixture.tree()).is_clean());

        // Each shape, one at a time, in both spellings where the shell had two — and each one's
        // UIKit twin, because the ported floor is where the leaks will be written from now on.
        for leak in [
            ".font(.system(size: 13))",
            ".font(.system(size:13))",
            ".rect(cornerRadius: 8)",
            ".cornerRadius(8)",
            ".frame(height: 28)",
            ".frame(height:28)",
            ".font = UIFont.systemFont(ofSize: 13)",
            ".font = UIFont.monospacedSystemFont(ofSize:13, weight: .regular)",
            ".layer.cornerRadius = 8",
            ".layer.cornerRadius=8",
            ".heightAnchor.constraint(equalToConstant: 28)",
            ".heightAnchor.constraint(equalToConstant:28)",
        ] {
            fixture.write(
                &format!("{}/View0.swift", super::PHONE_UI),
                &format!("Text(\"x\"){leak}\n"),
            );
            let report = super::design_tokens_are_not_bypassed(&fixture.tree());
            assert!(!report.is_clean(), "{leak} passed the ban");
            assert!(
                report.violations()[0].contains("View0.swift"),
                "the leaking file is named: {:?}",
                report.violations()
            );
        }
    }

    /// The prose above a ban names what it bans — the reason the rule reads code, not text.
    #[test]
    fn the_ban_does_not_fire_on_its_own_explanation() {
        let fixture = Fixture::new("design-ratchets-prose");
        phone_tree(&fixture);
        fixture.write(
            &format!("{}/View0.swift", super::PHONE_UI),
            "// never write .font(.system(size: 13)) — use Slate.Typeface.body\n/// nor .cornerRadius(8), \
             nor .frame(height: 28)\n// nor UIFont.systemFont(ofSize: 13), nor .layer.cornerRadius = 8, nor \
             .constraint(equalToConstant: 28)\nText(\"x\").font(Slate.Typeface.body)\n",
        );
        assert!(super::design_tokens_are_not_bypassed(&fixture.tree()).is_clean());
    }

    /// The shell's silent pass: a target directory that is not there.
    #[test]
    fn an_empty_client_tree_fails_rather_than_reporting_intact() {
        let fixture = Fixture::new("design-ratchets-empty");
        assert!(!super::design_tokens_are_not_bypassed(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_menu_shortcut_double_fires_and_is_banned() {
        let fixture = Fixture::new("design-ratchets-menu");
        fixture.write(
            super::MENU,
            "// a .keyboardShortcut( here would double-fire\nButton(\"Split\") { split() }\n",
        );
        assert!(super::the_menu_bar_owns_no_chord(&fixture.tree()).is_clean());

        fixture.append(
            super::MENU,
            "Button(\"Split\") { split() }.keyboardShortcut(\"d\", modifiers: .command)\n",
        );
        assert!(!super::the_menu_bar_owns_no_chord(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_renamed_menu_file_fails_closed() {
        let fixture = Fixture::new("design-ratchets-menu-gone");
        assert!(!super::the_menu_bar_owns_no_chord(&fixture.tree()).is_clean());
    }
}
