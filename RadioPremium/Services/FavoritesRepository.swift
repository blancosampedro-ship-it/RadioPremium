//
//  FavoritesRepository.swift
//  RadioPremium
//
//  Persistencia de emisoras favoritas en disco.
//  Wrapper sobre JSONStore<[FavoriteEntry]> con API explícita para el dominio
//  (toggle, isFavorite, load, remove). Orden de lectura: las añadidas más
//  recientemente aparecen primero — coincide con la expectativa del usuario
//  de "lo último que marqué está arriba".
//
//  La struct guardada es FavoriteEntry, que envuelve la Station con un
//  timestamp `addedAt`. Así el orden cronológico no depende de la posición
//  en el array (más robusto frente a reescrituras).
//

import Foundation
import os

/// Entrada de favorito persistida. Contiene la Station completa para que
/// la UI pueda renderizarla offline sin volver a llamar a Radio Browser.
nonisolated struct FavoriteEntry: Codable, Sendable, Equatable {
    let station: Station
    let addedAt: Date
}

actor FavoritesRepository {
    private let store: JSONStore<[FavoriteEntry]>

    /// Init estándar: persiste en Application Support/.../favorites.json.
    init() throws {
        self.store = try JSONStore(filename: "favorites", defaultValue: [])
    }

    /// Init para tests: pasa una URL custom (típicamente en tempDir).
    init(url: URL) {
        self.store = JSONStore(url: url, defaultValue: [])
    }

    /// Devuelve los favoritos, más recientemente añadido primero.
    func load() async -> [FavoriteEntry] {
        let all = await store.load()
        return all.sorted { $0.addedAt > $1.addedAt }
    }

    /// `true` si la emisora está marcada como favorita.
    func isFavorite(stationId: String) async -> Bool {
        let all = await store.load()
        return all.contains { $0.station.id == stationId }
    }

    /// Añade la emisora si no estaba. Idempotente: si ya existe, no duplica.
    /// Devuelve `true` si añadió, `false` si ya estaba.
    @discardableResult
    func add(_ station: Station) async throws -> Bool {
        var all = await store.load()
        if all.contains(where: { $0.station.id == station.id }) {
            return false
        }
        all.append(FavoriteEntry(station: station, addedAt: Date()))
        try await store.save(all)
        AppLogger.storage.info("favorite added '\(station.name, privacy: .public)' total=\(all.count, privacy: .public)")
        return true
    }

    /// Quita la emisora. Idempotente: si no existe, no hace nada.
    /// Devuelve `true` si quitó, `false` si no estaba.
    @discardableResult
    func remove(stationId: String) async throws -> Bool {
        var all = await store.load()
        let before = all.count
        all.removeAll { $0.station.id == stationId }
        if all.count == before {
            return false
        }
        try await store.save(all)
        AppLogger.storage.info("favorite removed id=\(stationId, privacy: .public) total=\(all.count, privacy: .public)")
        return true
    }

    /// Toggle: si está, quita; si no, añade. Devuelve el estado final
    /// (`true` = ahora favorito, `false` = ahora no favorito).
    @discardableResult
    func toggle(_ station: Station) async throws -> Bool {
        if await isFavorite(stationId: station.id) {
            try await remove(stationId: station.id)
            return false
        } else {
            try await add(station)
            return true
        }
    }

    /// Borra todos los favoritos. Idempotente.
    func clear() async {
        await store.reset()
        AppLogger.storage.info("favorites cleared")
    }
}
