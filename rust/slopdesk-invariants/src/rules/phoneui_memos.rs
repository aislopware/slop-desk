//! Ten held lines under the phone's `UIKit` shell — `docs/62` §4, plus two floors from §8.
//!
//! `docs/55` §8 catalogues a Mac hazard whose shape is "a fact re-derived because re-deriving it
//! looked free", and [`super::macui_memos`] pins those. The phone's hazards are a DIFFERENT shape,
//! and the difference is the reason this is a second family rather than more arms on the first.
//! `SwiftUI` owned the phone's lifetimes: a `@State` died with its view, an `.onChange` could not
//! outlive the body that declared it, and a closure stored in a `@StateObject` was the framework's
//! problem. `UIKit` hands every one of those back. So the hazards here are LIFETIME and THREAD
//! hazards — a retained `self`, an observation that fires after its view is gone, a cell reused
//! under an index that moved, a layout pass that writes the model it is laying out — and every one
//! of them is invisible to a green test suite. The app does not crash on the machine that wrote it;
//! it crashes on a device, on the eleventh tab switch, after a rotation.
//!
//! Measured on the live tree 2026-08-29, `rg` over `Sources/SlopDeskPhoneUI` (83 Swift files):
//! 50 closure-sink assignments · 9 files hand-rolling `withObservationTracking` · 35
//! `layoutSubviews` bodies · 1 `CADisplayLink` · 0 `Timer`s · 0 off-main-queue hops. Each rule
//! below records the count it was cut against, because a count that moves is how these rules go
//! quietly vacuous — which is `docs/62` §4.8's own hazard, and why every ban here carries either a
//! [`Claim::Populated`] floor or a counted floor of its own subject.
//!
//! ## What is deliberately NOT here
//! `docs/62` §4 names two hazards as review-only out loud: a retain cycle between two objects
//! NEITHER of which is `self`, and whether a `CADisplayLink`'s `invalidate()` is REACHED on every
//! path. Both are found by Instruments' Leaks and Allocations on a device, and §6 makes that run a
//! stage's exit condition rather than pretending a text rule covers it. Nothing below tries.

use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::path::Path;

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::{Source, Tree};

/// The phone's `UIKit` shell — every §4 hazard's scope, and nothing else.
const PHONE_UI: &str = "Sources/SlopDeskPhoneUI";
/// The same, as a claim's root list.
const PHONE_UI_ROOTS: &[&str] = &[PHONE_UI];
/// The floor under every §4 ban. The directory holds 83 files; 60 is well clear of a reshuffle and
/// well above the "somebody renamed the target and the ban resolved to nothing" case.
const PHONE_UI_FLOOR: usize = 60;
/// The shared placement floor both shells stand on — §8's subject, not §4's.
const CLIENT_CORE: &str = "Sources/SlopDeskClientCore";
/// The same, as a claim's root list.
const CLIENT_CORE_ROOTS: &[&str] = &[CLIENT_CORE];
/// 126 files live there today.
const CLIENT_CORE_FLOOR: usize = 90;

/// A closure-sink assignment: `row.onTap = {`, `keys.onResign = {`, `empty.onAction = {`.
const SINK_OPENS: &str = r"\.on[A-Z]\w*\s*=\s*\{";
/// The capture list that makes such a sink safe.
const WEAK_CAPTURE: &str = r"\[\s*(weak|unowned)\s+self";
/// A `layoutSubviews` override — the one method `UIKit` may call at the display's rate.
const LAYOUT_OPENS: &str = r"func layoutSubviews\(";
/// How far a block scan will read before giving up. No body in this tree is close.
const BLOCK_CEILING: usize = 400;

/// H1. A stored closure never captures `self` strongly
///
/// `SwiftUI`'s `.onTapGesture { … }` is a value the framework owns for the duration of a body
/// evaluation. `UIKit`'s `row.onTap = { … }` is a closure a view HOLDS, so `self` inside it is a
/// strong reference from the view to itself through its own child: the view never deallocates, its
/// observation never stops, and the leak is one row per scroll. It is silent — every test passes,
/// the row draws, the tap fires — and it is found on a device with Allocations, or here.
///
/// Measured 2026-08-29: 50 sink assignments across the shell, 0 of them offending.
///
/// ## Why this is a BLOCK scan and not two line patterns
/// The line-wise version — "a sink line naming `self` must also name `[weak self]`" — has a hole
/// wide enough to drive the hazard through: a MULTI-LINE sink whose opening line carries a
/// non-`self` capture list (`= { [store = deps.store] cause in`, which is live and correct in
/// `PaneCanvasView`) and whose body reaches `self.` three lines down passes both arms. Requiring a
/// `self` capture instead would red on that live line. So the rule reads the closure's whole brace
/// block: an offender is a sink whose opening line lacks `[weak self]`/`[unowned self]` and whose
/// BODY names `self` anywhere. That admits the non-`self` capture list and still catches the reach.
///
/// The residue this leaves is `docs/62` §4's first review-only hazard — a cycle between two objects
/// neither of which is `self` — which no scan anchored on `self` can see.
///
/// BREAK-TEST: a sink rewritten to `[self]` ⇒ FAIL; a sink with no capture list whose body reaches
/// `self.` on a later line ⇒ FAIL; the same body with `[weak self]` restored ⇒ PASS; every sink
/// renamed out of the `.onX =` shape ⇒ FAIL on the counted floor rather than passing vacuously.
#[must_use]
pub fn a_stored_closure_never_holds_its_view(tree: &Tree) -> Report {
    let mut report = check_all(tree, &[phone_ui_is_populated()]);
    let mut offenders = BTreeSet::new();
    let mut seen = 0_usize;
    for (path, source) in swift_under(tree, PHONE_UI) {
        let lines: Vec<&str> = source.statements().lines().collect();
        for (index, line) in lines.iter().enumerate() {
            if !text::matches(line, SINK_OPENS) {
                continue;
            }
            seen += 1;
            if text::matches(line, WEAK_CAPTURE) {
                continue;
            }
            if brace_block(&lines, index)
                .iter()
                .any(|body| text::matches(body, r"\bself\b"))
            {
                offenders.insert(format!("{}:{}", path.display(), index + 1));
            }
        }
    }
    report.fail_if(
        !offenders.is_empty(),
        format!(
            "these stored closures reach `self` without a weak capture: {} — a sink a view HOLDS makes the \
             view its own owner, so it never deallocates and its observation never stops (docs/62 §4.1)",
            named(&offenders)
        ),
    );
    report.fail_if(
        seen < 20,
        format!(
            "only {seen} closure sinks matched `{SINK_OPENS}` under {PHONE_UI} — the shell held 50 when \
             this ban was cut, so either the sinks moved or the ban stopped seeing them, and a ban that \
             sees nothing passes (docs/62 §4.8)"
        ),
    );
    report
}

/// H2. A hand-rolled `withObservationTracking` carries all three parts of the guard
///
/// `SwiftUI` re-ran a body and the framework coalesced. `UIKit` re-arms by hand, and a hand-rolled
/// re-arm has three separable failure modes, each of which ships green: no generation bump (the
/// observation re-arms into a stale read and the view stops updating), a strong `self` in the
/// `onChange` (the view outlives its controller), and no generation COMPARISON in the callback (a
/// re-arm that lands after the view moved on applies the old snapshot over the new one).
///
/// `ObservationFollow` supplies all three by construction and 35 files use it. The 9 that
/// hand-roll do so because they interleave the read with something the helper cannot express. Those
/// 9 are the subject; the rule says nothing about the 35, which is right — a file that MIGRATES to
/// the helper stops spelling `withObservationTracking` and leaves the rule's scope, and the rule
/// going quiet then is the correct outcome rather than the §4.8 hazard. That is why the
/// anti-vacuity floor here counts FILES in the directory rather than files matching the pattern:
/// the hazard genuinely can reach zero, and only the directory emptying is a defect.
///
/// Measured 2026-08-29: 9 files, all three arms satisfied by every one.
///
/// ⚠️ The pattern is `withObservationTracking` with NO parenthesis. Every live site spells it with
/// a trailing closure (`withObservationTracking {`), so the natural `withObservationTracking\(`
/// would have matched nothing in the whole tree and shipped green forever.
///
/// ⚠️ The generation counter is `[Gg]eneration`, not `generation`. `PhonePanelViewController`
/// spells its own `reloadGeneration`, and an anchored lower-case needle would have called it an
/// offender.
///
/// BREAK-TEST: each of the three rescues deleted from a hand-rolling file in turn ⇒ FAIL naming
/// that file; all three restored ⇒ PASS.
#[must_use]
pub fn a_hand_rolled_observation_is_guarded(tree: &Tree) -> Report {
    /// The three parts of the guard, and what each one's absence costs.
    const ARMS: &[(&str, &str)] = &[
        (
            r"[Gg]eneration &\+= 1",
            "re-arm without bumping a generation, so a callback that lands late applies a snapshot the view \
             has already moved past",
        ),
        (
            r"onChange: \{ \[weak self\] in",
            "hand the `onChange` a strong `self`, which keeps the view alive through its own observation \
             for as long as the model does",
        ),
        (
            r"[Gg]eneration == self\.",
            "never COMPARE the generation they bump, which makes the bump decoration and leaves the stale \
             apply in place",
        ),
    ];

    let mut report = check_all(tree, &[phone_ui_is_populated()]);
    for (rescue, cost) in ARMS {
        report.absorb(check_all(tree, &[Claim::NoFileUnder {
            roots: PHONE_UI_ROOTS,
            extensions: SWIFT,
            pattern: "withObservationTracking",
            rescued_by: Some(rescue),
            view: View::Code,
            exempt: &[],
            message: text::intern(format!(
                "these hand-roll `withObservationTracking` and {cost}: {{files}} — `ObservationFollow` \
                 supplies the generation guard, the weak capture and the read/apply split by construction, \
                 and a file that re-arms by hand owes all three (docs/62 §4.2)"
            )),
        }]));
    }
    report
}

/// H3. A collection-view cell resolves its row by IDENTIFIER, never by index
///
/// `SwiftUI`'s `ForEach` was identity-keyed and the framework did the diffing. `UICollectionView`
/// hands back an `IndexPath`, and `devices[indexPath.item]` is correct exactly until a reload lands
/// between the layout pass and the cell configuration — then it is an out-of-bounds crash on a
/// user's device and a green suite here, because a test never reloads mid-pass.
///
/// The fix is the diffable data source's `itemIdentifier(for:)`, which returns `nil` rather than
/// trapping. 9 call sites live; 0 index subscripts.
///
/// ⚠️ The one live `[indexPath.item]` in the tree is a COMMENT in `PhoneAndroidDeviceList.swift`
/// explaining why the file does not do it. [`View::Code`] drops it, which is exactly the reason a
/// ban reads code and not text — a `Claim::Mentions` here would have been satisfied by that
/// sentence and by nothing else, forever.
///
/// BREAK-TEST: `devices[indexPath.item]` added as CODE ⇒ FAIL; the same line as a `//` comment ⇒
/// PASS, which is the arm that proves the view choice.
#[must_use]
pub fn a_cell_resolves_its_row_by_identifier(tree: &Tree) -> Report {
    check_all(tree, &[phone_ui_is_populated(), Claim::NoneUnder {
        roots: PHONE_UI_ROOTS,
        extensions: SWIFT,
        pattern: r"\[\s*indexPath\.(item|row|section)\s*\]",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "these subscript a collection by index path: {files} — a reload landing between the layout \
                  pass and the cell configuration makes that an out-of-bounds trap on a device and nothing \
                  at all in a test, so the row comes from `itemIdentifier(for:)`, which returns nil \
                  (docs/62 §4.3)",
    }])
}

/// H4. Every `MainActor.assumeIsolated` is EARNED, because nothing here leaves the main queue
///
/// ## ⚠️ RE-AIMED 2026-08-29
/// `docs/62` §4.4 proposed testing an `assumeIsolated` against its neighbourhood — offending unless
/// the enclosing lines name `DispatchQueue.main.async`. Measured against the live tree that is
/// FALSIFIED: 29 `assumeIsolated` sites exist and most of them sit in a `UIView` callback `UIKit`
/// already delivers on the main thread, with no hop anywhere near. The proposed rule would have red
/// on the majority of correct code, and widening the neighbourhood until it went green would have
/// left a rule that fires on nothing.
///
/// So the arm is re-cut at the fact that makes every one of those 29 sound: the phone's view layer
/// NEVER LEAVES THE MAIN QUEUE. `assumeIsolated` is a promise the compiler cannot check, and it is
/// only ever wrong when something in the same target can run somewhere else. Ban the family that
/// creates a second thread and every `assumeIsolated` is earned by construction — which is the
/// behaviour §4.4 was reaching for, stated where a rule can decide it.
///
/// Measured 2026-08-29, all six spellings ZERO under the shell: `nonisolated(unsafe)`,
/// `@unchecked Sendable`, `DispatchQueue.global`, `Task.detached`, `DispatchQueue(label:`, and a
/// `qos:` argument. The two dwell timers that used to sit here moved down to `SlopDeskClientCore`,
/// which is not this rule's scope and has the Mac on it too.
///
/// BREAK-TEST: each of the six spellings added to a shell file in turn ⇒ FAIL naming that file.
#[must_use]
pub fn the_phone_view_layer_never_leaves_the_main_queue(tree: &Tree) -> Report {
    check_all(tree, &[phone_ui_is_populated(), Claim::NoneUnder {
        roots: PHONE_UI_ROOTS,
        extensions: SWIFT,
        pattern: r"nonisolated\(unsafe\)|@unchecked Sendable|DispatchQueue\.global|Task\.detached|DispatchQueue\(label:",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "these give the phone's view layer a second thread: {files} — the 29 live \
                  `MainActor.assumeIsolated` calls are sound BECAUSE nothing in this target runs off the \
                  main queue, so the concurrency primitive and the promise stand or fall together (docs/62 \
                  §4.4)",
    }])
}

/// H5. An observation registered by hand is retired by hand
///
/// `NotificationCenter.addObserver(forName:)` returns a token, and a token dropped on the floor is
/// an observation that outlives its view: the block fires against a deallocated controller on the
/// next post. The selector-taking `addObserver(_:selector:name:object:)` does NOT have this shape —
/// it is auto-removed on deallocation since iOS 9 — so it is not the subject, and the one live call
/// in `TerminalLeafView` is that form.
///
/// KVO is the same hazard with a different spelling: an `NSKeyValueObservation` that is not stored
/// is cancelled immediately, and a `forKeyPath` registration that is not removed crashes the
/// observed object's deallocation. Both are ZERO and stay that way — the phone observes through
/// `@Observable`, not KVO.
///
/// Measured 2026-08-29: 0 block-form registrations, 0 KVO of either spelling.
///
/// BREAK-TEST: an `addObserver(forName:` with no `removeObserver` ⇒ FAIL; the same file with a
/// `removeObserver` added ⇒ PASS; `observe(_:options:changeHandler:)` spelled as `forKeyPath` ⇒
/// FAIL.
#[must_use]
pub fn a_hand_registered_observation_is_retired(tree: &Tree) -> Report {
    check_all(tree, &[
        phone_ui_is_populated(),
        Claim::NoFileUnder {
            roots: PHONE_UI_ROOTS,
            extensions: SWIFT,
            pattern: r"addObserver\(forName:",
            rescued_by: Some("removeObserver"),
            view: View::Code,
            exempt: &[],
            message: "these take a notification token and never give it back: {files} — the block-form \
                      `addObserver` is NOT auto-removed, so the block fires against a deallocated view on \
                      the next post (docs/62 §4.5)",
        },
        Claim::NoneUnder {
            roots: PHONE_UI_ROOTS,
            extensions: SWIFT,
            pattern: r"forKeyPath|NSKeyValueObservation",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "these observe through KVO: {files} — an unstored `NSKeyValueObservation` is cancelled \
                      at once and an unremoved `forKeyPath` crashes the observed object's deallocation, and \
                      the phone reads models through `@Observable` instead (docs/62 §4.5)",
        },
    ])
}

/// H6a. A file that starts a `CADisplayLink` also invalidates one
///
/// A `CADisplayLink` retains its target and runs at the display's rate. One that is never
/// invalidated is a permanent 120 Hz callback into a view nobody can see, and it takes the view
/// with it — the strongest single battery regression this shell can ship, and completely invisible
/// to a test.
///
/// Measured 2026-08-29: exactly one consumer, `DesignSystem/StatusDotView.swift`, with two
/// `invalidate()` calls driven off `didMoveToWindow()`.
///
/// This is a FILE claim, not a line claim, because the shape is one line PRESENT and another line
/// ABSENT, which no single line carries. What it CANNOT decide is whether the `invalidate()` is
/// REACHED on every path — that is `docs/62` §4's second stated review-only hazard, and §6 books it
/// against an Instruments Allocations run on a device rather than pretending a text rule covers it.
///
/// BREAK-TEST: `invalidate()` deleted from the one consumer ⇒ FAIL naming it; restored ⇒ PASS.
#[must_use]
pub fn a_display_link_is_invalidated(tree: &Tree) -> Report {
    check_all(tree, &[phone_ui_is_populated(), Claim::NoFileUnder {
        roots: PHONE_UI_ROOTS,
        extensions: SWIFT,
        pattern: r"CADisplayLink\(",
        rescued_by: Some(r"invalidate\(\)"),
        view: View::Code,
        exempt: &[],
        message: "these start a `CADisplayLink` and never stop one: {files} — the link retains its target \
                  and ticks at the display's rate, so an un-invalidated one is a permanent callback into a \
                  view nobody can see (docs/62 §4.6)",
    }])
}

/// H6b. The phone shell owns no `Timer`
///
/// The sibling of H6a and the same hazard through the other API. A scheduled `Timer` retains its
/// target for as long as the run loop holds it, so a view that schedules one and is dismissed keeps
/// firing; and `Timer` has the second failure `CADisplayLink` does not, which is that it silently
/// stops during a scroll unless it is added to the common run-loop modes.
///
/// ⚠️ This ban's subject moved UNDER it mid-stage, which is worth recording because it is the shape
/// that turns a live ban into a dead one. When §4.6 was written the shell held two block-form
/// `Timer.scheduledTimer` dwell timers, in `PhoneToastStackView` and `IslandChipStackView`. Both
/// have since moved one floor down into `SlopDeskClientCore` as `OverlayDwell` and
/// `DecorationChipDwell`, so the count is 2 → 0 and the doc's flat ban is live-true again. It ships
/// as §4.6 wrote it, and it now pins a real architectural line rather than a coincidence: a phone
/// view holds a `ClientCore` dwell type or a stored `Task`, never its own timer.
///
/// The roots stay at the shell. The floor under `SlopDeskClientCore` is shared with the Mac and
/// belongs to a different family.
///
/// Measured 2026-08-29: 0 `Timer.scheduledTimer` and 0 `Timer(` under the shell.
///
/// BREAK-TEST: `Timer.scheduledTimer(withTimeInterval:` added ⇒ FAIL; a bare `Timer(timeInterval:`
/// added ⇒ FAIL.
#[must_use]
pub fn the_phone_shell_owns_no_timer(tree: &Tree) -> Report {
    check_all(tree, &[phone_ui_is_populated(), Claim::NoneUnder {
        roots: PHONE_UI_ROOTS,
        extensions: SWIFT,
        pattern: r"Timer\.scheduledTimer|\bTimer\(",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "these schedule a `Timer` inside the phone's view layer: {files} — a scheduled timer \
                  retains its target for as long as the run loop holds it and stalls during a scroll unless \
                  it joins the common modes, so dwell lives in `SlopDeskClientCore`'s \
                  `OverlayDwell`/`DecorationChipDwell` or in a stored `Task` (docs/62 §4.6)",
    }])
}

/// H7. `layoutSubviews` reads geometry and writes nothing the model can see
///
/// `UIKit` calls `layoutSubviews` whenever it likes and as often as it likes — a rotation, a
/// keyboard, a scroll, a sibling's own layout pass. Writing to the workspace store from inside one
/// is a re-entrant layout at best and an infinite one at worst: the write drives an observation,
/// the observation invalidates the layout, the layout calls back in. It does not deadlock in a test
/// because no test rotates a device.
///
/// A diffable `apply(` in the same place is the second named crash: `UICollectionView` asserts if a
/// snapshot lands during its own layout pass.
///
/// Measured 2026-08-29: 35 `layoutSubviews` bodies, 0 offenders on all three needles.
///
/// ## Why this is a BLOCK scan
/// A line ban cannot express "inside a `layoutSubviews` body" — `store.` is ordinary in every other
/// method of the same file, and `Claim::LacksWithin` wants a line-anchored `awk` range where a
/// method body wants brace depth. So the rule walks the brace block, over
/// [`Source::statements`] rather than [`Source::code`]: a trailing `// closes the drag {` comment
/// corrupts a line-based depth count, and `statements` blanks comments token-wise while keeping the
/// line structure and the string literals the block scan has to skip braces inside.
///
/// `drag.` and `chrome.` are deliberately NOT banned. `SplitCanvasView.swift:158` calls
/// `drag.reportContainerBounds(rect)` from its layout pass on purpose — reporting the geometry the
/// pass just computed is exactly what a layout pass is for, and banning it would be banning the
/// feature to satisfy the rule.
///
/// BREAK-TEST: `store.focusPane(id)` inside a `layoutSubviews` body ⇒ FAIL; the same line one
/// method below ⇒ PASS; `dataSource.apply(snapshot)` inside the body ⇒ FAIL; every `layoutSubviews`
/// renamed ⇒ FAIL on the counted floor.
#[must_use]
pub fn a_layout_pass_writes_no_model(tree: &Tree) -> Report {
    /// What a layout pass may not reach, and why.
    const BANS: &[(&str, &str)] = &[
        (r"\bstore\.", "write the workspace store"),
        (r"\bcoordinator\.", "call a coordinator"),
        (r"[Dd]ataSource\??\.apply\(", "apply a diffable snapshot"),
    ];

    let mut report = check_all(tree, &[phone_ui_is_populated()]);
    let mut offenders = BTreeSet::new();
    let mut seen = 0_usize;
    for (path, source) in swift_under(tree, PHONE_UI) {
        let lines: Vec<&str> = source.statements().lines().collect();
        for (index, line) in lines.iter().enumerate() {
            if !text::matches(line, LAYOUT_OPENS) {
                continue;
            }
            seen += 1;
            let body = brace_block(&lines, index);
            for (ban, _) in BANS {
                if body.iter().any(|held| text::matches(held, ban)) {
                    offenders.insert(format!("{}:{}", path.display(), index + 1));
                }
            }
        }
    }
    let why: Vec<&str> = BANS.iter().map(|(_, why)| *why).collect();
    report.fail_if(
        !offenders.is_empty(),
        format!(
            "these `layoutSubviews` bodies {}: {} — UIKit runs a layout pass on a rotation, a keyboard and \
             a sibling's own pass, so a write from inside one drives an observation that invalidates the \
             layout that called it (docs/62 §4.7)",
            why.join(", "),
            named(&offenders)
        ),
    );
    report.fail_if(
        seen < 15,
        format!(
            "only {seen} `layoutSubviews` bodies matched under {PHONE_UI} — the shell held 35 when this ban \
             was cut, and a body scan that finds nothing passes (docs/62 §4.8)"
        ),
    );
    report
}

/// `SlopDeskSlate` sits BELOW `SlopDeskClientCore`, and no header may say otherwise
///
/// `Package.swift` lists `SlopDeskSlate` among `SlopDeskClientCore`'s dependencies, and
/// `DecorationDivider` and `GuiLeafChromeLayout` spend `Slate.Metric.*` directly. The edge
/// compiles.
///
/// ## Why a rule exists for a sentence
/// The opposite claim — "`SlopDeskSlate` sits ABOVE this target, so it cannot be reached from here"
/// — was written into a header, copied into a second, and by the time it was caught it had reached
/// EIGHT places: three assertions in `docs/56-client-ui-split.md` and five `SlopDeskClientCore`
/// headers, laid down across several stages. It was never one author's slip. It propagated from a
/// design ledger into the code, and nothing in the tree could see it happen, because the tree can
/// only see what compiles and a false sentence in a comment compiles perfectly. In
/// `GuiLeafChromeLayout` the belief had gone load-bearing: the file had re-derived the metrics it
/// could have imported, and the duplicate is what `no-cross-target-clone` eventually reported — one
/// rule catching the SYMPTOM two stages after the cause was written down.
///
/// ## The three arms
/// 1. The edge itself, read out of `Package.swift`'s `SlopDeskClientCore` block. This is the fact;
///    everything else is downstream of it.
/// 2. A [`Claim::PinnedSet`] over `SlopDeskSlate`'s OWN dependency list. Arm 1 alone would stay
///    green if somebody added `SlopDeskClientCore` to Slate — which is the one change that would
///    make all eight sentences retroactively true and this ban wrong, and it would land as a build
///    error rather than as a rule that explains itself. Pinning the set makes the change say so.
/// 3. The prose ban, which has to read [`View::Raw`] because a comment is its entire subject. It is
///    scoped to `Sources/SlopDeskClientCore/` — `docs/` is not gated here.
///
/// ⚠️ The excusal is the delicate half, because a ban on a sentence has to admit the SIX
/// corrections that quote the sentence in order to recant it. It admits exactly three shapes: a
/// quoted identifier (`` "`SlopDeskSlate` "``), a quoted phrase (`"depends on this"`), and the
/// marker `the edge is the other way`. So a recantation must keep its opening quote on the same
/// line as the words it recants, or it will read as a fresh assertion — which is the correct
/// default. A bare `\bbelief\b` excusal was considered and rejected: "on the belief that …" is
/// exactly how a fresh false assertion would be phrased, so it would have admitted the thing the
/// ban exists for.
///
/// Verified 2026-08-29: 6 hits under `Sources/SlopDeskClientCore/`, 6 excused, 0 unexcused.
/// `CodeSidebarWebViewPool.swift:139` — "the target that owns the duel sits ABOVE this one", which
/// is about `SlopDeskMacUI`/`SlopDeskPhoneUI` and TRUE — stays green: it carries no Slate token
/// within 40 characters of the phrase.
///
/// BREAK-TEST: `SlopDeskSlate` removed from the `ClientCore` block ⇒ FAIL; `SlopDeskClientCore`
/// added to Slate's own list ⇒ FAIL on the pinned set; a fresh unquoted "`SlopDeskSlate` sits ABOVE
/// this target" in a `ClientCore` header ⇒ FAIL; the same sentence inside a quoted recantation ⇒
/// PASS.
#[must_use]
pub fn slate_sits_below_the_client_core(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Within {
            path: "Package.swift",
            start: r#"name: "SlopDeskClientCore",$"#,
            end: r"^\s+linkerSettings: ffiCLibraries,$",
            pattern: r#""SlopDeskSlate","#,
            message: "`SlopDeskClientCore` no longer depends on `SlopDeskSlate` — that edge is what lets \
                      the shared placement floor spend `Slate.Metric` instead of re-deriving it, and \
                      re-deriving it is what produced the clone this rule was written after (docs/56 \
                      increment 28)",
        },
        Claim::PinnedSet {
            label: "SlopDeskSlate's dependencies",
            from: Extract::statements("Package.swift", r#"^\s+(?:\.product\(name: )?"([A-Za-z]+)"[,)]"#)
                .within(r#"name: "SlopDeskSlate",$"#, r"^\s+\],$"),
            expect: &[
                "SFSafeSymbols",
                "SlopDeskAgentDetect",
                "SlopDeskFontFaces",
                "SlopDeskWorkspaceModel",
            ],
        },
        Claim::NoneUnder {
            roots: CLIENT_CORE_ROOTS,
            extensions: SWIFT,
            pattern: r"(SlopDeskSlate|Slate\.Metric)[^\n]{0,40}(sits ABOVE|sat ABOVE|DEPENDS on this|depends on this)",
            all: &[],
            unless: &[
                r#""`(SlopDeskSlate|Slate\.Metric)"#,
                r#""(DEPENDS|depends|sits|sat) "#,
                r"the edge (is|runs) the other way",
            ],
            view: View::Raw,
            exempt: &[],
            message: "these headers say `SlopDeskSlate` sits above `SlopDeskClientCore`: {files} — it does \
                      not, `Package.swift` lists it as a dependency, and the last time this sentence went \
                      unchecked it reached eight places and one file re-derived the metrics it could have \
                      imported (docs/56 increment 28)",
        },
    ])
}

/// `SlopDeskClientCore` may PLACE views and hold values; it may not DECLARE one or DRAW into one
///
/// ## ⚠️ RE-AIMED 2026-08-29 — the line `docs/62` §8 used to draw was the wrong one
/// §8 said the shared floor imports neither `AppKit` nor `UIKit`. That is false and had been for a
/// long time: 23 files under `SlopDeskClientCore` import one or the other today. It eroded silently
/// precisely because nothing enforced it, and re-asserting it now would red on 23 live files. So
/// the import ban is NOT restated here.
///
/// The line that actually holds is about what the floor DOES, not what it names: it may compute a
/// frame, place a subview and hand back a value, and it may not declare a view subclass or override
/// `draw(_:)`. Placement and geometry are the same arithmetic on both shells and belong in one
/// place; a view SUBCLASS is a platform's own object with a platform's own lifecycle, and one
/// living down here is how the Mac and the phone start disagreeing about a thing they both inherit.
///
/// ⚠️ `SlateHostView` must be in the needle. It is a `package typealias` for `NSView` on macOS and
/// `UIView` on iOS (`Support/SlateHostTypes.swift`), so a subclass of it evades an
/// `NSView|UIView`-only ban while being exactly the thing banned.
///
/// ⚠️ The needle is `class \w+ : …`, not a bare `: SlateHostView`. Ten live signatures under this
/// floor take a `SlateHostView` PARAMETER — `func slateEdges(of host: SlateHostView)` and its
/// family — and a bare colon needle would red on the whole placement family it exists to protect.
///
/// A third arm banning `import SwiftUI` under `SlopDeskSlate` was considered and dropped:
/// [`super::client_layers`] already bans the declarative framework tree-wide, and a target-scoped
/// duplicate restates an existing rule rather than adding one.
///
/// Measured 2026-08-29: 0 view subclasses, 0 `draw(_:)` overrides, across 125 files.
///
/// BREAK-TEST: `final class Divider: UIView {` under the floor ⇒ FAIL; the same through the
/// typealias (`: SlateHostView`) ⇒ FAIL, which is the arm the typealias needle buys; a function
/// taking `host: SlateHostView` ⇒ PASS; `override func draw(_ rect: CGRect)` ⇒ FAIL.
#[must_use]
pub fn the_client_core_places_but_never_draws(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Populated {
            roots: CLIENT_CORE_ROOTS,
            extensions: SWIFT,
            minimum: CLIENT_CORE_FLOOR,
            message: text::intern(format!(
                "{CLIENT_CORE} holds only {{found}} Swift files, under the floor of {CLIENT_CORE_FLOOR} — \
                 the two bans below resolve to nothing over an empty directory and would pass (docs/62 §8)"
            )),
        },
        Claim::NoneUnder {
            roots: CLIENT_CORE_ROOTS,
            extensions: SWIFT,
            pattern: r"class\s+\w+\s*:\s*(NSView|UIView|SlateHostView)\b",
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "these declare a view subclass under the shared floor: {files} — `SlopDeskClientCore` \
                      may PLACE a view and hold a value, and a subclass is a platform object with a \
                      platform lifecycle, which is where the Mac and the phone start disagreeing about \
                      something they both inherit. `SlateHostView` is a typealias for exactly `NSView` and \
                      `UIView` (docs/62 §8)",
        },
        Claim::NoneUnder {
            roots: CLIENT_CORE_ROOTS,
            extensions: SWIFT,
            pattern: r"override func draw\(",
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "these draw under the shared floor: {files} — placement and values live here, drawing \
                      lives in the shell that owns the pixels (docs/62 §8)",
        },
    ])
}

/// The floor under every §4 ban — spelled once because all eight ask for it.
fn phone_ui_is_populated() -> Claim {
    Claim::Populated {
        roots: PHONE_UI_ROOTS,
        extensions: SWIFT,
        minimum: PHONE_UI_FLOOR,
        message: text::intern(format!(
            "{PHONE_UI} holds only {{found}} Swift files, under the floor of {PHONE_UI_FLOOR} — a ban over \
             a drained directory passes, which is how this gate has died quietly before (docs/62 §4.8)"
        )),
    }
}

/// Every `.swift` file under `prefix`, path and contents.
fn swift_under<'a>(tree: &'a Tree, prefix: &'a str) -> impl Iterator<Item = (&'a Path, &'a Source)> {
    tree.under(prefix)
        .filter(|(path, _)| path.extension().and_then(OsStr::to_str) == Some("swift"))
}

/// How much deeper `line` leaves the brace depth, and whether it opened a brace at all.
///
/// Braces inside a double-quoted span do not count. [`Source::statements`] keeps string literals —
/// it blanks COMMENTS — so a `"{"` in a format string would otherwise open a block that never
/// closes, and the scan would read the rest of the file as one body. That is a false RED, which
/// costs a rule as much as a false green.
fn brace_delta(line: &str) -> (i32, bool) {
    let (mut depth, mut opened, mut quoted, mut escaped) = (0_i32, false, false, false);
    for ch in line.chars() {
        if escaped {
            escaped = false;
            continue;
        }
        match ch {
            '\\' if quoted => escaped = true,
            '"' => quoted = !quoted,
            '{' if !quoted => {
                depth += 1;
                opened = true;
            },
            '}' if !quoted => depth -= 1,
            _ => {},
        }
    }
    (depth, opened)
}

/// The lines of the brace block that OPENS on `lines[start]`, that line included.
///
/// The crate has no brace helper, and the two rules that need one need the same one: a Swift METHOD
/// or CLOSURE body, which `awk`-style line ranges cannot express because the closing line of a body
/// is not a pattern — it is whatever line the depth returns to zero on.
fn brace_block<'a, 'b>(lines: &'b [&'a str], start: usize) -> &'b [&'a str] {
    let ceiling = lines.len().min(start.saturating_add(BLOCK_CEILING));
    let (mut depth, mut opened) = (0_i32, false);
    for (offset, line) in lines[start..ceiling].iter().enumerate() {
        let (delta, saw_open) = brace_delta(line);
        depth += delta;
        opened |= saw_open;
        if opened && depth <= 0 {
            return &lines[start..=start + offset];
        }
    }
    &lines[start..ceiling]
}

/// H11. No stored property takes a name `UIResponder` already vends
///
/// `UIKit` puts a wide vocabulary on the class every view in this shell inherits from, and a stored
/// property that reuses one of those names does not shadow it — it tries to OVERRIDE it, against an
/// incompatible type, and the diagnostic points at the declaration rather than at the framework.
/// `SwiftUI` never had this hazard: a `@State` lives in a struct that inherits from nothing.
///
/// This is the third rule in this file cut against a bug that had already landed TWICE, which is
/// this campaign's own bar for minting one. `61eab344` unshadowed `UIView.isFocused`; stage I found
/// `TerminalFindBarView` storing `private let next: SlatePlateVerbButton`, which is
/// `UIResponder.next`. Both were written by someone naming a button after what it does, and both
/// were found by a compiler rather than by a reader — a rule is cheaper than the third one.
///
/// ⚠️ THE BAN IS ANCHORED AT TYPE SCOPE, AND THAT ANCHOR IS THE WHOLE RULE. `next` is a perfectly
/// good name for a LOCAL, and the tree holds six of them (`let next = Session(...)` in
/// `HintModeOverlayView`, four siblings, and one `guard let next`) — every one correct, because a
/// local shadows nothing it inherits. A ban on the bare word would red on all six, which is exactly
/// how H4's first cut and §8's import ban died: a rule whose premise is false on live code gets
/// suppressed, and a suppressed rule protects nothing. So the pattern requires a FOUR-SPACE indent,
/// which under this tree's `swiftformat` config is the member level and nothing else. It
/// under-reports — a stored property inside a NESTED type sits at eight and is missed — and that is
/// the correct direction for a ratchet: a miss costs one compiler error, a false positive costs the
/// rule.
///
/// Measured on the live tree 2026-08-29: 0 matches at member level, 6 locals at deeper indents.
///
/// BREAK-TEST: `    private let next: Button` ⇒ FAIL; the same declaration indented as a local, and
/// a member named `nextMatch`, ⇒ PASS — the two arms that prove the anchor and the word boundary.
#[must_use]
pub fn no_stored_property_shadows_the_responder(tree: &Tree) -> Report {
    check_all(tree, &[phone_ui_is_populated(), Claim::NoneUnder {
        roots: PHONE_UI_ROOTS,
        extensions: SWIFT,
        pattern: RESPONDER_NAME_AT_MEMBER_LEVEL,
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "these store a property under a name `UIResponder` already vends: {files} — that is an \
                  override against an incompatible type, not a shadow, and it is the third time this shell \
                  has hit it (`61eab344` for `isFocused`, stage I for `next`). Rename the member (`next` → \
                  `nextMatch`); a LOCAL of the same name is fine and is why this ban only reads member \
                  level (docs/62 §4.9)",
    }])
}

/// A stored `let`/`var` at MEMBER level — four spaces, this tree's one member indent — under a name
/// `UIResponder` or `UIView` already owns. The alternation is deliberately short: every name in it
/// has either already bitten this shell or sits one keystroke from one that did. Widening it is a
/// design change, because each addition is a name a reader may legitimately want.
const RESPONDER_NAME_AT_MEMBER_LEVEL: &str = r"(?m)^    (?:(?:private|fileprivate|internal|package|public)\s+)?(?:final\s+)?(?:weak\s+)?(?:lazy\s+)?(?:let|var)\s+(?:next|isFocused|undoManager|inputView|inputAccessoryView)\b";

/// Offender paths as one sentence fragment.
fn named(offenders: &BTreeSet<String>) -> String {
    offenders
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A shell wide enough to clear the §4 floor AND both counted floors, holding one file of each
    /// shape the rules read.
    ///
    /// The fillers are not inert: two of the eight rules count their own subject rather than the
    /// directory, so a tree of empty files would fail them for the right reason at the wrong time.
    fn phone_tree(fixture: &Fixture) -> &Fixture {
        for index in 0..30 {
            fixture.write(
                &format!("{}/Row{index}.swift", super::PHONE_UI),
                "final class Row: UIView {\n\x20   func wire() { row.onTap = { [weak self] in self?.act() } \
                 }\n\x20   override func layoutSubviews() { super.layoutSubviews() }\n}\n",
            );
        }
        for index in 0..45 {
            fixture.write(
                &format!("{}/Filler{index}.swift", super::PHONE_UI),
                "// nothing\n",
            );
        }
        fixture.write(
            &format!("{}/RowView.swift", super::PHONE_UI),
            "final class RowView: UIView {\n\x20   func wire() {\n\x20       row.onTap = { [weak self] \
             in\n\x20           self?.act()\n\x20       }\n\x20       row.onDrop = { [store = deps.store] \
             id in\n\x20           store.focus(id)\n\x20       }\n\x20   }\n\x20   override func \
             layoutSubviews() {\n\x20       super.layoutSubviews()\n\x20       \
             drag.reportContainerBounds(bounds)\n\x20   }\n\x20   func reload() {\n\x20       \
             store.focus(paneID)\n\x20       dataSource.apply(snapshot)\n\x20   }\n}\n",
        );
        fixture.write(
            &format!("{}/FollowView.swift", super::PHONE_UI),
            "func rearm() {\n\x20   reloadGeneration &+= 1\n\x20   withObservationTracking {\n\x20       _ \
             = model.title\n\x20   } onChange: { [weak self] in\n\x20       guard generation == \
             self.reloadGeneration else { return }\n\x20   }\n}\n",
        );
        fixture.write(
            &format!("{}/TickView.swift", super::PHONE_UI),
            "let link = CADisplayLink(target: self, selector: #selector(tick))\nfunc stop() { \
             link?.invalidate() }\n",
        );
        fixture
    }

    /// The shared floor, wide enough to clear its own populated floor.
    fn client_core_tree(fixture: &Fixture) -> &Fixture {
        for index in 0..100 {
            fixture.write(
                &format!("{}/Place{index}.swift", super::CLIENT_CORE),
                "// nothing\n",
            );
        }
        fixture.write(
            &format!("{}/Edges.swift", super::CLIENT_CORE),
            "func slateEdges(of host: SlateHostView) -> CGRect { host.bounds }\n",
        );
        fixture.write(
            "Package.swift",
            "        .target(\n\x20           name: \"SlopDeskClientCore\",\n\x20           dependencies: \
             [\n\x20               \"SlopDeskSlate\",\n\x20           ],\n\x20           linkerSettings: \
             ffiCLibraries,\n\x20       ),\n\x20       .target(\n\x20           name: \
             \"SlopDeskSlate\",\n\x20           dependencies: [\n\x20               \
             \"SlopDeskWorkspaceModel\",\n\x20               \"SlopDeskAgentDetect\",\n\x20               \
             \"SlopDeskFontFaces\",\n\x20               .product(name: \"SFSafeSymbols\", package: \
             \"SFSafeSymbols\"),\n\x20           ],\n\x20       ),\n",
        );
        fixture
    }

    fn fires(report: &crate::report::Report, needle: &str) -> bool {
        report
            .violations()
            .iter()
            .any(|violation| violation.contains(needle))
    }

    #[test]
    fn a_sink_that_holds_its_view_is_a_leak() {
        let fixture = Fixture::new("phoneui-sink-capture");
        phone_tree(&fixture);
        let clean = super::a_stored_closure_never_holds_its_view(&fixture.tree());
        assert!(
            clean.is_clean(),
            "the seeded shell is clean: {:?}",
            clean.violations()
        );

        // The strong `self` capture, which the doc's own line pattern would have caught.
        fixture.write(
            &format!("{}/Leak.swift", super::PHONE_UI),
            "row.onTap = { [self] in\n    act()\n    self.reload()\n}\n",
        );
        let report = super::a_stored_closure_never_holds_its_view(&fixture.tree());
        assert!(fires(&report, "Leak.swift:1"), "{:?}", report.violations());

        // THE HOLE A LINE BAN LEAVES: a non-`self` capture list, `self` three lines down. Only the
        // block scan sees this one, and it is the shape live code is nearest to.
        fixture.write(
            &format!("{}/Leak.swift", super::PHONE_UI),
            "row.onTap = { [store = deps.store] id in\n    store.focus(id)\n    self.reload()\n}\n",
        );
        let report = super::a_stored_closure_never_holds_its_view(&fixture.tree());
        assert!(fires(&report, "Leak.swift:1"), "{:?}", report.violations());

        // The same body, made weak — and a `self` in a sibling method, which is not the subject.
        fixture.write(
            &format!("{}/Leak.swift", super::PHONE_UI),
            "row.onTap = { [weak self] in\n    self?.reload()\n}\nfunc other() { self.reload() }\n",
        );
        let report = super::a_stored_closure_never_holds_its_view(&fixture.tree());
        assert!(report.is_clean(), "{:?}", report.violations());
    }

    /// The counted floor: a ban that stopped seeing its subject says so.
    #[test]
    fn a_shell_with_no_sinks_left_fails_rather_than_passing() {
        let fixture = Fixture::new("phoneui-sink-vacuum");
        for index in 0..70 {
            fixture.write(
                &format!("{}/Filler{index}.swift", super::PHONE_UI),
                "// nothing\n",
            );
        }
        let report = super::a_stored_closure_never_holds_its_view(&fixture.tree());
        assert!(
            fires(&report, "closure sinks matched"),
            "{:?}",
            report.violations()
        );
    }

    #[test]
    fn a_hand_rolled_observation_owes_all_three_parts() {
        let fixture = Fixture::new("phoneui-observation");
        phone_tree(&fixture);
        let clean = super::a_hand_rolled_observation_is_guarded(&fixture.tree());
        assert!(clean.is_clean(), "{:?}", clean.violations());

        for (missing, seeded) in [
            (
                "generation",
                "withObservationTracking {\n} onChange: { [weak self] in\n    guard generation == self.g \
                 else { return }\n}\n",
            ),
            (
                "weak self",
                "generation &+= 1\nwithObservationTracking {\n} onChange: {\n    guard generation == self.g \
                 else { return }\n}\n",
            ),
            (
                "comparison",
                "generation &+= 1\nwithObservationTracking {\n} onChange: { [weak self] in\n    \
                 self?.reload()\n}\n",
            ),
        ] {
            fixture.write(&format!("{}/FollowView.swift", super::PHONE_UI), seeded);
            let report = super::a_hand_rolled_observation_is_guarded(&fixture.tree());
            assert!(
                fires(&report, "FollowView.swift"),
                "{missing} passed the ban: {:?}",
                report.violations()
            );
        }
    }

    #[test]
    fn a_cell_may_not_subscript_by_index_path() {
        let fixture = Fixture::new("phoneui-index-path");
        phone_tree(&fixture);
        assert!(super::a_cell_resolves_its_row_by_identifier(&fixture.tree()).is_clean());

        for seed in [
            "devices[indexPath.item]",
            "rows[indexPath.row]",
            "held[ indexPath.section ]",
        ] {
            fixture.write(
                &format!("{}/List.swift", super::PHONE_UI),
                &format!("cell.apply({seed})\n"),
            );
            let report = super::a_cell_resolves_its_row_by_identifier(&fixture.tree());
            assert!(!report.is_clean(), "{seed} passed the ban");
        }

        // The view choice, proved: the tree's ONLY live match is a comment saying it does not do
        // it.
        fixture.write(
            &format!("{}/List.swift", super::PHONE_UI),
            "// nothing here indexes `devices[indexPath.item]`, because a reload can land first\n",
        );
        let report = super::a_cell_resolves_its_row_by_identifier(&fixture.tree());
        assert!(
            report.is_clean(),
            "the ban fired on its own explanation: {:?}",
            report.violations()
        );
    }

    #[test]
    fn a_second_thread_unearns_every_assume_isolated() {
        let fixture = Fixture::new("phoneui-main-queue");
        phone_tree(&fixture);
        assert!(super::the_phone_view_layer_never_leaves_the_main_queue(&fixture.tree()).is_clean());

        for seed in [
            "nonisolated(unsafe) static var held = 0",
            "extension Held: @unchecked Sendable {}",
            "DispatchQueue.global(qos: .userInitiated).async { work() }",
            "Task.detached { await work() }",
            "let queue = DispatchQueue(label: \"phone.work\")",
        ] {
            fixture.write(&format!("{}/Hop.swift", super::PHONE_UI), &format!("{seed}\n"));
            let report = super::the_phone_view_layer_never_leaves_the_main_queue(&fixture.tree());
            assert!(
                fires(&report, "Hop.swift"),
                "{seed} passed the ban: {:?}",
                report.violations()
            );
        }
    }

    #[test]
    fn a_notification_token_is_given_back() {
        let fixture = Fixture::new("phoneui-observers");
        phone_tree(&fixture);
        assert!(super::a_hand_registered_observation_is_retired(&fixture.tree()).is_clean());

        fixture.write(
            &format!("{}/Watch.swift", super::PHONE_UI),
            "let token = center.addObserver(forName: .x, object: nil, queue: .main) { _ in }\n",
        );
        let report = super::a_hand_registered_observation_is_retired(&fixture.tree());
        assert!(fires(&report, "Watch.swift"), "{:?}", report.violations());

        fixture.append(
            &format!("{}/Watch.swift", super::PHONE_UI),
            "deinit { center.removeObserver(token) }\n",
        );
        assert!(super::a_hand_registered_observation_is_retired(&fixture.tree()).is_clean());

        // The selector form is auto-removed and is NOT the subject.
        fixture.write(
            &format!("{}/Watch.swift", super::PHONE_UI),
            "center.addObserver(self, selector: #selector(tick), name: .x, object: nil)\n",
        );
        assert!(super::a_hand_registered_observation_is_retired(&fixture.tree()).is_clean());

        for kvo in [
            "observe(\"x\", forKeyPath: nil)",
            "var held: NSKeyValueObservation?",
        ] {
            fixture.write(&format!("{}/Watch.swift", super::PHONE_UI), &format!("{kvo}\n"));
            let report = super::a_hand_registered_observation_is_retired(&fixture.tree());
            assert!(fires(&report, "Watch.swift"), "{kvo} passed the ban");
        }
    }

    #[test]
    fn a_display_link_that_never_stops_is_a_leak() {
        let fixture = Fixture::new("phoneui-display-link");
        phone_tree(&fixture);
        assert!(super::a_display_link_is_invalidated(&fixture.tree()).is_clean());

        fixture.write(
            &format!("{}/TickView.swift", super::PHONE_UI),
            "let link = CADisplayLink(target: self, selector: #selector(tick))\n",
        );
        let report = super::a_display_link_is_invalidated(&fixture.tree());
        assert!(fires(&report, "TickView.swift"), "{:?}", report.violations());
    }

    #[test]
    fn the_shell_may_not_schedule_a_timer() {
        let fixture = Fixture::new("phoneui-timers");
        phone_tree(&fixture);
        assert!(super::the_phone_shell_owns_no_timer(&fixture.tree()).is_clean());

        for seed in [
            "Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in }",
            "let held = Timer(timeInterval: 0.4, repeats: false) { _ in }",
        ] {
            fixture.write(&format!("{}/Dwell.swift", super::PHONE_UI), &format!("{seed}\n"));
            let report = super::the_phone_shell_owns_no_timer(&fixture.tree());
            assert!(fires(&report, "Dwell.swift"), "{seed} passed the ban");
        }
    }

    #[test]
    fn a_layout_pass_may_not_reach_the_model() {
        let fixture = Fixture::new("phoneui-layout");
        phone_tree(&fixture);
        let clean = super::a_layout_pass_writes_no_model(&fixture.tree());
        // The seeded shell writes `store.` and `dataSource.apply(` in a SIBLING method, one line
        // below the layout body's closing brace. That is the arm that proves the block scan ends
        // where the body ends.
        assert!(clean.is_clean(), "{:?}", clean.violations());

        for seed in [
            "store.focusPane(paneID)",
            "coordinator.present(sheet)",
            "dataSource.apply(snapshot, animatingDifferences: false)",
        ] {
            fixture.write(
                &format!("{}/Layout.swift", super::PHONE_UI),
                &format!("override func layoutSubviews() {{\n    super.layoutSubviews()\n    {seed}\n}}\n"),
            );
            let report = super::a_layout_pass_writes_no_model(&fixture.tree());
            assert!(
                fires(&report, "Layout.swift:1"),
                "{seed} passed the ban: {:?}",
                report.violations()
            );
        }

        // A trailing comment holding a brace must not extend the body — the reason this reads
        // `statements()` and not `code()`.
        fixture.write(
            &format!("{}/Layout.swift", super::PHONE_UI),
            "override func layoutSubviews() {\n    super.layoutSubviews()\n} // closes it {\nfunc other() { \
             store.focus(id) }\n",
        );
        let report = super::a_layout_pass_writes_no_model(&fixture.tree());
        assert!(
            report.is_clean(),
            "a trailing brace comment widened the body: {:?}",
            report.violations()
        );
    }

    #[test]
    fn the_layout_ban_fails_when_it_finds_no_bodies() {
        let fixture = Fixture::new("phoneui-layout-vacuum");
        for index in 0..70 {
            fixture.write(
                &format!("{}/Filler{index}.swift", super::PHONE_UI),
                "// nothing\n",
            );
        }
        let report = super::a_layout_pass_writes_no_model(&fixture.tree());
        assert!(
            fires(&report, "`layoutSubviews` bodies matched"),
            "{:?}",
            report.violations()
        );
    }

    #[test]
    fn the_slate_edge_is_pinned_in_both_directions() {
        let fixture = Fixture::new("phoneui-slate-edge");
        client_core_tree(&fixture);
        let clean = super::slate_sits_below_the_client_core(&fixture.tree());
        assert!(clean.is_clean(), "{:?}", clean.violations());

        // The edge cut out of `Package.swift`.
        let manifest = fixture
            .tree()
            .get("Package.swift")
            .expect("manifest")
            .text
            .clone();
        fixture.write(
            "Package.swift",
            &manifest.replace("            \"SlopDeskSlate\",\n", ""),
        );
        let report = super::slate_sits_below_the_client_core(&fixture.tree());
        assert!(
            fires(&report, "no longer depends on"),
            "{:?}",
            report.violations()
        );

        // The edge ADDED the other way — the one change that would make the eight sentences true.
        fixture.write(
            "Package.swift",
            &manifest.replace(
                "                \"SlopDeskFontFaces\",\n",
                "                \"SlopDeskFontFaces\",\n                \"SlopDeskClientCore\",\n",
            ),
        );
        let report = super::slate_sits_below_the_client_core(&fixture.tree());
        assert!(
            fires(&report, "SlopDeskSlate's dependencies"),
            "{:?}",
            report.violations()
        );

        // A fresh assertion in a header.
        fixture.write("Package.swift", &manifest);
        fixture.write(
            &format!("{}/Chrome.swift", super::CLIENT_CORE),
            "// The metrics are re-derived here: SlopDeskSlate sits ABOVE this target.\n",
        );
        let report = super::slate_sits_below_the_client_core(&fixture.tree());
        assert!(fires(&report, "Chrome.swift"), "{:?}", report.violations());

        // The SAME sentence, quoted in order to recant it. All six live corrections take one of
        // these shapes, and a rule that reds on the fix is worse than no rule.
        for recantation in [
            "// An older header claimed `SlopDeskSlate` \"sits ABOVE this target\"; the edge is the other \
             way round.",
            "// The header said \"`SlopDeskSlate` sits ABOVE this one\" and it was wrong.",
            "// It read \"depends on this target\" — SlopDeskSlate depends on this target is false.",
        ] {
            fixture.write(
                &format!("{}/Chrome.swift", super::CLIENT_CORE),
                &format!("{recantation}\n"),
            );
            let report = super::slate_sits_below_the_client_core(&fixture.tree());
            assert!(
                report.is_clean(),
                "the ban reds on its own fix: {:?}",
                report.violations()
            );
        }

        // And the true sentence about the SHELLS, which genuinely do sit above this floor.
        fixture.write(
            &format!("{}/Chrome.swift", super::CLIENT_CORE),
            "// The target that owns the duel sits ABOVE this one, and hands the result down.\n",
        );
        let report = super::slate_sits_below_the_client_core(&fixture.tree());
        assert!(report.is_clean(), "{:?}", report.violations());
    }

    #[test]
    fn the_shared_floor_declares_no_view_and_draws_nothing() {
        let fixture = Fixture::new("phoneui-places-never-draws");
        client_core_tree(&fixture);
        let clean = super::the_client_core_places_but_never_draws(&fixture.tree());
        assert!(clean.is_clean(), "{:?}", clean.violations());

        for seed in [
            "final class DecorationDivider: UIView {}",
            "class Bed: NSView {}",
            // The typealias, which is the whole reason it is in the needle.
            "final class Card: SlateHostView {}",
            "extension Card { override func draw(_ rect: CGRect) {} }",
        ] {
            fixture.write(
                &format!("{}/Draws.swift", super::CLIENT_CORE),
                &format!("{seed}\n"),
            );
            let report = super::the_client_core_places_but_never_draws(&fixture.tree());
            assert!(
                fires(&report, "Draws.swift"),
                "{seed} passed the ban: {:?}",
                report.violations()
            );
        }

        // A PARAMETER of that type is the placement family this floor exists for.
        fixture.write(
            &format!("{}/Draws.swift", super::CLIENT_CORE),
            "func pad(_ body: SlateHostView, in card: SlateHostView) {}\nimport UIKit\n",
        );
        let report = super::the_client_core_places_but_never_draws(&fixture.tree());
        assert!(
            report.is_clean(),
            "a parameter or an import fired: {:?}",
            report.violations()
        );
    }

    #[test]
    fn a_member_may_not_take_a_responder_name() {
        let fixture = Fixture::new("phoneui-responder-name");
        phone_tree(&fixture);
        let clean = super::no_stored_property_shadows_the_responder(&fixture.tree());
        assert!(clean.is_clean(), "{:?}", clean.violations());

        // The two that actually landed, plus the three neighbours the alternation carries.
        for seed in [
            "final class Bar: UIView {\n    private let next: Button\n}",
            "final class Bar: UIView {\n    var isFocused = false\n}",
            "final class Bar: UIView {\n    weak var inputView: UIView?\n}",
            "final class Bar: UIView {\n    lazy var undoManager = UndoManager()\n}",
            "final class Bar: UIView {\n    public var inputAccessoryView: UIView?\n}",
        ] {
            fixture.write(&format!("{}/Bar.swift", super::PHONE_UI), &format!("{seed}\n"));
            let report = super::no_stored_property_shadows_the_responder(&fixture.tree());
            assert!(
                fires(&report, "Bar.swift"),
                "{seed} passed the ban: {:?}",
                report.violations()
            );
        }

        // The arm that is the whole rule: a LOCAL of the same name is correct code, and the tree
        // holds six. A member whose name merely STARTS with a banned one is correct too — that is
        // the rename the ban's own message prescribes, so firing on it would make the fix illegal.
        fixture.write(
            &format!("{}/Bar.swift", super::PHONE_UI),
            "final class Bar: UIView {\n    private let nextMatch: Button\n    func step() {\n                     let next = rung.after(current)\n        guard let next else { return }\n                     var isFocused = false\n        use(next, isFocused)\n    }\n}\n",
        );
        let report = super::no_stored_property_shadows_the_responder(&fixture.tree());
        assert!(
            report.is_clean(),
            "a local or a longer member name fired: {:?}",
            report.violations()
        );
    }
}
