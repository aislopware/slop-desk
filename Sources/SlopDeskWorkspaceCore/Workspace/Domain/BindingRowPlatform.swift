import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// BindingRowPlatform — the near side of which half lists a keybinding.
//
// The rule is `slopdesk_workspace::binding_rows`, and it is `PaletteRowPlatform` one surface further
// in. The registry this filters is not one list: it is the cheat sheet, the keybindings editor, the
// `ctl` verb list, and — the part that made this more than cosmetic — the CHORD TABLE the keyboard
// dispatcher resolves against. A row listed on a half that cannot run it does not merely lie in a
// list; its chord is taken away from the terminal to run nothing. ⌥⌘P was exactly that on the phone.
//
// ONE PLATFORM GATE, in ONE place. `WorkspaceBindingRegistry.bindings` is a `static let` built once
// per process and a process is one slice, so the compiled slice IS the answer — but the table still
// takes `mac` as an argument, because the interesting question ("what does the OTHER half bind?")
// can only be asked from a Mac, which is where the tests run.

/// Which half lists a keybinding, and therefore binds its chord.
///
/// `public` rather than `package` because the verb's declaration has a FOURTH reader outside this
/// module: `GuiLeafView`'s footer draws a detach ⇄ reattach button, which is the same capability the
/// row and the chord are. One declaration, every surface — a button carrying its own `#if` would be
/// a fourth place for the answer to drift.
public enum BindingRowPlatform {
    /// The half this binary IS.
    private static let isMac: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()

    /// Whether this half lists the binding filed under `id`.
    ///
    /// An id the table does not declare is LISTED — including the nine generated `pane.select.N`
    /// slots, which are `Both` and are covered by the collapsed `pane.selectN` representative. A typo
    /// must not unbind a chord without a word; `rust/slopdesk-invariants` pins the two id sets
    /// equal in both directions.
    public static func lists(_ id: String) -> Bool {
        lists(id, mac: isMac)
    }

    /// The same question asked of a named half — what a test uses to read the other side's table.
    public static func lists(_ id: String, mac: Bool) -> Bool {
        var id = id
        return id.withUTF8 { bytes in
            slopdesk_binding_row_shown(bytes.baseAddress, bytes.count, mac)
        }
    }

    /// Every id the table declares, in registry order. The parity test's half of the pin.
    public static var declaredIDs: [String] {
        (0..<slopdesk_binding_row_count()).compactMap { index in
            wsDelivered(capacity: idCapacity) { out, cap in
                slopdesk_binding_row_id(index, out, cap)
            }
        }
    }

    /// Comfortably past the longest registry id; the door reports a larger need and `wsDelivered` retries.
    private static let idCapacity = 64
}
