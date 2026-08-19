// CursorPreviewView — the Appearance → Cursor section.
//
// Follows the design spec `docs/ui-shell/screenshots/cursor-style.png`: a "CURSOR" section that opens with a
// one-line description + a LIVE PREVIEW card (the `john@doe-pc$ git commit -m "│"` mock that re-renders the
// caret as the user tunes it), then the cursor-color / text-color-under-cursor color wells, the opacity
// slider, and the Style / Blink / Animation dropdowns. Every control binds `store.terminal` (a
// `TerminalPreferences` render-pref field), so a change flows through the store's `terminal` `didSet`
// → `applyTerminal()` → `TerminalConfigBroadcaster` and re-applies live (the cursor color/opacity/text lines
// are emitted by `TerminalConfigBuilder`) — there is NO `refreshTerminalControls()` hop here (that seam
// is for the fire-time `Defaults` Controls toggles, not the typed render prefs).
//
// BOTH halves — this is the PHONE's. It was once `#if os(macOS)` with the phone reduced to plain Style/Blink
// rows on the stated grounds that the section is AppKit; it never was, and the gate cost the phone the cursor
// colour, the text-under colour and the opacity outright. Increment 49 gave the Mac its own AppKit drawing
// (``SlopDeskMacUI/MacCursorPreviewSurface``) and moved everything BOTH of them say — the blurb, the three
// control labels, the mock prompt's runs and their inks, the preview cell estimate, the blink rule — down to
// ``SettingsCursorSurface``. The hex codec went with it (``CursorColorHex`` in `SlopDeskClientCore`, still
// pinned headlessly by `CursorColorHexTests`); what stays here is the `Color` glue, because `Color.resolve(in:)`
// is SwiftUI's and the Mac reads its own well through `NSColor.usingColorSpace(.sRGB)`.
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - Color ↔ cursor-hex glue (pure SwiftUI, via Color.resolve(in:))

extension Color {
    /// Build a colour from a 6-hex `cursor-color` string, or `nil` when the string is empty / malformed (the
    /// caller then substitutes the effective default — the foreground for the cursor body, the background for
    /// the glyph-under-cursor).
    init?(cursorHex hex: String) {
        guard let rgb = CursorColorHex.rgb(hex) else { return nil }
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }

    /// This colour as a 6-hex `cursor-color` string (gamma-encoded sRGB), or `""` (follow the theme) when it
    /// can't be resolved — so a colour that resists conversion degrades to "Default", never traps. Resolved
    /// purely via `Color.resolve(in:)` (no `NSColor` bridge): `Color.Resolved.{red,green,blue}` are gamma-encoded
    /// sRGB 0…1 channels, with wide-gamut picks gamut-mapped to sRGB — equivalent to an
    /// `NSColor(self).usingColorSpace(.sRGB)` conversion within channel rounding, so hex values persisted by
    /// that bridge keep resolving to the same colour. This feeds the libghostty config string, NOT the frozen
    /// golden wire — `CursorColorHexTests` pins the pure `CursorColorHex.hex` helper.
    func cursorHexString(in environment: EnvironmentValues) -> String {
        let resolved = resolve(in: environment)
        return CursorColorHex.hex(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue))
    }
}

// MARK: - CursorPreviewView

/// The Appearance → Cursor `Section` (live preview + colour / opacity / style / blink / animation), bound to
/// `store.terminal`. Reached from the layout table's `cursor-preview` bespoke row on either half.
struct CursorPreviewView: View {
    @Bindable var store: PreferencesStore

    /// The resolved environment — threaded into `Color.cursorHexString(in:)` so a picked colour serializes via
    /// the SwiftUI-native `Color.resolve(in:)` (no `NSColor` bridge). `\.self` yields the whole `EnvironmentValues`.
    @Environment(\.self) private var environment

    /// Drives the blink animation of the preview caret (mirrors the chosen `cursorBlink`, purely cosmetic).
    @State private var blinkVisible = true

    var body: some View {
        // The rows only — the `Cursor` header and its timing chip come from the layout table, which
        // is where the phone's version of this group gets them too.
        Group {
            Text(SettingsCursorSurface.blurb)
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)

            previewCard

            ColorPicker(
                SettingsCursorSurface.colorLabel,
                selection: cursorColorBinding(\.cursorColor, fallbackHex: store.terminal.foreground),
                supportsOpacity: false,
            )
            ColorPicker(
                SettingsCursorSurface.textColorLabel,
                selection: cursorColorBinding(\.cursorTextColor, fallbackHex: store.terminal.background),
                supportsOpacity: false,
            )

            LabeledContent(SettingsCursorSurface.opacityLabel) {
                HStack(spacing: Slate.Metric.space2) {
                    Text(String(format: "%.2f", store.terminal.cursorOpacity))
                        .foregroundStyle(SettingsInk.secondary)
                        .monospacedDigit()
                    Slider(value: $store.terminal.cursorOpacity, in: 0...1)
                }
            }

            // Style CARDS, each drawing the caret it selects with the SAME `CursorCaret` the preview above
            // uses — so a card and the live prompt can never disagree about what "Hollow" looks like.
            SettingsOptionCards(
                settingLabel(AllSettingsCatalog.RenderKey.cursorStyle),
                options: SettingsCatalog.options(.cursorStyle),
                selection: $store.terminal.cursorStyle,
            ) { option in
                SettingsCaretArt(style: option.value, color: cursorPreviewColor)
            }

            SettingsOptionMenuRow(
                settingLabel(AllSettingsCatalog.RenderKey.cursorStyleBlink),
                options: SettingsCatalog.options(.cursorBlink),
                selection: $store.terminal.cursorBlink,
            )
        }
    }

    // MARK: Live preview

    /// The `john@doe-pc$ git commit -m "│"` mock — a monospaced prompt line with the live caret between the
    /// quotes, on the inset element surface (the preview card). The runs and what each one MEANS are
    /// ``SettingsCursorSurface/promptBeforeCaret``'s; this resolves those roles to hues and lays them out.
    private var previewCard: some View {
        HStack(spacing: 0) {
            ForEach(SettingsCursorSurface.promptBeforeCaret, id: \.text) { run in
                Text(run.text).foregroundStyle(SettingsInk.of(run.ink))
            }
            cursorGlyph
            ForEach(SettingsCursorSurface.promptAfterCaret, id: \.text) { run in
                Text(run.text).foregroundStyle(SettingsInk.of(run.ink))
            }
        }
        .font(SettingsType.mono)
        .padding(.vertical, Slate.Metric.space2)
        .padding(.horizontal, Slate.Metric.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous)
                .fill(SettingsInk.inset),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous)
                .strokeBorder(SettingsInk.hairline, lineWidth: 1),
        )
    }

    /// The preview caret, rendered per the chosen style / colour / opacity, blinking when `cursorBlink` is on.
    private var cursorGlyph: some View {
        cursorShape
            .opacity(blinkVisible ? store.terminal.cursorOpacity : 0)
            .onAppear { restartBlink() }
            .onChange(of: store.terminal.cursorBlink) { _, _ in restartBlink() }
    }

    /// The caret, via the SHARED ``CursorCaret`` — the one place the four caret silhouettes are drawn, so this
    /// preview and the style cards beneath it can't drift apart.
    private var cursorShape: some View {
        CursorCaret(style: store.terminal.cursorStyle, color: cursorPreviewColor, cell: previewCellSize)
    }

    /// The approximate monospace cell for the preview font, measured off the LIVE resolved `.body` size so
    /// the caret keeps its proportions when the user changes the system text size. The RATIOS are
    /// ``SettingsCursorSurface/previewCell(em:)``'s — the Mac reads the same ones, or the one caret would
    /// read as two silhouettes.
    private var previewCellSize: CGSize {
        let cell = SettingsCursorSurface.previewCell(em: Double(SettingsMetric.resolvedBodyPointSize))
        return CGSize(width: cell.width, height: cell.height)
    }

    /// The effective caret colour: the pinned `cursorColor`, else the foreground ("Default").
    private var cursorPreviewColor: Color {
        Color(cursorHex: store.terminal.cursorColor)
            ?? Color(cursorHex: store.terminal.foreground)
            ?? SettingsInk.primary
    }

    private var previewBlinks: Bool { SettingsCursorSurface.previewBlinks(store.terminal.cursorBlink) }

    private func restartBlink() {
        blinkVisible = true
        guard previewBlinks else { return }
        withAnimation(Slate.Anim.pulse) {
            blinkVisible = false
        }
    }

    // MARK: Colour bindings

    /// Bridge a `TerminalPreferences` 6-hex colour string field to a `ColorPicker`'s `Binding<Color>`. An
    /// empty / unset field reads as `fallbackHex` (the theme default) so the well shows the effective colour;
    /// picking a colour writes its sRGB 6-hex back, which re-applies live through the store's `terminal`
    /// `didSet`.
    private func cursorColorBinding(
        _ keyPath: WritableKeyPath<TerminalPreferences, String>, fallbackHex: String,
    ) -> Binding<Color> {
        Binding(
            get: {
                let hex = store.terminal[keyPath: keyPath]
                return Color(cursorHex: hex) ?? Color(cursorHex: fallbackHex) ?? SettingsInk.primary
            },
            set: { store.terminal[keyPath: keyPath] = $0.cursorHexString(in: environment) },
        )
    }
}
#endif
