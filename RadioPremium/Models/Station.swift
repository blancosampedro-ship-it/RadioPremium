//
//  Station.swift
//  RadioPremium
//
//  Emisora de radio. Mapea el formato de Radio Browser API
//  (snake_case con quirks: tags como string CSV, lastcheckok como Int 0/1,
//  doble URL `url`/`url_resolved`) a una struct Swift idiomática.
//
//  La misma struct se usa para persistencia local (favoritos, historial),
//  manteniendo el formato API-compatible para que el roundtrip sea trivial.
//

import Foundation

nonisolated struct Station: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let streamURL: URL?
    let homepage: URL?
    let faviconURL: URL?
    let country: String?
    let countryCode: String?
    let language: String?
    let tags: [String]
    let codec: String?
    let bitrate: Int?
    let votes: Int?
    let isWorking: Bool

    // MARK: - Memberwise init para construcción directa (tests, datos sintéticos)

    init(
        id: String,
        name: String,
        streamURL: URL? = nil,
        homepage: URL? = nil,
        faviconURL: URL? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        language: String? = nil,
        tags: [String] = [],
        codec: String? = nil,
        bitrate: Int? = nil,
        votes: Int? = nil,
        isWorking: Bool = true
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homepage = homepage
        self.faviconURL = faviconURL
        self.country = country
        self.countryCode = countryCode
        self.language = language
        self.tags = tags
        self.codec = codec
        self.bitrate = bitrate
        self.votes = votes
        self.isWorking = isWorking
    }

    // MARK: - Codable (Radio Browser-compatible)

    private enum CodingKeys: String, CodingKey {
        case id          = "stationuuid"
        case name
        case urlResolved = "url_resolved"
        case url
        case homepage
        case favicon
        case country
        case countryCode = "countrycode"
        case language
        case tags
        case codec
        case bitrate
        case votes
        case lastCheckOk = "lastcheckok"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)

        // Preferir url_resolved (resuelto por Radio Browser) sobre url (puede ser
        // playlist .pls/.m3u que necesita resolución). Caer al url si vacío.
        let resolved = (try? c.decodeIfPresent(String.self, forKey: .urlResolved)) ?? nil
        let raw = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        let pick = (resolved?.isEmpty == false ? resolved : raw) ?? ""
        streamURL = pick.isEmpty ? nil : URL(string: pick)

        homepage = try Self.optionalURL(c, forKey: .homepage)
        faviconURL = try Self.optionalURL(c, forKey: .favicon)

        country = try c.decodeIfPresent(String.self, forKey: .country)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        votes = try c.decodeIfPresent(Int.self, forKey: .votes)

        // tags: "rock,pop,paradise" → ["rock", "pop", "paradise"]
        let tagsRaw = (try c.decodeIfPresent(String.self, forKey: .tags)) ?? ""
        tags = tagsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // lastcheckok: ausente o 1 = working, 0 = broken
        let lastCheck = (try c.decodeIfPresent(Int.self, forKey: .lastCheckOk)) ?? 1
        isWorking = lastCheck == 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(streamURL?.absoluteString, forKey: .urlResolved)
        try c.encodeIfPresent(homepage?.absoluteString, forKey: .homepage)
        try c.encodeIfPresent(faviconURL?.absoluteString, forKey: .favicon)
        try c.encodeIfPresent(country, forKey: .country)
        try c.encodeIfPresent(countryCode, forKey: .countryCode)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(tags.joined(separator: ","), forKey: .tags)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(bitrate, forKey: .bitrate)
        try c.encodeIfPresent(votes, forKey: .votes)
        try c.encode(isWorking ? 1 : 0, forKey: .lastCheckOk)
    }

    private static func optionalURL(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> URL? {
        guard let s = try container.decodeIfPresent(String.self, forKey: key), !s.isEmpty else {
            return nil
        }
        return URL(string: s)
    }
}
