import Foundation
import SlopDeskWorkspaceModel

// BindingRowPlatform — which half lists a keybinding, asked one row at a time.
//
// The rule is `slopdesk_workspace::bindings`, and the platform column is why that table has one: the
// registry it filters is not one list — it is the cheat sheet, the keybindings editor, the `ctl` verb
// list, and the CHORD TABLE the keyboard dispatcher resolves against. A row listed on a half that
// cannot run it does not merely lie in a list; its chord is taken away from the terminal to run
// nothing. ⌥⌘P was exactly that on the phone.
//
// ``WorkspaceBindingRegistry/bindings`` no longer asks this — the table crosses already filtered for
// the half that asked. What is left is the question a SURFACE asks about a row it holds by id, and
// the answer comes from the same read, so there is still one gate and it is still in one place.

/// Which half lists a keybinding, and therefore binds its chord.
///
/// `public` rather than `package` because the verb's declaration has a reader outside this module:
/// `GuiLeafView`'s footer draws a detach ⇄ reattach button, which is the same capability the row and
/// the chord are. One declaration, every surface — a button carrying its own `#if` would be a second
/// place for the answer to drift.
public enum BindingRowPlatform {
    /// Whether this half lists the binding filed under `id`.
    ///
    /// An id the table does not declare is LISTED — including the nine generated `pane.select.N`
    /// slots, which are `Both` and are covered by the collapsed `pane.selectN` representative. A typo
    /// must not unbind a chord without a word; `rust/slopdesk-invariants` is what makes an undeclared
    /// id impossible in the first place.
    public static func lists(_ id: String) -> Bool {
        !WorkspaceBindingTable.current.withheldIDs.contains(id)
    }

    /// The same question asked of a named half — what a test uses to read the other side's table.
    ///
    /// A process is one slice, so ``lists(_:)`` is the answer for everything the app does. This
    /// overload exists because the interesting question ("what does the OTHER half bind?") can only
    /// be asked from a Mac, which is where the tests run.
    public static func lists(_ id: String, mac: Bool) -> Bool {
        !WorkspaceBindingTable.of(mac: mac).withheldIDs.contains(id)
    }

    /// Every id the table declares, in registry order — whether or not this half lists it.
    public static var declaredIDs: [String] {
        WorkspaceBindingTable.current.declaredIDs
    }
}
