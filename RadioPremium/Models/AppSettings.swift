//
//  AppSettings.swift
//  RadioPremium
//
//  Preferencias del usuario. Persiste en Application Support vía JSONStore.
//
//  Decisiones explícitas vs Windows app:
//  - Sin `theme` → Mac sigue el sistema (Light/Dark/Auto del SO).
//  - Sin `startInMiniPlayer` → app es menubar-only, no aplica.
//  - `captureSeconds` fijo a 10 en v1 (multi-duración aplazada a v2).
//

import Foundation

nonisolated struct AppSettings: Codable, Sendable, Equatable {
    var volume: Float
    var autoPlay: Bool
    var lastStationId: String?
    var captureSeconds: Int
    var showNotifications: Bool
    var defaultCountryCode: String?
    var searchResultLimit: Int
    var musicOnlyFilter: Bool

    static let `default` = AppSettings(
        volume: 0.8,
        autoPlay: false,
        lastStationId: nil,
        captureSeconds: 10,
        showNotifications: true,
        defaultCountryCode: nil,
        searchResultLimit: 50,
        musicOnlyFilter: true
    )
}
