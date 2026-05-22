//
//  RadioBrowserClient.swift
//  RadioPremium
//
//  Cliente de Radio Browser API. Compone HTTPClient.
//
//  API Radio Browser: https://api.radio-browser.info/
//  Endpoints relevantes:
//    GET /json/stations/search?name=X&countrycode=Y&limit=N&hidebroken=true&order=votes&reverse=true
//    GET /json/stations/topvote/{limit}
//    GET /json/stations/bycountrycodeexact/{code}?order=votes&reverse=true&limit=N&hidebroken=true
//    GET /json/stations/byuuid/{uuid}
//
//  Convenciones aplicadas en todos los reads:
//    - hidebroken=true  → filtra emisoras marcadas como rotas en el último check
//    - order=votes      → ordena por votos
//    - reverse=true     → descendente (más votadas primero)
//
//  Radio Browser pide identificarse vía User-Agent. Mandamos uno representativo
//  para no caer en filtros anti-abuso si nuestras llamadas se vuelven frecuentes.
//

import Foundation
import os

actor RadioBrowserClient {
    private let http: HTTPClient
    private let baseURL: URL
    private let userAgent: String

    /// Init explícito. Usado en tests con HTTPClient mockeado y URL ficticia.
    init(http: HTTPClient, baseURL: URL, userAgent: String = "RadioPremium/1.0 (macOS; com.blancosampedro.RadioPremium)") {
        self.http = http
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    /// Init de conveniencia: lee la base URL de Secrets.plist.
    init(http: HTTPClient = HTTPClient()) {
        guard let url = URL(string: Secrets.radioBrowserBaseUrl) else {
            fatalError("Secrets.radioBrowserBaseUrl no es una URL válida: \(Secrets.radioBrowserBaseUrl)")
        }
        self.http = http
        self.baseURL = url
        self.userAgent = "RadioPremium/1.0 (macOS; com.blancosampedro.RadioPremium)"
    }

    // MARK: - Search

    /// Búsqueda libre por nombre. Filtros opcionales por país y limit.
    /// Si `query` está vacío o solo whitespace, se omite el param `name`
    /// (devuelve top emisoras según el resto de filtros).
    func search(
        query: String,
        countryCode: String? = nil,
        limit: Int = 50
    ) async throws -> [Station] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "name", value: trimmed))
        }
        if let cc = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
            items.append(URLQueryItem(name: "countrycode", value: cc))
        }

        let url = try buildURL(path: "stations/search", queryItems: items)
        AppLogger.radio.debug("search query=\(trimmed.prefix(50), privacy: .public) cc=\(countryCode ?? "-", privacy: .public) limit=\(limit, privacy: .public)")
        return try await http.get(url, headers: defaultHeaders)
    }

    // MARK: - Popular

    /// Top votadas. Sin país → endpoint global topvote/{limit}.
    /// Con país → bycountrycodeexact/{cc} ordenado por votos descendente.
    func popular(countryCode: String? = nil, limit: Int = 50) async throws -> [Station] {
        if let cc = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
            let items: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "hidebroken", value: "true"),
                URLQueryItem(name: "order", value: "votes"),
                URLQueryItem(name: "reverse", value: "true")
            ]
            let url = try buildURL(path: "stations/bycountrycodeexact/\(cc)", queryItems: items)
            AppLogger.radio.debug("popular cc=\(cc, privacy: .public) limit=\(limit, privacy: .public)")
            return try await http.get(url, headers: defaultHeaders)
        } else {
            let url = baseURL.appendingPathComponent("stations/topvote/\(limit)")
            AppLogger.radio.debug("popular global limit=\(limit, privacy: .public)")
            return try await http.get(url, headers: defaultHeaders)
        }
    }

    // MARK: - By UUID

    /// Lookup por UUID. Devuelve nil si no existe (la API responde con array vacío).
    func byUUID(_ uuid: String) async throws -> Station? {
        let url = baseURL.appendingPathComponent("stations/byuuid/\(uuid)")
        AppLogger.radio.debug("byUUID \(uuid, privacy: .public)")
        let stations: [Station] = try await http.get(url, headers: defaultHeaders)
        return stations.first
    }

    // MARK: - Internals

    private var defaultHeaders: [String: String] {
        ["User-Agent": userAgent]
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let base = baseURL.appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw RadioPremiumError.invalidConfiguration(missing: "Radio Browser URL para path '\(path)'")
        }
        return url
    }
}
