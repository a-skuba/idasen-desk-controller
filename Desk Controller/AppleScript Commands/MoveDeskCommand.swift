//
//  ScriptableCommands.swift
//  Desk Controller
//
//  Created by David Williames on 12/1/21.
//

import Foundation

/// What happened to a scripted move, so the command can report a real
/// AppleScript error. Failing silently left Alfred workflows and Shortcuts with
/// no way to tell "moved" from "the desk isn't even connected".
enum DeskScriptResult: Sendable {
    case moved
    case notConnected
    case unrecognised(String)
}

@MainActor
enum DeskScripting {

    static func move(_ parameter: String) -> DeskScriptResult {
        guard let controller = DeskController.shared, controller.desk.isReady else {
            return .notConnected
        }

        switch parameter {
        case "to-stand":
            controller.moveToPosition(.stand)
        case "to-sit":
            controller.moveToPosition(.sit)
        case "up":
            controller.moveUp()
        case "down":
            controller.moveDown()
        default:
            return moveToHeight(parameter)
        }
        return .moved
    }

    static func moveToHeight(_ parameter: String) -> DeskScriptResult {
        guard let controller = DeskController.shared, controller.desk.isReady else {
            return .notConnected
        }
        guard let height = Preferences.shared.parseHeightToCentimeters(parameter) else {
            return .unrecognised(parameter)
        }
        controller.moveToHeight(height)
        return .moved
    }
}

extension NSScriptCommand {

    func report(_ result: DeskScriptResult) {
        switch result {
        case .moved:
            break
        case .notConnected:
            scriptErrorNumber = NSInternalScriptError
            scriptErrorString = "Desk Controller isn't connected to a desk yet."
        case .unrecognised(let input):
            scriptErrorNumber = NSArgumentsWrongScriptError
            scriptErrorString = "Couldn't understand \"\(input)\". Use to-sit, to-stand, up, down, or a height such as 120cm."
        }
    }

    func reportMissingParameter() {
        scriptErrorNumber = NSRequiredArgumentsMissingScriptError
        scriptErrorString = "Expected some text, for example: move \"to-stand\" or move \"120cm\"."
    }
}

class MoveDeskCommand: NSScriptCommand {

    override func performDefaultImplementation() -> Any? {
        guard let parameter = directParameter as? String else {
            reportMissingParameter()
            return nil
        }

        report(MainActor.assumeIsolated { DeskScripting.move(parameter) })
        return nil
    }
}
