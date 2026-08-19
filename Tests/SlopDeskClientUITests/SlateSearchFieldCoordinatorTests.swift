// SlateSearchFieldCoordinatorTests — the SwiftUI wrapper's one moving part.
//
// The FIELD's jump-free configuration is pinned one floor down
// (`SlopDeskSlateTests/SlateSearchFieldTests`), because the Mac's navigator mints the same field with
// no SwiftUI around it. What is only true up here is the representable's coordinator: an edit in the
// field has to reach the binding the phone's device lists read.

#if os(macOS)
import AppKit
import SlopDeskSlate
import SwiftUI
import XCTest
@testable import SlopDeskClientUI

@MainActor
final class SlateSearchFieldCoordinatorTests: XCTestCase {
    /// Typing flows field → binding through the coordinator (the SwiftUI side reads live).
    func testCoordinatorSyncsFieldEditsIntoTheBinding() {
        var captured = ""
        let binding = Binding(get: { captured }, set: { captured = $0 })
        let coordinator = SlateSearchField.Coordinator(text: binding)
        let field = SlateNativeSearchField.makeConfiguredField(text: "", delegate: coordinator)

        field.stringValue = "otty"
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field),
        )
        XCTAssertEqual(captured, "otty", "a field edit lands in the bound query")
    }
}
#endif
