//
//  MoveDeskToHeightCommand.swift
//  Desk Controller
//
//  Created by David Williames on 3/6/2022.
//

import Foundation


class MoveDeskToHeightCommand: NSScriptCommand {

    override func performDefaultImplementation() -> Any? {
        guard let parameter = directParameter as? String else {
            reportMissingParameter()
            return nil
        }

        report(MainActor.assumeIsolated { DeskScripting.moveToHeight(parameter) })
        return nil
    }
}
