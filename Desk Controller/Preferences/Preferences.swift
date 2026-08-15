//
//  PositionPreferences.swift
//  Desk Controller
//
//  Created by David Williames on 11/1/21.
//

import Foundation
import LaunchAtLogin

enum Position: Sendable {
    case sit, stand, custom(height: Float)
}

@MainActor
class Preferences {

    static let shared = Preferences()

    /// Where preferences are stored. Injectable so tests can run against a
    /// throwaway suite instead of the user's real settings.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private let standingKey = "standingPositionValue"
    private let sittingKey = "sittingPositionValue"

    private let automaticStandKey = "automaticStandValue"
    private let automaticStandInactivityKey = "automaticStandInactivityKey"
    private let automaticStandEnabledKey = "automaticStandEnabledKey"

    // New auto-stand model: explicit sit duration + stand duration, instead of
    // "X minutes of standing per clock hour".
    private let standEveryKey = "standEveryMinutes"
    private let standForKey = "standForMinutes"

    private let offsetKey = "positionOffsetValue"

    private let isMetricKey = "isMetric"

    private let doubleTapToSitStandKey = "doubleTapToSitStandKey"

    private let hasLaunched = "hasLaunched"

    private let notifyInsteadOfAutoMoveKey = "notifyInsteadOfAutoMove"

    var standingPosition: Float {
        get { defaults.object(forKey: standingKey) as? Float ?? 110 }
        set { defaults.set(newValue, forKey: standingKey) }
    }

    var sittingPosition: Float {
        get { defaults.object(forKey: sittingKey) as? Float ?? 70 }
        set { defaults.set(newValue, forKey: sittingKey) }
    }

    var automaticStandPerHour: TimeInterval {
        get { defaults.object(forKey: automaticStandKey) as? TimeInterval ?? 10 * 60 }
        set {
            defaults.set(newValue, forKey: automaticStandKey)
            AutoStand.shared.update()
        }
    }

    /// How long the desk stays SITTING between auto-stands.
    /// Default 50 min. On first launch under the new model it's seeded so
    /// that the old (`standFor + standEvery == 60`) cycle is preserved.
    var standEveryMinutes: Int {
        get {
            if let v = defaults.object(forKey: standEveryKey) as? Int {
                return v
            }
            // Migrate from old `automaticStandPerHour`: assume 60-min cycle.
            let oldStandMin = Int(automaticStandPerHour / 60)
            return max(1, 60 - oldStandMin)
        }
        set {
            defaults.set(max(1, newValue), forKey: standEveryKey)
            AutoStand.shared.update()
        }
    }

    /// How long the desk stays STANDING once it goes up. Minimum 5 minutes —
    /// shorter windows aren't enough for the IDÅSEN to physically travel
    /// from sit to stand before the next sit-fire arrives (~40 s of motion
    /// + BT round-trip lag), which caused cycles to silently skip the up.
    var standForMinutes: Int {
        get {
            let stored: Int
            if let v = defaults.object(forKey: standForKey) as? Int {
                stored = v
            } else {
                // Migrate from old `automaticStandPerHour`.
                stored = Int(automaticStandPerHour / 60)
            }
            return max(5, stored)
        }
        set {
            defaults.set(max(5, newValue), forKey: standForKey)
            AutoStand.shared.update()
        }
    }

    var automaticStandInactivity: TimeInterval {
        get { defaults.object(forKey: automaticStandInactivityKey) as? TimeInterval ?? 5 * 60 }
        set { defaults.set(newValue, forKey: automaticStandInactivityKey) }
    }

    var automaticStandEnabled: Bool {
        get { defaults.object(forKey: automaticStandEnabledKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: automaticStandEnabledKey)
            AutoStand.shared.update()
        }
    }

    var positionOffset: Float {
        get { defaults.object(forKey: offsetKey) as? Float ?? 0 }
        set { defaults.set(newValue, forKey: offsetKey) }
    }

    var isMetric: Bool {
        get { defaults.object(forKey: isMetricKey) as? Bool ?? (Locale.current.measurementSystem == .metric) }
        set { defaults.set(newValue, forKey: isMetricKey) }
    }

    var openAtLogin: Bool {
        get { LaunchAtLogin.isEnabled }
        set { LaunchAtLogin.isEnabled = newValue }
    }

    var doubleTapToSitStand: Bool {
        get { defaults.bool(forKey: doubleTapToSitStandKey) }
        set { defaults.setValue(newValue, forKey: doubleTapToSitStandKey) }
    }

    var isFirstLaunch: Bool {
        get { !(defaults.object(forKey: hasLaunched) as? Bool ?? false) }
        set { defaults.set(!newValue, forKey: hasLaunched) }
    }

    /// When `automaticStandEnabled` is on, post a user notification at the scheduled
    /// time instead of physically moving the desk. Off by default for backward compat.
    var notifyInsteadOfAutoMove: Bool {
        get { defaults.object(forKey: notifyInsteadOfAutoMoveKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: notifyInsteadOfAutoMoveKey)
            AutoStand.shared.update()
        }
    }

    /// The raw (uncalibrated) height the desk should travel to.
    ///
    /// Clamped to the desk's physical travel: a target it can never report
    /// reaching — a mistyped preset, `move "500cm"` from AppleScript — otherwise
    /// leaves the move loop chasing it until the desk stalls against its limit.
    func forPosition(_ position: Position) -> Float {
        let target: Float
        switch position {
        case .sit:
            target = sittingPosition - positionOffset
        case .stand:
            target = standingPosition - positionOffset
        case .custom(let height):
            target = height - positionOffset
        }
        return min(max(target, DeskPeripheral.minPosition), DeskPeripheral.maxPosition)
    }

    /// Parse a height string — "120cm", "60in", or a bare number interpreted in
    /// the user's current unit — into centimeters. Returns nil if unparseable.
    func parseHeightToCentimeters(_ string: String) -> Float? {
        if string.hasSuffix("cm") {
            return Float(string.dropLast(2))
        } else if string.hasSuffix("in") {
            return Float(string.dropLast(2))?.convertToCentimeters()
        } else if let value = Float(string) {
            return isMetric ? value : value.convertToCentimeters()
        }
        return nil
    }

    var measurementMetric: Unit {
        return isMetric ? UnitLength.centimeters : UnitLength.inches
    }
}
