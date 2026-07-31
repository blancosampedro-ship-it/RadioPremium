//
//  IdentifiedTracksRepository.swift
//  RadioPremium
//
//  Persistencia de IdentifiedTrackHistory en disco.
//  Wrapper sobre JSONStore<[IdentifiedTrackHistory]> con API más explícita
//  para el dominio (load, append, clear) y orden cronológico inverso
//  (más reciente primero) en lectura.
//

import Foundation
import os

actor IdentifiedTracksRepository {
    private let store: JSONStore<[IdentifiedTrackHistory]>

    /// Tope del historial. Sin él crecía para siempre y el archivo entero se
    /// reescribía en cada append. Mismo patrón que RecentStationsStore.
    private let maxEntries = 1000

    /// Init estándar: persiste en Application Support/.../identified-tracks.json.
    init() throws {
        self.store = try JSONStore(filename: "identified-tracks", defaultValue: [])
    }

    /// Init para tests: pasa una URL custom (típicamente en tempDir).
    init(url: URL) {
        self.store = JSONStore(url: url, defaultValue: [])
    }

    /// Devuelve historial completo, más reciente primero.
    func load() async -> [IdentifiedTrackHistory] {
        let all = await store.load()
        return all.sorted { $0.identifiedAt > $1.identifiedAt }
    }

    /// Añade una entrada al historial. Persiste atómicamente.
    /// Si se supera `maxEntries`, se descartan las más antiguas.
    func append(_ entry: IdentifiedTrackHistory) async throws {
        var all = await store.load()
        all.append(entry)
        if all.count > maxEntries {
            all.sort { $0.identifiedAt < $1.identifiedAt }
            all.removeFirst(all.count - maxEntries)
        }
        try await store.save(all)
        AppLogger.identify.info("history append \(entry.track.title, privacy: .public) total=\(all.count, privacy: .public)")
    }

    /// Borra todo el historial.
    func clear() async {
        await store.reset()
        AppLogger.identify.info("history cleared")
    }
}
