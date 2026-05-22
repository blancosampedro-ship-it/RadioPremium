//
//  SpotifyApiClient.swift
//  RadioPremium
//
//  Cliente Web API de Spotify. Compone HTTPClient + auto-añade Bearer token
//  consultando SpotifyAuthClient. Mapea 401 a refresh-and-retry una vez.
//
//  Endpoints implementados (los necesarios para identify → add to playlist):
//    GET  /v1/me
//    GET  /v1/search?q=isrc:X&type=track
//    GET  /v1/search?q=track:X+artist:Y&type=track
//    GET  /v1/me/playlists
//    POST /v1/users/{id}/playlists
//    GET  /v1/playlists/{id}/tracks
//    POST /v1/playlists/{id}/tracks
//

import Foundation
import os

actor SpotifyApiClient {
    private let http: HTTPClient
    private let auth: SpotifyAuthClient
    private let baseURL = URL(string: "https://api.spotify.com")!

    init(http: HTTPClient, auth: SpotifyAuthClient) {
        self.http = http
        self.auth = auth
    }

    /// Init de conveniencia: construye un SpotifyAuthClient default.
    init(http: HTTPClient = HTTPClient()) {
        self.http = http
        self.auth = SpotifyAuthClient(http: http)
    }

    // MARK: - User

    func currentUser() async throws -> SpotifyUser {
        try await authedGet("/v1/me")
    }

    // MARK: - Search

    /// Búsqueda exacta por ISRC (International Standard Recording Code).
    /// Es la forma más fiable cuando ACRCloud nos da el ISRC.
    func findTrackByISRC(_ isrc: String) async throws -> SpotifyTrack? {
        let query = "isrc:\(isrc)"
        let url = try buildSearchURL(query: query, limit: 1)
        let response: SpotifySearchResponse = try await authedGetURL(url)
        return response.tracks?.items.first
    }

    /// Búsqueda por título y artista. Fallback cuando no hay ISRC o no matchea.
    /// Filtros explícitos `track:` y `artist:` mejoran precisión vs texto libre.
    /// Confiamos en el ranking de Spotify y devolvemos el primer resultado.
    func findTrack(title: String, artist: String) async throws -> SpotifyTrack? {
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "")
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let query = "track:\(cleanTitle) artist:\(cleanArtist)"
        let url = try buildSearchURL(query: query, limit: 5)
        let response: SpotifySearchResponse = try await authedGetURL(url)
        return response.tracks?.items.first
    }

    // MARK: - Playlists

    func userPlaylists() async throws -> [SpotifyPlaylist] {
        let response: SpotifyPaging<SpotifyPlaylist> = try await authedGet("/v1/me/playlists?limit=50")
        return response.items
    }

    /// Busca la playlist con el nombre dado. Si no existe, la crea (privada).
    /// Coincide con el comportamiento de la app Windows.
    func findOrCreatePlaylist(named name: String) async throws -> SpotifyPlaylist {
        let existing = try await userPlaylists()
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }

        // No existe — crear.
        let user = try await currentUser()
        let url = baseURL.appendingPathComponent("/v1/users/\(user.id)/playlists")
        // OJO: solo mandamos name/description/public. NO incluir `collaborative`.
        // La app Windows que funciona manda exactamente estos 3 campos. Añadir
        // `collaborative: false` provoca 403 Forbidden en cuentas dev/free aunque
        // la doc oficial lo permita.
        let body = CreatePlaylistRequest(
            name: name,
            description: SpotifyConstants.radioLikesPlaylistDescription,
            isPublic: false
        )

        let token = try await auth.getValidAccessToken()
        let playlist: SpotifyPlaylist = try await http.post(
            url,
            body: body,
            headers: ["Authorization": "Bearer \(token)"]
        )
        AppLogger.spotify.info("created playlist '\(name, privacy: .public)' id=\(playlist.id, privacy: .public)")
        return playlist
    }

    // MARK: - Tracks in playlist

    /// Devuelve los URIs de los tracks ya en la playlist (hasta 100 primeros).
    /// Útil para dedup antes de añadir.
    func trackUrisInPlaylist(_ playlistId: String) async throws -> Set<String> {
        let response: SpotifyPaging<SpotifyPlaylistTrackItem> = try await authedGet(
            "/v1/playlists/\(playlistId)/tracks?limit=100"
        )
        let uris = response.items.compactMap { $0.track?.uri }
        return Set(uris)
    }

    /// Añade un track a la playlist. Si ya está, no duplica (devuelve `.alreadyPresent`).
    func addTrackToPlaylist(playlistId: String, trackUri: String) async throws -> SpotifyAddOutcome {
        let existing = try await trackUrisInPlaylist(playlistId)
        if existing.contains(trackUri) {
            AppLogger.spotify.info("track \(trackUri, privacy: .public) ya en playlist, skip add")
            return .alreadyPresent
        }

        let url = baseURL.appendingPathComponent("/v1/playlists/\(playlistId)/tracks")
        let body = AddTracksRequest(uris: [trackUri])

        let token = try await auth.getValidAccessToken()
        let _: SpotifyAddTracksResponse = try await http.post(
            url,
            body: body,
            headers: ["Authorization": "Bearer \(token)"]
        )
        AppLogger.spotify.info("added \(trackUri, privacy: .public) to playlist \(playlistId, privacy: .public)")
        return .added
    }

    // MARK: - High-level helper

    /// Encuentra el URI del track en Spotify (ISRC primero, fallback
    /// title+artist) **sin tocar ninguna playlist**. Pensado para el flujo
    /// "Abrir en Spotify" — solo usa el endpoint de búsqueda (/v1/search),
    /// que sigue funcionando en Development Mode de Spotify donde las
    /// escrituras y lecturas de playlists privadas devuelven 403.
    ///
    /// Devuelve URIs estilo `spotify:track:XXXX`. Lanza `.spotifyTrackNotFound`
    /// si Spotify no encuentra match ni por ISRC ni por título+artista.
    func findTrackUri(for track: Track) async throws -> String {
        var spotifyTrack: SpotifyTrack?
        if let isrc = track.isrc, !isrc.isEmpty {
            spotifyTrack = try await findTrackByISRC(isrc)
        }
        if spotifyTrack == nil {
            spotifyTrack = try await findTrack(title: track.title, artist: track.artist)
        }
        guard let st = spotifyTrack else {
            throw RadioPremiumError.spotifyTrackNotFound(query: track.displayText)
        }
        return st.uri
    }

    /// Flujo completo: encuentra el track en Spotify (ISRC primero, fallback
    /// title+artist), busca/crea la playlist "Radio Likes", añade el track.
    /// Lanza `.spotifyTrackNotFound` si no existe en Spotify.
    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome {
        var spotifyTrack: SpotifyTrack?
        if let isrc = track.isrc, !isrc.isEmpty {
            spotifyTrack = try await findTrackByISRC(isrc)
        }
        if spotifyTrack == nil {
            spotifyTrack = try await findTrack(title: track.title, artist: track.artist)
        }
        guard let st = spotifyTrack else {
            throw RadioPremiumError.spotifyTrackNotFound(query: track.displayText)
        }

        let playlist = try await findOrCreatePlaylist(named: SpotifyConstants.radioLikesPlaylistName)
        return try await addTrackToPlaylist(playlistId: playlist.id, trackUri: st.uri)
    }

    // MARK: - Internals

    private func buildSearchURL(query: String, limit: Int) throws -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("/v1/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            throw RadioPremiumError.invalidConfiguration(missing: "Spotify search URL")
        }
        return url
    }

    /// GET con Bearer token + retry-on-401 (refresh + retry una vez).
    /// Acepta paths con query string ej. "/v1/me/playlists?limit=50".
    private func authedGet<T: Decodable>(_ pathWithQuery: String) async throws -> T {
        let url = try makeURL(pathWithQuery: pathWithQuery)
        return try await authedGetURL(url)
    }

    /// Construye URL absoluta a partir de baseURL + path (con query opcional).
    /// NO usa `appendingPathComponent` porque eso URL-encoda el `?` (genera
    /// `%3F` y rompe la query). En su lugar, parsea como URL relativa.
    private func makeURL(pathWithQuery: String) throws -> URL {
        guard let url = URL(string: pathWithQuery, relativeTo: baseURL)?.absoluteURL else {
            throw RadioPremiumError.invalidConfiguration(missing: "Spotify URL para '\(pathWithQuery)'")
        }
        return url
    }

    private func authedGetURL<T: Decodable>(_ url: URL) async throws -> T {
        let token = try await auth.getValidAccessToken()
        do {
            return try await http.get(url, headers: ["Authorization": "Bearer \(token)"])
        } catch RadioPremiumError.httpStatus(401, _) {
            // Token quizá rechazado (revocado / cambio scope). Forzar refresh + 1 retry.
            AppLogger.spotify.warning("401 from Spotify, forcing token refresh + retry")
            let fresh = try await auth.getValidAccessToken()
            return try await http.get(url, headers: ["Authorization": "Bearer \(fresh)"])
        }
    }
}

// MARK: - Public outcome enum

/// Resultado de añadir un track a una playlist. Top-level para que ViewModels
/// y stubs lo referencien sin tocar el actor SpotifyApiClient.
enum SpotifyAddOutcome: Sendable, Equatable {
    case added
    case alreadyPresent
}

// MARK: - Internal request DTOs

private struct CreatePlaylistRequest: Codable, Sendable {
    let name: String
    let description: String
    let isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case isPublic = "public"
    }
}

private struct AddTracksRequest: Codable, Sendable {
    let uris: [String]
}
