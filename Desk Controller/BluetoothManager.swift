//
//  BluetoothManager.swift
//  Desk Controller
//
//  Created by David Williames on 11/1/21.
//

import Cocoa
@preconcurrency import CoreBluetooth

@MainActor
class BluetoothManager: NSObject {

    var stopOnFirstConnection = true

    // Singleton for managing it all
    static let shared = BluetoothManager()

    var centralManager: CBCentralManager?

    var onCentralManagerStateChange: (CBCentralManager?) -> Void = { _ in }

    var onConnectedPeripheralChange: (CBPeripheral?) -> Void = { _ in  }
    private var connectPeripheralRSSI: NSNumber?

    /// The peripheral we are attempting to connect to (set in didDiscover)
    private var pendingPeripheral: CBPeripheral?

    /// The peripheral that is fully connected (set in didConnect, cleared in didDisconnect)
    private(set) var connectedPeripheral: CBPeripheral?

    /// The last desk we successfully connected to. Unlike `connectedPeripheral`
    /// this is NOT cleared on disconnect, so we always know what to reconnect to.
    private var knownPeripheral: CBPeripheral?

    private static let lastDeskIdentifierKey = "lastDeskPeripheralIdentifier"

    private var lastDeskIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastDeskIdentifierKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastDeskIdentifierKey) }
    }

    private var retryTask: Task<Void, Never>?

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
        startScanning()
    }

    func startScanning() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else {
            reconnect()
        }
    }

    @objc private func onWake(_ note: Notification) {
        dbg("[BT] system did wake")
        reconnect()
    }

    /// Idempotent: safe to call any time (wake, popover open, Shortcuts). Does
    /// nothing if already connected or a connection attempt is in flight.
    func reconnect() {
        guard let central = centralManager, central.state == .poweredOn else {
            return
        }
        if connectedPeripheral?.state == .connected {
            return
        }

        let candidate = knownPeripheral ?? pendingPeripheral ?? retrieveLastDesk(central)
        if let candidate {
            switch candidate.state {
            case .disconnected, .disconnecting:
                connect(candidate, via: central, reason: "reconnect()")
            case .connecting:
                dbg("[BT] reconnect(): \(candidate.identifier) already connecting")
            case .connected:
                // Connected at the OS level but we lost track of it; adopt it.
                dbg("[BT] reconnect(): adopting connected \(candidate.identifier)")
                adoptConnected(candidate, via: central)
            @unknown default:
                break
            }
            return
        }

        startDiscovery(central)
    }

    private func retrieveLastDesk(_ central: CBCentralManager) -> CBPeripheral? {
        guard let id = lastDeskIdentifier else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    /// A CoreBluetooth connect request never times out: if the desk is out of
    /// range / busy, the request stays pending and completes when it is
    /// reachable again. So a single `connect` after a drop is enough.
    private func connect(_ peripheral: CBPeripheral, via central: CBCentralManager, reason: String) {
        dbg("[BT] connect \(peripheral.identifier) (\(reason))")
        pendingPeripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    private func adoptConnected(_ peripheral: CBPeripheral, via central: CBCentralManager) {
        // Calling connect on an already-connected peripheral makes CoreBluetooth
        // deliver didConnect for this app.
        connect(peripheral, via: central, reason: "adopt")
    }

    private func startDiscovery(_ central: CBCentralManager) {
        // Adopt any peripheral macOS already has connected on the IDÅSEN
        // service — these will NOT show up via scanForPeripherals because
        // they don't advertise while held by another connection.
        let alreadyConnected = central.retrieveConnectedPeripherals(
            withServices: [DeskPeripheral.deskControlServiceUUID]
        )
        if let desk = alreadyConnected.first {
            dbg("[BT] adopting already-connected peripheral \(desk.identifier) name=\(desk.name ?? "—")")
            adoptConnected(desk, via: central)
            return
        }

        if !central.isScanning {
            dbg("[BT] no known desk, starting advertising scan")
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reconnect()
        }
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "nil" }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
    }
}

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            centralManager = central
            dbg("[BT] state -> \(central.state.rawValue) (poweredOn=\(central.state == .poweredOn))")

            guard central.state == .poweredOn else {
                // Bluetooth off / resetting: all links are gone, and
                // didDisconnect is not guaranteed to be delivered.
                retryTask?.cancel()
                if connectedPeripheral != nil {
                    connectedPeripheral = nil
                    onConnectedPeripheralChange(nil)
                }
                pendingPeripheral = nil
                onCentralManagerStateChange(central)
                return
            }

            onCentralManagerStateChange(central)
            reconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Extract Sendable primitives BEFORE crossing into the MainActor closure —
        // `advertisementData` is `[String: Any]` and can't be sent across isolations.
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue

        MainActor.assumeIsolated {
            let cachedName = peripheral.name
            // Match the desk's advertised name. Case-insensitive, and inspects
            // `CBAdvertisementDataLocalNameKey` too so a desk that hasn't been
            // paired before (and therefore has no `peripheral.name` yet) still
            // matches on the first scan.
            let looksLikeDesk = (cachedName?.lowercased().contains("desk") ?? false)
                || (localName?.lowercased().contains("desk") ?? false)

            guard pendingPeripheral != peripheral && connectedPeripheral != peripheral else {
                return
            }
            guard looksLikeDesk else { return }

            let isClosestMatchingPeripheral = (connectPeripheralRSSI != nil && rssi < connectPeripheralRSSI!.intValue)

            if pendingPeripheral == nil || isClosestMatchingPeripheral {
                connectPeripheralRSSI = RSSI
                connect(peripheral, via: central, reason: "discovered rssi=\(rssi)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral == pendingPeripheral || peripheral == knownPeripheral else {
                dbg("[BT] didConnect ignored for \(peripheral.identifier)")
                return
            }
            dbg("[BT] didConnect \(peripheral.identifier) name=\(peripheral.name ?? "—")")

            retryTask?.cancel()
            if stopOnFirstConnection {
                central.stopScan()
            }

            // Promote pending → connected
            connectedPeripheral = peripheral
            knownPeripheral = peripheral
            lastDeskIdentifier = peripheral.identifier
            pendingPeripheral = nil
            connectPeripheralRSSI = nil
            onConnectedPeripheralChange(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            dbg("[BT] didDisconnect \(peripheral.identifier) error=\(Self.describe(error))")

            let wasOurs = peripheral == connectedPeripheral || peripheral == knownPeripheral
            if peripheral == connectedPeripheral {
                connectedPeripheral = nil
            }
            if peripheral == pendingPeripheral {
                pendingPeripheral = nil
            }
            connectPeripheralRSSI = nil

            onConnectedPeripheralChange(nil)

            // Auto-reconnect. Previously nothing re-issued a connect here, and
            // both references were cleared, so the app stayed disconnected
            // until it was restarted.
            if wasOurs, central.state == .poweredOn {
                connect(peripheral, via: central, reason: "auto-reconnect after disconnect")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            dbg("[BT] didFailToConnect \(peripheral.identifier) error=\(Self.describe(error))")
            if peripheral == pendingPeripheral {
                pendingPeripheral = nil
            }
            connectPeripheralRSSI = nil

            onConnectedPeripheralChange(nil)

            if peripheral == knownPeripheral || knownPeripheral == nil {
                scheduleRetry(after: 3)
            }
        }
    }

}
