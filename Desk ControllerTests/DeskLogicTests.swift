//
//  DeskLogicTests.swift
//  Desk ControllerTests
//
//  Covers the pure logic the desk connection depends on: decoding what the desk
//  reports, recognising the double-tap gesture, and turning preferences into a
//  height the desk can actually travel to.
//

import XCTest
@testable import Desk_Controller

// MARK: - Position decoding

final class PositionDecodingTests: XCTestCase {

    @MainActor
    func testDecodesLittleEndianPosition() {
        // 0x0350 = 848 → 8.48 cm above the desk's minimum height.
        let (position, speed) = DeskPeripheral.decodePosition(Data([0x50, 0x03, 0x00, 0x00]))
        XCTAssertEqual(position, 848)
        XCTAssertEqual(speed, 0)
    }

    @MainActor
    func testDecodesNegativeSpeedWhenTravellingDown() {
        // 0xFF9C is -100 as a signed little-endian 16-bit value.
        XCTAssertEqual(DeskPeripheral.decodePosition(Data([0x00, 0x00, 0x9C, 0xFF])).speed, -100)
    }

    @MainActor
    func testDecodesExtremeValuesWithoutOverflow() {
        let (position, speed) = DeskPeripheral.decodePosition(Data([0xFF, 0xFF, 0xFF, 0x7F]))
        XCTAssertEqual(position, 65535)
        XCTAssertEqual(speed, 32767)
    }

    @MainActor
    func testIgnoresBytesBeyondTheFirstFour() {
        let value = Data([0x50, 0x03, 0x00, 0x00, 0xAA, 0xBB])
        XCTAssertEqual(DeskPeripheral.decodePosition(value).position, 848)
    }
}

// MARK: - Double-tap gesture

final class SwitchControlCommandQueueTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func tap(_ queue: SwitchControlCommandQueue,
                     _ direction: MovingDirection,
                     at offset: TimeInterval) -> Bool {
        queue.addCommand(command: SwitchControlCommand(direction: direction,
                                                       time: start.addingTimeInterval(offset)))
    }

    func testDetectsDoubleTapUp() {
        let queue = SwitchControlCommandQueue()
        XCTAssertTrue(tap(queue, .up, at: 0))
        XCTAssertTrue(tap(queue, .none, at: 0.2))
        XCTAssertTrue(tap(queue, .up, at: 0.4))
        XCTAssertEqual(queue.detectDoubleTap(), .up)
    }

    func testDetectsDoubleTapDown() {
        let queue = SwitchControlCommandQueue()
        _ = tap(queue, .down, at: 0)
        _ = tap(queue, .none, at: 0.2)
        _ = tap(queue, .down, at: 0.4)
        XCTAssertEqual(queue.detectDoubleTap(), .down)
    }

    func testIgnoresTapsInOppositeDirections() {
        let queue = SwitchControlCommandQueue()
        _ = tap(queue, .up, at: 0)
        _ = tap(queue, .none, at: 0.2)
        _ = tap(queue, .down, at: 0.4)
        XCTAssertNil(queue.detectDoubleTap())
    }

    func testIgnoresRepeatedSameDirectionUpdates() {
        let queue = SwitchControlCommandQueue()
        XCTAssertTrue(tap(queue, .up, at: 0))
        XCTAssertFalse(tap(queue, .up, at: 0.1), "a direction that hasn't changed isn't a new tap")
    }

    func testTapsMoreThanASecondApartAreNotAGesture() {
        let queue = SwitchControlCommandQueue()
        _ = tap(queue, .up, at: 0)
        _ = tap(queue, .none, at: 0.2)
        _ = tap(queue, .up, at: 1.5)
        XCTAssertNil(queue.detectDoubleTap())
    }

    func testResetClearsAConsumedGesture() {
        let queue = SwitchControlCommandQueue()
        _ = tap(queue, .up, at: 0)
        _ = tap(queue, .none, at: 0.2)
        _ = tap(queue, .up, at: 0.4)
        queue.reset()
        XCTAssertNil(queue.detectDoubleTap())
    }
}

// MARK: - Move commands

final class MoveCommandEncodingTests: XCTestCase {

    func testEncodesTheLinakMoveCommands() {
        XCTAssertEqual(Data(hexString: "4700"), Data([0x47, 0x00]), "move up")
        XCTAssertEqual(Data(hexString: "4600"), Data([0x46, 0x00]), "move down")
        XCTAssertEqual(Data(hexString: "FF00"), Data([0xFF, 0x00]), "stop")
    }

    func testRejectsNonHexInput() {
        XCTAssertNil(Data(hexString: "ZZ"))
    }
}

// MARK: - Preferences

final class PreferencesTests: XCTestCase {

    /// A `Preferences` backed by a throwaway defaults suite, so tests never
    /// touch the settings of the app installed on this machine.
    @MainActor
    private func makePreferences() -> (preferences: Preferences, cleanup: () -> Void) {
        let suiteName = "DeskControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (Preferences(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
    }

    @MainActor
    func testParsesExplicitCentimetres() {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        XCTAssertEqual(preferences.parseHeightToCentimeters("120cm"), 120)
    }

    @MainActor
    func testParsesExplicitInches() throws {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        let parsed = try XCTUnwrap(preferences.parseHeightToCentimeters("60in"))
        XCTAssertEqual(parsed, 152.4, accuracy: 0.01)
    }

    @MainActor
    func testBareNumberFollowsTheUnitPreference() throws {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }

        preferences.isMetric = true
        XCTAssertEqual(preferences.parseHeightToCentimeters("80"), 80)

        preferences.isMetric = false
        XCTAssertEqual(try XCTUnwrap(preferences.parseHeightToCentimeters("80")), 203.2, accuracy: 0.01)
    }

    @MainActor
    func testRejectsUnparseableHeight() {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }
        XCTAssertNil(preferences.parseHeightToCentimeters("tall"))
    }

    @MainActor
    func testAppliesCalibrationOffsetToPresets() {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }

        preferences.positionOffset = 2
        preferences.sittingPosition = 75
        XCTAssertEqual(preferences.forPosition(.sit), 73, accuracy: 0.001)
    }

    @MainActor
    func testClampsATargetAboveTheDesksReach() {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }

        // A mistyped preset — 1100 instead of 110 — must not become a target the
        // desk can never report reaching, which used to leave the move loop
        // running until it stalled against the desk's limit.
        preferences.positionOffset = 0
        XCTAssertEqual(preferences.forPosition(.custom(height: 1100)), DeskPeripheral.maxPosition)
    }

    @MainActor
    func testClampsATargetBelowTheDesksReach() {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }

        preferences.positionOffset = 0
        XCTAssertEqual(preferences.forPosition(.custom(height: 10)), DeskPeripheral.minPosition)
    }

    @MainActor
    func testLeavesReachableTargetsAlone() {
        let (preferences, cleanup) = makePreferences()
        defer { cleanup() }

        preferences.positionOffset = 0
        XCTAssertEqual(preferences.forPosition(.custom(height: 100)), 100, accuracy: 0.001)
    }
}
