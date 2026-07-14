//
//  RecentStationsStore.swift
//  RadioPremium
//
//  Fuente única de verdad para "última emisora" y "emisoras recientes".
//  La última emisora reproducida es simplemente la primera posición de la
//  lista — no existe un lastStationId separado (evita dos fuentes de verdad
//  que se desincronicen).
//
//  Reglas:
//  - Máximo 10 entradas, ordenadas por lastPlayedAt descendente.
//  - Sin duplicados (dedup por station.id: re-reproducir una emisora la
//    sube arriba con fecha nueva, no crea otra entrada).
//  - recordPlayed() registra COMO MÁXIMO UNA VEZ por playbackSessionID:
//    rebufferings, cambios de metadata ICY y reintentos internos de la
//    misma sesión no re-registran ni alteran el orden de la lista.
//  - Solo se registra cuando la reproducción llegó de verdad a .playing
//    (responsabilidad del caller — PlayerViewModel observa el estado).
//  - Solo local (sin iCloud) en esta versión.
//

import Foundation
import os

/// Entrada de emisora reciente persistida. Guarda la Station completa para
/// que la UI pueda renderizar (y re-reproducir) offline sin llamar a la API.
nonisolated struct RecentEntry: Codable, Sendable, Equatable {
    let station: Station
    let lastPlayedAt: Date
}

actor RecentStationsStore {

    static let maxEntries = 10

    private let store: JSONStore<[RecentEntry]>

    /// Última sesión de reproducción ya registrada. Garantiza la regla
    /// una-vez-por-sesión aunque el estado .playing se alcance varias veces
    /// (rebuffering → playing → rebuffering → playing…).
    private var lastRecordedSessionID: UUID?

    /// Init estándar: persiste en Application Support/.../recent-stations.json.
    init() throws {
        self.store = try JSONStore(filename: "recent-stations", defaultValue: [])
    }

    /// Init para tests: URL custom (típicamente tempDir).
    init(url: URL) {
        self.store = JSONStore(url: url, defaultValue: [])
    }

    /// Devuelve las recientes, más recientemente reproducida primero.
    func load() async -> [RecentEntry] {
        let all = await store.load()
        return all.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    /// La última emisora reproducida (primera posición), o nil si no hay.
    func lastPlayed() async -> Station? {
        await load().first?.station
    }

    /// Registra una reproducción real. Idempotente por sesión: si esta
    /// sessionID ya se registró, no hace nada (devuelve false).
    /// Deduplica por station.id: si la emisora ya estaba en la lista, la
    /// mueve arriba con fecha nueva.
    @discardableResult
    func recordPlayed(_ station: Station, sessionID: UUID) async throws -> Bool {
        guard sessionID != lastRecordedSessionID else { return false }
        lastRecordedSessionID = sessionID

        var all = await store.load()
        all.removeAll { $0.station.id == station.id }
        all.append(RecentEntry(station: station, lastPlayedAt: Date()))
        all.sort { $0.lastPlayedAt > $1.lastPlayedAt }
        if all.count > Self.maxEntries {
            all = Array(all.prefix(Self.maxEntries))
        }
        try await store.save(all)
        AppLogger.storage.info("recent recorded '\(station.name, privacy: .public)' total=\(all.count, privacy: .public)")
        return true
    }

    /// Elimina una emisora concreta de recientes. Idempotente.
    func remove(stationId: String) async throws {
        var all = await store.load()
        let before = all.count
        all.removeAll { $0.station.id == stationId }
        guard all.count != before else { return }
        try await store.save(all)
        AppLogger.storage.info("recent removed id=\(stationId, privacy: .public)")
    }

    /// Vacía todas las recientes. Idempotente.
    func clear() async {
        await store.reset()
        lastRecordedSessionID = nil
        AppLogger.storage.info("recents cleared")
    }
}
