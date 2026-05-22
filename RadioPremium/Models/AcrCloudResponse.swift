//
//  AcrCloudResponse.swift
//  RadioPremium
//
//  Tipos internos para parsear la respuesta de ACRCloud `/v1/identify`.
//  No exponemos estos tipos al resto de la app — AcrCloudClient los consume
//  y devuelve un `Track` (modelo neutro) hacia arriba.
//
//  Doc: https://docs.acrcloud.com/reference/identification-api
//
//  Status codes relevantes:
//    0    = OK (hay match)
//    1001 = no result
//    2002 = audio length too short
//    2004 = unable to generate fingerprint
//    3xxx = errores de servidor / auth
//

import Foundation

struct ACRResponse: Decodable {
    let status: ACRStatus
    let metadata: ACRMetadata?
    let resultType: Int?
    let costTime: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case metadata
        case resultType = "result_type"
        case costTime = "cost_time"
    }
}

struct ACRStatus: Decodable {
    let code: Int
    let msg: String?
    let version: String?
}

struct ACRMetadata: Decodable {
    let music: [ACRMusic]?
}

struct ACRMusic: Decodable {
    let title: String
    let artists: [ACRArtist]?
    let album: ACRAlbum?
    let releaseDate: String?
    let durationMs: Int?
    let externalMetadata: ACRExternalMetadata?
    let externalIds: ACRExternalIds?

    enum CodingKeys: String, CodingKey {
        case title
        case artists
        case album
        case releaseDate = "release_date"
        case durationMs = "duration_ms"
        case externalMetadata = "external_metadata"
        case externalIds = "external_ids"
    }
}

struct ACRArtist: Decodable {
    let name: String
}

struct ACRAlbum: Decodable {
    let name: String?
}

struct ACRExternalIds: Decodable {
    let isrc: String?
    let upc: String?
}

struct ACRExternalMetadata: Decodable {
    let spotify: ACRSpotifyMeta?
    let deezer: ACRDeezerMeta?
}

struct ACRSpotifyMeta: Decodable {
    let track: ACRSpotifyTrackMeta?
    let album: ACRSpotifyAlbumMeta?
}

struct ACRSpotifyTrackMeta: Decodable {
    let id: String?
    let name: String?
}

struct ACRSpotifyAlbumMeta: Decodable {
    let images: [ACRSpotifyImage]?
}

struct ACRSpotifyImage: Decodable {
    let url: String?
    let height: Int?
    let width: Int?
}

struct ACRDeezerMeta: Decodable {
    let track: ACRDeezerTrackMeta?
}

struct ACRDeezerTrackMeta: Decodable {
    let id: Int?
}
