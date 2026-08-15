//
//  BluetoothManager.swift
//  Desk Controller
//
//  Created by David Williames on 11/1/21.
//

import AppKit
@preconcurrency import CoreBluetooth

/// Finds the desk, connects to it, and keeps it connected.
///
/// The guiding rule is that there is **no terminal state** other than "Bluetooth
/// itself is unusable". Every failure — a refused connect, a dropped link, a
/// connect that hangs, service discovery that never completes, a Bluetooth
/// power cycle — funnels back into `startConnecting()`, which is idempotent and
/// safe to call from anywhere.
///
/// Once a desk has been connected to, its identifier is remembered. Later
/// launches skip discovery entirely and hand the identifier straight to
/// CoreBluetooth, which connects the moment the desk is in range.
@MainActor
final class BluetoothManager: NSObject {

    /// What the app is currently doing about the desk connection.
    enum State: Equatable {
        /// Bluetooth can't be used at all (off, unauthorized, unsupported…).
        case unavailable(CBManagerState)
        /// Looking for a desk — scanning, or waiting out a retry backoff.
        case searching
        /// A `connect()` is in flight.
        case connecting
        /// Connected; discovering services and subscribing to position updates.
        case preparing
        /// Connected, prepared, and usable. `desk` is non-nil and ready.
        case ready
    }

    static let shared = BluetoothManager()

    // MARK: - Tuning

    /// How long to keep collecting advertisements before picking a desk. Only
    /// used before the first successful connection — after that the remembered
    /// identifier is connected to directly.
    private static let discoveryWindow: TimeInterval = 2
    /// How long a `connect()` may sit unanswered before we *also* start
    /// scanning. The pending connect is deliberately left alive: that is
    /// CoreBluetooth's own "connect as soon as it appears" mechanism and it
    /// costs nothing to keep waiting.
    private static let connectEscalationDelay: TimeInterval = 15
    /// How long that parallel scan runs before we fall back to waiting on the
    /// pending connect alone.
    private static let escalatedScanDuration: TimeInterval = 30
    /// How long service discovery may take before we give up and reconnect.
    private static let prepareTimeout: TimeInterval = 10
    private static let minRetryDelay: TimeInterval = 1
    private static let maxRetryDelay: TimeInterval = 30

    private static let rememberedDeskKey = "rememberedDeskIdentifier"

    // MARK: - Published state

    private(set) var state: State = .unavailable(.unknown) {
        didSet {
            guard state != oldValue else { return }
            dbg("[BT] \(oldValue) -> \(state)")
            onStateChange(state)
        }
    }

    /// Called on every distinct `state` transition. Entering `.ready` means
    /// `desk` is prepared and usable; leaving it means the desk is gone.
    var onStateChange: (State) -> Void = { _ in }

    /// The connected desk. Non-nil from `.preparing` onwards — only safe to
    /// send commands to once `state == .ready`.
    private(set) var desk: DeskPeripheral?

    /// Name of the desk we're connected to, for display.
    private(set) var deskName: String?

    /// Whether a desk identifier has been remembered from a previous connection.
    var hasRememberedDesk: Bool { rememberedDeskIdentifier != nil }

    /// The underlying central, exposed so the UI can report authorization state.
    private(set) var centralManager: CBCentralManager?

    // MARK: - Internals

    /// The peripheral we've asked CoreBluetooth to connect to.
    private var pendingPeripheral: CBPeripheral?
    /// The peripheral we're connected to (possibly still preparing).
    private var connectedPeripheral: CBPeripheral?

    /// Advertisements seen during the current discovery window.
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]

    private var discoveryTimer: Timer?
    private var escalationTimer: Timer?
    private var escalatedScanTimer: Timer?
    private var prepareTimer: Timer?
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = BluetoothManager.minRetryDelay

    private var rememberedDeskIdentifier: UUID? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: Self.rememberedDeskKey) else {
                return nil
            }
            return UUID(uuidString: stored)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.rememberedDeskKey)
        }
    }

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Entry points

    /// Bring the Bluetooth stack up. Call once, after the UI has registered its
    /// `onStateChange` handler.
    func start() {
        guard centralManager == nil else {
            startConnecting()
            return
        }
        // `queue: nil` delivers every delegate callback on the main queue, which
        // is what makes the `MainActor.assumeIsolated` calls below valid. Don't
        // pass a custom queue without revisiting them.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Ask for a connection. Idempotent — a no-op while already connecting or
    /// connected, so it's safe to call from timers, wake notifications and the
    /// UI alike.
    func startConnecting() {
        guard let central = centralManager, central.state == .poweredOn else { return }

        switch state {
        case .connecting, .preparing, .ready:
            return
        case .unavailable, .searching:
            break
        }

        retryTimer?.invalidate()
        retryTimer = nil

        // A desk we've connected to before: hand CoreBluetooth the identifier
        // and let it do the waiting. No scan, no name matching, and it works
        // even if the desk has since been renamed.
        if let identifier = rememberedDeskIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            dbg("[BT] connecting to remembered desk \(identifier)")
            connect(known)
            return
        }

        // A desk macOS already holds a connection to doesn't advertise, so it
        // can never be found by scanning. Adopt it directly.
        if let adopted = central.retrieveConnectedPeripherals(
            withServices: [DeskPeripheral.deskControlServiceUUID]).first {
            dbg("[BT] adopting already-connected desk \(adopted.identifier)")
            connect(adopted)
            return
        }

        beginScan()
    }

    /// The user asked us to try again right now (menu item, popover opened).
    func retryNow() {
        guard state != .ready else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        retryDelay = Self.minRetryDelay

        guard centralManager != nil else {
            start()
            return
        }
        // Nothing to retry while Bluetooth is unusable — and claiming to be
        // searching when we can't even scan would just be a lie on screen.
        guard centralManager?.state == .poweredOn else { return }

        if state == .connecting {
            // A connect is already armed. Scanning alongside it is a better use
            // of the user's click than cancelling an attempt that may be about
            // to land.
            beginScan()
            return
        }
        startConnecting()
    }

    /// Forget the remembered desk and start looking from scratch — the escape
    /// hatch for having latched onto the wrong desk in a room full of them.
    func forgetDesk() {
        dbg("[BT] forgetting remembered desk")
        rememberedDeskIdentifier = nil
        deskName = nil
        retryDelay = Self.minRetryDelay

        if let connected = connectedPeripheral {
            // Let `didDisconnect` restart discovery. Restarting it here instead
            // would run `retrieveConnectedPeripherals` while the link is still
            // up, and we'd immediately adopt the desk we just asked to forget.
            centralManager?.cancelPeripheralConnection(connected)
            return
        }

        cancelPendingConnect()
        teardownDesk()
        guard centralManager?.state == .poweredOn else { return }
        state = .searching
        startConnecting()
    }

    @objc private func systemDidWake() {
        dbg("[BT] system woke")
        guard state != .ready else { return }
        retryNow()
    }

    // MARK: - Scanning

    private func beginScan() {
        guard let central = centralManager, central.state == .poweredOn else { return }
        state = .searching
        guard !central.isScanning else { return }

        candidates.removeAll()
        dbg("[BT] scanning")
        // Duplicate filtering is off on purpose. With it on, CoreBluetooth
        // reports each peripheral once per scan session — so a desk that failed
        // to connect would never be offered again, and the closest-desk
        // comparison would only ever see a single sample per desk.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func stopScan() {
        guard let central = centralManager, central.isScanning else { return }
        central.stopScan()
    }

    /// Pick the strongest advertiser seen during the discovery window.
    private func connectToClosestCandidate() {
        discoveryTimer = nil
        guard state == .searching else { return }
        guard let best = candidates.values.max(by: { $0.rssi < $1.rssi }) else { return }

        candidates.removeAll()
        stopScan()
        dbg("[BT] chose \(best.peripheral.identifier) name=\(best.peripheral.name ?? "—") rssi=\(best.rssi)")
        connect(best.peripheral)
    }

    // MARK: - Connecting

    private func connect(_ peripheral: CBPeripheral) {
        guard let central = centralManager else { return }

        cancelPendingConnect()
        pendingPeripheral = peripheral
        state = .connecting
        central.connect(peripheral, options: nil)

        escalationTimer = scheduleTimer(after: Self.connectEscalationDelay) { [weak self] in
            guard let self, self.state == .connecting else { return }
            // Leave the pending connect in place — CoreBluetooth will still take
            // it if the desk shows up — but start scanning as well, so a stale
            // remembered identifier (desk reset, replaced, factory-defaulted)
            // can be superseded by whatever is actually out there.
            dbg("[BT] connect still pending, scanning in parallel")
            self.beginScan()

            // Long enough to turn up a replacement desk, short enough not to
            // leave the radio scanning all day. The pending connect keeps
            // waiting either way, and it's the power-efficient way to do so.
            self.escalatedScanTimer = self.scheduleTimer(after: Self.escalatedScanDuration) { [weak self] in
                guard let self, self.pendingPeripheral != nil, self.state == .searching else { return }
                dbg("[BT] ending escalated scan; the pending connect stays armed")
                self.stopScan()
            }
        }
    }

    /// Release any connect we've asked for but no longer want. Dropping the
    /// reference without cancelling leaves the request live inside
    /// CoreBluetooth, which can later hand us a connection we then hold open
    /// forever — keeping the desk away from every other client.
    private func clearConnectTimers() {
        escalationTimer?.invalidate()
        escalationTimer = nil
        escalatedScanTimer?.invalidate()
        escalatedScanTimer = nil
    }

    private func cancelPendingConnect() {
        clearConnectTimers()
        if let pending = pendingPeripheral {
            pendingPeripheral = nil
            centralManager?.cancelPeripheralConnection(pending)
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        let delay = retryDelay
        retryDelay = min(Self.maxRetryDelay, retryDelay * 2)
        dbg("[BT] retrying in \(Int(delay))s")
        state = .searching
        retryTimer = scheduleTimer(after: delay) { [weak self] in
            self?.startConnecting()
        }
    }

    // MARK: - Desk lifecycle

    private func deskDidBecomeReady() {
        prepareTimer?.invalidate()
        prepareTimer = nil
        guard state == .preparing else { return }
        dbg("[BT] desk ready")
        state = .ready
    }

    /// The desk connected but isn't usable. Reconnecting is the only reliable
    /// recovery, and cancelling produces a `didDisconnect` that drives it.
    private func deskDidFail(_ reason: String) {
        guard let connected = connectedPeripheral else { return }
        dbg("[BT] desk unusable (\(reason)) — reconnecting")
        prepareTimer?.invalidate()
        prepareTimer = nil
        centralManager?.cancelPeripheralConnection(connected)
    }

    private func teardownDesk() {
        prepareTimer?.invalidate()
        prepareTimer = nil
        desk?.invalidate()
        desk = nil
    }

    /// Drop every peripheral reference and scheduled retry. Leaves `state`
    /// alone so the caller can decide what to report.
    private func invalidateEverything() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        clearConnectTimers()
        retryTimer?.invalidate()
        retryTimer = nil
        candidates.removeAll()
        pendingPeripheral = nil
        connectedPeripheral = nil
        teardownDesk()
    }

    // MARK: - Timers

    @discardableResult
    private func scheduleTimer(after delay: TimeInterval,
                               _ block: @escaping @Sendable @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { @Sendable _ in
            MainActor.assumeIsolated { block() }
        }
        timer.tolerance = delay * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            centralManager = central
            dbg("[BT] central state = \(central.state.rawValue)")

            guard central.state == .poweredOn else {
                // CoreBluetooth invalidates every CBPeripheral it has handed out
                // when the central leaves `poweredOn`. Reconnecting to a cached
                // one afterwards silently never completes, so throw them away and
                // rebuild from the remembered identifier once Bluetooth is back.
                invalidateEverything()
                state = .unavailable(central.state)
                return
            }

            retryDelay = Self.minRetryDelay
            startConnecting()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // `advertisementData` is `[String: Any]` and can't cross into the
        // MainActor closure — reduce it to Sendable primitives first.
        // Scanning runs with duplicate filtering off, so this is a hot path —
        // keep it allocation-free.
        let deskService = DeskPeripheral.deskControlServiceUUID
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advertisesDeskService =
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(deskService) == true
            || (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?.contains(deskService) == true
        let rssi = RSSI.intValue

        MainActor.assumeIsolated {
            guard state == .searching else { return }

            // Matching the advertised Linak control service means a renamed desk
            // is still found; the name check stays as a fallback for desks that
            // don't put the service UUID in their advertisement.
            let nameMatches = (peripheral.name?.localizedCaseInsensitiveContains("desk") ?? false)
                || (localName?.localizedCaseInsensitiveContains("desk") ?? false)
            guard advertisesDeskService || nameMatches else { return }

            // RSSI is negative dBm, so the greatest value is the closest desk.
            let best = max(rssi, candidates[peripheral.identifier]?.rssi ?? Int.min)
            candidates[peripheral.identifier] = (peripheral, best)

            // Collect for a moment before choosing, so a desk two rooms away
            // doesn't win simply by advertising first.
            guard discoveryTimer == nil else { return }
            discoveryTimer = scheduleTimer(after: Self.discoveryWindow) { [weak self] in
                self?.connectToClosestCandidate()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral == pendingPeripheral else {
                // A connect we've since abandoned completed anyway. Release it
                // rather than silently holding the desk away from other clients.
                dbg("[BT] releasing unexpected connection to \(peripheral.identifier)")
                central.cancelPeripheralConnection(peripheral)
                return
            }

            clearConnectTimers()
            discoveryTimer?.invalidate()
            discoveryTimer = nil
            candidates.removeAll()
            stopScan()

            pendingPeripheral = nil
            connectedPeripheral = peripheral
            retryDelay = Self.minRetryDelay
            rememberedDeskIdentifier = peripheral.identifier
            deskName = peripheral.name
            dbg("[BT] connected \(peripheral.identifier) name=\(peripheral.name ?? "—")")

            state = .preparing

            let desk = DeskPeripheral(peripheral: peripheral)
            desk.onReady = { [weak self] in self?.deskDidBecomeReady() }
            desk.onFailure = { [weak self] reason in self?.deskDidFail(reason) }
            self.desk = desk
            desk.prepare()

            // Connected but never usable is the worst failure mode — a green
            // light and buttons that do nothing. Give discovery a deadline.
            prepareTimer = scheduleTimer(after: Self.prepareTimeout) { [weak self] in
                self?.deskDidFail("service discovery timed out")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            dbg("[BT] disconnected \(peripheral.identifier) error=\(error?.localizedDescription ?? "none")")
            guard peripheral == connectedPeripheral || peripheral == pendingPeripheral else { return }

            // A link that dropped while still being prepared never worked. Going
            // straight back in would spin: connect → discovery fails → cancel →
            // connect. Back off instead.
            let neverBecameUsable = (state == .preparing)

            clearConnectTimers()
            connectedPeripheral = nil
            pendingPeripheral = nil
            teardownDesk()

            state = .searching
            if neverBecameUsable {
                scheduleRetry()
            } else {
                // Straight back to a pending connect on the remembered
                // identifier; CoreBluetooth takes it the moment the desk
                // advertises again.
                startConnecting()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            dbg("[BT] failed to connect \(peripheral.identifier): \(error?.localizedDescription ?? "unknown")")
            guard peripheral == pendingPeripheral else { return }

            clearConnectTimers()
            pendingPeripheral = nil
            // Retry with backoff. Leaving this as a dead end was what stranded
            // the app disconnected until Bluetooth was power-cycled.
            scheduleRetry()
        }
    }
}
