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

    /// Clave compartida con la app iOS hermana dentro de NSUbiquitousKeyValueStore.
    private let kvKey = "RadioPremium.favorites.v1"
    /// `nil` cuando los tests inyectan una URL custom — en ese caso no
    /// sincronizamos con iCloud (las pruebas no necesitan red).
    private let kvStore: NSUbiquitousKeyValueStore?

    /// Init estándar: persiste en Application Support/.../favorites.json
    /// y mantiene espejo en iCloud KV para sync con iPhone.
    init() throws {
        self.store = try JSONStore(filename: "favorites", defaultValue: [])
        self.kvStore = NSUbiquitousKeyValueStore.default
    }

    /// Init para tests: pasa una URL custom (típicamente en tempDir).
    /// No usa iCloud.
    init(url: URL) {
        self.store = JSONStore(url: url, defaultValue: [])
        self.kvStore = nil
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
        pushToIcloud(stations: all.map { $0.station })
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
        pushToIcloud(stations: all.map { $0.station })
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
        pushToIcloud(stations: [])
        AppLogger.storage.info("favorites cleared")
    }

    // MARK: - iCloud sync

    /// Lee de iCloud KV y aplica el resultado al store local.
    /// Llamar en arranque y cuando llegue notificación didChangeExternally.
    /// Estrategia: iCloud gana si tiene datos. Si iCloud está vacío y nosotros
    /// tenemos favoritos locales, pusheamos para sembrar (típico primer arranque).
    func syncWithIcloud() async {
        guard let kv = kvStore else { return }
        // El KV store puede no haber tirado de iCloud aún. `synchronize()` no
        // es síncrono pero al menos solicita el pull.
        kv.synchronize()

        if let data = kv.data(forKey: kvKey) {
            do {
                let remoteStations = try JSONDecoder().decode([Station].self, from: data)
                AppLogger.storage.info("iCloud has \(remoteStations.count, privacy: .public) favorites — merging")
                await applyIcloudStations(remoteStations)
            } catch {
                // iCloud TIENE datos pero no los entendemos (blob corrupto o
                // formato de una versión futura de la app). Antes esto caía en
                // la rama "vacío" y PUSHEÁBAMOS lo local, machacando el remoto
                // y propagando la pérdida al resto de dispositivos. Ahora: log
                // y no tocar nada (igual que hace la versión iOS).
                AppLogger.storage.error(
                    "iCloud favorites decode failed: \(error.localizedDescription, privacy: .public) — conservando el remoto intacto"
                )
            }
        } else {
            // iCloud vacío de verdad: pusheamos lo que tengamos local (primera vez).
            let all = await store.load()
            if !all.isEmpty {
                AppLogger.storage.info("iCloud empty, seeding with \(all.count, privacy: .public) local favorites")
                pushToIcloud(stations: all.map { $0.station })
            }
        }
    }

    /// Reemplaza el contenido local con el array de Stations recibido de iCloud.
    /// Para Stations nuevas (que no estaban antes), asignamos `addedAt = Date()`.
    /// Para Stations que se mantienen, conservamos su addedAt original.
    private func applyIcloudStations(_ remote: [Station]) async {
        let current = await store.load()
        let now = Date()
        var merged: [FavoriteEntry] = []
        for station in remote {
            if let existing = current.first(where: { $0.station.id == station.id }) {
                merged.append(FavoriteEntry(station: station, addedAt: existing.addedAt))
            } else {
                merged.append(FavoriteEntry(station: station, addedAt: now))
            }
        }
        do {
            try await store.save(merged)
        } catch {
            // Único punto del archivo que tragaba el error sin log.
            AppLogger.storage.error(
                "saving merged iCloud favorites failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Pushea el array de Stations a iCloud KV (drop addedAt — iCloud solo guarda
    /// el set de favoritos, no metadata local).
    private func pushToIcloud(stations: [Station]) {
        guard let kv = kvStore else { return }
        do {
            let data = try JSONEncoder().encode(stations)
            kv.set(data, forKey: kvKey)
            kv.synchronize()
            AppLogger.storage.debug("pushed \(stations.count, privacy: .public) favorites to iCloud")
        } catch {
            AppLogger.storage.error("iCloud push failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
