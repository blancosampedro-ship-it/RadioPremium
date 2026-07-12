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

    /// Servidor por defecto. La API recomienda resolver `all.api.radio-browser.info`
    /// para load-balancing, pero un mirror estable nos sirve para uso personal.
    private let baseURL = URL(string: "https://de1.api.radio-browser.info/json")!

    private let session: URLSession
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "radio")

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Top N emisoras por votos. Filtra las marcadas como rotas.
    func topStations(limit: Int = 50) async throws -> [Station] {
        var components = URLComponents(url: baseURL.appendingPathComponent("stations/topvote"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
        ]
        return try await fetch(components.url!)
    }

    /// Búsqueda por nombre. Usa el endpoint /stations/search.
    func search(name: String, limit: Int = 50) async throws -> [Station] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("stations/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true"),
        ]
        return try await fetch(components.url!)
    }

    // MARK: - Internals

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
