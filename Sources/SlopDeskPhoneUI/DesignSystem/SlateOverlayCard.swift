// SlateOverlayCard — the shared vocabulary every FLOATING surface speaks: the paper card it is drawn on,
// the plate a selected row lifts onto, and the keycap a pressable key is set in.
//
// It was written for the ⌃⇥ pane switcher and then, once that card was the one surface the user liked,
// promoted here so the palette / Open Quickly / global search / cheat sheet / connect / peek-reply all read
// as the SAME object. Before this file each of those was a native `.sheet` in the system's own voice —
// a grouped `Form`, a `List` with section backgrounds, an opaque window ground — and the set had no
// common shape at all: six dialogs that happened to share a presentation modifier.
//
// The four moves, which is all "the switcher's style" actually is:
//
//   1. The SURFACE is PAPER: the ground's own cream, opaque, cut at the FAMILY's own corner
//      (``Slate/Metric/radiusPanel`` — not the island's; ``SlatePaperCardSurface/apply(to:)`` is where
//      the corner is cut, the SwiftUI `shape` having been a property of a view that no longer exists),
//      edged by a
//      hairline and dropped on a real shadow. It was Liquid Glass until 2026-08-08, and ONE
//      ISLAND took that material's reason away. Glass earns its keep by refracting what varies behind
//      it; behind these cards now lie exactly two flat opaque tones, so the effect degraded to a grey
//      slab that also flipped relationship halfway across itself — light-over-cream at the edges,
//      light-over-glass in the middle. Apple's own rule points the same way (avoid stacking glass;
//      apply the material once, at the top). Rendered side by side at true size, the paper card reads
//      as a sheet laid on the canvas and the glass one all but disappeared into it.
//   2. NO chrome inside it. No `Divider` between regions, no grouped-`Form` insets, no `List` section fills.
//      A card that is already a distinct object does not need internal boxes to say where it ends; spacing
//      carries the structure. This is the move that makes the surfaces look related rather than merely tinted.
//   3. A selected row is a PLATE — one surface rung up, hairline-bordered — and its title goes HEAVIER.
//      Never coloured: importance is light and weight, not hue (DECISIONS §git-line-two-registers).
//   4. A key you can press right now is drawn as a KEYCAP in the instrument voice. A bare glyph run does not
//      say "press this"; a cap does.
//
// ⚠️ THE INK IS NEUTRAL, NOT THE TERMINAL'S. `Slate` supplies every DIMENSION here (raw font/radius/height
// literals fail the `design-token-leaks` gate) and the mono FACE, but none of its colour. A floating card is
// not part of the workspace's world: the profile's greys are tinted violet, and a dialog wearing them
// reads as a stained panel rather than as a neutral surface hovering over coloured work. So the family's
// ink comes from the SYSTEM's semantic colours (``Slate/Native/Overlay``), which are neutral by
// construction.
// The card stands on the CHROME's polarity — the same light the navigator and the panel stand in — so
// every one of those inks resolves dark on the cream without a single call site changing.
//
// Nor is the MACHINE'S accent part of the family. It was the last colour left — the caret, the fuzzy-match
// run, the ✓ gutter, the default button — and a card that is otherwise monochrome reads as a system dialog
// the moment one blue thing lands on it (and as a PINK one on a machine whose accent is pink, which is not
// a decision this design gets to make). A match run is marked the way every other readout here marks
// importance: heavier, against quieter neighbours. Filled controls, focus rings and selection are handled
// APP-WIDE by the neutral AccentColor asset (see Apps/Shared/Assets.xcassets) — the one supported way to
// reach the focus ring, which no per-subtree `.tint()` can.
//
// Status colour is the exception and stays: a blocked agent's mark and a validation warning MEAN something,
// and neutrality is about the chrome not competing, never about suppressing a signal.
//
// No AppKit, so this compiles for iOS with the rest of `SlopDeskPhoneUI`. The Mac speaks the same
// vocabulary through its own `Mac*` views, and the two meet in `SlopDeskSlate`'s tokens rather than here.

#if os(iOS)
import QuartzCore
import SlopDeskSlate
import UIKit

// ⚠️ THE FAMILY IS TWO SHAPES, AND WHICH ONE A SURFACE TAKES IS THIS FILE'S ONE REAL DECISION. Decorating
// a view is not a type, so the suffix says how each member is spent:
//
//   * `…Surface` — an `enum` of static functions that CONFIGURE THE CALLER'S OWN LAYER. Taken wherever the
//     whole of a surface lives in `layer` properties, because it then costs ZERO views. On a phone that is
//     not tidiness: ``SlateSelectionPlateSurface`` is applied to every row of a scrolling list, and a
//     wrapper view per row is a wrapper view per row, measured on every layout pass and composited on
//     every frame.
//   * `…View` — a real `UIView` that HOSTS its content. Taken only where a surface adds chrome a
//     decoration cannot supply: an inset around arbitrary content, a second layer, a polarity flip. Of the
//     four decorating members here, ``SlatePaperCapsuleView`` is the ONLY one that earns a view.
//
// ⚠️ AND THE `CGColor` PROBLEM RUNS THROUGH ALL OF THEM, because these surfaces are mostly EDGE. A view's
// own `backgroundColor` stays dynamic — UIKit re-resolves it on every trait change for free — so every
// fill here is a view-level fill and no fill is ever re-inked. A `CALayer`'s `borderColor`/`shadowColor`
// is a flat `CGColor`, fixed at the appearance current when it was assigned, so those two are resolved
// against the view's traits and re-applied through `registerForTraitChanges`. `traitCollectionDidChange`
// is gone from this tree; the registration names the ONE trait these surfaces depend on.

// MARK: - The card surface

/// The floating card's SURFACE: PAPER — the ground's cream, opaque, at the floating family's own corner,
/// edged by a hairline and dropped on the deepest rung of the shadow ladder. A DECORATION of the caller's
/// own view, and the twin of the Mac's ``SlopDeskMacUI/MacOverlayCardView``.
///
/// Nothing here is appearance-directed any more. The app has ONE polarity (`SlateAppearancePin`), one
/// ground and one glass, so a card that summoned itself over the workspace is either the ground raised or
/// the glass repeated — and the glass repeated is invisible, because a card lands centred, which is where
/// the island already is. The cream reverses that: ~13:1 against the canvas it covers, and against the
/// ground at the card's edges the hairline and the cast shadow carry it, exactly as they carry the island
/// itself. No material, no rim highlight, no Reduce-Transparency branch to keep honest.
///
/// ⚠️ A CONFIGURATOR RATHER THAN A HOSTING VIEW, AND HIT-TESTING IS WHY IT CAN BE. Three of the card's
/// four ingredients — the cream, the rim, the cast — are `layer` properties. The FOURTH was an invisible
/// button BEHIND the content, and it is not needed here at all: a framework that hit-tests DRAWN CONTENT
/// let a tap landing on a card's inert body (a label's padding, the gap beside a disclosure row) fall
/// straight through to the dismiss floor and close the card the user was reaching into, and the barrier
/// was the correctness fix for it. UIKit hit-tests BOUNDS — `hitTest(_:)` returns the deepest view
/// whose `point(inside:)` is true — so any `UIView` already stops every touch inside it. The one card that
/// had to OPT OUT of the barrier (the notification card, whose whole body is its jump action) needs no opt
/// out either: it is a ``SlateRowButton``, and a control cannot be outranked by a background it does not
/// have.
///
/// ⚠️ What the caller still owes is the pair UIKit hit-tests on: a view at `alpha == 0`, `isHidden`, or
/// `isUserInteractionEnabled == false` takes no touches AT ALL, and the floor below starts eating them
/// again. Clear is not transparent.
@MainActor
enum SlatePaperCardSurface {
    /// Dress `view` as a floating paper card. ONCE, at construction — this installs a trait-change
    /// registration, and registrations STACK on a second call (the re-ink is idempotent, so a stacked
    /// one is wasted work rather than a wrong colour, but there is no reason to pay for it).
    ///
    /// ⚠️ IT IS HALF OF A CONTRACT: the shadow is not finished until ``layoutShadow(of:)`` has run from
    /// the caller's `layoutSubviews`. See that function for what the missing half costs.
    static func apply(to view: UIView) {
        // The ground's own cream, opaque. A VIEW-level fill, so it follows the appearance by itself.
        view.backgroundColor = Slate.Native.Surface.field
        // ⚠️ THE FLOATING FAMILY KEEPS ITS OWN CORNER — ``Slate/Metric/radiusPanel``, not the island's.
        // The island's is a WINDOW corner earned by a ~880 × 775pt surface; a switcher or a palette is a
        // fraction of that, so the same number reads as a soft blob rather than as a card.
        view.layer.cornerRadius = Slate.Metric.radiusPanel
        view.layer.cornerCurve = .continuous
        // ``Slate/Native/Line/overlayRim``, not the system separator: this card COVERS the workspace, so
        // its edge is the only thing saying where the object ends, and the separator lands at ~1.25 : 1
        // on the cream — a rule between two visible things, not a boundary.
        view.layer.borderWidth = Slate.Metric.hairline
        // The cast falls OUTSIDE the card, so the layer must not clip to its own bounds.
        view.layer.masksToBounds = false
        reink(view)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: UIView, _: UITraitCollection) in
            reink(card)
        }
    }

    /// The other half of the contract — call from the caller's `layoutSubviews`.
    ///
    /// ⚠️ A SHADOW WITHOUT A `shadowPath` IS A PER-FRAME RASTERISATION. With no path, Core Animation
    /// reads the alpha channel of the whole layer tree under this view to work out what shape to cast,
    /// on every frame it is composited. A card is opaque and its silhouette is known — it is exactly the
    /// rounded rect above — so handing the path over turns that into a blur of a known shape, which the
    /// render server does once. On a scrolling phone list this is the difference between 120fps and jank.
    static func layoutShadow(of view: UIView) {
        view.layer.shadowPath = UIBezierPath(
            roundedRect: view.bounds, cornerRadius: Slate.Metric.radiusPanel,
        ).cgPath
    }

    /// The two `CGColor`s, resolved against the view's own traits — see the section header for why a
    /// fill never appears here and an edge always does.
    private static func reink(_ view: UIView) {
        let traits = view.traitCollection
        view.layer.borderColor = Slate.Native.Line.overlayRim.resolvedColor(with: traits).cgColor
        // The shadow is what LIFTS an opaque cream card off an opaque cream ground — the hairline alone
        // only draws its outline. The deepest rung on purpose: this surface floats above the island,
        // which is itself already above the ground.
        view.layer.slateShadow(.palette, color: Slate.Native.State.overlayShadow, in: traits)
    }
}

/// The floating family's ONE-LINE member — the transient notice CAPSULE that stands at the island's foot
/// (`Copied`, `Tab closed`, `Jumped`, `Reply sent`) — as a real view, and the twin of the Mac's
/// ``SlopDeskMacUI/MacNoticeCapsuleView``.
///
/// ⚠️ THE ONE MEMBER THAT EARNS A HOSTING VIEW, for two reasons a layer decoration cannot supply.
/// First the INSET: generous sides against a tight top/bottom is what reads as a capsule rather than as
/// a rounded box — the proportion IS the shape here, since a capsule has no radius to tune — and an
/// inset is a thing you do to content, not to a layer. Second the POLARITY: this is the one paper
/// surface mounted INSIDE the island subtree, which the glass has forced dark, so its ink has to climb
/// back OUT of the glass or the label draws white on cream. `overrideUserInterfaceStyle` is what says so,
/// and it is inherited by the hosted content the way an ambient value would be — but there is nothing to
/// override on a caller's LAYER, which is what settles the shape of this one.
///
/// ⚠️ IT IS PAPER, AND THAT IS ARITHMETIC RATHER THAN TASTE. Drawn on the glass, the plate stood at
/// 1.63 : 1 against the face, its rim at 1.49 : 1 and the LABEL at 2.19 : 1 — under even the 3.0 floor
/// for non-text. The whole on-glass band is 3.56 : 1 wide in total and a chip needs three separable
/// steps inside it, so every arrangement spends one to buy another. On paper each passes with room:
/// plate 15.32 against the glass, rim 9.57, label 6.99, detail 20.25.
///
/// ⚠️ AND IT NEEDS NO CLIP, which is worth saying because the shape's other spelling did. A stroked
/// capsule PATH leaves a stray vertical tick a point or so outside each horizontal extreme, where its two
/// arcs meet — isolated in the `testRenderIslandChips` probe on 2026-08-11 by rendering the chip four ways
/// at native scale, where the ticks tracked the border alone — and it was clipped away. A `CALayer` border
/// is drawn INSIDE the layer's own bounds along the corner path, so a capsule radius cannot put a whisker
/// outside it and the clip would only cost a rounded-corner rasterisation, for the reason
/// `MacNoticeCapsuleView` already records.
@MainActor
final class SlatePaperCapsuleView: UIView {
    /// The one line this capsule carries. Held so a caller can restyle it without reaching through
    /// `subviews`; the capsule never reads it.
    let content: UIView

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ BEFORE THE FIRST RE-INK, and that ordering is load-bearing: `overrideUserInterfaceStyle`
        // rewrites this view's own `traitCollection`, which is what every `CGColor` below resolves
        // against. Set after, the rim and the cast would carry the island's dark appearance for one
        // trait cycle. It is the app's own polarity, not a third appearance — the same rung
        // ``SlopDeskSlate/SlateAppearancePin`` pins every scene to.
        overrideUserInterfaceStyle = Slate.chromeColorScheme == .dark ? .dark : .light
        backgroundColor = Slate.Native.Surface.field
        layer.borderWidth = Slate.Metric.hairline
        // The cast falls outside the capsule; a clip here would eat it.
        layer.masksToBounds = false

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
        ])
        reink()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (capsule: Self, _: UITraitCollection) in
            capsule.reink()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A true capsule: the corner follows the HEIGHT rather than naming a radius, which is why this
        // member is the one surface in the family with no radius token. `.circular`, not `.continuous` —
        // a squircle at half the height is no longer a capsule.
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        layer.cornerCurve = .circular
        // ⚠️ The `shadowPath` obligation ``SlatePaperCardSurface/layoutShadow(of:)`` documents, met from
        // this view's own layout pass: without it Core Animation rasterises the alpha channel of the
        // whole layer on every frame, and this capsule floats over LIVE terminal output.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }

    private func reink() {
        let traits = traitCollection
        // ``Slate/Native/Line/overlayRim`` verbatim, NOT a second light-side rim solved for this shape:
        // it is the same paper over the same terminal, and two washes that mean the same thing drifting
        // apart by a few hundredths is the exact failure the ``Slate/Opacity`` ladder exists to prevent.
        // Where the capsule crosses BRIGHT output the cream itself falls to ~1.03 and the rim plus the
        // cast are what carry the boundary — which is why neither is optional on this member.
        layer.borderColor = Slate.Native.Line.overlayRim.resolvedColor(with: traits).cgColor
        // The ladder's own rung for a pill floating over the glass. Nearly invisible against the dark
        // face, and that is fine — it is bought for the case that needs it.
        layer.slateShadow(.chip, color: Slate.Native.State.overlayShadow, in: traits)
    }
}

/// Sink an editable field into its plate: the pane face, ringed by a hairline, at the small radius.
///
/// A card carries no grouped form chrome, so nothing else says "you may type here". The fill goes DOWN a
/// rung
/// (``Slate/Native/Overlay/well``, not `plate`) on purpose: a selected row rises out of the card and an
/// input sinks into it, and the two must not read alike.
///
/// ⚠️ A DECORATION, AND THE PADDING DOES NOT COME WITH IT — the one place this family's port is not a
/// straight translation. The caller of a field plate is a `UITextField`, and a text field insets its
/// TEXT rather than a wrapper: `textRect(forBounds:)` / `editingRect(forBounds:)` are where that inset
/// belongs, because the caret's own rect is derived from them and a hosting view around the field would
/// put the caret out of step with the plate it is drawn on. So the two rungs a plate owes its text are
/// PUBLISHED here instead of being applied, and the caller spends the same two where the caret can see
/// them.
@MainActor
enum SlateFieldPlateSurface {
    /// The horizontal text inset a field on this plate owes.
    static let horizontalInset = Slate.Metric.space2
    /// The vertical text inset, likewise. Tighter than the sides: a field is a line, not a box.
    static let verticalInset = Slate.Metric.space1

    /// Dress `view` as a field plate. ONCE, at construction — see ``SlatePaperCardSurface/apply(to:)``
    /// on why a second call is wasted work. No shadow, so no layout half to this contract.
    static func apply(to view: UIView) {
        view.backgroundColor = Slate.Native.Overlay.well
        view.layer.cornerRadius = Slate.Metric.radiusSmall
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = Slate.Metric.hairline
        reink(view)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (plate: UIView, _: UITraitCollection) in
            reink(plate)
        }
    }

    private static func reink(_ view: UIView) {
        view.layer.borderColor = Slate.Native.Overlay.hairline
            .resolvedColor(with: view.traitCollection).cgColor
    }
}

/// Lift a SELECTED row onto its plate: one surface rung up, hairline-bordered, at the card radius.
/// Unselected costs nothing — no fill, no border, no reserved inset — so a list at rest is just text.
///
/// ⚠️ THE STRONGEST CASE IN THE FAMILY FOR A DECORATION over a hosting view: this is applied to EVERY
/// row of a list that scrolls, and a wrapper view per row is one more view to measure on every layout
/// pass and one more layer to composite on every frame, for a rectangle the row's own container already
/// draws.
///
/// ⚠️ IT IS THE ONE MEMBER THAT SPLITS IN TWO, and the split is what keeps a re-apply free.
/// ``install(on:)`` runs once and owns the trait registration; ``apply(_:to:)`` runs on every selection
/// change and touches nothing but the fill and the border WIDTH. The border COLOUR is written
/// unconditionally by the re-ink and simply goes inert at width zero — which is what lets the
/// registration be state-free and lets a selection change cost two property writes.
@MainActor
enum SlateSelectionPlateSurface {
    /// Called ONCE, when the row's container is built.
    static func install(on view: UIView) {
        view.layer.cornerRadius = Slate.Metric.radiusCard
        view.layer.cornerCurve = .continuous
        reink(view)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (row: UIView, _: UITraitCollection) in
            reink(row)
        }
    }

    /// Called on every selection change. Never coloured: importance is light and weight, not hue
    /// (`docs/DECISIONS.md` §git-line-two-registers).
    static func apply(_ selected: Bool, to view: UIView) {
        view.backgroundColor = selected ? Slate.Native.Overlay.plate : .clear
        view.layer.borderWidth = selected ? Slate.Metric.cardBorderWidth : .zero
    }

    private static func reink(_ view: UIView) {
        view.layer.borderColor = Slate.Native.Overlay.hairline
            .resolvedColor(with: view.traitCollection).cgColor
    }
}

// MARK: - Tapping on a floating card

/// The card's DISMISS FLOOR: an invisible full-bleed control that closes the overlay when the tap lands
/// beside the card.
///
/// ⚠️ CLEAR IS NOT TRANSPARENT, and it is the other side of the same coin as the card's absent hit
/// barrier. A framework that hit-tests DRAWN CONTENT needs a clear fill to be given a content shape
/// before it takes a touch at all; UIKit hit-tests BOUNDS, so `backgroundColor = .clear` already takes
/// every touch inside the floor. What UIKit will NOT forgive is `alpha`: at zero (or
/// `isHidden`, or `isUserInteractionEnabled == false`) the view leaves the hit-test walk entirely and the
/// floor silently stops dismissing. A floor is drawn clear and left fully opaque.
///
/// ⚠️ VoiceOver's own dismissal is NOT this control's, and that is deliberate rather than dropped. The
/// two-finger scrub arrives as `accessibilityPerformEscape()` sent UP from the focused element, and the
/// floor is the card's SIBLING — it is never on that path. The gesture belongs to whatever presents the
/// pair (the overlay's own controller), which is also the object that owns the dismissal. The floor is a
/// pointer affordance and no accessibility element of its own.
@MainActor
final class SlateClickTargetView: UIControl {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func fire() { action() }
}

/// A finished card row, TAPPABLE.
///
/// ⚠️ THE ROW'S OWN CONTAINER IS THE CONTROL, never an invisible one laid over it. The overlay form is
/// what broke hover-select on the palette and Open Quickly, and UIKit does not forgive it either: a
/// transparent view laid on TOP of a row is what `hitTest(_:)` returns, so it takes the row's
/// `UIHoverGestureRecognizer` along with its taps and the selection stops following the pointer — the one
/// thing a palette must do. Built INTO this control, the row's own subviews stay topmost (a `UIControl`
/// receives what its subviews decline) while the control still owns the tap.
///
/// It costs no view. A row already needs a container to lay its title, mark and keycap out in; this IS
/// that container, which is why the wrapper-versus-decoration question does not arise for it.
@MainActor
final class SlateRowButton: UIControl {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func fire() { action() }
}

// MARK: - The keycap

/// A key the reader can press RIGHT NOW, drawn as a cap: the instrument voice on a faint plate with a
/// hairline edge.
///
/// ⚠️ THE CAP IS FIXED-SIZE, AND THE TWO PRIORITIES BELOW ARE WHAT SAY SO. In a stack a
/// flexible label will happily eat the width its neighbours needed, and a long row title used to
/// truncate the shortcut down to a bare "⌘" — the one glyph on a row that CANNOT survive being
/// shortened, because a shortcut with its key cut off is not a shortcut. Required compression resistance
/// is what lays the cap out first and leaves the title what is left.
///
/// A chord is ONE cap ("⇧⌘L"), not a cap per glyph. The modifiers are not separate keys to find; they
/// are one gesture, and splitting them into a row of little boxes reads as four things to do.
///
/// ⚠️ THE ONE INSTRUMENT-VOICE READOUT SET IN THE SYSTEM FACE, and it is a rendering fact rather than a
/// preference. A chord's modifiers are SYMBOL glyphs (⇧ U+21E7, ⌘ U+2318, ⌥, ⌃) and a monospaced face
/// advances them by its cell rather than by the glyph, overlapping ⇧ into ⌘ into W until "⇧⌘W" is one
/// smear. Every system menu draws the same glyphs in the same face, so this is also the register a
/// reader already knows a shortcut in.
///
/// ⚠️ It is a `UILabel` and not a label INSIDE a view, which is what keeps the cap at one view: the
/// padding rides ``intrinsicContentSize`` and the height comes off the ladder rather than off a
/// constraint. `MacNoticeKeycap` sets its type SEMIBOLD and this one sets it MEDIUM: the phone's cap is
/// read at arm's length on a denser row, and the two surfaces were tuned apart on purpose.
@MainActor
final class SlateKeycapView: UILabel {
    /// Whether the row this cap sits on is the selected one — the cap brightens WITH its row rather than
    /// staying at one fixed weight, so the eye tracks a single object down the list.
    var lit: Bool {
        didSet {
            guard lit != oldValue else { return }
            textColor = lit ? Slate.Native.Overlay.secondary : Slate.Native.Overlay.tertiary
        }
    }

    init(label: String, lit: Bool = false) {
        self.lit = lit
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        text = label
        font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        textColor = lit ? Slate.Native.Overlay.secondary : Slate.Native.Overlay.tertiary
        textAlignment = .center
        // The cap's face and its edge. The fill is view-level and follows the appearance by itself; only
        // the border is a `CGColor` and needs re-inking.
        backgroundColor = Slate.Native.Overlay.plate
        layer.cornerRadius = Slate.Metric.radiusSmall
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        layer.masksToBounds = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        reink()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cap: Self, _: UITraitCollection) in
            cap.reink()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The cap's own padding, which is why this type exists instead of a bare `UILabel`: generous sides
    /// against the control rung's height. The height is the LADDER's, never the text's — a cap has to
    /// measure the same as every other control on the row it sits in.
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: super.intrinsicContentSize.width + 2 * Slate.Metric.space2,
            height: Slate.Metric.heightControl,
        )
    }

    private func reink() {
        layer.borderColor = Slate.Native.Overlay.hairline
            .resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - The one line a card is allowed to draw inside itself

/// The card's internal hairline — the ONE exception to "no chrome inside", and the twin of the Mac's
/// ``SlopDeskMacUI/MacCardRuleView``.
///
/// A card with a live search field at its top has a real boundary to mark: the results scroll UNDER that
/// field, and without a line the topmost row slides into the query text as it passes. So: a hairline
/// where content MOVES past content, nowhere else — never to separate two static regions, which is what
/// the system divider was doing in these overlays before and what made them read as stacked boxes.
///
/// The whole rule is one fill and one intrinsic height, and NOTHING here is re-inked: a view's
/// `backgroundColor` holds the dynamic `UIColor` itself, so the one place in the family with no edge and
/// no cast is also the one with no trait registration.
@MainActor
final class SlateCardSeparatorView: UIView {
    // `init(frame:)` rather than a bare `init()`, matching ``SlateStatusMarkView``: it is UIView's own
    // designated initialiser, so the rule needs no initialiser of its own to be constructed by one.
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // The theme's own divider ink rather than a system separator, whose grey ignores the theme and
        // lands far too heavy on glass.
        backgroundColor = Slate.Native.Overlay.hairline
        // A rule is not a thing to land on: the regions it separates speak for themselves.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Slate.Metric.hairline)
    }
}

// MARK: - The card's own title

/// A floating card's title line: a REAL title — the system face at `title`/semibold in the reading ink —
/// with an optional trailing accessory, and no rule under it (the card has an edge already).
///
/// It spoke the instrument caps micro-label first (`CONNECT TO HOST`, mono, tracked wide) and was
/// photographed and rejected as "not modern": three caps-mono runs stacked on one form read as engraving
/// on an instrument panel. So the title is the ONE line on a card that outranks the content —
/// ``Slate/Typeface/title`` at semibold in the primary ink, against `base`-in-`secondary` field labels —
/// hierarchy by size and weight, never by voice-switching into caps.
///
/// The accessory is ONE optional `UIView` and needs no generic parameter, and no second initialiser to
/// pin that parameter to "nothing" for the plain case: UIKit's view tree is not a type, so "no accessory"
/// is `nil` rather than a specialisation.
@MainActor
final class SlateCardTitleView: UIView {
    private let label = UILabel()

    init(_ title: String, trailing: UIView? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.text = title
        label.font = .systemFont(ofSize: Slate.Typeface.title, weight: .semibold)
        label.textColor = Slate.Native.Overlay.primary
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        // The one line that outranks everything under it, said to VoiceOver as well as to the eye — free
        // here, and a role a plain text run carries nowhere else.
        label.accessibilityTraits.insert(.header)
        // The title is laid out at its own width and the GAP takes the slack — the priority pair that
        // spells `Spacer` in Auto Layout. Under pressure the order reverses by construction: the gap's
        // compression resistance is the lowest in the row, so it closes to its floor before the title
        // ever truncates.
        label.setContentHuggingPriority(.required, for: .horizontal)

        // A SPACER IS A REAL VIEW here, with its own minimum: the gap absorbs the slack and holds its own
        // floor, rather than the label being taught to stretch — which would put a layout rule on the
        // caller's accessory instead of between the two.
        let gap = UIView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var arranged: [UIView] = [label, gap]
        if let trailing { arranged.append(trailing) }
        let row = UIStackView(arrangedSubviews: arranged)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Slate.Metric.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            gap.widthAnchor.constraint(greaterThanOrEqualToConstant: Slate.Metric.space2),
            // A spacer has no intrinsic size at all, so its HEIGHT is borrowed from the title rather
            // than left for the stack to guess — an unconstrained arranged subview is an ambiguity the
            // engine resolves silently and differently on different rows.
            gap.heightAnchor.constraint(equalTo: label.heightAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space4),
            // Tighter under the title than over it: the line belongs to what follows it.
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space3),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}
#endif
