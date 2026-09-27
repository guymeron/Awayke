//
//  Log.swift
//  Awayke
//
//  Unified logging. View live with:
//    log stream --predicate 'subsystem == "daemonphantom.Awayke"'
//  or after the fact with:
//    log show --last 1h --predicate 'subsystem == "daemonphantom.Awayke"'
//

import os

enum Log {
    static let battery = Logger(subsystem: "daemonphantom.Awayke", category: "battery")
    static let power = Logger(subsystem: "daemonphantom.Awayke", category: "power")
}
