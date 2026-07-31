//
//  RadioBrowserAPI.swift
//  RadioPremium-iOS
//
//  Cliente HTTP minimal contra Radio Browser API.
//  https://api.radio-browser.info/
//

import Foundation
import os

actor RadioBrowserAPI {

    /// Espejos de la API, en orden de preferencia. Port del failover de macOS
    /// (RadioBrowserMirrors): los espejos de Radio Browser se caen a menudo y
    /// su proxy responde `503 no available server` — con un único servidor
    /// clavado, cada caída de de1 dejaba el iPhone sin listado ni búsqueda.
    /// `all` va primero: es el entry point recomendado (DNS a un servidor vivo).
    private let baseURLs: [URL] = [
        URL(string: "https://all.api.radio-browser.info/json")!,
        URL(string: "https://de2.api.radio-browser.info/json")!,
        URL(string: "https://de1.api.radio-browser.info/json")!,
        URL(string: "https://at1.api.radio-browser.info/json")!,
        URL(string: "https://nl1.api.radio-browser.info/json")!,
    ]

    /// Índice del espejo que funcionó la última vez ("sticky": las siguientes
    /// peticiones empiezan por él en vez de rechocar contra el caído).
    private var preferredIndex = 0

    private let session: URLSession
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "radio")

    init(session: URLSession? = nil) {
        // Sesión propia con timeout corto: URLSession.shared espera 60s, y con
        // failover queremos descartar un espejo colgado en segundos.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    /// Top N emisoras por votos. Filtra las marcadas como rotas.
    func topStations(limit: Int = 50) async throws -> [Station] {
        try await fetchAcrossMirrors(path: "stations/topvote", queryItems: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
        ])
    }

    /// Búsqueda por nombre. Usa el endpoint /stations/search.
    func search(name: String, limit: Int = 50) async throws -> [Station] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return try await fetchAcrossMirrors(path: "stations/search", queryItems: [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
        ])
    }

    // MARK: - Internals

    /// Una vuelta a la lista de espejos empezando por el preferido. Devuelve en
    /// cuanto uno responde; si fallan todos, propaga el último error.
    private func fetchAcrossMirrors(path: String, queryItems: [URLQueryItem]) async throws -> [Station] {
        var lastError: Error = URLError(.cannotConnectToHost)

        for offset in 0..<baseURLs.count {
            try Task.checkCancellation()
            let index = (preferredIndex + offset) % baseURLs.count
            let base = baseURLs[index]

            var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = queryItems
            guard let url = components.url else { continue }

            do {
                let stations = try await fetch(url)
                if index != preferredIndex {
                    log.info("failover OK → usando \(base.host ?? "?", privacy: .public) a partir de ahora")
                    preferredIndex = index
                }
                return stations
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                log.error("espejo \(base.host ?? "?", privacy: .public) falló (\(error.localizedDescription, privacy: .public)) — probando el siguiente")
            }
        }
        throw lastError
    }

    private func fetch(_ url: URL) async throws -> [Station] {
        log.debug("GET \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue("RadioPremium-iOS/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            log.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        // Decode con tolerancia: si algún station individual falla parseo, lo saltamos.
        let decoder = JSONDecoder()
        struct PartialList: Decodable {
            let stations: [Station]
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var result: [Station] = []
                while !container.isAtEnd {
                    if let s = try? container.decode(Station.self) {
                        result.append(s)
                    } else {
                        _ = try? container.decode(EmptyDecodable.self)
                    }
                }
                self.stations = result
            }
        }
        struct EmptyDecodable: Decodable {}

        let list = try decoder.decode(PartialList.self, from: data)
        log.info("fetched \(list.stations.count) stations")
        return list.stations
    }
}
