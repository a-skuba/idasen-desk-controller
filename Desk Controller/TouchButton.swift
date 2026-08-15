//
//  TouchButton.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Cocoa

class TouchButton: NSButton {
    
    var isPressed = false
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    func setup() {
        // Fire on mouse-down only (while `isPressed` is true → start holding).
        // The matching release/stop is sent manually from `mouseDown` below, so
        // adding `.leftMouseUp` here would just fire a redundant hold-start at
        // release before the stop lands.
        sendAction(on: [.leftMouseDown])
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)   // tracks until release; fires action on press
        isPressed = false
        let _ = target?.perform(action, with: self)   // release → stop
    }
}
