// otty visual-verification harness (L10) — renders an otty chrome showcase to a PNG via ImageRenderer so the
// Paper palette + component kit can be eyeballed headlessly (no GUI/TCC). Opt-in: INERT unless the env var
// `OTTY_SNAPSHOT_OUT=<path.png>` is set, so `swift test` / `make check` never write a file. Run on demand:
//   OTTY_SNAPSHOT_OUT="$PWD/.build/otty-showcase.png" swift test --filter OttySnapshotRender
// It renders a hand-built mock of the real chrome from the SAME token layer + component kit, so a palette /
// component regression shows up visually. It is NOT a pixel-diff CI gate.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SFSafeSymbols
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

final class OttySnapshotRender: XCTestCase {
    @MainActor
    func testRenderOttyShowcase() throws {
        // Opt-in only: inert under `swift test` / `make check` unless an output path is requested.
        guard let out = ProcessInfo.processInfo.environment["OTTY_SNAPSHOT_OUT"] else {
            throw XCTSkip("set OTTY_SNAPSHOT_OUT=<path.png> to render the otty showcase")
        }
        let renderer = ImageRenderer(content: OttyShowcase().frame(width: 920, height: 560))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("OTTY_SNAPSHOT_WRITTEN \(out)")
    }
}

/// A static mock of the otty chrome: sidebar + floating card + inspector, built from the real token layer
/// and component kit (OttySidebarRow / OttySectionHeader / OttyPlateButton / OttyStatusDot / OttyKeyValueRow
/// / OttyPill / .ottyCard).
private struct OttyShowcase: View {
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
            inspector
        }
        .frame(width: 920, height: 560)
        .background(Otty.Surface.window)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            OttySectionHeader("Workspace") {
                OttyPlateButton(symbol: .plus, plate: 20)
            }
            OttySidebarRow(symbol: .terminal, title: "zsh — main", subtitle: "~/oss/aislopdesk", isSelected: true) {}
            OttySidebarRow(symbol: .terminal, title: "build", subtitle: "swift build", isSelected: false) {}
            OttySidebarRow(symbol: .display, title: "Remote window", subtitle: nil, isSelected: false) {}
            OttySidebarRow(symbol: .lockShield, title: "System dialog", subtitle: nil, isSelected: false) {}
            Spacer()
        }
        .padding(Otty.Metric.space2)
        .frame(width: 220)
        .background(Otty.Surface.sidebar)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("zsh — main")
                    .font(.system(size: Otty.Typeface.base, weight: .medium))
                    .foregroundStyle(Otty.Text.primary)
                Spacer()
                OttyPlateButton(symbol: .squareSplit2x1, plate: 22)
                OttyPlateButton(symbol: .xmark, plate: 22)
            }
            .padding(.horizontal, Otty.Metric.space2)
            .frame(height: Otty.Metric.paneHeaderHeight)
            .background(Otty.Surface.window)
            .overlay(alignment: .bottom) { Rectangle().fill(Otty.Line.divider).frame(height: 1) }

            VStack(alignment: .leading, spacing: 2) {
                (Text("~ ").foregroundStyle(Otty.Status.info)
                    + Text("via ").foregroundStyle(Otty.Text.secondary)
                    + Text("🥭 jmango").foregroundStyle(Otty.Status.ok))
                    .font(.system(size: 13, design: .monospaced))
                (Text("❯ ").foregroundStyle(Otty.State.accent)
                    + Text("swift build").foregroundStyle(Otty.Text.primary))
                    .font(.system(size: 13, design: .monospaced))
                Spacer()
                OttyPill(symbol: .folder, text: "~/oss/aislopdesk")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Otty.Metric.space3)
            .background(Otty.Surface.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard, style: .continuous)
                .strokeBorder(Otty.State.accent, lineWidth: 1),
        )
        .shadow(color: Otty.State.shadow, radius: 6, y: 1)
        .padding(Otty.Metric.space2)
        .frame(maxWidth: .infinity)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSION")
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .foregroundStyle(Otty.State.header)
            OttyKeyValueRow(label: "Status") {
                HStack(spacing: 6) {
                    OttyStatusDot(color: Otty.Status.ok, glowKey: nil)
                    Text("connected")
                }
            }
            OttyKeyValueRow(label: "Host") { Text("macstudio:7799") }
            OttyKeyValueRow(label: "Ping") { Text("1 ms").monospacedDigit() }
            OttyKeyValueRow(label: "Agent") {
                HStack(spacing: 6) {
                    Image(systemSymbol: .gearshapeFill).foregroundStyle(Otty.Status.warn)
                    Text("working")
                }
            }
            Rectangle().fill(Otty.Line.divider).frame(height: 1).padding(.vertical, 4)
            Text("COMMANDS")
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .foregroundStyle(Otty.State.header)
            Text("$ swift test")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Otty.Text.primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ottyCard()
            Spacer()
        }
        .font(.system(size: Otty.Typeface.base))
        .padding(Otty.Metric.space3)
        .frame(width: 240)
        .background(Otty.Surface.sidebar)
    }
}
#endif
