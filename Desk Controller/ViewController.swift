//
//  ViewController.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Cocoa
@preconcurrency import CoreBluetooth

class ViewController: NSViewController {

    var controller: DeskController? = nil

    let bluetoothManager = BluetoothManager.shared

    @IBOutlet weak var messageLabel: NSTextField?
    @IBOutlet weak var containerStackView: NSStackView?

    @IBOutlet weak var currentPositionLabel: NSTextField?
    @IBOutlet weak var currentPositionDimenstionLabel: NSTextField?

    @IBOutlet weak var upButton: NSButton?
    @IBOutlet weak var downButton: NSButton?

    @IBOutlet weak var sitButton: NSButton?
    @IBOutlet weak var standButton: NSButton?

    // Status indicator
    @IBOutlet weak var statusIndicator: NSView?
    @IBOutlet weak var statusLabel: NSTextField?
    @IBOutlet weak var deviceNameLabel: NSTextField?

    weak var popover: NSPopover?


    let stopLabelString = "Stop moving"

    private var countdownLabel: NSTextField?
    private var countdownTimer: Timer?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        bluetoothManager.onStateChange = { [weak self] state in
            self?.deskConnectionStateChanged(state)
        }
    }

    /// Build a controller once a desk is prepared and usable, and drop it the
    /// moment the desk goes away — otherwise auto-stand and AppleScript keep
    /// writing into a peripheral that no longer exists while the UI says
    /// "Not connected".
    private func deskConnectionStateChanged(_ state: BluetoothManager.State) {
        if state == .ready, let desk = bluetoothManager.desk {
            setControllerFor(desk: desk)
        } else if controller != nil {
            controller?.teardown()
            controller = nil
        }
        updateConnectionLabels()
        refreshCountdown()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        resetActionButtonTitles()
        view.window?.makeFirstResponder(nil)
        installCountdownLabelIfNeeded()
        refreshCountdown()
        startCountdownTimer()
        // Flip the label immediately on phase transitions instead of waiting
        // for the next 1 s tick.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoStandPhaseDidChange),
            name: .autoStandPhaseChanged,
            object: nil
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        countdownTimer?.invalidate()
        countdownTimer = nil
        NotificationCenter.default.removeObserver(self, name: .autoStandPhaseChanged, object: nil)
    }

    @objc private func autoStandPhaseDidChange() {
        refreshCountdown()
    }

    // MARK: - AutoStand countdown

    private func installCountdownLabelIfNeeded() {
        guard countdownLabel == nil, let status = statusIndicator else { return }
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6)
        ])
        countdownLabel = label
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCountdown()
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    private func refreshCountdown() {
        guard let label = countdownLabel else { return }
        guard Preferences.shared.automaticStandEnabled else {
            label.stringValue = ""
            label.isHidden = true
            return
        }
        let autoStand = AutoStand.shared
        let phase = autoStand.currentPhase
        guard phase != .disabled else {
            label.stringValue = ""
            label.isHidden = true
            return
        }
        label.isHidden = false

        let now = Date()
        let up = autoStand.nextUpDate
        let down = autoStand.nextDownDate

        // Pick whichever fires next.
        let next: (Date, String)?
        switch (up, down) {
        case let (u?, d?):
            next = u < d ? (u, "stand") : (d, "sit")
        case let (u?, nil):
            next = (u, "stand")
        case let (nil, d?):
            next = (d, "sit")
        default:
            next = nil
        }

        guard let (fire, target) = next else {
            label.stringValue = ""
            return
        }
        let remaining = max(0, fire.timeIntervalSince(now))
        // "🪑 Sitting · 4m 23s to stand"  /  "🧍 Standing · 1m 17s to sit"
        let stateText: String
        switch phase {
        case .sitting:  stateText = "🪑 Sitting"
        case .standing: stateText = "🧍 Standing"
        case .disabled: stateText = ""
        }
        label.stringValue = "\(stateText) · \(formatRemaining(remaining)) to \(target)"
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let totalSecs = Int(seconds)
        let m = totalSecs / 60
        let s = totalSecs % 60
        if m < 5 {
            return String(format: "%dm %02ds", m, s)
        }
        return "\(m) min"
    }

    // MARK: - Inline config section (DELETED on revert)
    /*
    private func installConfigSectionIfNeeded_DELETED() {
        guard configSection == nil, let sit = sitButton, let status = statusIndicator else { return }

        // Use an NSGridView so labels and controls line up in two columns.
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.required, for: .vertical)

        // Heights — label, [Stand field, Sit field row]
        let standField = compactField(action: #selector(changedStandingHeight(_:)))
        standingHeightField = standField
        let sitField = compactField(action: #selector(changedSittingHeight(_:)))
        sittingHeightField = sitField
        let heightFields = NSStackView(views: [
            inlineLabel("Stand"),
            standField,
            inlineLabel("Sit"),
            sitField
        ])
        heightFields.orientation = .horizontal
        heightFields.spacing = 4
        grid.addRow(with: [makeRightAlignedLabel("Heights"), heightFields])

        // Units
        let units = NSPopUpButton(frame: .zero, pullsDown: false)
        units.controlSize = .small
        units.font = .systemFont(ofSize: 11)
        units.addItems(withTitles: ["cm", "in"])
        units.target = self
        units.action = #selector(changedUnits(_:))
        unitsPopup = units
        grid.addRow(with: [makeRightAlignedLabel("Units"), wrap(units)])

        // Section separator
        grid.addRow(with: [NSGridCell.emptyContentView, makeFullWidthSeparator()])

        // Automatically stand row — checkbox + stepper + value
        let autoCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggledAutoStand(_:)))
        autoStandCheckbox = autoCheckbox
        let autoLabel = NSTextField(labelWithString: "Automatically stand")
        autoLabel.font = .systemFont(ofSize: 11)
        let autoStepper = compactStepper(min: 1, max: 55, action: #selector(changedAutoStandStepper(_:)))
        autoStandStepper = autoStepper
        let autoValue = compactValueLabel()
        autoStandValueLabel = autoValue
        let autoRow = NSStackView(views: [autoCheckbox, autoLabel, autoValue, autoStepper, inlineLabel("min/hr")])
        autoRow.orientation = .horizontal
        autoRow.spacing = 4
        grid.addRow(with: [makeRightAlignedLabel(""), autoRow])

        // Idle threshold
        let idleStepper = compactStepper(min: 1, max: 60, action: #selector(changedInactivityStepper(_:)))
        inactivityStepper = idleStepper
        let idleValue = compactValueLabel()
        inactivityValueLabel = idleValue
        let idleRow = NSStackView(views: [idleValue, idleStepper, inlineLabel("min")])
        idleRow.orientation = .horizontal
        idleRow.spacing = 4
        grid.addRow(with: [makeRightAlignedLabel("Skip if idle >"), idleRow])

        // Schedule preview
        let previewWrap = schedulePreviewContainer()
        grid.addRow(with: [makeRightAlignedLabel(""), previewWrap])

        // Explainer caption (the same copy David's original XIB used).
        let caption = NSTextField(wrappingLabelWithString:
            "Automatically raise the desk the specified number of minutes per hour if the computer is active.")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .tertiaryLabelColor
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 0
        caption.preferredMaxLayoutWidth = 220
        grid.addRow(with: [makeRightAlignedLabel(""), caption])

        // Separator
        grid.addRow(with: [NSGridCell.emptyContentView, makeFullWidthSeparator()])

        // Open at login
        let loginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(toggledOpenAtLogin(_:)))
        loginCheckbox.font = .systemFont(ofSize: 11)
        openAtLoginCheckbox = loginCheckbox
        grid.addRow(with: [makeRightAlignedLabel(""), loginCheckbox])

        // Notify instead
        let notifyCheckbox = NSButton(checkboxWithTitle: "Notify instead of moving the desk",
                                       target: self, action: #selector(toggledNotifyInstead(_:)))
        notifyCheckbox.font = .systemFont(ofSize: 11)
        notifyCheckbox.lineBreakMode = .byWordWrapping
        notifyCheckbox.cell?.wraps = true
        notifyInsteadCheckbox = notifyCheckbox
        grid.addRow(with: [makeRightAlignedLabel(""), notifyCheckbox])

        // Column alignment: right-align col 0, fill col 1
        let labelColumn = grid.column(at: 0)
        labelColumn.xPlacement = .trailing
        let controlColumn = grid.column(at: 1)
        controlColumn.xPlacement = .leading

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: sit.bottomAnchor, constant: 18),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: status.topAnchor, constant: -14)
        ])

        configSection = grid
    }

    // MARK: - Inline-config widget helpers

    private func makeRightAlignedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func inlineLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func compactField(action: Selector) -> NSTextField {
        let field = NSTextField()
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.target = self
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return field
    }

    private func compactStepper(min: Double, max: Double, action: Selector) -> NSStepper {
        let s = NSStepper()
        s.minValue = min
        s.maxValue = max
        s.increment = 1
        s.controlSize = .small
        s.target = self
        s.action = action
        return s
    }

    private func compactValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "1")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return label
    }

    private func wrap(_ view: NSView) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.orientation = .horizontal
        return wrapper
    }

    private func makeFullWidthSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return box
    }

    /// Wrap the schedule preview bar in a centered container so it lives inside
    /// the config stack (instead of floating as a sibling view).
    private func schedulePreviewContainer() -> NSView {
        let container = NSView()
        let preview = SchedulePreviewView(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.toolTip = "Auto-stand schedule per hour. Green = standing window."
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 200),
            preview.heightAnchor.constraint(equalToConstant: 8)
        ])
        schedulePreview = preview
        return container
    }

    private func makeHeightsRow() -> NSView {
        let standLabel = NSTextField(labelWithString: "Stand")
        standLabel.font = .systemFont(ofSize: 11)
        standLabel.textColor = .secondaryLabelColor

        let standField = NSTextField()
        standField.controlSize = .small
        standField.font = .systemFont(ofSize: 11)
        standField.target = self
        standField.action = #selector(changedStandingHeight(_:))
        standingHeightField = standField

        let sitLabel = NSTextField(labelWithString: "Sit")
        sitLabel.font = .systemFont(ofSize: 11)
        sitLabel.textColor = .secondaryLabelColor

        let sitField = NSTextField()
        sitField.controlSize = .small
        sitField.font = .systemFont(ofSize: 11)
        sitField.target = self
        sitField.action = #selector(changedSittingHeight(_:))
        sittingHeightField = sitField

        for f in [standField, sitField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 50).isActive = true
        }

        let row = NSStackView(views: [standLabel, standField, sitLabel, sitField])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func makeUnitsRow() -> NSView {
        let label = NSTextField(labelWithString: "Units")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItems(withTitles: ["cm", "in"])
        popup.target = self
        popup.action = #selector(changedUnits(_:))
        unitsPopup = popup

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func makeAutoStandRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "Automatically stand", target: self,
                                action: #selector(toggledAutoStand(_:)))
        checkbox.font = .systemFont(ofSize: 11)
        autoStandCheckbox = checkbox

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 55
        stepper.increment = 1
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(changedAutoStandStepper(_:))
        autoStandStepper = stepper

        let valueLabel = NSTextField(labelWithString: "1")
        valueLabel.font = .systemFont(ofSize: 11)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true
        autoStandValueLabel = valueLabel

        let unit = NSTextField(labelWithString: "min/hr")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor

        let row = NSStackView(views: [checkbox, valueLabel, stepper, unit])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func makeActivityTimeoutRow() -> NSView {
        let label = NSTextField(labelWithString: "Skip if idle >")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 60
        stepper.increment = 1
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(changedInactivityStepper(_:))
        inactivityStepper = stepper

        let valueLabel = NSTextField(labelWithString: "1")
        valueLabel.font = .systemFont(ofSize: 11)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true
        inactivityValueLabel = valueLabel

        let unit = NSTextField(labelWithString: "min")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor

        let row = NSStackView(views: [label, valueLabel, stepper, unit])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func makeOpenAtLoginRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "Open at login", target: self,
                                action: #selector(toggledOpenAtLogin(_:)))
        checkbox.font = .systemFont(ofSize: 11)
        openAtLoginCheckbox = checkbox
        return checkbox
    }

    private func makeNotifyInsteadRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "Notify instead of moving the desk", target: self,
                                action: #selector(toggledNotifyInstead(_:)))
        checkbox.font = .systemFont(ofSize: 11)
        checkbox.lineBreakMode = .byWordWrapping
        checkbox.cell?.wraps = true
        notifyInsteadCheckbox = checkbox
        return checkbox
    }

    private func refreshConfigSection() {
        var standing = Preferences.shared.standingPosition
        var sitting = Preferences.shared.sittingPosition
        if !Preferences.shared.isMetric {
            standing = standing.convertToInches()
            sitting = sitting.convertToInches()
        }
        standingHeightField?.stringValue = String(format: "%.1f", standing)
        sittingHeightField?.stringValue = String(format: "%.1f", sitting)

        unitsPopup?.selectItem(at: Preferences.shared.isMetric ? 0 : 1)

        let enabled = Preferences.shared.automaticStandEnabled
        autoStandCheckbox?.state = enabled ? .on : .off
        let stand = Int(Preferences.shared.automaticStandPerHour / 60)
        let idle = Int(Preferences.shared.automaticStandInactivity / 60)
        autoStandStepper?.intValue = Int32(stand)
        autoStandValueLabel?.stringValue = String(stand)
        inactivityStepper?.intValue = Int32(idle)
        inactivityValueLabel?.stringValue = String(idle)
        autoStandStepper?.isEnabled = enabled
        inactivityStepper?.isEnabled = enabled
        autoStandValueLabel?.textColor = enabled ? .labelColor : .disabledControlTextColor
        inactivityValueLabel?.textColor = enabled ? .labelColor : .disabledControlTextColor

        openAtLoginCheckbox?.state = Preferences.shared.openAtLogin ? .on : .off
        notifyInsteadCheckbox?.state = Preferences.shared.notifyInsteadOfAutoMove ? .on : .off
    }

    // MARK: - Inline config actions

    @objc private func changedStandingHeight(_ sender: NSTextField) {
        if var v = Float(sender.stringValue) {
            if !Preferences.shared.isMetric { v = v.convertToCentimeters() }
            Preferences.shared.standingPosition = v
        }
        refreshConfigSection()
    }

    @objc private func changedSittingHeight(_ sender: NSTextField) {
        if var v = Float(sender.stringValue) {
            if !Preferences.shared.isMetric { v = v.convertToCentimeters() }
            Preferences.shared.sittingPosition = v
        }
        refreshConfigSection()
    }

    @objc private func changedUnits(_ sender: NSPopUpButton) {
        Preferences.shared.isMetric = sender.titleOfSelectedItem == "cm"
        refreshConfigSection()
    }

    @objc private func toggledAutoStand(_ sender: NSButton) {
        Preferences.shared.automaticStandEnabled = sender.state == .on
        refreshConfigSection()
        refreshSchedulePreview()
        (NSApp.delegate as? AppDelegate)?.refreshAutoStandIcon()
    }

    @objc private func changedAutoStandStepper(_ sender: NSStepper) {
        Preferences.shared.automaticStandPerHour = Double(sender.intValue) * 60
        refreshConfigSection()
        refreshSchedulePreview()
    }

    @objc private func changedInactivityStepper(_ sender: NSStepper) {
        Preferences.shared.automaticStandInactivity = Double(sender.intValue) * 60
        refreshConfigSection()
    }

    @objc private func toggledOpenAtLogin(_ sender: NSButton) {
        Preferences.shared.openAtLogin = sender.state == .on
    }

    @objc private func toggledNotifyInstead(_ sender: NSButton) {
        Preferences.shared.notifyInsteadOfAutoMove = sender.state == .on
        if sender.state == .on {
            NotificationManager.shared.requestAuthorizationIfNeeded()
        }
    }
    */

    // (Schedule preview bar now lives in PreferencesWindowController.)

    override func viewDidAppear() {
        super.viewDidAppear()
        // NSPopover re-establishes its initial first responder *after*
        // viewWillAppear returns, so a second pass once the view is on
        // screen is needed to make sure nothing claims focus.
        view.window?.makeFirstResponder(nil)
    }

    private func resetActionButtonTitles() {
        let moving = controller?.movingToPosition != nil
        if !moving {
            sitButton?.title = "Move to sit"
            standButton?.title = "Move to stand"
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = NSSize(width: 260, height: 170)

        // The arrow buttons (TouchButtons) keep grabbing first-responder when
        // the popover appears, painting a focus ring around the up arrow.
        upButton?.refusesFirstResponder = true
        downButton?.refusesFirstResponder = true

        // Vibrant background to mimic the popover look on older macOS.
        // NSGlassEffectView (Tahoe-only) was the original choice; this works on macOS 13+.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        containerStackView?.isHidden = true
        messageLabel?.stringValue = ""

        if let indicator = statusIndicator {
            indicator.wantsLayer = true
            indicator.layer?.cornerRadius = indicator.frame.height / 2
        }

        statusLabel?.stringValue = "Connecting..."
        deviceNameLabel?.stringValue = ""

        currentPositionDimenstionLabel?.stringValue = Preferences.shared.isMetric ? "cm" : "in"

        if let position = controller?.desk.position {
            onDeskPositionChange(position)
        }

        updateConnectionLabels()
    }

    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }

    /// How a connection state reads to the user: headline, device line, dot
    /// colour, and the longer explanation shown in place of the controls.
    private struct StatusPresentation {
        let status: String
        let detail: String
        let colour: NSColor
        let message: String
    }

    private static let searchingHelp = "Searching for your desk…\n\nIf the desk hasn't connected to this Mac before, put it into pairing mode by holding the Bluetooth button on its controller until the light blinks.\n\nOtherwise, make sure no phone or other computer is currently connected to it."

    private func presentation(for state: BluetoothManager.State) -> StatusPresentation {
        let name = bluetoothManager.deskName ?? ""

        switch state {
        case .ready:
            return StatusPresentation(status: "Connected", detail: name, colour: .systemGreen, message: "")
        case .preparing:
            // Connected but not yet usable. Reporting this honestly matters:
            // showing "Connected" here is what made the buttons look broken.
            return StatusPresentation(status: "Getting ready…", detail: name,
                                      colour: .systemOrange, message: "Reading the desk's height…")
        case .connecting:
            return StatusPresentation(status: "Connecting…", detail: name,
                                      colour: .systemOrange, message: ViewController.searchingHelp)
        case .searching:
            return StatusPresentation(status: "Searching for your desk", detail: "",
                                      colour: .systemOrange, message: ViewController.searchingHelp)
        case .unavailable(let managerState):
            switch managerState {
            case .poweredOff:
                return StatusPresentation(status: "Bluetooth is off", detail: "", colour: .systemRed,
                                          message: "Turn Bluetooth on and Desk Controller will reconnect to your desk on its own.")
            case .unauthorized:
                return StatusPresentation(status: "Bluetooth access denied", detail: "", colour: .systemRed,
                                          message: "Desk Controller can't reach your desk without Bluetooth. Grant access in System Settings › Privacy & Security › Bluetooth, then reopen the app.")
            case .unsupported:
                return StatusPresentation(status: "Bluetooth not supported", detail: "", colour: .systemRed,
                                          message: "This Mac can't use Bluetooth Low Energy, which the desk requires.")
            case .resetting:
                return StatusPresentation(status: "Bluetooth is restarting", detail: "", colour: .systemOrange,
                                          message: "Reconnecting as soon as Bluetooth is back.")
            default:
                return StatusPresentation(status: "Starting up…", detail: "", colour: .systemOrange, message: "")
            }
        }
    }

    func updateConnectionLabels() {
        // "Connected" is not the same as "usable" — the desk only becomes
        // controllable once its characteristics are discovered, so the controls
        // key off `.ready` rather than the raw link state.
        let isReady = bluetoothManager.state == .ready
        var shown = presentation(for: bluetoothManager.state)

        // Authorization can already be denied while the central still reports
        // `.unknown`, so let it override whatever the state says.
        if bluetoothManager.centralManager?.authorization == .denied {
            shown = presentation(for: .unavailable(.unauthorized))
        }

        containerStackView?.isHidden = !isReady
        messageLabel?.isHidden = isReady

        statusLabel?.stringValue = shown.status
        deviceNameLabel?.stringValue = shown.detail
        messageLabel?.stringValue = shown.message
        statusIndicator?.layer?.backgroundColor = shown.colour.cgColor
    }

    func setControllerFor(desk: DeskPeripheral) {
        // Tear down the previous controller first so its move timer doesn't
        // leak or keep firing against the new controller.
        controller?.teardown()

        controller = DeskController(desk: desk)
        controller?.onPositionChange({ [weak self] deskPosition in
            self?.onDeskPositionChange(deskPosition)
        })

        // Preferences shows the live height and calibrates against it; if its
        // window is already open, repoint it at the controller we just built.
        if PreferencesWindowController.sharedInstance.isWindowLoaded {
            PreferencesWindowController.sharedInstance.deskController = controller
        }

        controller?.onDoubleTapDetected = { [weak self] direction in
            guard Preferences.shared.doubleTapToSitStand else {
                return
            }

            DispatchQueue.main.async {
                if direction == .up {
                    self?.stand()
                }

                if direction == .down {
                    self?.sit()
                }
            }
        }

        controller?.onCurrentMovingDirectionChange = { [weak self] movingDirection in
            if movingDirection == .none {
                self?.sitButton?.title = "Move to sit"
                self?.standButton?.title = "Move to stand"
            }
        }

    }

    func onDeskPositionChange(_ newPosition: Float) {
        var convertedPosition = newPosition + Preferences.shared.positionOffset

        if !Preferences.shared.isMetric {
            convertedPosition = convertedPosition.convertToInches()
        }

        currentPositionLabel?.stringValue = "\(Int(convertedPosition.rounded()))"

        sitButton?.isEnabled = abs((Preferences.shared.sittingPosition - Preferences.shared.positionOffset) - newPosition) > 0.5
        standButton?.isEnabled = abs((Preferences.shared.standingPosition - Preferences.shared.positionOffset) - newPosition) > 0.5
    }

    /// Called when the popover opens. Opening it is the user saying "connect
    /// already", so give the connection a real kick rather than the no-op the
    /// old `startScanning()` call amounted to once the central existed.
    func reconnect() {
        bluetoothManager.retryNow()

        if let position = controller?.desk.position {
            onDeskPositionChange(position)
        }
    }

    @IBAction func moveUpClicked(_ sender: TouchButton) {
        let pos = controller?.desk.position
        dbg("moveUpClicked isPressed=\(sender.isPressed) controller=\(controller == nil ? "nil" : "ok") pos=\(pos.map { String(format: "%.1f", $0) } ?? "nil")")
        guard let controller = controller else { return }

        // Always nudge while held — the sit/stand named buttons handle preset
        // targeting. Auto-routing the arrows to a preset target caused single-
        // packet "micro moves" when the desk was already within the overshoot
        // guard's 0.5 cm window of that preset.
        if sender.isPressed {
            controller.startHoldingUp()
        } else {
            controller.stopMoving()
        }
    }

    @IBAction func moveDownClicked(_ sender: TouchButton) {
        let pos = controller?.desk.position
        dbg("moveDownClicked isPressed=\(sender.isPressed) controller=\(controller == nil ? "nil" : "ok") pos=\(pos.map { String(format: "%.1f", $0) } ?? "nil")")
        guard let controller = controller else { return }

        if sender.isPressed {
            controller.startHoldingDown()
        } else {
            controller.stopMoving()
        }
    }

    @IBAction func sit(_ sender: Any) {
        dbg("sit() clicked controller=\(controller == nil ? "nil" : "ok")")
        guard let button = sitButton, let controller else {
            return
        }

        if button.title == stopLabelString {
            controller.stopMoving()
        } else {
            button.title = stopLabelString
            controller.moveToPosition(.sit)
        }
    }

    private func sit() {
        controller?.stopMoving()
        controller?.moveToPosition(.sit)
    }

    @IBAction func stand(_ sender: Any) {
        dbg("stand() clicked controller=\(controller == nil ? "nil" : "ok")")
        guard let button = standButton, let controller else {
            return
        }

        if button.title == stopLabelString {
            controller.stopMoving()
        } else {
            button.title = stopLabelString
            controller.moveToPosition(.stand)
        }
    }

    private func stand() {
        controller?.stopMoving()
        controller?.moveToPosition(.stand)
    }

    @IBAction func showPreferences(_ sender: Any) {
        PreferencesWindowController.sharedInstance.showWindow(nil)
        PreferencesWindowController.sharedInstance.deskController = controller
        popover?.performClose(self)
    }
}

// Convenience for the inline config section dividers.
fileprivate extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
}
