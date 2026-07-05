import Foundation

// MARK: - Compact projection types

/// One page of the compact (phone) carousel: a leaf projected into the swipeable page list
/// (docs/22 §2.2, §4). It carries just enough to render the page header without re-walking the
/// tree — the pane's id (which page), its kind (glyph), and its title.
public struct CompactPage: Sendable, Equatable {
    public let id: PaneID
    public let kind: PaneKind
    public let title: String
    public init(id: PaneID, kind: PaneKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

// MARK: - Compact projection

/// The pure **compact projection** (docs/22 §1.3, §2.2, §4): it flattens the SAME tree of intent
/// into an ordered page list (and reports the focused page's index). The phone layout is therefore a
/// *view of the same model* — a 3-pane Mac split opens on iPhone as 3 swipeable pages, losslessly,
/// and a size-class flip is view-only (it must NOT reconcile, drop focus, or tear sessions down,
/// docs/22 §4). Free of UIKit; unit-tested on macOS (docs/22 §8 `CompactLayoutResolverTests`).
public enum CompactLayoutResolver {
    /// The carousel pages, in canvas **z-order** — identical to `canvas.allIDs()`, so page order is a
    /// stable, total ordering of the panes (the canvas analogue of the old pre-order leaf order).
    public static func pages(for canvas: Canvas) -> [CompactPage] {
        canvas.allIDs().compactMap { id in
            guard let spec = canvas.spec(for: id) else { return nil }
            return CompactPage(id: id, kind: spec.kind, title: spec.title)
        }
    }

    /// The index of the currently focused page (the page bound as the carousel's selection).
    /// Returns `0` if the focused pane is absent / nil (defensive — keeps the carousel on a valid page
    /// rather than out of bounds).
    public static func selectedIndex(focusedPane: PaneID?, in canvas: Canvas) -> Int {
        guard let focusedPane else { return 0 }
        return canvas.allIDs().firstIndex(of: focusedPane) ?? 0
    }
}
