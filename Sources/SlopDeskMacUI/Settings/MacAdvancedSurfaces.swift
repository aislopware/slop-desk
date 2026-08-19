// MacAdvancedSurfaces — the two Advanced groups the phone does not have.
//
// docs/56 stage D, increment 49. `raw-overrides` and `config-file` are gated to `Platform::Mac` by the
// layout table for reasons that are facts rather than layout: the `SLOPDESK_*` overlay is a HOST-side
// concern, and `~/.config` is a path iOS has none of. So these are the SECOND shape of a bespoke group —
// the `os-integration` / `cli-install` shape — where "drawn once" means once, full stop. Their SwiftUI arms
// went with this increment rather than surviving as a half nothing renders, and their words live here
// beside their single renderer, exactly as `MacOSIntegrationRows`' and `MacCLIInstallCard`'s do.
//
// What did NOT stay here is the config PATH and the two verbs over it: `SettingsConfigFile` in
// `SlopDeskClientCore` owns those, because the resolution is `SlopDeskCLICore`'s (env override included)
// and this target cannot reach that module — re-spelling an XDG lookup to avoid one face would be the
// second implementation the one-implementation rule refuses.

import AppKit
import SlopDeskClientCore // SettingsConfigFile — the path, and what the buttons do
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

// MARK: - Advanced → Raw overrides

/// The power-user raw `SLOPDESK_*` box.
///
/// The overlay folds this LAST, so a key typed here beats the matching typed preference — and a REAL
/// process env var still beats the lot, which the caption says because nothing on screen otherwise would.
///
/// THE BUFFER IS RENDERED FROM THE STORE, which is what makes "Reset All Settings" clear the box: the reset
/// writes the store, the page rebuilds, and the box comes back empty. It used to need a callback threaded
/// from the All-Settings list two groups below, which only worked while one page happened to own both.
@MainActor
final class MacRawOverridesBox: NSStackView, NSTextViewDelegate {
    private let store: PreferencesStore
    private let editor = NSTextView()

    init(store: PreferencesStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space2
        translatesAutoresizingMaskIntoConstraints = false

        let blurb = macSettingsNote(
            "One SLOPDESK_KEY=value per line. Folded last, so a key here overrides the matching typed setting.",
            .secondary, style: .subheadline,
        )
        addArrangedSubview(blurb)
        blurb.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        editor.string = Self.render(store.rawOverrides)
        editor.delegate = self
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.editorHeight),
        ])

        let caption = NSStackView(views: [
            NSImageView(
                image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage(),
            ),
            macSettingsNote(
                "A real environment variable set on the process still wins over any value here.", .tertiary,
            ),
        ])
        caption.orientation = .horizontal
        caption.alignment = .firstBaseline
        caption.spacing = Slate.Metric.space1
        addArrangedSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Tall enough that a handful of overrides are visible at once without the box owning the page.
    private static let editorHeight: CGFloat = 120

    // MARK: Committing

    /// COMMIT ON END OF EDITING, never per keystroke — the rule `MacActionField` states for every field in
    /// this window. Each write to `rawOverrides` persists and re-publishes the overlay, so committing as
    /// the reader types would rebuild it once per character, and the SwiftUI half needs a
    /// re-render guard for exactly the churn this avoids.
    func textDidEndEditing(_: Notification) { commit() }

    private func commit() {
        let parsed = Self.parse(editor.string)
        guard parsed != store.rawOverrides else { return }
        store.rawOverrides = parsed
    }

    /// The `key=value` lines as a map. An empty or malformed line is DROPPED rather than stored as a key
    /// with no name — the box is free text, and half a line is not an override.
    private static func parse(_ raw: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }
        return map
    }

    /// The map as text, sorted by key so the box reads the same way twice.
    private static func render(_ map: [String: String]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Advanced → Config File

/// The resolved config path, plus Open and Reload.
///
/// The path is shown MIDDLE-truncated on one line: it is long, the interesting halves are both ends
/// (`~/.config/…` and the file name), and a wrapped path in a settings row reads as prose.
@MainActor
final class MacConfigFileRows: NSStackView {
    init(store: PreferencesStore) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space2
        translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: SettingsConfigFile.resolvedPath)
        path.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        path.textColor = Slate.Native.Text.secondary
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1

        let row = NSStackView(views: [NSTextField(labelWithString: "Config path"), path])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Slate.Metric.space3
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let buttons = NSStackView(views: [
            MacActionButton(title: "Open Config File") {
                ExternalOpen.url(SettingsConfigFile.prepared())
            },
            MacActionButton(title: "Reload Config") { SettingsConfigFile.reload(store) },
        ])
        buttons.orientation = .horizontal
        buttons.spacing = Slate.Metric.space3
        addArrangedSubview(buttons)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}
