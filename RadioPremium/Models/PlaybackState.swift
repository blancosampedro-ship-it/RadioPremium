//
//  PlaybackState.swift
//  RadioPremium
//
//  Estado del reproductor de audio. Cinco estados explícitos para que la UI
//  pueda mostrar feedback distintivo en cada uno (sin "loading…" genérico).
//

import Foundation

nonisolated enum PlaybackState: Sendable, Equatable {
    case idle               // sin emisora cargada, listo para reproducir
    case buffering          // cargando stream, aún no suena
    case playing            // reproduciendo
    case paused             // pausado por usuario o por sleep
    case error(reason: String)

    var isActive: Bool {
        switch self {
        case .playing, .buffering: return true
        case .idle, .paused, .error: return false
        }
    }
}
