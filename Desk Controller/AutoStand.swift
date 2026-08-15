//
//  AutoStand.swift
//  Desk Controller
//
//  Created by Johan Eklund on 2021-03-05.
//

import AppKit
import CoreGraphics

extension Notification.Name {
    /// Posted whenever the auto-stand phase may have changed: at the end of
    /// every `AutoStand.update()` and after each timer block (sit↔stand fire).
    /// `object` is the new `AutoStand.Phase`.
    static let autoStandPhaseChanged = Notification.Name("autoStandPhaseChanged")
}

/// The sit/stand schedule.
///
/// Deliberately a singleton that outlives any one Bluetooth connection. When it
/// hung off `DeskController` — which is rebuilt on every reconnect — the whole
/// cycle re-anchored to "now" each time the desk dropped and re-joined, so on a
/// flaky link the stand reminder could never actually come due. It also meant
/// reminders stopped entirely while the desk was unreachable, even in
/// "notify instead of moving" mode where they don't need the desk at all.
@MainActor
class AutoStand: NSObject {

    static let shared = AutoStand()

    enum Phase: Sendable { case disabled, sitting, standing }

    private var upTimer: Timer?
    private var downTimer: Timer?

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        // Timers don't fire while the Mac is asleep and their fire dates drift
        // past. Re-anchor the cycle from now rather than firing a backlog the
        // moment the lid opens.
        dbg("AutoStand: system woke, re-anchoring schedule")
        update()
    }

    /// When the next stand-up fire is scheduled, or `nil` if auto-stand is off.
    var nextUpDate: Date? { upTimer?.isValid == true ? upTimer?.fireDate : nil }
    /// When the next sit-down fire is scheduled, or `nil` if auto-stand is off.
    var nextDownDate: Date? { downTimer?.isValid == true ? downTimer?.fireDate : nil }

    /// Position-based phase. Reflects what the desk *actually* is right now
    /// (sitting vs standing) by comparing the current desk height against the
    /// midpoint of the sit/stand presets. When `automaticStandEnabled` is off,
    /// the indicator is irrelevant and we return `.disabled` so consumers
    /// hide it.
    var currentPhase: Phase {
        guard Preferences.shared.automaticStandEnabled else { return .disabled }
        guard let position = DeskController.shared?.desk.position else {
            // No desk height yet (still connecting). Seed `.sitting` — the
            // cycle always opens with a sit window and this gets corrected
            // on the first position notification anyway.
            return .sitting
        }
        // Presets are in calibrated coordinates; `position` is raw. Convert the
        // presets to raw (subtract the calibration offset) before comparing —
        // the same way `Preferences.forPosition` derives raw move targets.
        let offset = Preferences.shared.positionOffset
        let sit = Preferences.shared.sittingPosition - offset
        let stand = Preferences.shared.standingPosition - offset
        let midpoint = (sit + stand) / 2
        return position < midpoint ? .sitting : .standing
    }

    func unschedule() {
        upTimer?.invalidate()
        downTimer?.invalidate()
    }

    /// Cached last-broadcast phase so we don't spam observers on every
    /// position notification (only on actual transitions).
    private var lastPostedPhase: Phase?

    fileprivate func postPhaseChanged() {
        let phase = currentPhase
        guard phase != lastPostedPhase else { return }
        lastPostedPhase = phase
        NotificationCenter.default.post(name: .autoStandPhaseChanged, object: phase)
    }

    /// Called by `DeskController` on each desk-position update so the icon /
    /// popover label flip exactly when the desk crosses the sit/stand
    /// midpoint, not earlier (timer fire) and not later (manual recompute).
    func deskPositionChanged() {
        postPhaseChanged()
    }

    func update() {

        self.unschedule()

        guard Preferences.shared.automaticStandEnabled else {
            dbg("AutoStand.update: disabled, nothing scheduled")
            postPhaseChanged()
            return
        }

        // New model: sit for `standEvery` minutes, then stand for `standFor`
        // minutes, then repeat. Both timers cycle on (standEvery + standFor).
        let standEvery = TimeInterval(Preferences.shared.standEveryMinutes) * 60
        let standFor = TimeInterval(Preferences.shared.standForMinutes) * 60
        let cycle = standEvery + standFor

        guard cycle > 0 else { return }

        let now = Date()
        let nextUp = now.addingTimeInterval(standEvery)
        let nextDown = nextUp.addingTimeInterval(standFor)

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        dbg("AutoStand.update: now=\(fmt.string(from: now)) standEvery=\(Int(standEvery))s standFor=\(Int(standFor))s inactivity=\(Preferences.shared.automaticStandInactivity)s notifyInsteadOfMove=\(Preferences.shared.notifyInsteadOfAutoMove) nextUp=\(fmt.string(from: nextUp)) nextDown=\(fmt.string(from: nextDown))")

        upTimer = Timer.init(fire: nextUp, interval: cycle, repeats: true, block: { @Sendable _ in
            MainActor.assumeIsolated {
                let lastEvent = CGEventSource.secondsSinceLastEventType(CGEventSourceStateID.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
                let pos = DeskController.shared?.desk.position
                dbg("AutoStand UP timer fired: lastEvent=\(String(format: "%.1f", lastEvent))s threshold=\(Preferences.shared.automaticStandInactivity)s deskPos=\(pos.map { String(format: "%.1f", $0) } ?? "nil") notifyInsteadOfMove=\(Preferences.shared.notifyInsteadOfAutoMove)")

                if lastEvent < Preferences.shared.automaticStandInactivity {
                    if Preferences.shared.notifyInsteadOfAutoMove {
                        dbg("AutoStand UP: posting stand reminder notification")
                        NotificationManager.shared.postStandReminder()
                    } else {
                        dbg("AutoStand UP: calling DeskController.moveToPosition(.stand)")
                        DeskController.shared?.moveToPosition(.stand)
                    }
                } else {
                    dbg("AutoStand UP: SKIPPED — last input event was \(String(format: "%.1f", lastEvent))s ago (>= \(Preferences.shared.automaticStandInactivity)s threshold)")
                }
                // Phase advanced regardless of whether the move was issued —
                // the timer's fireDate has moved on by `cycle`. (Phase is
                // schedule-based, not desk-position-based. See plan.)
                AutoStand.shared.postPhaseChanged()
            }
        })
        upTimer?.tolerance = 10

        downTimer = Timer.init(fire: nextDown, interval: cycle, repeats: true, block: { @Sendable _ in
            MainActor.assumeIsolated {
                let pos = DeskController.shared?.desk.position
                dbg("AutoStand DOWN timer fired: deskPos=\(pos.map { String(format: "%.1f", $0) } ?? "nil") notifyInsteadOfMove=\(Preferences.shared.notifyInsteadOfAutoMove)")
                if Preferences.shared.notifyInsteadOfAutoMove {
                    NotificationManager.shared.postSitReminder()
                } else {
                    DeskController.shared?.moveToPosition(.sit)
                }
                AutoStand.shared.postPhaseChanged()
            }
        })
        downTimer?.tolerance = 10

        RunLoop.main.add(upTimer!, forMode: .common)
        RunLoop.main.add(downTimer!, forMode: .common)

        // Fresh schedule is live — broadcast the resulting phase (will be
        // `.sitting` because nextUp < nextDown after a fresh schedule).
        postPhaseChanged()
    }
}
