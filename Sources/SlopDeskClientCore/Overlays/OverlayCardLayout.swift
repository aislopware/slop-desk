// OverlayCardLayout — the two Auto Layout shapes every floating card in this tree draws by hand.
//
// ⚠️ THIS IS NOT ``SlateHostView/slateEdges(of:)``, AND THE DIFFERENCE IS THE WHOLE REASON IT EXISTS.
// That helper answers "this view IS its host" — four `constraint(equalTo:)` calls with a zero constant,
// which is right for a pane filling a container and wrong for every card in the floating family, because
// a card is exactly its PADDING. The two shapes below both carry a decided constant, which `slateEdges`
// has no place to put and should not grow one: a pin whose constants are always zero is a different
// promise from a pin whose constants are the design ladder's rungs.
//
// ⚠️ THE RUNGS ARE PARAMETERS, AND THE REASON IS THAT THEY VARY — not, as this header first claimed,
// that "`SlopDeskSlate` depends on this module, not the reverse, so `Slate.Metric.*` is unreachable from
// here". That is false: `Package.swift:475` lists `SlopDeskSlate` among this target's dependencies, and
// `Pane/GuiLeafChromeLayout.swift` reads `Slate.Metric` directly two directories over. The true reason is
// the second half of the old sentence, which stands on its own: WHICH rung a card pads itself by is a
// decision the design system makes per surface (a toast pads by `space3`, a contextual badge by
// `space2`/`space1`), so there is no one number to bake in. Where a lifted shape DOES have one number —
// the GUI leaf's corners — passing it in was the mistake, and it cost a `no-cross-target-clone` red,
// because both callers then spelled the same argument list. The shell hands a rung down only when the
// rung is the shell's to choose; the geometry is what lives here.
//
// ⚠️ IT ACTIVATES RATHER THAN RETURNING, unlike `slateEdges`. That helper hands its constraints back so a
// caller that must keep one — to animate it, or to swap it later — still can. Nothing here is ever kept:
// a card's padding and a mark's centring are fixed at build time on both platforms, and a call site that
// wrote `NSLayoutConstraint.activate(…)` around this would be spelling ceremony for a constraint it will
// never name again.
//
// Auto Layout is ONE api on both frameworks — `NSLayoutConstraint`, `NSLayoutXAxisAnchor` and the anchor
// members are vended under those exact names by UIKit too — so the only word here that is genuinely two
// types is the view, which is ``SlateHostView``.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The floating family's two hand-written layouts, written once.
@MainActor
package enum OverlayCardLayout {
    /// Pins `body` inside `card` with `x` of horizontal padding and `y` of vertical padding, with the
    /// autoresizing mask already turned off — because a pin whose mask is still on is a pin that
    /// silently loses.
    ///
    /// EDGES, NOT THE SAFE AREA: a card has already been placed by whatever presented it, and a helper
    /// that quietly pinned to `safeAreaLayoutGuide` would inset the corner's column twice.
    package static func pad(_ body: SlateHostView, in card: SlateHostView, x: CGFloat, y: CGFloat) {
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: x),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -x),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: y),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -y),
        ])
    }

    /// Stacks `layers` on one another, each centred in `host`, and fixes `host` to a `square` of that
    /// side — the composed-symbol shape a status mark is drawn as.
    ///
    /// Each layer centres on ITS OWN bounding box, which is the point: the fused `*.circle.fill` sets
    /// its inner glyph measurably off the disc's centre, and a mark composed of a disc under a bare
    /// glyph does not. The host hugs and resists at `.required` in both directions of the horizontal,
    /// so a mark beside a headline keeps its size no matter how long the sentence gets.
    package static func centre(_ layers: [SlateHostView], in host: SlateHostView, square side: CGFloat) {
        for layer in layers {
            layer.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(layer)
            NSLayoutConstraint.activate([
                layer.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                layer.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: side),
            host.heightAnchor.constraint(equalToConstant: side),
        ])
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}
