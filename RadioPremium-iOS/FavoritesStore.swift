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
        do {
            stations = try JSONDecoder().decode([Station].self, from: data)
            log.info("loaded \(self.stations.count) favorites from local mirror")
        } catch {
            log.error("local favorites decode failed: \(error.localizedDescription, privacy: .public)")
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
        do {
            let remote = try JSONDecoder().decode([Station].self, from: data)
            log.info("iCloud tiene \(remote.count) favoritos, mergeando")
            stations = remote
            persistLocal()
        } catch {
            log.error("iCloud favorites decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeIcloudChanges() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.log.info("iCloud changed externally → re-mergeando")
                self?.mergeIcloud(initial: false)
            }
        }
    }
}
