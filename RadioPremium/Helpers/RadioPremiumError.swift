//
//  RadioPremiumError.swift
//  RadioPremium
//
//  Tipo central de errores de la app. UI hace switch sobre los casos
//  para responder con mensajes y acciones específicas en lugar de
//  parsear strings de error genéricos.
//
//  Decisión 1C de /plan-eng-review.
//

import Foundation

enum RadioPremiumError: LocalizedError, Sendable {
    // MARK: - HTTP / red
    case network(URLError)
    case httpStatus(code: Int, body: String?)
    case decodingFailed(underlying: String)

    // MARK: - ACRCloud
    case acrCloudFailed(reason: String)
    case acrCloudNoMatch

    // MARK: - Spotify
    case spotifyAuthRequired
    case spotifyAuthFailed(reason: String)
    case spotifyTrackNotFound(query: String)

    // MARK: - Apple Music
    case appleMusicAuthRequired
    case appleMusicAuthDenied
    case appleMusicSubscriptionRequired
    case appleMusicTrackNotFound(query: String)
    case appleMusicFailed(reason: String)

    // MARK: - Captura de audio
    case screenRecordingPermissionDenied
    case audioFormatUnsupported(detail: String)

    // MARK: - Configuración / persistencia
    case settingsCorrupted
    case invalidConfiguration(missing: String)

    var errorDescription: String? {
        switch self {
        case .network(let urlError):
            return "Sin red: \(urlError.localizedDescription)"

        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
                return "Error HTTP \(code): \(truncated)"
            }
            return "Error HTTP \(code)"

        case .decodingFailed(let underlying):
            return "No se pudo interpretar la respuesta del servidor: \(underlying)"

        case .acrCloudFailed(let reason):
            return "Identificación falló: \(reason)"

        case .acrCloudNoMatch:
            return "No reconocí esta canción. Reintenta cuando llegue el estribillo o cuando no haya voz por encima."

        case .spotifyAuthRequired:
            return "Necesitas conectar Spotify para añadir canciones a tu playlist."

        case .spotifyAuthFailed(let reason):
            return "No se pudo autenticar con Spotify: \(reason)"

        case .spotifyTrackNotFound(let query):
            return "No encontré esta canción en Spotify (búsqueda: \(query))."

        case .appleMusicAuthRequired:
            return "Necesitas autorizar Apple Music para añadir canciones a tu playlist."

        case .appleMusicAuthDenied:
            return "Permiso de Apple Music denegado. Abre System Settings → Privacy & Security → Media & Apple Music y activa RadioPremium."

        case .appleMusicSubscriptionRequired:
            return "Necesitas una suscripción activa de Apple Music para añadir canciones a una playlist."

        case .appleMusicTrackNotFound(let query):
            return "No encontré esta canción en Apple Music (búsqueda: \(query))."

        case .appleMusicFailed(let reason):
            return "Apple Music falló: \(reason)"

        case .screenRecordingPermissionDenied:
            return "Necesito permiso de Screen Recording para escuchar el audio del sistema. Abre System Settings → Privacy & Security → Screen Recording y activa RadioPremium."

        case .audioFormatUnsupported(let detail):
            return "Formato de audio no soportado: \(detail)"

        case .settingsCorrupted:
            return "Los ajustes guardados estaban corruptos y se han restaurado a los valores por defecto."

        case .invalidConfiguration(let missing):
            return "Configuración incompleta: falta '\(missing)' en Secrets.plist."
        }
    }
}
