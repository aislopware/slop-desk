// SlateHostTypes — the shell types the two imperative halves genuinely spell apart
//
// Auto Layout, Core Graphics, Core Animation, `NSAttributedString` and the whole of Foundation are one
// api on both platforms; what is genuinely two types is the VIEW and the arranged-subview STRIP. Every
// other "this cannot descend to the floor" in this tree has so far turned out to be one of those
// wearing a longer sentence — see `ViewEdges.swift`'s header for the one that claimed
// `UILayoutConstraint` existed.
//
// ⚠️ TYPEALIASES, NOT PROTOCOLS, and the reason is the same for both: the members shared code calls
// are spelled IDENTICALLY on both frameworks (`topAnchor`, `addSubview`, `arrangedSubviews`,
// `addArrangedSubview`, `spacing`, `alignment`). A protocol here would buy a witness table to hide a
// name that is not hidden. The moment a shared body needs a member only ONE framework has, that body
// has found a real divergence and belongs back in its shell — the alias is not a licence to paper
// over one. `NSStackView.orientation` against `UIStackView.axis`, and `edgeInsets` against
// `isLayoutMarginsRelativeArrangement` plus `layoutMargins`, are exactly that: a shared body never
// sets an axis or an inset, it takes a strip that has already been given one.
//
// ⚠️ IT USED TO NAME FOUR TYPES, AND TWO OF THEM WERE THIS CAMPAIGN'S OWN DUPLICATION. `SlateColor`
// and `SlateFont` were declared here while `SlopDeskSlate` had been vending the very same two aliases
// as ``SlateNativeColor``/``SlateNativeFont`` (`SlateDesign.swift:72-81`) for the whole campaign. So a
// stage whose one finding is "the copies were paying for a type NAME" shipped a second name for two
// of them. The call sites now read the Slate spelling and the two declarations are gone, on the rule
// that the LOWER floor wins: `SlopDeskClientCore` depends on `SlopDeskSlate` (`Package.swift:475`), so
// anything the token layer already names is named there.
//
// The split that remains reads like an accident and is not. Slate vends the two VALUES (the colour and
// the font, which a token layer must name to vend a token at all); this file vends the two VIEW types,
// which have no business in a design floor — `panel_shells::one_design_floor_two_renderers` fails the
// build if a drawing lands there.
//
// ⚠️ A COLOUR CROSSES A BOUNDARY AS ITS `cgColor` WHEREVER THE RECEIVER ONLY DRAWS. A dynamic colour
// resolves against the trait environment at the moment `.cgColor` is read, which is correct inside
// `draw(_:)` and wrong anywhere else, so a shared drawing takes the resolved value while a shared
// MODEL takes ``SlateNativeColor`` and lets its shell resolve it. `SlateVectorDraw` is the first of the
// former; `Pane/DecorationDropBlob.swift` states the boundary at the point it is crossed.

#if os(macOS)
import AppKit

/// The imperative shell's view type, whichever shell is compiling.
package typealias SlateHostView = NSView
/// The imperative shell's arranged-subview strip, whichever shell is compiling.
package typealias SlateHostStack = NSStackView
#else
import UIKit

/// The imperative shell's view type, whichever shell is compiling.
package typealias SlateHostView = UIView
/// The imperative shell's arranged-subview strip, whichever shell is compiling.
package typealias SlateHostStack = UIStackView
#endif
