//
//  DeskController.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Foundation


enum MovingDirection: Sendable {
    case up, down, none
}

@MainActor
class DeskController: NSObject {

    var onCurrentMovingDirectionChange: (MovingDirection) -> Void = { _ in }
    var currentMovingDirection: MovingDirection = .none {
        didSet {
            onCurrentMovingDirectionChange(currentMovingDirection)
        }
    }

    var onDoubleTapDetected: ((_ direction: MovingDirection) -> ())? {
        didSet {
            self.desk.onDoubleTapDetected = onDoubleTapDetected
        }
    }

    var movingToPosition: Position? = nil {
        didSet {
            moveIfNeeded()
        }
    }

    let desk: DeskPeripheral

    let distanceOffset: Float = 0.5
    let minDurationIncrements: TimeInterval = 0.5
    var lastMoveTime: Date

    let minMovementIncrements: Float = 0.5
    var previousMovementIncrement: Float

    static var shared: DeskController?

    private var positionChangeCallbacks = [(Float) -> Void]()

    init(desk: DeskPeripheral) {
        self.desk = desk
        self.lastMoveTime = Date().addingTimeInterval(-minDurationIncrements)
        self.previousMovementIncrement = minMovementIncrements
        super.init()

        desk.onPositionChange = { [weak self] position in
            guard let self else { return }
            self.notePositionProgress(position)
            self.moveIfNeeded()
            self.positionChangeCallbacks.forEach { $0(position) }
            // Phase indicator (icon + popover label) is position-based; let
            // AutoStand reread and (de-duped) broadcast on every position
            // update so the indicator flips when the desk crosses midpoint.
            AutoStand.shared.deskPositionChanged()
        }

        DeskController.shared = self
    }

    /// Detach this controller from global resources before it's replaced. A new
    /// controller is built on every reconnect, so without this the old one's
    /// move timer keeps running and `DeskController.shared` can be left pointing
    /// at a controller whose peripheral is gone.
    func teardown() {
        stopMoveTimer()
        holdDirection = .none
        movingToPosition = nil
        if DeskController.shared === self {
            DeskController.shared = nil
        }
    }


    func onPositionChange(_ callback: @escaping (Float) -> Void) {
        positionChangeCallbacks.append(callback)
    }


    // MARK: - Sending commands

    private static let moveUpCommand = "4700"
    private static let moveDownCommand = "4600"
    private static let stopCommand = "FF00"

    @discardableResult
    private func write(_ hexCommand: String) -> Bool {
        guard desk.isReady, let characteristic = desk.controlCharacteristic else {
            dbg("write \(hexCommand): desk not ready")
            return false
        }
        guard let data = Data(hexString: hexCommand) else { return false }
        dbg("write \(hexCommand) to \(characteristic.uuid.uuidString)")
        desk.peripheral.writeValue(data, for: characteristic, type: .withResponse)
        return true
    }

    func moveUp() {
        guard write(DeskController.moveUpCommand) else { return }
        lastMoveTime = Date()
        currentMovingDirection = .up
    }

    func moveDown() {
        guard write(DeskController.moveDownCommand) else { return }
        lastMoveTime = Date()
        currentMovingDirection = .down
    }

    func stopMoving() {
        dbg("stopMoving()")
        holdDirection = .none
        stopMoveTimer()
        write(DeskController.stopCommand)
        currentMovingDirection = .none
        movingToPosition = nil
        previousPosition = nil
    }

    func moveToPosition(_ position: Position) {
        guard desk.isReady else {
            dbg("moveToPosition: desk not ready")
            return
        }
        // Clear `previousPosition` so `moveIfNeeded`'s "did the desk actually
        // move?" guard doesn't block the FIRST packet of a fresh move. The
        // guard exists to detect a non-responding desk during a multi-packet
        // travel; on a brand-new target the previous position is stale (from
        // the last move that ended) and `distSincePrev` would read as 0,
        // causing the first move-down/up command to be silently dropped.
        previousPosition = nil
        holdDirection = .none
        markProgress()
        movingToPosition = position
        startMoveTimer()
    }

    func moveToHeight(_ height: Float) {
        moveToPosition(.custom(height: height))
    }

    // MARK: - Move driver
    //
    // Linak desks need the move command resent every ~500ms to keep moving.
    // Both the hold-to-nudge arrows and the "move to preset" targets run off one
    // timer. Clocking the loop off incoming position notifications instead — as
    // the preset path used to — means a move that never started (dropped first
    // packet, desk asleep, write rejected) is never retried, because a desk that
    // isn't moving doesn't send position notifications.

    private static let resendInterval: TimeInterval = 0.4
    /// How long the desk may report no movement before we conclude it isn't
    /// going to reach the target — it hit its physical limit, it's blocked, or
    /// the command never landed. Without this an unreachable target leaves the
    /// app stuck "moving" forever, with the sit/stand button latched on "Stop".
    private static let stallTimeout: TimeInterval = 3
    /// Close enough to the target to count as arrived. Also catches the case
    /// where the desk is already exactly at the requested height.
    private static let arrivalTolerance: Float = 0.3

    private var moveTimer: Timer?
    private var holdDirection: MovingDirection = .none
    private var lastProgressTime = Date()
    private var lastProgressPosition: Float?

    func startHoldingDown() {
        startHolding(direction: .down)
    }

    func startHoldingUp() {
        startHolding(direction: .up)
    }

    private func startHolding(direction: MovingDirection) {
        dbg("startHolding(direction=\(direction))")
        guard desk.isReady else {
            dbg("startHolding: desk not ready")
            return
        }
        // Manual control wins over any in-flight automatic target, so
        // `moveIfNeeded` doesn't fight us by issuing stopMoving when it thinks
        // we passed the target.
        movingToPosition = nil
        holdDirection = direction
        markProgress()
        send(direction)
        startMoveTimer()
    }

    private func send(_ direction: MovingDirection) {
        switch direction {
        case .up:   moveUp()
        case .down: moveDown()
        case .none: break
        }
    }

    private func startMoveTimer() {
        guard moveTimer == nil else { return }
        let timer = Timer(timeInterval: DeskController.resendInterval, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.moveTick()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer
    }

    private func stopMoveTimer() {
        moveTimer?.invalidate()
        moveTimer = nil
    }

    private func moveTick() {
        // Holding an arrow just keeps resending; running into the desk's limit
        // is the user's business, not a fault to recover from.
        if holdDirection != .none {
            send(holdDirection)
            return
        }
        guard movingToPosition != nil else {
            stopMoveTimer()
            return
        }
        if isStalled {
            dbg("moveTick: no movement for \(DeskController.stallTimeout)s, ending move")
            stopMoving()
            return
        }
        moveIfNeeded()
    }

    /// The desk hasn't reported real movement recently. A desk that isn't moving
    /// sends no position notifications at all, so this also catches a move that
    /// never started.
    private var isStalled: Bool {
        Date().timeIntervalSince(lastProgressTime) > DeskController.stallTimeout
    }

    private func markProgress() {
        lastProgressTime = Date()
        lastProgressPosition = desk.position
    }

    private func notePositionProgress(_ position: Float) {
        if let last = lastProgressPosition, abs(last - position) < 0.1 { return }
        lastProgressPosition = position
        lastProgressTime = Date()
    }


    var previousPosition: Float?

    private func moveIfNeeded() {

        guard let toPosition = movingToPosition, var position = desk.position else {
            if movingToPosition != nil {
                dbg("moveIfNeeded: target set but desk.position is nil")
            }
            return
        }

        let speed = desk.speed

        let timeSinceLastMove = lastMoveTime.distance(to: Date())
        let distanceSincePreviousPosition = abs((previousPosition ?? position + minMovementIncrements) - position)


        let positionToMoveTo = Preferences.shared.forPosition(toPosition)

        let dirInt = (currentMovingDirection == .up ? 1 : (currentMovingDirection == .down ? -1 : 0))
        dbg("moveIfNeeded: pos=\(String(format: "%.1f", position)) target=\(String(format: "%.1f", positionToMoveTo)) speed=\(String(format: "%.1f", speed)) dir=\(dirInt) tsLast=\(String(format: "%.2f", timeSinceLastMove)) distSincePrev=\(String(format: "%.2f", distanceSincePreviousPosition))")

        // Arrived (or was already there). Without this the two branches below
        // both fall through on an exact match and the move never ends.
        if abs(positionToMoveTo - position) <= DeskController.arrivalTolerance {
            stopMoving()
            return
        }

        if positionToMoveTo > position {

            if currentMovingDirection == .up {
                position += distanceOffset
            }

            if position < positionToMoveTo && speed >= 0 {
                if timeSinceLastMove > minDurationIncrements && distanceSincePreviousPosition >= minMovementIncrements {
                    previousPosition = position
                    moveUp()
                }

            } else {
                stopMoving()
            }
        } else if positionToMoveTo < position {

            if currentMovingDirection == .down {
                position -= distanceOffset
            }

            if position > positionToMoveTo && speed <= 0 {
                if timeSinceLastMove > minDurationIncrements && distanceSincePreviousPosition >= minMovementIncrements {
                    previousPosition = position
                    moveDown()
                }
            } else {
                stopMoving()
            }
        }


    }
}
