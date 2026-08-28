// PlatformView — the one name for "the view class this platform's imperative UI framework draws
// into": `NSView` on the Mac, `UIView` on the phone.
//
// It exists because the leaf SEAMS (``TerminalRendererFactory``, ``VideoWindowFactory``) hand a
// renderer's view back to a canvas that must add it as a subview, and after the SwiftUI removal
// there is no longer a framework-neutral view type to phrase that in. There used to be one —
// `AnyView` — and it is exactly what was deleted: a seam typed in SwiftUI forced every AppKit and
// UIKit canvas to interpose a hosting view over the one surface that must take every keystroke.
//
// ⚠️ THIS IS NOT A COMPATIBILITY SHIM AND MUST NOT GROW INTO ONE. It aliases a class name and
// nothing else — no shared protocol, no wrapper, no `#if` cascade of method spellings. AppKit and
// UIKit differ in ways that matter (`isFlipped`, `layer` ownership, `needsLayout` vs
// `setNeedsLayout`), and a seam that tried to paper over those would be the cross-platform view
// layer this campaign removed, rebuilt under a new name. Each platform's canvas is written against
// its OWN framework; this alias only lets the two seams declare a return type once.
#if canImport(AppKit)
import AppKit

/// The Mac's view class. `NSView` is main-actor isolated, which is why every factory closure
/// returning one carries `@MainActor` on the closure TYPE rather than only at the call site.
public typealias PlatformView = NSView
#elseif canImport(UIKit)
import UIKit

/// The phone's view class. `UIView` is main-actor isolated for the same reason `NSView` is, so the
/// seam signatures are identical on both platforms — the alias is the only thing that differs.
public typealias PlatformView = UIView
#endif
