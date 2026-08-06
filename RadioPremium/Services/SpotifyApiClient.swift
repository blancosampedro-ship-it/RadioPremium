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

    // MARK: - Lookup directo por ID

    /// Trae un track por su ID de catálogo. Devuelve `nil` si Spotify no lo
    /// conoce (404). Usado para confirmar el ID que nos da ACRCloud.
    func trackById(_ id: String) async throws -> SpotifyTrack? {
        let url = try makeURL(pathWithQuery: "/v1/tracks/\(id)")
        do {
            let track: SpotifyTrack = try await authedGetURL(url)
            return track
        } catch RadioPremiumError.httpStatus(404, _) {
            return nil
        }
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

    /// Búsqueda por título y artista con filtros de campo.
    ///
    /// Los valores van ENTRECOMILLADOS a propósito: en la sintaxis de Spotify
    /// un filtro sin comillas solo captura la palabra siguiente, así que
    /// `track:Sing It Back artist:Kevin McKay` preguntaba en realidad por una
    /// canción llamada "Sing" de un artista llamado "Kevin".
    func findTrack(title: String, artist: String) async throws -> SpotifyTrack? {
        let cleanTitle = Self.sanitize(title)
        let cleanArtist = Self.sanitize(artist)
        let query = "track:\"\(cleanTitle)\" artist:\"\(cleanArtist)\""
        let url = try buildSearchURL(query: query, limit: 5)
        let response: SpotifySearchResponse = try await authedGetURL(url)
        return response.tracks?.items.first
    }

    /// Búsqueda en texto libre, sin filtros de campo — el mismo enfoque que usa
    /// Apple Music. Último recurso: los filtros exigen que el título coincida
    /// casi literalmente, y ACRCloud y Spotify nombran las versiones distinto
    /// ("Sing It Back (Extended Feel Love Mix)" vs "Sing It Back - (I Feel Love)").
    /// Aquí mandamos el título sin el sufijo de versión y el artista principal.
    func findTrackFreeText(title: String, artist: String) async throws -> SpotifyTrack? {
        let core = Self.searchableTitle(title)
        let primary = Self.primaryArtist(artist)
        guard !core.isEmpty else { return nil }
        let query = Self.sanitize("\(core) \(primary)")
        let url = try buildSearchURL(query: query, limit: 5)
        let response: SpotifySearchResponse = try await authedGetURL(url)
        return response.tracks?.items.first
    }

    // MARK: - Normalización para búsqueda

    /// Quita comillas, que romperían la query.
    static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Título sin sufijos de versión: quita grupos entre paréntesis o corchetes
    /// —"(Extended Mix)", "[Radio Edit]", "(feat. X)"— y lo que siga a " - ".
    /// Si al quitarlo no queda nada, devuelve el título original.
    static func searchableTitle(_ title: String) -> String {
        var result = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]"#,
            with: "",
            options: .regularExpression
        )
        if let dash = result.range(of: " - ") {
            result = String(result[..<dash.lowerBound])
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    /// Artista principal: ACRCloud encadena colaboradores ("S.A.M., Sarah Ikumu")
    /// y a veces cuela créditos de remix ("Majed/Luna Orbit/Master Produções").
    /// Para buscar, el primero es el que más ayuda.
    static func primaryArtist(_ artist: String) -> String {
        let separators = CharacterSet(charactersIn: ",/&")
        let first = artist.components(separatedBy: separators).first ?? artist
        let withoutFeat = first.replacingOccurrences(
            of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let trimmed = withoutFeat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? artist.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
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
        try await resolveTrack(for: track).uri
    }

    /// Localiza el track en Spotify probando, en orden de fiabilidad:
    ///
    ///   1. **El ID que ya nos dio ACRCloud** (`external_metadata.spotify.track.id`).
    ///      Es exacto y cubre ~80% de las identificaciones. Antes se ignoraba por
    ///      completo y se iba directo a buscar por texto, que fallaba en cuanto el
    ///      título llevaba un sufijo de versión.
    ///   2. ISRC, también exacto (aunque ACRCloud rara vez lo incluye).
    ///   3. Filtros `track:`/`artist:` entrecomillados.
    ///   4. Texto libre con el título sin sufijo de versión, como hace Apple Music.
    ///
    /// Lanza `.spotifyTrackNotFound` si ninguna vía da resultado.
    private func resolveTrack(for track: Track) async throws -> SpotifyTrack {
        if let id = track.spotifyId, !id.isEmpty {
            // Se confirma contra /v1/tracks para no propagar un ID muerto; si no
            // resuelve, seguimos con el resto de vías en lugar de rendirnos.
            if let confirmed = try await trackById(id) {
                AppLogger.spotify.debug("resuelto por ID de ACRCloud: \(id, privacy: .public)")
                return confirmed
            }
            AppLogger.spotify.warning("el ID de ACRCloud \(id, privacy: .public) no resolvió — probando búsqueda")
        }

        if let isrc = track.isrc, !isrc.isEmpty,
           let byIsrc = try await findTrackByISRC(isrc) {
            AppLogger.spotify.debug("resuelto por ISRC")
            return byIsrc
        }

        if let byFields = try await findTrack(title: track.title, artist: track.artist) {
            AppLogger.spotify.debug("resuelto por título+artista")
            return byFields
        }

        if let byText = try await findTrackFreeText(title: track.title, artist: track.artist) {
            AppLogger.spotify.debug("resuelto por texto libre")
            return byText
        }

        throw RadioPremiumError.spotifyTrackNotFound(query: track.displayText)
    }

    /// Flujo completo: encuentra el track en Spotify (ISRC primero, fallback
    /// title+artist), busca/crea la playlist "Radio Likes", añade el track.
    /// Lanza `.spotifyTrackNotFound` si no existe en Spotify.
    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome {
        let spotifyTrack = try await resolveTrack(for: track)
        let playlist = try await findOrCreatePlaylist(named: SpotifyConstants.radioLikesPlaylistName)
        return try await addTrackToPlaylist(playlistId: playlist.id, trackUri: spotifyTrack.uri)
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
            // Token rechazado server-side (revocado / cambio scope). OJO:
            // getValidAccessToken aquí devolvía el MISMO token cacheado (aún
            // "válido" según el reloj local) y el retry repetía el 401.
            // forceRefreshedAccessToken refresca de verdad.
            AppLogger.spotify.warning("401 from Spotify, forcing token refresh + retry")
            let fresh = try await auth.forceRefreshedAccessToken()
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
