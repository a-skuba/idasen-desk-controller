//
//  AppDelegate.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Cocoa
@preconcurrency import UserNotifications

@main @MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusBarItem: NSStatusItem!
    var popover: NSPopover!
    var eventMonitor: EventMonitor?
    var aboutWindow: AboutWindowController?

    /// Right-click menu for the status item. Kept here and popped up manually on
    /// right-click rather than assigned to `button.menu`: assigning the button's
    /// menu makes AppKit show it on *any* click and swallows the left-click
    /// popover toggle.
    private var statusBarMenu: NSMenu!

    var viewController: ViewController?

    /// Cached current phase for icon refresh de-duping. Nil forces first draw.
    private var lastIconPhase: AutoStand.Phase?

    /// Unit tests are injected into this app, so its launch work would otherwise
    /// run during `xcodebuild test` too — claiming the desk over Bluetooth,
    /// adding a status-bar item, and registering the test build's throwaway path
    /// as a login item. XCTest sets this variable before the app starts, unlike
    /// `NSClassFromString("XCTestCase")` which isn't loaded yet at this point.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard !isRunningTests else { return }

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        // If it's the first launch set the value for Open at Login to true
        if Preferences.shared.isFirstLaunch {
            Preferences.shared.openAtLogin = true
            Preferences.shared.isFirstLaunch = false
        }

        // Don't show the icon in the Dock
        NSApp.setActivationPolicy(.accessory)

        // Notifications (used by AutoStand when "notify instead of auto-move" is on).
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.requestAuthorizationIfNeeded()

        // Setup the right click menu
        statusBarMenu = NSMenu(title: "Desk Controller Menu")
        statusBarMenu.addItem(withTitle: "Move to sit", action: #selector(moveToSit), keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "Move to stand", action: #selector(moveToStand), keyEquivalent: "")
        statusBarMenu.addItem(.separator())
        // Connection recovery, reachable without opening the popover — the app
        // used to offer no way at all to ask it to try again.
        statusBarMenu.addItem(withTitle: "Reconnect", action: #selector(reconnectDesk), keyEquivalent: "")
        let forgetItem = statusBarMenu.addItem(withTitle: "Forget This Desk",
                                               action: #selector(forgetDesk), keyEquivalent: "")
        forgetItem.toolTip = "Stop reconnecting to the remembered desk and search for one again."
        statusBarMenu.addItem(.separator())
        statusBarMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "About Desk Controller", action: #selector(showAbout), keyEquivalent: "")
        statusBarMenu.addItem(.separator())
        statusBarMenu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "")
        // Explicit targets so `validateMenuItem` below is consulted, instead of
        // relying on this detached menu finding us through the responder chain.
        statusBarMenu.items.forEach { $0.target = self }

        // Set the status bar icon and action
        if let button = statusBarItem.button {
            // Seed: if auto-stand is enabled but the DeskController (and its
            // AutoStand) hasn't booted yet, show .sitting — the cycle always
            // opens with a sit. AutoStand's first notification will correct
            // this if needed.
            let initialPhase: AutoStand.Phase = Preferences.shared.automaticStandEnabled
                ? (AutoStand.shared.currentPhase)
                : .disabled
            applyStatusBarIcon(phase: initialPhase)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(AppDelegate.clickedStatusItem(_:))
        }

        // Observe phase transitions broadcast by AutoStand.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoStandPhaseDidChange(_:)),
            name: .autoStandPhaseChanged,
            object: nil
        )
        // After sleep, NSTimer fires may have been suppressed. Pull the
        // current phase out of AutoStand explicitly so the icon doesn't
        // drift stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if let mainViewController = NSStoryboard(name: "Main", bundle: nil).instantiateController(withIdentifier: "ViewControllerId") as? ViewController {
            mainViewController.popover = popover
            viewController = mainViewController
            popover.contentViewController = mainViewController
        }

        // Bring Bluetooth up only once the view controller has registered its
        // state handler, so the very first state change can't be missed.
        BluetoothManager.shared.start()

        // The schedule is independent of the desk connection, so start it here
        // rather than waiting for a desk to turn up.
        AutoStand.shared.update()

        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self = self, self.popover.isShown {
                    self.closePopover(nil)
                }
            }
        }
    }

    @objc func showPreferences() {
        PreferencesWindowController.sharedInstance.showWindow(nil)
        PreferencesWindowController.sharedInstance.deskController = viewController?.controller
        popover.performClose(self)
    }

    @objc func moveToSit() {
        viewController?.controller?.moveToPosition(.sit)
    }

    @objc func moveToStand() {
        viewController?.controller?.moveToPosition(.stand)
    }

    @objc func reconnectDesk() {
        BluetoothManager.shared.retryNow()
    }

    @objc func forgetDesk() {
        BluetoothManager.shared.forgetDesk()
    }

    // MARK: - Menubar icon

    /// Compatibility shim for the Preferences checkbox path: pulls the current
    /// phase from `AutoStand` (if any) and re-applies the icon. Auto-stand off
    /// always renders the template (disabled) icon regardless of `AutoStand`.
    func refreshAutoStandIcon() {
        let phase: AutoStand.Phase
        if !Preferences.shared.automaticStandEnabled {
            phase = .disabled
        } else {
            phase = AutoStand.shared.currentPhase
        }
        applyStatusBarIcon(phase: phase)
    }

    @objc private func autoStandPhaseDidChange(_ note: Notification) {
        let phase = (note.object as? AutoStand.Phase) ?? .disabled
        applyStatusBarIcon(phase: phase)
    }

    @objc private func systemDidWake() {
        // The phase notification may have been suppressed during sleep. Force
        // a re-read.
        let phase: AutoStand.Phase
        if !Preferences.shared.automaticStandEnabled {
            phase = .disabled
        } else {
            phase = AutoStand.shared.currentPhase
        }
        applyStatusBarIcon(phase: phase)
    }

    private func applyStatusBarIcon(phase: AutoStand.Phase) {
        guard let button = statusBarItem?.button else { return }
        guard phase != lastIconPhase else { return }
        lastIconPhase = phase

        let baseConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let glyphName = "arrow.up.and.down.circle"

        switch phase {
        case .disabled:
            // Template glyph adopts the menubar foreground colour (light/dark
            // mode aware) when auto-stand is off.
            let image = configuredStatusImage(
                symbolName: glyphName,
                accessibilityDescription: "Desk Controller",
                configuration: baseConfig
            )
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        case .sitting:
            // Sit phase = blue.
            let palette = baseConfig.applying(.init(paletteColors: [.systemBlue]))
            let image = configuredStatusImage(
                symbolName: glyphName,
                accessibilityDescription: "Desk Controller — sitting",
                configuration: palette
            )
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = nil
        case .standing:
            // Stand phase = green.
            let palette = baseConfig.applying(.init(paletteColors: [.systemGreen]))
            let image = configuredStatusImage(
                symbolName: glyphName,
                accessibilityDescription: "Desk Controller — standing",
                configuration: palette
            )
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = nil
        }
    }

    private func configuredStatusImage(
        symbolName: String,
        accessibilityDescription: String,
        configuration: NSImage.SymbolConfiguration
    ) -> NSImage? {
        if let symbol = NSImage(systemSymbolName: symbolName,
                                accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration) {
            return symbol
        }

        let fallback = NSImage(named: "StatusBarButtonImage")
        fallback?.accessibilityDescription = accessibilityDescription
        return fallback
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowController()
        }
        aboutWindow?.showWindow(nil)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {

    }

    @objc func clickedStatusItem(_ sender: NSStatusItem) {
        guard let event = NSApp.currentEvent else {
            return
        }

        if event.type == .rightMouseUp {
            if let button = statusBarItem.button {
                statusBarMenu.popUp(positioning: nil, at: CGPoint(x: -15, y: button.bounds.maxY + 6), in: button)
            }
        } else {
            togglePopover(sender)
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    func showPopover(_ sender: AnyObject?) {

        guard let button = statusBarItem.button else {
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
        eventMonitor?.start()

        viewController?.reconnect()
    }

    func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
        eventMonitor?.stop()
    }

    public static func bringToFront(window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

extension AppDelegate: NSMenuItemValidation {

    /// Grey out what can't work right now, so the menu tells the truth about
    /// the connection instead of silently doing nothing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveToSit), #selector(moveToStand):
            return BluetoothManager.shared.state == .ready
        case #selector(reconnectDesk):
            return BluetoothManager.shared.state != .ready
        case #selector(forgetDesk):
            return BluetoothManager.shared.hasRememberedDesk
        default:
            return true
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let actionID = response.actionIdentifier
        Task { @MainActor in
            if NotificationManager.shared.notificationActionWasStand(actionID) {
                DeskController.shared?.moveToPosition(.stand)
            } else if NotificationManager.shared.notificationActionWasSit(actionID) {
                DeskController.shared?.moveToPosition(.sit)
            }
            completionHandler()
        }
    }
}
