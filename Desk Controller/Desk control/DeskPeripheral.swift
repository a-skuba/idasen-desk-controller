//
//  DeskPeripheral.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Cocoa
@preconcurrency import CoreBluetooth

@MainActor
class DeskPeripheral: NSObject {

    // `nonisolated` so the scan callbacks can match against them before hopping
    // to the main actor. CBUUID is immutable, so sharing one is safe.
    nonisolated(unsafe) public static let deskPositionServiceUUID = CBUUID.init(string: "99FA0020-338A-1024-8A49-009C0215F78A")
    nonisolated(unsafe) public static let deskPositionCharacteristicUUID = CBUUID.init(string: "99FA0021-338A-1024-8A49-009C0215F78A")

    nonisolated(unsafe) public static let deskControlServiceUUID = CBUUID.init(string: "99FA0001-338A-1024-8A49-009C0215F78A")
    nonisolated(unsafe) public static let deskControlCharacteristicUUID = CBUUID.init(string: "99FA0002-338A-1024-8A49-009C0215F78A")

    static let heightPositionOffset: Float = 61.5 // min

    /// The travel the desk can physically reach, in raw (uncalibrated) cm.
    /// Targets outside this can never be reached, so the move loop would chase
    /// them until it stalled.
    static let minPosition: Float = heightPositionOffset
    static let maxPosition: Float = heightPositionOffset + 65

    let peripheral: CBPeripheral

    var positionService: CBService?
    var positionCharacteristic: CBCharacteristic?

    var controlService: CBService?
    var controlCharacteristic: CBCharacteristic?

    var speed: Float = 0

    var hasLoadedPositionCharacteristicValues = false

    var onPositionChange: (Float) -> Void = { _ in }

    /// Fired once, when the desk is fully usable: control characteristic found,
    /// position notifications subscribed, and a first height received.
    var onReady: () -> Void = { }

    /// Fired when the desk connected but can't be prepared. The connection
    /// needs to be torn down and re-established.
    var onFailure: (String) -> Void = { _ in }

    /// Whether commands can actually be sent. "Connected" on its own is not
    /// enough — without the control characteristic every button silently does
    /// nothing.
    var isReady: Bool {
        controlCharacteristic != nil && isSubscribedToPosition && hasLoadedPositionCharacteristicValues
    }

    private var isSubscribedToPosition = false
    private var hasReportedReady = false

    var position: Float? {
        didSet {
            if let position = position, hasLoadedPositionCharacteristicValues {
                onPositionChange(position)
            }
        }
    }

    var switchControlCommandQueue = SwitchControlCommandQueue()
    var onDoubleTapDetected: ((_ direction: MovingDirection) -> ())?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
    }

    /// Begin service discovery. Separate from `init` so the owner can install
    /// `onReady` / `onFailure` before anything can fire.
    func prepare() {
        peripheral.delegate = self
        // Only the two services we use — discovering everything is slower and
        // gives the desk more chances to time us out.
        peripheral.discoverServices([
            DeskPeripheral.deskPositionServiceUUID,
            DeskPeripheral.deskControlServiceUUID
        ])
    }

    /// Detach from a peripheral that is going away, so a late delegate callback
    /// can't resurrect a dead connection and `isReady` reports the truth.
    func invalidate() {
        peripheral.delegate = nil
        positionService = nil
        positionCharacteristic = nil
        controlService = nil
        controlCharacteristic = nil
        isSubscribedToPosition = false
        onPositionChange = { _ in }
        onReady = { }
        onFailure = { _ in }
        onDoubleTapDetected = nil
    }

    private func reportReadyIfPrepared() {
        guard !hasReportedReady, isReady else { return }
        hasReportedReady = true
        onReady()
    }
}

extension DeskPeripheral: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }

            if let error {
                onFailure("service discovery failed: \(error.localizedDescription)")
                return
            }
            guard let services = peripheral.services, !services.isEmpty else {
                onFailure("no services found")
                return
            }

            services.forEach { service in
                if service.uuid == DeskPeripheral.deskPositionServiceUUID {
                    positionService = service
                    peripheral.discoverCharacteristics(
                        [DeskPeripheral.deskPositionCharacteristicUUID], for: service)
                } else if service.uuid == DeskPeripheral.deskControlServiceUUID {
                    controlService = service
                    peripheral.discoverCharacteristics(
                        [DeskPeripheral.deskControlCharacteristicUUID], for: service)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }

            if let error {
                onFailure("characteristic discovery failed: \(error.localizedDescription)")
                return
            }
            guard let characteristics = service.characteristics else {
                onFailure("no characteristics on \(service.uuid.uuidString)")
                return
            }

            characteristics.forEach { characteristic in
                if characteristic.uuid == DeskPeripheral.deskPositionCharacteristicUUID {
                    dbg("found positionCharacteristic, subscribing")
                    positionCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == DeskPeripheral.deskControlCharacteristicUUID {
                    dbg("found controlCharacteristic")
                    controlCharacteristic = characteristic
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic == positionCharacteristic else { return }

            // Without position notifications the move loop never gets told where
            // the desk is, so every "move to preset" silently does nothing. Treat
            // a failed subscribe as a failed connection rather than limping on.
            if let error {
                onFailure("could not subscribe to position: \(error.localizedDescription)")
                return
            }
            guard characteristic.isNotifying else {
                onFailure("position notifications did not start")
                return
            }

            dbg("subscribed to position notifications")
            isSubscribedToPosition = true
            reportReadyIfPrepared()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                dbg("didWriteValueFor \(characteristic.uuid.uuidString) ERROR: \(error.localizedDescription)")
            } else {
                dbg("didWriteValueFor \(characteristic.uuid.uuidString) OK")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic == positionCharacteristic, error == nil,
                  let value = characteristic.value, value.count >= 4 else {
                return
            }

            let (positionValue, speedValue) = DeskPeripheral.decodePosition(value)

            hasLoadedPositionCharacteristicValues = true
            speed = Float(speedValue)
            position = Float(positionValue) / 100 + DeskPeripheral.heightPositionOffset
            dbg("position notification: raw=\(positionValue) speed=\(speedValue) → \(String(format: "%.1f", position ?? -1)) cm")
            detectSwitchAction(speed: speed)
            reportReadyIfPrepared()
        }
    }

    /// Position is a little-endian `UInt16` of centimetres × 100 above the
    /// desk's minimum height; speed is a little-endian `Int16`.
    ///
    /// Assembled byte by byte rather than loaded through a raw pointer: the
    /// buffer has no alignment guarantee, and this keeps the byte order
    /// explicit instead of inheriting the host's.
    static func decodePosition(_ value: Data) -> (position: UInt16, speed: Int16) {
        let bytes = Array(value.prefix(4))
        let position = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let speed = Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
        return (position, speed)
    }

    private func detectSwitchAction(speed: Float) {
        var direction: MovingDirection = .none

        switch speed {
            case _ where speed == 0:
                direction = .none
            case _ where speed < 0:
                direction = .down
            case _ where speed > 0:
                direction = .up
            default:
                break
        }

        if (self.switchControlCommandQueue.addCommand(command: SwitchControlCommand(direction: direction))) {
            if let doubleTapDirection = self.switchControlCommandQueue.detectDoubleTap() {
                self.switchControlCommandQueue.reset()
                self.onDoubleTapDetected?(doubleTapDirection)
            }
        }
    }
}

struct SwitchControlCommand {
    let direction: MovingDirection
    let time: Date

    init(direction: MovingDirection, time: Date = Date()) {
        self.direction = direction
        self.time = time
    }
}

class SwitchControlCommandQueue {
    private var commands: [SwitchControlCommand] = []

    func addCommand(command: SwitchControlCommand) -> Bool {
        commands.removeAll { command.time.timeIntervalSince($0.time) > 1 }

        guard command.direction != self.commands.last?.direction else {
            return false
        }

        if self.commands.count == 3 {
            if command.direction == .none {
                return false
            }

            self.commands.removeFirst()
        }

        self.commands.append(command)

        return true
    }

    func detectDoubleTap() -> MovingDirection? {
        guard self.commands.count == 3 else {
            return nil
        }

        guard self.commands[1].direction == .none else {
            return nil
        }

        if self.commands[0].direction == self.commands[2].direction {
            return self.commands[0].direction
        } else {
            return nil
        }
    }

    /// Clear the queue once a gesture has been consumed, so the next double-tap
    /// is detected from a clean slate. Without this a stale `[dir, none, dir]`
    /// can block a rapid second same-direction double-tap.
    func reset() {
        self.commands.removeAll()
    }
}
