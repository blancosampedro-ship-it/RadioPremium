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
//  RESILIENCIA (ver RadioBrowserMirrors.swift):
//  Los espejos de Radio Browser se caen a menudo y devuelven `503 no available
//  server`. Todas las lecturas pasan por `get(path:queryItems:)`, que aplica dos
//  niveles de defensa: failover inmediato entre espejos y, si fallan todos,
//  reintento con backoff. Antes una sola respuesta 503 llegaba cruda a la UI y
//  el usuario tenía que pulsar "Reintentar" a mano.
//

import Foundation
import os

/// User-Agent por defecto. A nivel de archivo (no `static` del actor) para
/// poder usarlo como valor por defecto de parámetro sin cruzar aislamiento.
private let defaultRadioBrowserUserAgent = "RadioPremium/1.0 (macOS; com.blancosampedro.RadioPremium)"

/// Vueltas completas a la lista de espejos antes de rendirse.
private let defaultRadioBrowserRetryRounds = 2

/// Espera inicial entre vueltas (se duplica en cada una).
private let radioBrowserRetryDelayMs = 400

/// URLSession propia con timeout corto.
///
/// `URLSession.shared` espera hasta 60s. Con failover eso es inaceptable: si un
/// espejo está colgado queremos descartarlo y pasar al siguiente en segundos, no
/// dejar al usuario mirando un spinner. Sesión propia para no alterar los
/// timeouts de ACRCloud (que sube audio) ni de Spotify.
private func makeRadioBrowserSession() -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
}

actor RadioBrowserClient {
    private let http: HTTPClient
    private let baseURLs: [URL]
    private let userAgent: String
    private let retryRounds: Int

    /// Índice del espejo que funcionó la última vez.
    ///
    /// "Sticky": una vez que hacemos failover a un espejo sano, las siguientes
    /// peticiones empiezan por ese en lugar de volver a chocar contra el caído.
    /// Así el usuario paga el fallo una vez por sesión, no en cada búsqueda.
    private var preferredIndex: Int = 0

    /// Init explícito con un único servidor. Usado en tests con HTTPClient
    /// mockeado y URL ficticia (sin failover, pero sí con reintentos).
    init(
        http: HTTPClient,
        baseURL: URL,
        userAgent: String = defaultRadioBrowserUserAgent,
        retryRounds: Int = defaultRadioBrowserRetryRounds
    ) {
        self.http = http
        self.baseURLs = [baseURL]
        self.userAgent = userAgent
        self.retryRounds = retryRounds
    }

    /// Init explícito con lista de espejos. Los prueba en orden.
    init(
        http: HTTPClient,
        baseURLs: [URL],
        userAgent: String = defaultRadioBrowserUserAgent,
        retryRounds: Int = defaultRadioBrowserRetryRounds
    ) {
        precondition(!baseURLs.isEmpty, "RadioBrowserClient necesita al menos una base URL")
        self.http = http
        self.baseURLs = baseURLs
        self.userAgent = userAgent
        self.retryRounds = retryRounds
    }

    /// Init de conveniencia: lee la base URL de Secrets.plist y le añade los
    /// espejos de fallback. Es el que usa la app real.
    init(http: HTTPClient? = nil) {
        guard let url = URL(string: Secrets.radioBrowserBaseUrl) else {
            fatalError("Secrets.radioBrowserBaseUrl no es una URL válida: \(Secrets.radioBrowserBaseUrl)")
        }
        self.http = http ?? HTTPClient(session: makeRadioBrowserSession())
        self.baseURLs = RadioBrowserMirrors.baseURLs(preferring: url)
        self.userAgent = defaultRadioBrowserUserAgent
        self.retryRounds = defaultRadioBrowserRetryRounds
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

        AppLogger.radio.debug("search query=\(trimmed.prefix(50), privacy: .public) cc=\(countryCode ?? "-", privacy: .public) limit=\(limit, privacy: .public)")
        return try await get(path: "stations/search", queryItems: items)
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
            AppLogger.radio.debug("popular cc=\(cc, privacy: .public) limit=\(limit, privacy: .public)")
            return try await get(path: "stations/bycountrycodeexact/\(cc)", queryItems: items)
        } else {
            AppLogger.radio.debug("popular global limit=\(limit, privacy: .public)")
            return try await get(path: "stations/topvote/\(limit)")
        }
    }

    // MARK: - By UUID

    /// Lookup por UUID. Devuelve nil si no existe (la API responde con array vacío).
    func byUUID(_ uuid: String) async throws -> Station? {
        AppLogger.radio.debug("byUUID \(uuid, privacy: .public)")
        let stations: [Station] = try await get(path: "stations/byuuid/\(uuid)")
        return stations.first
    }

    // MARK: - Internals

    private var defaultHeaders: [String: String] {
        ["User-Agent": userAgent]
    }

    /// GET resiliente: failover entre espejos + reintento con backoff.
    ///
    /// Dos niveles, a propósito:
    ///   1. **Failover inmediato** (`attemptAcrossMirrors`): si un espejo
    ///      devuelve 503 o expira, saltamos al siguiente SIN esperar. Es el caso
    ///      común — un espejo caído y los demás bien — y así el usuario no llega
    ///      ni a ver el error.
    ///   2. **Reintento con backoff** (`retry`): si fallan TODOS, esperamos y
    ///      damos otra vuelta completa. Cubre el bache global (wifi que
    ///      parpadea, la API entera saturada un instante).
    ///
    /// Reintentar el mismo espejo antes de probar los demás sería peor: ante un
    /// 503 lo útil es cambiar de servidor ya, no esperar a que el caído resucite.
    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        try await retry(times: retryRounds, initialDelayMs: radioBrowserRetryDelayMs) {
            try await self.attemptAcrossMirrors(path: path, queryItems: queryItems)
        }
    }

    /// Una vuelta a la lista de espejos, empezando por el preferido.
    /// Devuelve en cuanto uno responde; lanza el último error si fallan todos.
    private func attemptAcrossMirrors<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem]?
    ) async throws -> T {
        var lastError: Error = RadioPremiumError.invalidConfiguration(
            missing: "espejos de Radio Browser para path '\(path)'"
        )

        for offset in 0..<baseURLs.count {
            try Task.checkCancellation()

            let index = (preferredIndex + offset) % baseURLs.count
            let base = baseURLs[index]
            let url = try buildURL(base: base, path: path, queryItems: queryItems)

            do {
                let value: T = try await http.get(url, headers: defaultHeaders)
                if index != preferredIndex {
                    AppLogger.radio.info(
                        "Failover OK → usando \(base.host ?? "?", privacy: .public) a partir de ahora."
                    )
                    preferredIndex = index
                }
                return value
            } catch {
                // Solo hacemos failover ante errores transitorios. Un 404 o un
                // JSON corrupto fallarían igual en el resto de espejos: mejor
                // propagarlo ya que gastar 5 peticiones para el mismo resultado.
                guard defaultTransientCheck(error) else { throw error }

                lastError = error
                AppLogger.radio.error(
                    "Espejo \(base.host ?? "?", privacy: .public) falló (\(error.localizedDescription, privacy: .public)) — probando el siguiente."
                )
            }
        }

        throw lastError
    }

    private func buildURL(base: URL, path: String, queryItems: [URLQueryItem]?) throws -> URL {
        let full = base.appendingPathComponent(path)
        guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            throw RadioPremiumError.invalidConfiguration(missing: "Radio Browser URL para path '\(path)'")
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw RadioPremiumError.invalidConfiguration(missing: "Radio Browser URL para path '\(path)'")
        }
        return url
    }
}
