//
//  AppleMusicClient.swift
//  RadioPremium
//
//  Wrapper sobre MusicKit + Apple Music REST API.
//
//  Por qué REST y no MusicLibrary.shared:
//    `MusicLibrary.shared.createPlaylist(...)` y `add(_:to:)` están marcadas
//    iOS-only (también iPadOS y Mac Catalyst, pero NO macOS nativo).
//    Para crear y modificar playlists desde una app macOS hay que pegarle
//    directo a https://api.music.apple.com vía `MusicDataPostRequest`, que
//    sí funciona en macOS 12+. MusicKit inyecta los headers de auth
//    (developer token + user token) automáticamente.
//
//  Para search seguimos usando MusicCatalog... requests porque son tipados
//  y funcionan perfectamente en macOS.
//
//  Endpoints REST usados:
//    GET  /v1/me/library/playlists?limit=100
//    POST /v1/me/library/playlists                              (crear)
//    GET  /v1/me/library/playlists/{id}/tracks?limit=100        (dedupe)
//    POST /v1/me/library/playlists/{id}/tracks                  (añadir)
//

import Foundation
import MusicKit
import os

actor AppleMusicClient {

    private let apiBase = URL(string: "https://api.music.apple.com")!
    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    init() {}

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> MusicAuthorization.Status {
        let current = MusicAuthorization.currentStatus
        if current == .authorized { return .authorized }
        let result = await MusicAuthorization.request()
        AppLogger.appleMusic.info("authorization status=\(String(describing: result), privacy: .public)")
        return result
    }

    func currentAuthorizationStatus() -> MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    func isAuthorized() -> Bool {
        MusicAuthorization.currentStatus == .authorized
    }

    // MARK: - Catalog search (MusicKit, tipado)

    func findSongByISRC(_ isrc: String) async throws -> Song? {
        var request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
        request.limit = 1
        let response = try await request.response()
        return response.items.first
    }

    func findSong(title: String, artist: String) async throws -> Song? {
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "")
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let term = "\(cleanTitle) \(cleanArtist)"
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 5
        let response = try await request.response()
        return response.songs.first
    }

    // MARK: - Library playlists (REST)

    /// Lista las playlists de la biblioteca del usuario.
    func userLibraryPlaylists() async throws -> [LibraryPlaylist] {
        let url = apiBase.appendingPathComponent("/v1/me/library/playlists")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "100")])
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        let request = MusicDataRequest(urlRequest: urlRequest)
        let response = try await request.response()
        let body: LibraryPlaylistsResponse = try jsonDecoder.decode(LibraryPlaylistsResponse.self, from: response.data)
        return body.data
    }

    /// Busca o crea la playlist "Radio Likes". Si la crea, devuelve la nueva.
    func findOrCreateRadioLikesPlaylist() async throws -> LibraryPlaylist {
        let target = SpotifyConstants.radioLikesPlaylistName
        let existing = try await userLibraryPlaylists()
        if let match = existing.first(where: {
            $0.attributes.name.caseInsensitiveCompare(target) == .orderedSame
        }) {
            AppLogger.appleMusic.debug("found existing playlist '\(target, privacy: .public)' id=\(match.id, privacy: .public)")
            return match
        }

        AppLogger.appleMusic.info("creating playlist '\(target, privacy: .public)' in library")
        let body = CreatePlaylistRequest(
            attributes: .init(
                name: target,
                description: SpotifyConstants.radioLikesPlaylistDescription
            )
        )
        let data = try JSONEncoder().encode(body)
        let url = apiBase.appendingPathComponent("/v1/me/library/playlists")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = data
        let request = MusicDataRequest(urlRequest: urlRequest)
        let response = try await request.response()
        let decoded = try jsonDecoder.decode(LibraryPlaylistsResponse.self, from: response.data)
        guard let created = decoded.data.first else {
            throw RadioPremiumError.appleMusicFailed(reason: "Apple Music no devolvió la playlist creada")
        }
        return created
    }

    /// Devuelve los IDs de catálogo de los songs ya en la playlist (hasta 100).
    /// Apple Music devuelve cada track con `attributes.playParams.catalogId`
    /// (referencia al song original del catálogo).
    func catalogIdsInPlaylist(_ playlistId: String) async throws -> Set<String> {
        let url = apiBase.appendingPathComponent("/v1/me/library/playlists/\(playlistId)/tracks")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "100")])
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        let request = MusicDataRequest(urlRequest: urlRequest)
        do {
            let response = try await request.response()
            let body = try jsonDecoder.decode(LibraryTracksResponse.self, from: response.data)
            let ids = body.data.compactMap { $0.attributes.playParams?.catalogId }
            return Set(ids)
        } catch {
            // Si la playlist está vacía Apple devuelve 404. Tratamos como conjunto vacío.
            if case let urlError as URLError = error, urlError.code.rawValue == 404 {
                return []
            }
            // MusicKit envuelve 404 en su propio error; comprobamos por descripción.
            let desc = "\(error)".lowercased()
            if desc.contains("404") || desc.contains("not found") {
                return []
            }
            throw error
        }
    }

    /// Añade un song (id catálogo) a la playlist.
    func addCatalogSong(_ songId: String, toPlaylist playlistId: String) async throws {
        let body = AddTracksRequest(data: [.init(id: songId, type: "songs")])
        let data = try JSONEncoder().encode(body)
        let url = apiBase.appendingPathComponent("/v1/me/library/playlists/\(playlistId)/tracks")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = data
        let request = MusicDataRequest(urlRequest: urlRequest)
        _ = try await request.response()
    }

    // MARK: - High-level helper

    /// Flujo completo: autoriza → encuentra song (ISRC primero, fallback
    /// title+artist) → encuentra/crea playlist "Radio Likes" → dedupe → añade.
    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome {
        let status = await requestAuthorization()
        guard status == .authorized else {
            switch status {
            case .denied, .restricted:
                throw RadioPremiumError.appleMusicAuthDenied
            default:
                throw RadioPremiumError.appleMusicAuthRequired
            }
        }

        // 1. Search.
        var song: Song?
        do {
            if let isrc = track.isrc, !isrc.isEmpty {
                song = try await findSongByISRC(isrc)
            }
            if song == nil {
                song = try await findSong(title: track.title, artist: track.artist)
            }
        } catch {
            AppLogger.appleMusic.error("search failed: \(error.localizedDescription, privacy: .public)")
            throw RadioPremiumError.appleMusicFailed(reason: error.localizedDescription)
        }

        guard let s = song else {
            throw RadioPremiumError.appleMusicTrackNotFound(query: track.displayText)
        }

        let songId = s.id.rawValue

        // 2. Find/create playlist + dedupe + add.
        do {
            let playlist = try await findOrCreateRadioLikesPlaylist()
            let existingIds = try await catalogIdsInPlaylist(playlist.id)
            if existingIds.contains(songId) {
                AppLogger.appleMusic.info("song \(songId, privacy: .public) ya en playlist, skip add")
                return .alreadyPresent
            }
            try await addCatalogSong(songId, toPlaylist: playlist.id)
            AppLogger.appleMusic.info("added \(songId, privacy: .public) to playlist \(playlist.id, privacy: .public)")
            return .added
        } catch {
            let desc = error.localizedDescription.lowercased()
            if desc.contains("subscription") || desc.contains("suscripción") {
                throw RadioPremiumError.appleMusicSubscriptionRequired
            }
            AppLogger.appleMusic.error("playlist op failed: \(error.localizedDescription, privacy: .public)")
            throw RadioPremiumError.appleMusicFailed(reason: error.localizedDescription)
        }
    }
}

// MARK: - REST DTOs

/// Playlist de la biblioteca devuelta por la Apple Music API.
struct LibraryPlaylist: Decodable, Sendable {
    let id: String
    let type: String
    let attributes: Attributes

    struct Attributes: Decodable, Sendable {
        let name: String
        let canEdit: Bool?
    }
}

private struct LibraryPlaylistsResponse: Decodable, Sendable {
    let data: [LibraryPlaylist]
}

private struct LibraryTracksResponse: Decodable, Sendable {
    let data: [LibraryTrack]

    struct LibraryTrack: Decodable, Sendable {
        let id: String
        let type: String
        let attributes: Attributes

        struct Attributes: Decodable, Sendable {
            let name: String?
            let playParams: PlayParams?
        }

        struct PlayParams: Decodable, Sendable {
            /// ID del song en el catálogo de Apple Music. Cuando una pista
            /// de la biblioteca proviene de un add desde catálogo, este campo
            /// referencia el song original — lo usamos para dedupe.
            let catalogId: String?

            enum CodingKeys: String, CodingKey {
                case catalogId
            }
        }
    }
}

private struct CreatePlaylistRequest: Encodable, Sendable {
    let attributes: Attributes

    struct Attributes: Encodable, Sendable {
        let name: String
        let description: String
    }
}

private struct AddTracksRequest: Encodable, Sendable {
    let data: [Item]

    struct Item: Encodable, Sendable {
        let id: String
        let type: String
    }
}
