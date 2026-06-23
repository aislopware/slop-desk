// Details — Warp's per-theme opacity PROFILE (warp-tokens-color.md §1, `theme/color.rs:21-85`).
// All fields are `Opacity` percents (0...100). `Darker` and `Lighter` are byte-identical in this
// build; `Default == DARKER`. The Dark theme uses `.darker`.
//
// These percents drive the text tiers (main/sub/hint/disabled) and the button overlay opacities.

import Foundation

/// Per-theme opacity profile. The 10 percent fields exactly mirror Warp's `CustomDetails`.
public struct CustomDetails: Hashable, Sendable {
    public var mainTextOpacity: Int
    public var subTextOpacity: Int
    public var hintTextOpacity: Int
    public var disabledTextOpacity: Int
    public var foregroundButtonOpacity: Int
    public var accentButtonOpacity: Int
    public var buttonHoverOpacity: Int
    public var buttonClickOpacity: Int
    public var keybindingRowOverlayOpacity: Int
    public var welcomeTipsCompletionOverlayOpacity: Int

    public init(
        mainTextOpacity: Int,
        subTextOpacity: Int,
        hintTextOpacity: Int,
        disabledTextOpacity: Int,
        foregroundButtonOpacity: Int,
        accentButtonOpacity: Int,
        buttonHoverOpacity: Int,
        buttonClickOpacity: Int,
        keybindingRowOverlayOpacity: Int,
        welcomeTipsCompletionOverlayOpacity: Int,
    ) {
        self.mainTextOpacity = mainTextOpacity
        self.subTextOpacity = subTextOpacity
        self.hintTextOpacity = hintTextOpacity
        self.disabledTextOpacity = disabledTextOpacity
        self.foregroundButtonOpacity = foregroundButtonOpacity
        self.accentButtonOpacity = accentButtonOpacity
        self.buttonHoverOpacity = buttonHoverOpacity
        self.buttonClickOpacity = buttonClickOpacity
        self.keybindingRowOverlayOpacity = keybindingRowOverlayOpacity
        self.welcomeTipsCompletionOverlayOpacity = welcomeTipsCompletionOverlayOpacity
    }

    /// `DARKER_DETAILS` (warp-tokens-color.md §1, `color.rs:40-70`). Also `Default for CustomDetails`.
    public static let darker = Self(
        mainTextOpacity: 90,
        subTextOpacity: 60,
        hintTextOpacity: 40,
        disabledTextOpacity: 20,
        foregroundButtonOpacity: 30,
        accentButtonOpacity: 0,
        buttonHoverOpacity: 10,
        buttonClickOpacity: 20,
        keybindingRowOverlayOpacity: 40,
        welcomeTipsCompletionOverlayOpacity: 90,
    )

    /// `LIGHTER_DETAILS` — byte-identical to `darker` in this build (warp-tokens-color.md §1).
    public static let lighter = darker
}

/// `enum Details { Darker, Lighter, Custom }` (warp-tokens-color.md §1, `theme/mod.rs:565-571`).
public enum Details: Hashable, Sendable {
    case darker
    case lighter
    case custom(CustomDetails)

    /// The resolved opacity profile.
    public var profile: CustomDetails {
        switch self {
        case .darker: .darker
        case .lighter: .lighter
        case let .custom(p): p
        }
    }
}
