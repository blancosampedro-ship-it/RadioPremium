//
//  FavoritesStore.swift
//  RadioPremium-iOS
//
//  Persiste favoritos con sincronización iCloud entre Mac y iPhone via
//  NSUbiquitousKeyValueStore. Local UserDefaults se usa como caché instantánea
//  (escritura rápida + funcionar offline). iCloud es la fuente de verdad
//  para sincronización cross-device.
//
//  Convivencia con app macOS: ambas declaran el mismo ubiquity-kvstore-identifier
//  en sus entitlements (`com.blancosampedro.RadioPremium`) y guardan bajo la
//  misma clave `RadioPremium.favorites.v1`.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class FavoritesStore {

    /// Clave dentro del KV store iCloud. Compartida con la app macOS.
    private let kvKey = "RadioPremium.favorites.v1"
    /// Clave local de UserDefaults (caché instantánea).
    private let localKey = "RadioPremium.iOS.favorites.v1.local-mirror"

    private let kv = NSUbiquitousKeyValueStore.default
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "favorites")

    private(set) var stations: [Station] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadLocal()
        observeIcloudChanges()
        // Pide a iCloud que sincronice. Si hay datos remotos los recibiremos
        // vía notification didChangeExternally en breve.
        kv.synchronize()
        mergeIcloud(initial: true)
    }

    // MARK: - Queries

    func isFavorite(_ stationId: String) -> Bool {
        stations.contains { $0.id == stationId }
    }

    // MARK: - Mutations

    func toggle(_ station: Station) {
        if let idx = stations.firstIndex(where: { $0.id == station.id }) {
            stations.remove(at: idx)
            log.info("removed favorite \(station.name, privacy: .public)")
        } else {
            stations.append(station)
            log.info("added favorite \(station.name, privacy: .public)")
        }
        persistEverywhere()
    }

    func remove(_ station: Station) {
        stations.removeAll { $0.id == station.id }
        persistEverywhere()
    }

    // MARK: - Local persistence

    private func loadLocal() {
        guard let data = defaults.data(forKey: localKey) else { return }
        if let decoded = Self.decodeStationsTolerant(data) {
            stations = decoded
            log.info("loaded \(self.stations.count) favorites from local mirror")
        } else {
            log.error("local favorites decode failed (payload ilegible)")
            stations = []
        }
    }

    private func persistLocal() {
        do {
            let data = try JSONEncoder().encode(stations)
            defaults.set(data, forKey: localKey)
        } catch {
            log.error("local favorites encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - iCloud persistence

    private func persistIcloud() {
        do {
            let data = try JSONEncoder().encode(stations)
            kv.set(data, forKey: kvKey)
            kv.synchronize()
            log.debug("pushed \(self.stations.count) favorites to iCloud")
        } catch {
            log.error("icloud favorites encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistEverywhere() {
        persistLocal()
        persistIcloud()
    }

    /// Mezcla los favoritos de iCloud con los locales.
    /// - En arranque inicial: iCloud gana si tiene datos; si está vacío y hay
    ///   datos locales (escenario raro en iPhone, normal en Mac), pushea locales.
    /// - En notificación didChangeExternally: iCloud gana siempre.
    private func mergeIcloud(initial: Bool) {
        guard let data = kv.data(forKey: kvKey) else {
            if initial && !stations.isEmpty {
                log.info("iCloud vacío, pushing \(self.stations.count) locales")
                persistIcloud()
            }
            return
        }
        if let remote = Self.decodeStationsTolerant(data) {
            log.info("iCloud tiene \(remote.count) favoritos, mergeando")
            stations = remote
            persistLocal()
        } else {
            log.error("iCloud favorites decode failed (payload ilegible) — conservando lo local")
        }
    }

    /// Decodifica el array de Stations descartando las entradas que no
    /// decodifican, en vez de invalidar el array completo.
    ///
    /// Crítico para el interop con macOS: la Station de macOS codifica
    /// `url_resolved` con encodeIfPresent (puede faltar), y la de iOS lo exige.
    /// Con el decode estricto, UN solo favorito sin stream URL guardado desde
    /// el Mac rompía TODOS los favoritos del iPhone en silencio, y el sync
    /// quedaba muerto mientras esa entrada existiera. Mismo patrón PartialList
    /// que ya usa RadioBrowserAPI.
    /// Devuelve nil solo si el payload ni siquiera es un array JSON.
    private static func decodeStationsTolerant(_ data: Data) -> [Station]? {
        struct PartialList: Decodable {
            let stations: [Station]
            let skipped: Int
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var result: [Station] = []
                var failures = 0
                while !container.isAtEnd {
                    if let station = try? container.decode(Station.self) {
                        result.append(station)
                    } else {
                        _ = try? container.decode(EmptyDecodable.self)
                        failures += 1
                    }
                }
                self.stations = result
                self.skipped = failures
            }
        }
        struct EmptyDecodable: Decodable {}

        guard let list = try? JSONDecoder().decode(PartialList.self, from: data) else {
            return nil
        }
        if list.skipped > 0 {
            Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "favorites")
                .warning("favoritos: \(list.skipped) entradas ilegibles descartadas (¿guardadas por otra versión?)")
        }
        return list.stations
    }

    private func observeIcloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] note in
            // Una violación de cuota (1 MB de iCloud KV) también llega por esta
            // notificación; sin mirar el reason se confundía con un cambio
            // remoto normal y el push rechazado pasaba desapercibido.
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor in
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    self?.log.error("iCloud KV: cuota superada — el push de favoritos fue rechazado")
                }
                self?.log.info("iCloud changed externally → re-mergeando")
                self?.mergeIcloud(initial: false)
            }
        }
    }
}
