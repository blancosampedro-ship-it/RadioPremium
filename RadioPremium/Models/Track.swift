//
//  Track.swift
//  RadioPremium
//
//  Canción identificada (resultado de ACRCloud). Modelo neutro:
//  AcrCloudClient lo construye parseando su respuesta específica;
//  SpotifyApiClient lo consume como entrada para search/add.
//

import Foundation

nonisolated struct Track: Codable, Sendable, Equatable, Hashable {
    let title: String
    let artist: String
    let album: String?
    let isrc: String?
    let artworkURL: URL?
    let durationMs: Int?
    let spotifyId: String?

    init(
        title: String,
        artist: String,
        album: String? = nil,
        isrc: String? = nil,
        artworkURL: URL? = nil,
        durationMs: Int? = nil,
        spotifyId: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isrc = isrc
        self.artworkURL = artworkURL
        self.durationMs = durationMs
        self.spotifyId = spotifyId
    }

    /// Texto compacto para mostrar en notificaciones y sheets.
    var displayText: String {
        "\(artist) — \(title)"
    }
}
