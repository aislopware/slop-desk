import Foundation

/// Decides whether the keyboard accessory bar (Ctrl / Esc / Tab / arrows row) should be
/// shown (doc 17 §2.5).
///
/// The bar is only useful when the **software** keyboard is on screen — with a hardware
/// keyboard the user already has those keys, and iOS shows only a thin (or zero-height) input
/// accessory area. The verified heuristic: read the keyboard frame height from
/// `keyboardWillShow`/`Change`/`Hide` notifications; a software keyboard occupies a large
/// portion of the screen (hundreds of points), a hardware-keyboard shortcut bar is short.
/// We threshold at **~150pt**: height ≥ threshold ⇒ software keyboard ⇒ show the bar.
///
/// Pure + value-type: the iOS view wrapper feeds it the notification's keyboard height and
/// renders/ hides the bar per ``shouldShowAccessoryBar(keyboardHeight:)``. Unit-tested on
/// macOS; holds no UIKit type.
public struct KeyboardAccessoryDecision: Sendable, Equatable {
    /// Keyboard-frame height (points) at/above which we treat it as a software keyboard.
    /// Doc 17 §2.5: "hardware-kbd qua keyboard frame height < ~150pt".
    public let softwareKeyboardThreshold: Double

    public init(softwareKeyboardThreshold: Double = 150.0) {
        precondition(softwareKeyboardThreshold > 0, "threshold must be positive")
        self.softwareKeyboardThreshold = softwareKeyboardThreshold
    }

    /// Whether to show the accessory bar for a keyboard of `keyboardHeight` points.
    ///
    /// - `keyboardHeight == 0` (keyboard hidden) → `false`.
    /// - `0 < keyboardHeight < threshold` (hardware-keyboard shortcut bar) → `false`.
    /// - `keyboardHeight >= threshold` (software keyboard) → `true`.
    public func shouldShowAccessoryBar(keyboardHeight: Double) -> Bool {
        keyboardHeight >= softwareKeyboardThreshold
    }
}
