// DeviceStageLayout — the two Auto Layout shapes a device stage writes, spelled once for both shells.
//
// A device panel's stage is the same picture on a Mac and on a phone: three bands down the view, and
// one device view seated inside a host with a margin the caller decides. Both were typed twice — the
// AppKit and UIKit copies were character-identical apart from the loop variable's NAME — because the
// only word in either that looks framework-specific is the view type, which is what ``SlateHostView``
// already answers. Auto Layout itself is ONE api: `NSLayoutConstraint`, `NSLayoutXAxisAnchor` and
// `NSLayoutYAxisAnchor` are vended under those exact names by UIKit too. See `ViewEdges.swift`'s
// header for the duplication that hid behind a claim about `UILayoutConstraint`.
//
// ⚠️ THIS IS NOT `slateEdges(of:)` WITH A NUMBER. That helper is the zero-inset pin and stays the one
// spelling of it; ``pin(_:into:inset:)`` exists for the case `slateEdges` deliberately does not carry —
// a device inset from its host on all four sides by a rung of the ladder — and a caller with no margin
// should still reach for `slateEdges`.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

package enum DeviceStageLayout {
    /// Stack `header`, `bed` and `drawer` down `host`, each pinned to both its side edges, and return
    /// the DRAWER's height constraint — already active, and the caller's to animate.
    ///
    /// The drawer starts at zero height because a console that has never been opened is not a band
    /// with nothing in it: it is a band that is not there. The returned constraint is the one thing
    /// the caller has to keep, which is why it comes back rather than going into an `inout`.
    @MainActor
    package static func stackBands(
        header: SlateHostView, bed: SlateHostView, drawer: SlateHostView, in host: SlateHostView,
    ) -> NSLayoutConstraint {
        for band in [header, bed, drawer] {
            band.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(band)
        }
        let height = drawer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),

            bed.topAnchor.constraint(equalTo: header.bottomAnchor),
            bed.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bed.trailingAnchor.constraint(equalTo: host.trailingAnchor),

            drawer.topAnchor.constraint(equalTo: bed.bottomAnchor),
            drawer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            drawer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            height,
        ])
        return height
    }

    /// The four constraints that seat `view` inside `host` with `inset` on every side, mask already
    /// off. Returned rather than activated, for the same reason ``SlateHostView/slateEdges(of:)``
    /// returns: a caller that wants to keep one still can.
    @MainActor
    package static func pin(
        _ view: SlateHostView, into host: SlateHostView, inset: CGFloat,
    ) -> [NSLayoutConstraint] {
        view.translatesAutoresizingMaskIntoConstraints = false
        return [
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset),
        ]
    }
}
