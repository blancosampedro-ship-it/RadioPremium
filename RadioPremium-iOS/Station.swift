//
//  Station.swift
//  RadioPremium-iOS
//
//  Modelo de una emisora devuelta por Radio Browser API.
//  Versión iOS — auto-contenida (no comparte con el target macOS).
//

import Foundation

struct Station: Codable, Identifiable, Hashable, Sendable {
    let id: String                  // stationuuid
    let name: String
    let url: URL                    // stream URL (url_resolved)
    let homepage: URL?
    let favicon: URL?
    let country: String?
    let tags: String?               // CSV "pop,rock,..."
    let bitrate: Int?
    let codec: String?
    /// `true` si Radio Browser marca el stream como HLS. Con HLS el servidor
    /// conserva los últimos minutos en trocitos descargables: colchón REAL de
    /// decenas de segundos, como TuneIn. nil en datos guardados antiguos.
    let hls: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "stationuuid"
        case name
        case url = "url_resolved"
        case homepage
        case favicon
        case country
        case tags
        case bitrate
        case codec
        case hls
    }

    /// `true` si el stream es HLS (por flag del directorio o por la URL).
    var isHLS: Bool {
        if hls == true { return true }
        return url.absoluteString.lowercased().contains(".m3u8")
    }

    /// Decoder defensivo: Radio Browser a veces devuelve strings vacíos donde
    /// debería haber URL. Tratamos esos como nil para no fallar el decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)

        let urlString = try c.decode(String.self, forKey: .url)
        guard let parsed = URL(string: urlString), !urlString.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: c, debugDescription: "url_resolved vacío o inválido"
            )
        }
        url = parsed

        homepage = Self.lenientURL(try? c.decode(String.self, forKey: .homepage))
        favicon = Self.lenientURL(try? c.decode(String.self, forKey: .favicon))
        country = try? c.decode(String.self, forKey: .country)
        tags = try? c.decode(String.self, forKey: .tags)
        bitrate = try? c.decode(Int.self, forKey: .bitrate)
        codec = try? c.decode(String.self, forKey: .codec)
        // Radio Browser manda 0/1; nuestros payloads guardados, Bool; los
        // antiguos, nada. Tolerante con los tres.
        if let intFlag = try? c.decode(Int.self, forKey: .hls) {
            hls = intFlag == 1
        } else {
            hls = try? c.decode(Bool.self, forKey: .hls)
        }
    }

    private static func lenientURL(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}

extension Station {
    /// Lista de tags como array, conveniente para UI.
    var tagList: [String] {
        (tags ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
