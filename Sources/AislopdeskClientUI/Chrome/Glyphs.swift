// Glyphs — small neutral brand/icon marks (ORCH-DECISIONS F3). We do NOT vendor Warp's proprietary
// SVGs; generic UI icons use SF Symbols and the agent/Claude brand mark is a neutral asterisk-flower
// glyph (the ✳ shown), never a trademarked logo.

import AislopdeskDesignSystem
import SwiftUI

/// A neutral asterisk-flower brand mark for the agent/Claude pane (F3). Six rounded spokes, drawn as a
/// vector so it scales crisply at any icon size.
struct AgentBrandGlyph: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2
            let spokeWidth = radius * 0.34
            let spokeLength = radius * 1.9
            var spoke = Path()
            spoke.addRoundedRect(
                in: CGRect(
                    x: center.x - spokeWidth / 2,
                    y: center.y - spokeLength / 2,
                    width: spokeWidth,
                    height: spokeLength,
                ),
                cornerSize: CGSize(width: spokeWidth / 2, height: spokeWidth / 2),
            )
            for i in 0..<3 {
                let angle = Double(i) * (.pi / 3.0)
                var transformed = spoke
                transformed = transformed.applying(
                    CGAffineTransform(translationX: -center.x, y: -center.y)
                        .concatenating(CGAffineTransform(rotationAngle: angle))
                        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)),
                )
                context.fill(transformed, with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A solid accent circle holding the avatar initials (warp-window-chrome.md §6 — 20×20, accent fill,
/// black bold 12pt initials).
struct AvatarCircle: View {
    @Environment(\.theme) private var theme
    var initials: String = "A"

    var body: some View {
        Circle()
            .fill(theme.accent)
            .frame(width: WarpSize.avatarCircle, height: WarpSize.avatarCircle)
            .overlay(
                Text(initials)
                    .font(WarpType.ui(WarpType.uiSize, weight: .bold))
                    .foregroundStyle(Color.black),
            )
    }
}
