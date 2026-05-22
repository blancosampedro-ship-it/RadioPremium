//
//  Retry.swift
//  RadioPremium
//
//  Helper para reintentos exponenciales en lecturas idempotentes.
//
//  IMPORTANTE: NO aplicar a writes (POST identify, POST add to playlist) —
//  duplicaría operaciones. Solo a GETs y a operaciones idempotentes
//  (search, /me, list playlists, refresh token).
//
//  Decisión 1D de /plan-eng-review.
//

import Foundation

@discardableResult
func retry<T>(
    times: Int = 3,
    initialDelayMs: Int = 200,
    backoffMultiplier: Double = 2.0,
    isTransient: (Error) -> Bool = defaultTransientCheck,
    operation: () async throws -> T
) async throws -> T {
    precondition(times >= 1, "retry: times must be >= 1")
    var attempt = 0
    var delayMs = initialDelayMs

    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            if attempt >= times || !isTransient(error) {
                throw error
            }
            try await Task.sleep(for: .milliseconds(delayMs))
            delayMs = Int(Double(delayMs) * backoffMultiplier)
        }
    }
}

/// Política por defecto: reintenta errores de red transitorios y respuestas HTTP
/// que sugieren "vuelve a intentarlo más tarde" (5xx, 408, 429).
/// NO reintenta 4xx (auth, bad request, not found) ni errores de aplicación
/// (token expirado, permiso denegado, etc.).
func defaultTransientCheck(_ error: Error) -> Bool {
    if let appError = error as? RadioPremiumError {
        switch appError {
        case .network:
            return true
        case .httpStatus(let code, _) where (500..<600).contains(code) || code == 408 || code == 429:
            return true
        default:
            return false
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
    return false
}
