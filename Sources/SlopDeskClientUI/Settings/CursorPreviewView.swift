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
// macOS-only: the full Cursor section (`ColorPicker` + live preview) is macOS; the Appearance tab keeps a
// simpler Style/Blink section on iOS (see `AppearanceSettingsTab`). The pure hex helper (`CursorColorHex`) is
// cross-platform + headlessly testable (`CursorColorHexTests`); the `Color`↔hex glue below is pure SwiftUI
// (`Color.resolve(in:)`, NO `NSColor`).
// Colour + type: `SettingsInk` / `SettingsType` (SYSTEM semantics — not the terminal theme); geometry
// rides `Slate.Metric` (raw font/radius/height literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - CursorColorHex (pure 6-hex ↔ RGB bridge — no SwiftUI / AppKit, so it is unit-pinned)

/// The pure conversion between a libghostty `cursor-color` 6-hex string (what `TerminalPreferences` persists
/// and `TerminalConfigBuilder` emits) and integer / unit RGB channels. Kept AppKit-free so
/// `CursorColorHexTests` can pin the round-trip headlessly; the SwiftUI `Color`↔hex glue (via
/// `Color.resolve(in:)`) lives in the macOS-only `Color` extension below and is code-reviewed, not unit-tested.
enum CursorColorHex {
    /// Parse a 6-hex RGB string (no leading `#`) into 0…255 channels. Returns `nil` for an empty string
    /// (an empty string means "Default" = follow the theme), the wrong length, or any non-hex character — the caller then
    /// falls back to the effective default colour. Case-insensitive.
    static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// Format unit RGB doubles (each clamped to `0…1`, NaN → `0`) into an UPPERCASE 6-hex string (no `#`) —
    /// exactly the shape `TerminalConfigBuilder` forwards as `cursor-color = …`. The clamp uses an ordered
    /// comparison (NaN-faithful) rather than a bare `min`/`max` ternary.
    static func hex(r: Double, g: Double, b: Double) -> String {
        String(format: "%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// One unit-double channel → a `0…255` int (rounded-to-nearest). NaN → `0` (a safe default); ±infinity
    /// falls through to the ordered, NaN-faithful clamp (→ `1` / `0`).
    private static func channel(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let clamped = Double.minimum(1, Double.maximum(0, value))
        return Int((clamped * 255).rounded())
    }
}

#if os(macOS)

// MARK: - Color ↔ cursor-hex glue (macOS — pure SwiftUI, via Color.resolve(in:))

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
/// `store.terminal`. Hosted by `AppearanceSettingsTab` on macOS.
struct CursorPreviewView: View {
    @Bindable var store: PreferencesStore

    /// The resolved environment — threaded into `Color.cursorHexString(in:)` so a picked colour serializes via
    /// the SwiftUI-native `Color.resolve(in:)` (no `NSColor` bridge). `\.self` yields the whole `EnvironmentValues`.
    @Environment(\.self) private var environment

    /// Drives the blink animation of the preview caret (mirrors the chosen `cursorBlink`, purely cosmetic).
    @State private var blinkVisible = true

    var body: some View {
        slateFormSection("Cursor") {
            Text("Live preview of your cursor color, style, opacity and blink behavior.")
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)

            previewCard

            ColorPicker(
                "Cursor color",
                selection: cursorColorBinding(\.cursorColor, fallbackHex: store.terminal.foreground),
                supportsOpacity: false,
            )
            ColorPicker(
                "Text color under cursor",
                selection: cursorColorBinding(\.cursorTextColor, fallbackHex: store.terminal.background),
                supportsOpacity: false,
            )

            LabeledContent("Cursor opacity") {
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
                "Cursor Style",
                options: SettingsOptionCatalog.cursorStyles,
                selection: $store.terminal.cursorStyle,
            ) { option in
                SettingsCaretArt(style: option.value, color: cursorPreviewColor)
            }

            LabeledContent {
                Picker("", selection: $store.terminal.cursorBlink) {
                    Text("Default").tag(TerminalPreferences.CursorBlink.default)
                    Text("On").tag(TerminalPreferences.CursorBlink.on)
                    Text("Off").tag(TerminalPreferences.CursorBlink.off)
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text("Cursor blink style")
                    Text("The `Default` option defers to DEC mode 12 to determine blinking state.")
                        .font(SettingsType.subtitle)
                        .foregroundStyle(SettingsInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Live preview

    /// The `john@doe-pc$ git commit -m "│"` mock — a monospaced prompt line with the live caret between the
    /// quotes, on the inset element surface (the preview card). Per `cursor-style.png`'s visual spec the
    /// prompt colours are `john` in green, `@doe-pc` in muted blue-gray (the host run, distinct from the user),
    /// and `$ git commit -m "` in the default foreground — so the host part maps to the blue `SettingsInk.info`
    /// token (the closest theme-aware blue-gray), NOT the same green as `john`.
    private var previewCard: some View {
        HStack(spacing: 0) {
            Text("john").foregroundStyle(SettingsInk.ok)
            Text("@doe-pc").foregroundStyle(SettingsInk.info)
            Text("$ git commit -m \"").foregroundStyle(SettingsInk.primary)
            cursorGlyph
            Text("\"").foregroundStyle(SettingsInk.primary)
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

    /// The approximate monospace cell for the preview font (advance ≈ 0.62 em, line height ≈ 1.3 em),
    /// measured off the LIVE resolved `.body` size so the caret keeps its proportions when the user changes
    /// the system text size. A preview-only estimate — the real surface metrics come from libghostty.
    private var previewCellSize: CGSize {
        let em = SettingsMetric.resolvedBodyPointSize
        return CGSize(width: em * 0.62, height: em * 1.3)
    }

    /// The effective caret colour: the pinned `cursorColor`, else the foreground ("Default").
    private var cursorPreviewColor: Color {
        Color(cursorHex: store.terminal.cursorColor)
            ?? Color(cursorHex: store.terminal.foreground)
            ?? SettingsInk.primary
    }

    /// Whether the cosmetic preview caret blinks: `.on` (and `.default`, which defers to DEC mode 12 — the
    /// terminal's usual blink-on default) animate; `.off` holds steady. Preview-only — the real surface
    /// honours DEC mode 12 for `.default`.
    private var previewBlinks: Bool { store.terminal.cursorBlink != .off }

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
#endif
