//
//  AppLogger.swift
//  RadioPremium
//
//  Logging unificado vía os.Logger. Cero archivos .log en disco.
//  Filtrar en Console.app por subsystem com.blancosampedro.RadioPremium.
//
//  Decisión 2B de /plan-eng-review.
//

import Foundation
import os

enum AppLogger {
    nonisolated static let subsystem = "com.blancosampedro.RadioPremium"

    nonisolated static let app      = Logger(subsystem: subsystem, category: "app")
    nonisolated static let radio    = Logger(subsystem: subsystem, category: "radio")
    nonisolated static let identify = Logger(subsystem: subsystem, category: "identify")
    nonisolated static let spotify  = Logger(subsystem: subsystem, category: "spotify")
    nonisolated static let appleMusic = Logger(subsystem: subsystem, category: "applemusic")
    nonisolated static let audio    = Logger(subsystem: subsystem, category: "audio")
    nonisolated static let http     = Logger(subsystem: subsystem, category: "http")
    nonisolated static let storage  = Logger(subsystem: subsystem, category: "storage")
}
