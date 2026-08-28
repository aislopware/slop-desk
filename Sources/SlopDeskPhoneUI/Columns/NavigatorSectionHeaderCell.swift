// NavigatorSectionHeaderCell — one project group's header, in UIKit.
//
// The top line of a project group: the FOLDER glyph, the group's NAME, and — while open — the live
// git line beneath it. While COLLAPSED the git line folds away and the hidden-row COUNT takes the
// trailing slot instead, wearing the strongest ATTENTION ink of the rows it hides, so folding a group
// never mutes a waiting agent.
//
// The dialect is not here: which sigils, in what order, at what weight, and what gets shed are all
// ``SidebarGitLine``'s (SlopDeskClientCore), and the palette is ``Slate/Native/gitInk(_:)``'s. The
// measuring is ``SidebarGitLineView``'s. What is left here is one row's worth of layout.
//
// TWO THINGS THE MAC HEADER OWNS THAT THIS ONE HANDS TO UIKIT:
//
//   - THE CHEVRON. ``MacSidebarHeaderView`` mounts one glyph and rotates it 0°↔90° itself, because
//     AppKit has no outline list. Here it is `UICellAccessory.outlineDisclosure(options:)` at the
//     `.header` style: the system draws the chevron, turns it in its own curve, and makes the WHOLE
//     cell the toggle — which is the `mouseDown { onToggle() }` the Mac hand-wrote, and a thumb-sized
//     target rather than a 10pt glyph.
//   - THE COLLAPSE ITSELF. The Mac folds rows out of an `NSStackView` inside an animation group; the
//     diffable data source folds them out of an ``NSDiffableDataSourceSectionSnapshot`` and animates
//     that. The COLUMN still owns which keys are collapsed, because that set outlives any one cell.
//
// The header's own tap is therefore NOT wired here. What IS: the live read, and the ink ladder.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import UIKit

@MainActor
final class NavigatorSectionHeaderCell: UICollectionViewListCell {
    static let reuseIdentifier = "NavigatorSectionHeaderCell"

    private var store: WorkspaceStore?
    /// The group's display name — the basename, worktree-collision-qualified.
    private var groupTitle = ""
    private(set) var projectKey: String?
    /// The group's rows — read to fuse the hidden rows' badges into the collapsed count's roll-up ink,
    /// and to work out whether the FOCUSED pane lives in this group.
    private var rows: [RailRow] = []
    private var collapsed = false

    /// The one-shot tracker's generation — see ``NavigatorRowCell/generation``. A reused header must
    /// not be woken by the project it used to name.
    private var generation = 0

    private let folder = UIImageView()
    private let name = UILabel()
    private let git = SidebarGitLineView()
    private let count = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Construction

    private func build() {
        // The folder — the group is a PLACE, spoken in the header's own ink; the one pictogram the
        // monochrome rail keeps.
        folder.contentMode = .center
        folder.isAccessibilityElement = false
        folder.setContentHuggingPriority(.required, for: .horizontal)
        folder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(folder)

        name.lineBreakMode = .byTruncatingTail
        name.numberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(name)

        contentView.addSubview(git)

        count.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold)
        count.textAlignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(count)

        NSLayoutConstraint.activate([
            // A bare header keeps the touch rung; a git-lined one grows to fit its second line, which
            // the git view's own bottom anchor drives. `heightRowTall`, not the Mac's
            // `heightSectionHeader` (24): this cell IS the collapse toggle, so it is a thumb target.
            contentView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Slate.Metric.heightRowTall,
            ),
            folder.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Slate.Metric.space3,
            ),
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            name.leadingAnchor.constraint(equalTo: folder.trailingAnchor, constant: 6),
            name.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Slate.Metric.space2),
            name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            git.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            git.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            git.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Slate.Metric.space3,
            ),
            git.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Slate.Metric.space2,
            ),
        ])
    }

    // MARK: The live read

    func configure(
        title: String, projectKey: String?, rows: [RailRow], collapsed: Bool, store: WorkspaceStore,
    ) {
        groupTitle = title
        self.projectKey = projectKey
        self.rows = rows
        self.collapsed = collapsed
        self.store = store
        accessories = [.outlineDisclosure(options: .init(style: .header))]
        // The bed is the Mac's — a project-tint wash under the whole island. There is no island here
        // (a list layout has no container view per section), and the deleted SwiftUI phone half drew
        // no bed either: the phone's grouping is the header line and the indent, monochrome.
        backgroundConfiguration = .clear()
        follow()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        generation &+= 1
        store = nil
        rows = []
        git.summary = nil
    }

    /// Re-resolve the header's volatile chrome — the git summary, whether this group holds focus, the
    /// collapsed count's roll-up — and re-arm for the next store tick. Leaf-scoped for the reason
    /// ``NavigatorRowCell/follow()`` is: a git or status tick repaints this header, never the list.
    ///
    /// ⚠️ EVERY TRACKED READ IS INSIDE THE CLOSURE. Hoisting `projectGitSummary` out to a `let` above
    /// would leave this header deaf to the very poll it exists to show.
    private func follow() {
        generation &+= 1
        let generation = generation
        guard let store else { return }
        var summary: PaneGitSummary?
        var focused = false
        var rollup: AttentionRole?
        withObservationTracking {
            summary = projectKey.flatMap { store.projectGitSummary[$0] }
            focused = SidebarSections.holdsFocus(rows: rows, store: store)
            rollup = collapsed
                ? TabBadgeReading.rollup(
                    RailRowsBuilder.liveChrome(for: rows, store: store).map(\.badge),
                )
                : nil
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        apply(summary: summary, focused: focused, rollup: rollup)
    }

    private func apply(summary: PaneGitSummary?, focused: Bool, rollup: AttentionRole?) {
        // WHICH project is open, said on the ink ladder the sidebar already has: the focused group's
        // folder and name step up to the body ink; every other group stays on the quiet rung. A step
        // on a ladder that already exists spends no new vocabulary, and it cannot collide with the
        // SELECTED ROW's dark chip standing inside the same group.
        let ink = focused ? Slate.Native.Text.primary : Slate.Native.Text.secondary
        folder.image = UIImage(
            systemName: "folder.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.small, weight: .regular,
            ),
            // MONOCHROME even though a group has an identity hue elsewhere: the header ink is the
            // whole signal here, and a second one would say the same thing twice.
        )?.withTintColor(ink, renderingMode: .alwaysOriginal)

        // `slateNerdAware` — a project folder named with a nerd-font glyph draws it from the bundled
        // symbols face instead of a notdef box.
        name.attributedText = .slateNerdAware(
            groupTitle,
            font: .systemFont(ofSize: Slate.Typeface.footnote, weight: .semibold),
            color: ink,
        )

        git.summary = SidebarGitLine.detailSummary(collapsed: collapsed, summary: summary)
        git.isHidden = git.segments.isEmpty

        if let trailing = SidebarGitLine.trailingCount(collapsed: collapsed, count: rows.count) {
            count.text = trailing
            count.textColor = rollup.map(Slate.Native.attentionInk) ?? Slate.Native.Text.tertiary
            count.isHidden = false
        } else {
            count.isHidden = true
        }

        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = groupTitle
        accessibilityValue = summary.flatMap(SidebarGitLine.line)
        accessibilityHint = SidebarGitLine.tooltip(projectKey: projectKey, summary: summary) ?? ""
    }
}
#endif
