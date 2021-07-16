//
//  LibreTransmitterPlugin.swift
//  LibreTransmitterPlugin
//
//  Created by Nathaniel Hamming on 2019-12-19.
//  Copyright © 2019 Mark Wilson. All rights reserved.
//

import Foundation

import LibreTransmitter
import LibreTransmitterUI
import os.log

class LibreTransmitterPlugin: NSObject, CGMManagerUIPlugin {
    
    private let log = OSLog(category: "LibreTransmitterPlugin")
    
    public var pumpManagerType: PumpManagerUI.Type? {
        nil
    }
    
    public var cgmManagerType: CGMManagerUI.Type? {
        LibreTransmitterManager.self
    }
    
    override init() {
        super.init()
        log.default("Instantiated")
    }
}
