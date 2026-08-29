// GuiLeafChromeLayout — where the GUI leaf's seven chrome overlays sit, decided once.
//
// The last region `MacGuiLeafView` and `GuiLeafView` still shared after the leaf's logic descended to
// ``GuiLeafCore``: twenty character-identical lines of Auto Layout, one corner per overlay. It stayed
// shared because the dedup that took the logic down was barred from putting a view type in the floor,
// and every one of these lines is about views.
//
// ⚠️ A SHARED LAYOUT IS WORTH LIFTING WHERE A SHARED CALL IS NOT, and that is the whole argument for
// this file. Two call sites into one implementation cannot disagree; two anchor blocks can, silently
// and by two points — the corner a pill moves to on one platform and not the other is exactly the
// class of drift nothing goes red for. The overlays' PLACEMENT is a design decision (which corner is
// free, which pair can be on screen at once) rather than framework spelling, so it belongs with the
// rest of the leaf's decisions rather than beside each drawing of them.
//
// It takes ``SlateHostView`` and returns constraints. Auto Layout is ONE API on both platforms —
// `NSLayoutConstraint` and both anchor types are spelled identically by AppKit and UIKit — so the only
// per-shell word in the whole block was the host's type, which `Support/SlateHostTypes.swift` now names.
// Nothing here draws, and no shell type crosses: the caller hands over the seven views it already
// owns and activates what comes back. ``mount(in:placeholder:overlays:dropHighlight:conceal:)`` also
// adds them, because `addSubview` is one API on both frameworks and z-order is add-order on both —
// so the sequence was a shared decision hiding behind eight identical lines rather than a spelling.
//
// AND IT READS THE RUNGS ITSELF. This file first shipped taking `pad`/`inset`/`height` as parameters
// on the belief that `SlopDeskSlate` sat ABOVE this target; the edge is the other way round, and the
// belief cost each caller an identical eight-line call that `no-cross-target-clone` then fired on.
// See ``constraints(in:overlays:)`` for the full note — it is this stage's lesson twice over, since
// a lifted body that still makes both halves spell its arguments has not finished being lifted.

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SlopDeskSlate

/// The GUI leaf's chrome corners.
@MainActor
package enum GuiLeafChromeLayout {
    /// The six overlays that take a corner, in one value.
    ///
    /// A struct rather than six arguments, and not only to clear the parameter-count lint: at six
    /// same-typed views a caller's argument order is a thing that can be got wrong SILENTLY — the
    /// stats readout and the read-only pill would swap corners and still compile. Labels at the call
    /// site are what make that a typo instead of a bug.
    package struct Overlays {
        package let controlBar: SlateHostView
        package let collapsedChip: SlateHostView
        package let stallCaption: SlateHostView
        package let statsReadout: SlateHostView
        package let uploadOverlay: SlateHostView
        package let readOnlyPill: SlateHostView

        package init(
            controlBar: SlateHostView,
            collapsedChip: SlateHostView,
            stallCaption: SlateHostView,
            statsReadout: SlateHostView,
            uploadOverlay: SlateHostView,
            readOnlyPill: SlateHostView,
        ) {
            self.controlBar = controlBar
            self.collapsedChip = collapsedChip
            self.stallCaption = stallCaption
            self.statsReadout = statsReadout
            self.uploadOverlay = uploadOverlay
            self.readOnlyPill = readOnlyPill
        }

        /// The six, in the z-order they mount in — bottom-up, which is the order they are declared in.
        var ordered: [SlateHostView] {
            [controlBar, collapsedChip, stallCaption, statsReadout, uploadOverlay, readOnlyPill]
        }
    }

    /// Mount the leaf's whole chrome into `host` and hand back every constraint it needs, ready to
    /// activate: the placeholder at the back, the six overlays and the drop highlight over it, each
    /// concealed on the way in.
    ///
    /// ⚠️ THE ORDER IS THE DECISION, which is why this is here and not spelled twice. `addSubview` is
    /// one API on both frameworks and z-order is add-order on both, so the sequence — floor, chrome,
    /// highlight — carried no framework word at all; it was eight identical lines in both shells,
    /// and `no-cross-target-clone` fired on them the moment the chrome CONSTRAINTS came down and
    /// stopped hiding them. The drop highlight goes on LAST on purpose: it is a whole-leaf border,
    /// and a control bar drawn over it would break the frame it is drawing.
    ///
    /// `conceal` is the one genuinely per-shell word left, and it is a closure rather than a rung
    /// because the two shells do not merely spell the same thing differently — the Mac takes an
    /// overlay out with `alphaValue` and `isHidden`, the phone with `layer.opacity` and
    /// `accessibilityElementsHidden`, and those are different states, not one state twice. A
    /// divergence that real belongs at the call site where it can be read.
    package static func mount(
        in host: SlateHostView,
        placeholder: SlateHostView,
        overlays: Overlays,
        dropHighlight: SlateHostView,
        conceal: (SlateHostView) -> Void,
    ) -> [NSLayoutConstraint] {
        // The mask goes off HERE for every one of them. `slateEdges(of:)` turns it off for the two it
        // pins, but the six corners are placed by ``constraints(in:overlays:)``, which returns
        // constraints and touches no view — so a mask left on would silently win over every anchor.
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(placeholder)
        for overlay in overlays.ordered + [dropHighlight] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            conceal(overlay)
            host.addSubview(overlay)
        }
        return placeholder.slateEdges(of: host)
            + dropHighlight.slateEdges(of: host)
            + constraints(in: host, overlays: overlays)
    }

    /// Every constraint that places the leaf's chrome inside `host`, ready to activate.
    ///
    /// The corners are not interchangeable and each is a reading of what is free:
    ///
    /// * the control bar spans the FOOT — it is the leaf's own bar, not an overlay on a corner;
    /// * the collapsed chip takes bottom-TRAILING, which is where the bar collapses to;
    /// * the stall caption takes bottom-LEADING, because bottom-trailing is the chip's and the two can
    ///   be up at once — a stalled stream still has controls;
    /// * the stats readout takes top-leading and the read-only pill top-trailing;
    /// * the upload overlay takes top-CENTRE, the only edge left with no corner in it.
    ///
    /// The drop highlight is NOT here: it is a whole-leaf border, pinned to every edge by the caller
    /// with `slateEdges(of:)`, and it sits above this chrome on purpose — a control bar drawn over it
    /// would break the frame it is drawing.
    /// ⚠️ THE TWO RUNGS ARE READ HERE, and they used to be PARAMETERS on a claim that was simply
    /// false. The doc comment said "`SlopDeskSlate` depends on this target, so the token ladder is
    /// not reachable from here at all" — the edge runs the other way (`Package.swift:475` declares
    /// `SlopDeskSlate` among `SlopDeskClientCore`'s dependencies), and `Pane/DecorationDivider.swift`
    /// two files over has been spending `Slate.Metric.space2` directly the whole time.
    ///
    /// It was not a harmless inaccuracy. Passing the rungs in left each caller spelling the same
    /// eight-line call, and `no-cross-target-clone` went red on exactly that block — a rule firing on
    /// a duplication that a wrong comment was holding in place. The corner inset (`space2`) and the
    /// stall caption's wider one (`space3`) are not decisions a shell gets to make differently: which
    /// corner each overlay takes is already this file's, and the gap it sits at is the same reading.
    /// A shell that genuinely needed its own inset would be describing a divergence, and would take
    /// it back with its own constraint rather than by re-parameterising this one.
    package static func constraints(in host: SlateHostView, overlays: Overlays) -> [NSLayoutConstraint] {
        let pad = Slate.Metric.space2
        let inset = Slate.Metric.space3
        let controlBar = overlays.controlBar
        let collapsedChip = overlays.collapsedChip
        let stallCaption = overlays.stallCaption
        let statsReadout = overlays.statsReadout
        let uploadOverlay = overlays.uploadOverlay
        let readOnlyPill = overlays.readOnlyPill
        return [
            controlBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.trailingAnchor.constraint(equalTo: collapsedChip.trailingAnchor, constant: pad),
            host.bottomAnchor.constraint(equalTo: collapsedChip.bottomAnchor, constant: pad),
            stallCaption.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            host.bottomAnchor.constraint(equalTo: stallCaption.bottomAnchor, constant: inset),
            statsReadout.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
            statsReadout.topAnchor.constraint(equalTo: host.topAnchor, constant: pad),
            uploadOverlay.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            uploadOverlay.topAnchor.constraint(equalTo: host.topAnchor, constant: pad),
            host.trailingAnchor.constraint(equalTo: readOnlyPill.trailingAnchor, constant: pad),
            readOnlyPill.topAnchor.constraint(equalTo: host.topAnchor, constant: pad),
        ]
    }

    /// The control bar itself: one inset row, centred, over a top hairline, in a bar of fixed height.
    ///
    /// The second region the two shells shared after the leaf's logic descended, and here for the same
    /// reason as the corners above — eight identical lines placing a bar, which is an arrangement, not
    /// a spelling. The bar's CONTENTS are per-shell (`NSButton` against `UIButton`, `onClick` against
    /// `addAction`) and stay there; only where the row and the rule sit is one decision.
    ///
    /// The three rungs are read here for the reason above: the row's inset (`space2`), the bar's
    /// height (`paneHeaderHeight`) and the rule's thickness (`hairline`) are the SAME bar on both
    /// shells, so passing them in bought each caller a six-argument call it had to spell identically.
    package static func controlBarConstraints(
        in host: SlateHostView, row: SlateHostView, hairline: SlateHostView,
    ) -> [NSLayoutConstraint] {
        let pad = Slate.Metric.space2
        let height = Slate.Metric.paneHeaderHeight
        let hairlineHeight = Slate.Metric.hairline
        return [
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -pad),
            row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: height),
            hairline.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: host.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: hairlineHeight),
        ]
    }
}
