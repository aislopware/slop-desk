// MacSettingsNavigator — the Settings window's source list.
//
// The rows are `SettingsCatalog.sections`, which is the one taxonomy the phone's list reads too, so
// the two halves cannot disagree about which sections exist or in what order. What this file adds is
// only how a source list is BUILT in AppKit: a search field over the section titles and a table with
// the `.sourceList` style, which is where a settings navigator's selection highlight, row height and
// inset come from without any of them being spelled as a number here.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

/// The left column: a search field and the section rows it narrows.
@MainActor
final class MacSettingsNavigatorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called with a section id when the selection changes.
    var onSelect: (String) -> Void = { _ in }

    private let table = NSTableView()
    private let search = NSSearchField()
    /// The rows currently shown — every section, or the title-substring matches while the field has a
    /// query. Substring rather than the fuzzy ranking every other search field uses, for the same
    /// reason the flat index does it: someone typing here already knows the name of the page.
    private var shown: [SettingsCatalog.Section] = SettingsCatalog.sections

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = "Search"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsWholeSearchString = false

        let root = NSView()
        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: Slate.Metric.space2),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Slate.Metric.space2),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Slate.Metric.space2),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: Slate.Metric.space2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Select a section by id — at open, to land on the first page, and every time the All-Settings
    /// index's ✎ names the page that owns a key.
    ///
    /// ⚠️ IT CLEARS THE QUERY WHEN IT HAS TO. The rows this searched used to be ``shown`` — the
    /// FILTERED array — so a jump whose target the live query excluded fell straight through the
    /// guard and did nothing at all: no page change, no selection move, no complaint. That is the
    /// exact case the ✎ is for, because the index it is pressed in is the surface people reach FOR
    /// by searching. A jump is an explicit instruction to go somewhere, which outranks a filter the
    /// reader typed to find it; so an unshown target drops the query rather than losing the request.
    /// The alternative — jumping without clearing — would leave the source list showing rows that no
    /// longer contain the selected one, which is the state ``searchChanged`` already refuses to
    /// create.
    func select(_ id: String) {
        if !shown.contains(where: { $0.id == id }) {
            guard SettingsCatalog.sections.contains(where: { $0.id == id }) else { return }
            search.stringValue = ""
            shown = SettingsCatalog.sections
            table.reloadData()
        }
        guard let row = shown.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // A selection below the fold is not a selection anybody can see. The list is short enough
        // that this only bites on a short window, which is exactly when it is hardest to notice.
        table.scrollRowToVisible(row)
    }

    @objc
    private func searchChanged() {
        let needle = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selected = shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].id : nil
        shown = needle.isEmpty
            ? SettingsCatalog.sections
            : SettingsCatalog.sections.filter { $0.title.lowercased().contains(needle) }
        table.reloadData()
        // Narrowing the list must not silently change WHICH page is shown: keep the selection where it
        // was if it survived the filter, and otherwise leave the page alone rather than jumping to
        // whatever happens to be first.
        if let selected, let row = shown.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: Table

    func numberOfRows(in _: NSTableView) -> Int { shown.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let section = shown[row]
        let cell = NSTableCellView()
        let image = NSImageView(
            image: NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil)
                ?? NSImage(),
        )
        image.contentTintColor = Slate.Native.Text.icon
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: section.title)
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: Slate.Metric.iconSize),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: Slate.Metric.space2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard shown.indices.contains(table.selectedRow) else { return }
        onSelect(shown[table.selectedRow].id)
    }
}
