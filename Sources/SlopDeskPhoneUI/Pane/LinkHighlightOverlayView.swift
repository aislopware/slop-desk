// LinkHighlightOverlayView — the ⌘-hold link underline, in UIKit (docs/62, the pane-leaf cluster).
//
// A DECORATION coincident with the terminal surface (never a content branch — the libghostty-freeze
// guardrail): while the pane model reports ⌘ is held, it runs the pure ``TerminalLinkDetector`` over the
// live VISIBLE viewport rows and draws a hairline under every detected path / URL / `file://` /
// `mailto:` span, mapped to points by the ``TerminalCellMetrics``. Only the underlines: the renderer owns
// the open gestures and the hovered link's resolved path is the model's.
//
// ⚠️ INERT ON A PHONE, LIVE ON AN IPAD, AND THE GATE IS RUNTIME STATE RATHER THAN A `#if`. There is no ⌘
// to hold on a touch-only device, so ``TerminalViewModel/linkHighlightActive`` never goes true there and
// this overlay short-circuits to nothing; attach a hardware keyboard and it is the Mac's behaviour
// exactly. Compiling it out would make the iPad quietly worse to save nothing, which is why the SwiftUI
// original said the same thing in the same words.
//
// Honest ceiling: a headless / ``BuildStatusPlaceholderView`` surface does NOT conform to
// ``TerminalViewportSnapshotting`` (the real surface hangs without a window server — CLAUDE.md rule #6),
// so `cellMetrics()` is absent and this draws nothing — an ABSENT underline, never a wrong one.
//
// THE ARM PREDICATE AND THE PATH ARE VALUES, not code in here: ``LinkUnderlineGeometry`` owns the three
// gates and the baseline inset, and is pinned by its own tests.
//
// ⚠️ NO FLIP, AND A `CAShapeLayer` RATHER THAN A CANVAS. ``TerminalCellMetrics`` answers in the surface's
// TOP-LEFT-origin space, which is `UIView`'s own, so the Mac half's `isFlipped { true }` has no
// counterpart and every point is used verbatim. And the strokes are STATIC between detections — a shape
// layer holds the path and composites it, where the `Canvas` this replaces (and a `draw(_:)` override
// would) forces a CPU rasterization of the whole pane-sized backing store on every redraw. docs/62
// §5.1(f) names this file as the module's one `Canvas` and this layer as its answer.
//
// THEME colours only, from the on-glass vocabulary: `Slate.Native.Terminal.ink` — the CELL FOREGROUND,
// not the brand accent (user-directed 2026-08-09). An underline is a property OF the text it sits under,
// so it is the colour that text is already drawn in; and this overlay lives inside the terminal island,
// where the on-glass vocabulary governs and the semantic tiers (tuned for the chrome) do not.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskTerminal
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class LinkHighlightOverlayView: UIView {
    /// The pane's terminal model — observed for the ⌘-hold flag and the two viewport-change signals,
    /// dereferenced non-reactively for its `surface` snapshot at detection time.
    private let model: TerminalViewModel

    /// The pane cwd (OSC 7 `pane/cwd`) so a RELATIVE detected path resolves. It only affects the
    /// detector's `resolvedAbsolute` (the hover preview's), never the underline rect, which is pure cells
    /// — but it is a `var` because cwd changes under a live pane, and the leaf pushes it.
    var cwd: String? {
        didSet {
            guard cwd != oldValue else { return }
            refresh()
        }
    }

    /// The underline strokes for the current viewport.
    private var strokes: [TerminalStroke] = []

    /// One shape layer per distinct stroke WIDTH, keyed by it.
    ///
    /// ⚠️ Grouped rather than one layer for the lot, because `lineWidth` is a property of the LAYER and
    /// ``TerminalStroke`` carries one PER STROKE — folding every stroke into a single path would mean
    /// picking one width and drawing the rest at it. Today the geometry hands back one width for every
    /// stroke and this dictionary holds exactly one entry; the grouping costs nothing for that case and
    /// is the difference between "correct" and "correct by a coincidence nothing checks" if the value
    /// ever varies by row.
    private var painters: [CGFloat: CAShapeLayer] = [:]

    /// Guards the observation re-arm against a stale `onChange` firing after this view is gone.
    private var generation = 0

    init(model: TerminalViewModel, cwd: String?) {
        self.model = model
        self.cwd = cwd
        super.init(frame: .zero)
        isAccessibilityElement = false
        // DECORATION only: never swallow a touch. The renderer owns tap, drag-select and the long-press
        // menu on a detected link, and a touch this view answered would open nothing at all.
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.reink()
        }
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Bump the generation so an already-scheduled re-arm drops itself.
    func teardown() {
        generation &+= 1
    }

    /// A resize re-wraps the grid, so every detected span moves and several stop existing. No observable
    /// property bumps for it (the metrics are read off the live surface), and stale underlines over
    /// re-wrapped text are the wrong-decoration failure this family refuses.
    ///
    /// ⚠️ READS ONLY (docs/62 hazard 7): ``refresh()`` runs the detector and writes nothing back.
    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    // MARK: The live read

    /// ONE-SHOT observation, re-armed by its own `onChange`.
    ///
    /// ⚠️ THE DEPENDENCY IS CONDITIONAL AND THAT IS THE POINT. The three arm signals are read on every
    /// arm, so the underlines reveal / clear the instant ⌘ is pressed or released. The two
    /// viewport-change signals are read ONLY inside the armed branch, so an idle pane does not re-detect
    /// once per ingest chunk while nobody is holding ⌘ — the same bargain the SwiftUI half struck by
    /// putting them inside its `if`.
    ///
    /// BOTH signals, not just the loud one: `bytesReceived` covers new streaming output, and
    /// `viewportRevision` covers a LOCAL scrollback scroll, which moves the viewport without a single new
    /// wire byte. Observing only the first leaves the underlines stranded at their pre-scroll screen rows,
    /// over unrelated text.
    ///
    /// A `SettingsKey` read needs the config's own observable edge in the SAME tracked block — turning
    /// link detection off in Settings has to reach a pane that is otherwise idle.
    private func follow() {
        generation &+= 1
        let token = generation
        withObservationTracking {
            _ = ConfigRevision.shared.generation
            // `alternateScreenActive`, the OBSERVABLE twin — not `isAlternateScreen`, which reads through
            // an `@ObservationIgnored` tracker and would register no dependency at all here. The tracked
            // closure is the one place the distinction bites: without the twin, a flip to a full-screen
            // TUI under a held ⌘ only clears the underlines if MORE output happens to arrive.
            if LinkUnderlineGeometry.isArmed(
                highlightActive: model.linkHighlightActive,
                detectionEnabled: SettingsKey.linkDetectionEnabled,
                isAlternateScreen: model.alternateScreenActive,
            ) {
                _ = model.bytesReceived
                _ = model.viewportRevision
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.follow()
                }
            }
        }
        refresh()
    }

    /// Re-detect, and re-path only if the answer moved. Streaming output bumps `bytesReceived` per chunk
    /// while ⌘ is held, and most chunks do not touch a link's row — the detector still runs (it is the
    /// only way to know), but the layers are left alone.
    private func refresh() {
        let next = detected()
        guard next != strokes else { return }
        strokes = next
        repath()
    }

    private func detected() -> [TerminalStroke] {
        guard LinkUnderlineGeometry.isArmed(
            highlightActive: model.linkHighlightActive,
            detectionEnabled: SettingsKey.linkDetectionEnabled,
            isAlternateScreen: model.isAlternateScreen,
        ),
            let snapshot = model.surface as? TerminalViewportSnapshotting,
            let metrics = snapshot.cellMetrics()
        else { return [] }
        return LinkUnderlineGeometry.strokes(
            links: TerminalLinkDetector.detect(
                rows: snapshot.viewportTextRows(),
                cwd: cwd,
                schemes: SettingsKey.linkSchemePolicy,
            ),
            metrics: metrics,
        )
    }

    /// Rebuild one path per stroke width, and retire the layers no width needs any more.
    ///
    /// Retiring matters more than it looks: the widths are the DICTIONARY's keys, so a layer left behind
    /// for a width that has stopped occurring would keep drawing its last path for the life of the pane.
    private func repath() {
        var grouped: [CGFloat: UIBezierPath] = [:]
        for stroke in strokes {
            let path = grouped[stroke.lineWidth] ?? UIBezierPath()
            path.move(to: stroke.start)
            path.addLine(to: stroke.end)
            grouped[stroke.lineWidth] = path
        }
        for (width, layer) in painters where grouped[width] == nil {
            layer.removeFromSuperlayer()
            painters.removeValue(forKey: width)
        }
        for (width, path) in grouped {
            let painter = painters[width] ?? mint(width: width)
            // A path change is a HARD CUT. An underline that tweened from one link's row to another's on
            // every re-detect would draw a line under text that has no link in it for the length of the
            // tween — a wrong decoration, which is the one thing this family refuses.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            painter.path = path.cgPath
            CATransaction.commit()
        }
    }

    private func mint(width: CGFloat) -> CAShapeLayer {
        let painter = CAShapeLayer()
        painter.fillColor = nil
        painter.lineWidth = width
        painter.strokeColor = Slate.Native.Terminal.ink
            .resolvedColor(with: traitCollection).cgColor
        layer.addSublayer(painter)
        painters[width] = painter
        return painter
    }

    /// The on-glass ink is the profile's, and it resolves against the appearance — a `CGColor` on a shape
    /// layer is frozen at whichever one was current when it was assigned.
    private func reink() {
        let ink = Slate.Native.Terminal.ink.resolvedColor(with: traitCollection).cgColor
        for painter in painters.values { painter.strokeColor = ink }
    }
}
#endif
