//
//  IdentifiedTrackHistory.swift
//  RadioPremium
//
//  Entrada del historial: track identificado + contexto de la emisora donde
//  estaba sonando + timestamp. Persiste en JSON en Application Support.
//
//  Conserva los datos básicos de la emisora (uuid, nombre, país, favicon)
//  en lugar de referenciar Station por id, para que el historial siga siendo
//  legible aunque la emisora desaparezca de Radio Browser más adelante.
//

import Foundation

nonisolated struct IdentifiedTrackHistory: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: UUID
    let track: Track
    let identifiedAt: Date
    let stationUuid: String?
    let stationName: String?
    let stationCountry: String?
    let stationFavicon: URL?

    init(
        id: UUID = UUID(),
        track: Track,
        identifiedAt: Date = Date(),
        stationUuid: String? = nil,
        stationName: String? = nil,
        stationCountry: String? = nil,
        stationFavicon: URL? = nil
    ) {
        self.id = id
        self.track = track
        self.identifiedAt = identifiedAt
        self.stationUuid = stationUuid
        self.stationName = stationName
        self.stationCountry = stationCountry
        self.stationFavicon = stationFavicon
    }

    /// Construye una entrada de historial a partir de un Track + Station opcional.
    static func from(track: Track, station: Station?, at date: Date = Date()) -> IdentifiedTrackHistory {
        IdentifiedTrackHistory(
            track: track,
            identifiedAt: date,
            stationUuid: station?.id,
            stationName: station?.name,
            stationCountry: station?.country,
            stationFavicon: station?.faviconURL
        )
    }
}
