// MacConnectSheet — the Connect-to-Host form, as a real AppKit sheet.
//
// The LAST of the Mac's floating surfaces to leave the shared SwiftUI floor (docs/56 stage D), and the
// only one that was never a card. Every other overlay is a picker you summon, skim and dismiss in a
// second, so each became an `NSPanel` (``MacOverlayPanel``). This one is a FORM you fill in and commit,
// and a form is what the platform's own modal is for: the sheet owns the window, so no stray click into
// the workspace drops it mid-edit, and Esc / Return reach Cancel and Connect through the buttons' own
// key equivalents rather than through a hand-rolled dismiss floor.
//
// So it is `beginSheet`, the presentation AppKit sheets use, and it wears the SYSTEM's
// sheet chrome rather than the floating family's corner. The phone's `.sheet` had to be talked into that
// corner (`slateSheetSurface`) because SwiftUI's sheet is a window with its own mask; an AppKit sheet is
// already the platform's, which is exactly what this surface asked to be.
//
// A THIN VIEW over ``AppConnection``, which already owns the editable host/port strings, the parse, the
// validation hint and the `connect()` lifecycle. Nothing here re-derives any of it: the fields write
// through on every keystroke so `canConnect` gates the Connect button live, and everything drawn is read
// back inside `withObservationTracking`, so a failed connect re-renders its own reason.
//
// THE SHEET DOES NOT TEAR ITSELF DOWN. Cancel, Esc and a successful connect all flip
// `coordinator.connectVisible`, and the scene edge that follows closes it — the same discipline every
// panel keeps, and the reason the flag and the window can never disagree.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore

/// Presents the Connect-to-Host form over the workspace window.
@MainActor
final class MacConnectSheet {
    private var sheet: NSWindow?

    /// Show the form over `host`, or do nothing if it is already up.
    func present(over host: NSWindow, connection: AppConnection, coordinator: OverlayCoordinator) {
        guard sheet == nil else { return }
        let content = MacConnectFormController(connection: connection, coordinator: coordinator)
        let created = NSWindow(contentViewController: content)
        created.styleMask = [.titled, .fullSizeContentView]
        sheet = created
        host.beginSheet(created) { _ in }
    }

    /// Orders the sheet out. Idempotent — a second call on an already-dismissed sheet is a no-op.
    func dismiss() {
        guard let sheet else { return }
        self.sheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }
}

// MARK: - The form

/// The sheet's content: a title, the host/port pair, the folded video ports, a validation line, and the
/// Cancel/Connect footer.
@MainActor
final class MacConnectFormController: NSViewController, NSTextFieldDelegate {
    private let connection: AppConnection
    private let coordinator: OverlayCoordinator

    private let host = NSTextField()
    private let port = NSTextField()
    private let mediaPort = NSTextField()
    private let cursorPort = NSTextField()

    /// The two video-port fields, folded away by default — most people keep the defaults, and a card
    /// that opens showing four fields asks four questions when it only has two.
    private let advancedRow = NSStackView()
    private let disclosure = NSButton()
    /// The validation / failure line. Emptied rather than hidden would move the footer under the
    /// pointer mid-edit, so it is HIDDEN and the sheet re-fits.
    private let warning = NSStackView()
    private let warningText = NSTextField(wrappingLabelWithString: "")
    private let connect = NSButton()

    /// The in-flight connect Task. Stored so Cancel and teardown CANCEL it — a fire-and-forget one
    /// outlives the sheet and, when a slow connect finally resolves, dismisses a freshly REOPENED sheet
    /// mid-edit. Belt and suspenders with the ``OverlayCoordinator/connectGeneration`` guard below.
    private var connectTask: Task<Void, Never>?

    init(connection: AppConnection, coordinator: OverlayCoordinator) {
        self.connection = connection
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    deinit {
        connectTask?.cancel()
    }

    override func loadView() {
        let title = NSTextField(labelWithString: ConnectForm.title)
        title.font = .systemFont(ofSize: Slate.Typeface.title, weight: .semibold)
        title.textColor = Slate.Native.Overlay.primary

        // Host and port share ONE row — a port is five digits, and a five-digit field the full width of
        // the card asks a question the same size as "which machine?". Every WORD below is
        // ``ConnectForm``'s, including the prompts: the phone draws this same form, and the card's copy
        // is the form's meaning rather than this shell's drawing.
        let hostField = field(host, prompt: ConnectForm.hostPrompt, mono: false)
        let portField = field(port, prompt: ConnectForm.portPrompt, mono: true)
        portField.widthAnchor.constraint(equalToConstant: Slate.Metric.portFieldWidth).isActive = true
        let headline = pair(
            labelled(ConnectForm.hostLabel, hostField), labelled(ConnectForm.portLabel, portField),
        )

        disclosure.title = ConnectForm.videoPortsLabel
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        disclosure.imagePosition = .imageLeading
        disclosure.isBordered = false
        disclosure.contentTintColor = Slate.Native.Overlay.secondary
        disclosure.target = self
        disclosure.action = #selector(toggleAdvanced)

        // The two video ports are peers, so they share a row the way host/port do.
        let media = labelled(
            ConnectForm.mediaPortLabel,
            field(mediaPort, prompt: ConnectForm.mediaPortPrompt, mono: true),
        )
        let cursor = labelled(
            ConnectForm.cursorPortLabel,
            field(cursorPort, prompt: ConnectForm.cursorPortPrompt, mono: true),
        )
        advancedRow.orientation = .horizontal
        advancedRow.alignment = .top
        advancedRow.spacing = Slate.Metric.space3
        advancedRow.distribution = .fillEqually
        advancedRow.addArrangedSubview(media)
        advancedRow.addArrangedSubview(cursor)
        advancedRow.isHidden = true

        // Amber, because this one IS a status: the neutrality rule is about the chrome not competing
        // for attention, never about suppressing an actual signal.
        let mark = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                ?? NSImage(),
        )
        mark.contentTintColor = Slate.Native.StatusInk.notice
        warningText.font = .preferredFont(forTextStyle: .callout)
        warningText.textColor = Slate.Native.StatusInk.notice
        warningText.isSelectable = false
        warning.orientation = .horizontal
        warning.alignment = .firstBaseline
        warning.spacing = Slate.Metric.space1
        warning.addArrangedSubview(mark)
        warning.addArrangedSubview(warningText)
        warning.isHidden = true

        let body = NSStackView(views: [headline, disclosure, advancedRow, warning])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = Slate.Metric.space3
        for row in [headline, advancedRow, warning] {
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let column = NSStackView(views: [title, body, footer()])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Slate.Metric.space4
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space4, right: Slate.Metric.space4,
        )
        column.widthAnchor.constraint(equalToConstant: Slate.Metric.cardFormWidth).isActive = true
        body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -Slate.Metric.space4 * 2)
            .isActive = true
        view = column
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Seed the fields from the COMMITTED target (re-editing the live host), then take the keyboard —
        // a field cannot become first responder in a window that is not yet on screen.
        connection.fillForm(from: connection.target)
        host.stringValue = connection.host
        port.stringValue = connection.port
        mediaPort.stringValue = connection.mediaPort
        cursorPort.stringValue = connection.cursorPort
        view.window?.makeFirstResponder(host)
        render()
    }

    // MARK: The live parts

    /// Draws what the connection currently says, and re-arms itself on everything it read.
    private func render() {
        withObservationTracking {
            draw()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.render() }
            }
        }
    }

    private func draw() {
        connect.isEnabled = connection.canConnect
        // The hint wins over the failure: an unparseable form is a question about what is typed, and a
        // stale failure from the last attempt is not the answer to it. A failed connect leaves the
        // sheet UP (see `runConnect`), so the reason is carried here — run through the presenter so it
        // reads as the actionable copy every other connection surface shows, never the raw dump.
        if let hint = connection.validationHint {
            warningText.stringValue = hint
        } else if case let .failed(reason) = connection.status {
            warningText.stringValue = ConnectionPresenter.friendlyFailure(reason)
        } else {
            warningText.stringValue = ""
        }
        warning.isHidden = warningText.stringValue.isEmpty
    }

    // MARK: Actions

    @objc
    private func toggleAdvanced() {
        advancedRow.isHidden.toggle()
        disclosure.image = NSImage(
            systemSymbolName: advancedRow.isHidden ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil,
        )
    }

    /// Validate-then-connect: no-op unless the form parses (the button is disabled then too), then fire
    /// the app's `connect()`. Only a SUCCESSFUL connect closes the sheet. The close is DOUBLE-guarded —
    /// the Task is stored and cancelled on Cancel/teardown, AND the completion only closes if the
    /// coordinator's generation still matches the presentation this Task started under.
    @objc
    private func runConnect() {
        guard connection.canConnect else { return }
        connectTask?.cancel()
        let generation = coordinator.connectGeneration
        connectTask = Task { [connection, coordinator] in
            await connection.connect()
            guard !Task.isCancelled else { return }
            guard ConnectPresentation.shouldCloseAfterConnect(status: connection.status) else { return }
            coordinator.closeConnect(ifCurrent: generation)
        }
    }

    /// Cancel: kill the in-flight connect Task (its completion must never fire) and flip the flag. The
    /// scene edge that follows orders the sheet out.
    @objc
    private func runCancel() {
        connectTask?.cancel()
        connectTask = nil
        coordinator.closeConnect()
    }

    // MARK: Typing

    /// Every keystroke writes through, so ``AppConnection/canConnect`` and the validation hint answer
    /// about what is on screen rather than about what was last committed.
    func controlTextDidChange(_ note: Notification) {
        switch note.object as? NSTextField {
        case host: connection.host = host.stringValue
        case port: connection.port = port.stringValue
        case mediaPort: connection.mediaPort = mediaPort.stringValue
        case cursorPort: connection.cursorPort = cursorPort.stringValue
        default: break
        }
    }

    // MARK: Chrome

    /// Cancel and the confirming action, trailing-aligned. Esc and ↩ take their standard meanings
    /// through the buttons' own key equivalents, which is the whole reason this surface is a sheet.
    private func footer() -> NSView {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(runCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        connect.title = ConnectForm.connectAction
        connect.bezelStyle = .rounded
        connect.keyEquivalent = "\r"
        connect.target = self
        connect.action = #selector(runConnect)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, cancel, connect])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space2
        return row
    }

    /// A real macOS field at the system's own size — the card is ours, what sits in it is the system's.
    private func field(_ control: NSTextField, prompt: String, mono: Bool) -> NSTextField {
        control.isEditable = true
        control.isBordered = true
        control.bezelStyle = .roundedBezel
        control.placeholderString = prompt
        control.controlSize = .large
        control.font = mono
            ? .monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
            : .systemFont(ofSize: Slate.Typeface.body)
        control.delegate = self
        return control
    }

    /// One labelled input: a sentence-case name in the system face over the field.
    private func labelled(_ name: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        label.textColor = Slate.Native.Overlay.secondary

        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Slate.Metric.space1
        control.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func pair(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Slate.Metric.space3
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return row
    }
}
