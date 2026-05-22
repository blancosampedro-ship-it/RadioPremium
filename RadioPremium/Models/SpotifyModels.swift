//
//  SpotifyModels.swift
//  RadioPremium
//
//  Types Codable para la Spotify Web API. Solo los campos que usa la app —
//  ignoramos el resto del JSON (Spotify es generoso con metadatos, nosotros
//  conservadores con lo que parseamos).
//
//  https://developer.spotify.com/documentation/web-api
//

import Foundation

// MARK: - Auth tokens

nonisolated struct SpotifyTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresAt: Date
    var scope: String

    var isExpired: Bool {
        // Margen de 30 segundos para evitar usar un token a punto de morir.
        Date().addingTimeInterval(30) >= expiresAt
    }

    var grantedScopes: [String] {
        scope.split(separator: " ").map(String.init)
    }

    func hasScopes(_ required: [String]) -> Bool {
        // Spotify a veces omite `scope` en respuestas de refresh — si no lo
        // sabemos, dejamos que el endpoint sea la fuente de verdad (devolverá 403).
        if scope.isEmpty { return true }
        let granted = Set(grantedScopes)
        return required.allSatisfy { granted.contains($0) }
    }
}

// MARK: - User

nonisolated struct SpotifyUser: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    let email: String?
    let country: String?
    let product: String?      // "premium" / "free"
    let uri: String?
    let images: [SpotifyImage]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case email
        case country
        case product
        case uri
        case images
    }
}

// MARK: - Track / Artist / Album / Image

nonisolated struct SpotifyTrack: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?
    let uri: String                 // "spotify:track:{id}"
    let externalIds: SpotifyExternalIds?
    let durationMs: Int?
    let isExplicit: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case album
        case uri
        case externalIds = "external_ids"
        case durationMs = "duration_ms"
        case isExplicit = "explicit"
    }

    var primaryArtist: String {
        artists.first?.name ?? "Unknown"
    }
}

nonisolated struct SpotifyArtist: Codable, Sendable, Equatable, Identifiable {
    let id: String?
    let name: String
    let uri: String?
}

nonisolated struct SpotifyAlbum: Codable, Sendable, Equatable, Identifiable {
    let id: String?
    let name: String
    let images: [SpotifyImage]?
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case images
        case releaseDate = "release_date"
    }
}

nonisolated struct SpotifyImage: Codable, Sendable, Equatable {
    let url: String
    let width: Int?
    let height: Int?
}

nonisolated struct SpotifyExternalIds: Codable, Sendable, Equatable {
    let isrc: String?
    let upc: String?
}

// MARK: - Playlist

nonisolated struct SpotifyPlaylist: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let isPublic: Bool?
    let collaborative: Bool?
    let owner: SpotifyPlaylistOwner?
    let tracks: SpotifyPlaylistTracksRef?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case isPublic = "public"
        case collaborative
        case owner
        case tracks
        case uri
    }
}

nonisolated struct SpotifyPlaylistOwner: Codable, Sendable, Equatable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

nonisolated struct SpotifyPlaylistTracksRef: Codable, Sendable, Equatable {
    let total: Int
    let href: String?
}

// MARK: - Paginated responses

nonisolated struct SpotifyPaging<T: Codable & Sendable>: Codable, Sendable {
    let items: [T]
    let total: Int?
    let limit: Int?
    let offset: Int?
    let next: String?
    let previous: String?
}

// MARK: - Search response

nonisolated struct SpotifySearchResponse: Codable, Sendable {
    let tracks: SpotifyPaging<SpotifyTrack>?
}

// MARK: - Add to playlist response

nonisolated struct SpotifyAddTracksResponse: Codable, Sendable {
    let snapshotId: String

    enum CodingKeys: String, CodingKey {
        case snapshotId = "snapshot_id"
    }
}

// MARK: - Playlist track item (paged result of /playlists/{id}/tracks)

nonisolated struct SpotifyPlaylistTrackItem: Codable, Sendable {
    let track: SpotifyTrack?
}

// MARK: - Constants

enum SpotifyConstants {
    /// Nombre de la playlist a la que añadimos canciones identificadas.
    /// Coincide con el de la app Windows para que coexistan ambas.
    static let radioLikesPlaylistName = "Radio Likes"
    static let radioLikesPlaylistDescription = "Canciones identificadas desde Radio Premium"

    /// Scopes solicitados al usuario en el OAuth flow.
    static let requiredScopes = [
        "user-read-private",
        "user-read-email",
        "playlist-modify-public",
        "playlist-modify-private",
        "playlist-read-private"
    ]

    /// Feature flag: si la integración con Spotify está expuesta en UI.
    /// Está bloqueada por la política Spotify Development Mode (Nov 2024)
    /// que rechaza endpoints de escritura hasta pasar Extended Quota review.
    /// Mientras tanto el botón se oculta — el código sigue compilándose para
    /// cuando se reactive sin tocar nada más que este flag.
    static let isUIEnabled = true
}
