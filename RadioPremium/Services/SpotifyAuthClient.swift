//
//  SpotifyAuthClient.swift
//  RadioPremium
//
//  OAuth 2.0 flow para Spotify con PKCE + ASWebAuthenticationSession.
//  Decisión 1A del /plan-eng-review: usa el primitivo nativo Mac en lugar de
//  un HTTPListener local (como hacía la app Windows).
//
//  Tokens persistidos en Keychain via KeychainStore.
//  Service: com.blancosampedro.RadioPremium.spotify
//  Keys:
//    - accessToken
//    - refreshToken
//    - tokenType
//    - expiresAt (ISO 8601)
//    - scope
//
//  Auto-refresh: getValidAccessToken() comprueba expiry y refresca si falta
//  poco para expirar. Si el refresh falla, hace signOut() automático.
//

import Foundation
import AuthenticationServices
import AppKit
import os

actor SpotifyAuthClient {
    private let http: HTTPClient
    private let keychain: KeychainStore
    private let clientId: String
    private let redirectUri: String
    private let scopes: [String]
    private let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    private let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!

    private var cachedTokens: SpotifyTokens?

    /// Init explícito (tests).
    init(
        http: HTTPClient,
        keychain: KeychainStore,
        clientId: String,
        redirectUri: String,
        scopes: [String]
    ) {
        self.http = http
        self.keychain = keychain
        self.clientId = clientId
        self.redirectUri = redirectUri
        self.scopes = scopes
    }

    /// Init de producción: lee Secrets, usa HTTPClient default y KeychainStore
    /// con el service específico de Spotify (aislado del de los tests).
    init(http: HTTPClient = HTTPClient()) {
        self.http = http
        self.keychain = KeychainStore(service: "com.blancosampedro.RadioPremium.spotify")
        self.clientId = Secrets.spotifyClientId
        self.redirectUri = Secrets.spotifyRedirectUri
        self.scopes = SpotifyConstants.requiredScopes
    }

    // MARK: - Public API

    /// `true` si tenemos tokens válidos en Keychain (aunque estén expirados —
    /// el access token se refresca solo en getValidAccessToken).
    func isAuthenticated() async -> Bool {
        let tokens = await loadTokens()
        return tokens != nil
    }

    /// Inicia el flujo OAuth completo:
    ///   1. Genera PKCE.
    ///   2. Abre ASWebAuthenticationSession.
    ///   3. Espera callback en `radiopremium://callback?code=...&state=...`.
    ///   4. Intercambia code por tokens.
    ///   5. Persiste en Keychain.
    /// Devuelve los tokens al éxito.
    func signIn() async throws -> SpotifyTokens {
        let (verifier, challenge) = PKCEGenerator.generate()
        let state = PKCEGenerator.generateState()

        let authURL = buildAuthorizationURL(challenge: challenge, state: state)
        AppLogger.spotify.info("signIn: opening ASWebAuthenticationSession")

        let callbackURL: URL
        do {
            callbackURL = try await openAuthSession(authURL: authURL)
        } catch {
            AppLogger.spotify.error("signIn cancelled or failed: \(error.localizedDescription, privacy: .public)")
            throw RadioPremiumError.spotifyAuthFailed(reason: error.localizedDescription)
        }

        // Validar state y extraer code
        guard let code = extractQueryValue(from: callbackURL, name: "code") else {
            if let errorDesc = extractQueryValue(from: callbackURL, name: "error") {
                throw RadioPremiumError.spotifyAuthFailed(reason: "Spotify rechazó autorización: \(errorDesc)")
            }
            throw RadioPremiumError.spotifyAuthFailed(reason: "Callback sin code")
        }
        guard extractQueryValue(from: callbackURL, name: "state") == state else {
            throw RadioPremiumError.spotifyAuthFailed(reason: "State mismatch (posible CSRF)")
        }

        // Exchange code → tokens
        let tokens = try await exchangeCodeForTokens(code: code, verifier: verifier)
        try await saveTokens(tokens)
        AppLogger.spotify.info("signIn: success, scopes=\(tokens.scope, privacy: .public)")
        return tokens
    }

    /// Borra tokens del Keychain. Siguiente llamada a getValidAccessToken
    /// disparará re-auth si se llama signIn() de nuevo.
    func signOut() async {
        cachedTokens = nil
        try? keychain.delete("accessToken")
        try? keychain.delete("refreshToken")
        try? keychain.delete("tokenType")
        try? keychain.delete("expiresAt")
        try? keychain.delete("scope")
        AppLogger.spotify.info("signOut: tokens cleared")
    }

    /// Devuelve un access token usable. Si está expirado o a punto, lo refresca.
    /// Si refresh falla → signOut + lanza spotifyAuthRequired.
    func getValidAccessToken() async throws -> String {
        guard let tokens = await loadTokens() else {
            throw RadioPremiumError.spotifyAuthRequired
        }

        if !tokens.isExpired {
            return tokens.accessToken
        }

        AppLogger.spotify.debug("access token expired, refreshing")
        return try await refreshAndPersist(tokens)
    }

    /// Fuerza un refresh real contra Spotify aunque el token local no haya
    /// expirado. Para el retry tras un 401: un token revocado server-side sigue
    /// pareciendo "válido" según el reloj local, y getValidAccessToken lo
    /// devolvía cacheado tal cual — el retry fallaba con el mismo 401.
    func forceRefreshedAccessToken() async throws -> String {
        guard let tokens = await loadTokens() else {
            throw RadioPremiumError.spotifyAuthRequired
        }
        AppLogger.spotify.debug("forcing token refresh (server rejected current token)")
        return try await refreshAndPersist(tokens)
    }

    /// Refresca contra /api/token, mergea con los tokens actuales y persiste.
    /// Si el refresh falla → signOut + spotifyAuthRequired.
    private func refreshAndPersist(_ current: SpotifyTokens) async throws -> String {
        var tokens = current
        do {
            let refreshed = try await refreshTokens(refreshToken: tokens.refreshToken)
            // Spotify a veces no devuelve un nuevo refresh_token en la respuesta;
            // en ese caso conservamos el actual.
            tokens.accessToken = refreshed.accessToken
            tokens.expiresAt = refreshed.expiresAt
            tokens.tokenType = refreshed.tokenType
            if !refreshed.refreshToken.isEmpty {
                tokens.refreshToken = refreshed.refreshToken
            }
            if !refreshed.scope.isEmpty {
                tokens.scope = refreshed.scope
            }
            try await saveTokens(tokens)
            return tokens.accessToken
        } catch {
            AppLogger.spotify.error("refresh failed: \(error.localizedDescription, privacy: .public). Forcing re-auth.")
            await signOut()
            throw RadioPremiumError.spotifyAuthRequired
        }
    }

    /// Devuelve los tokens cacheados/persistidos. Útil para tests y diagnostics.
    func currentTokens() async -> SpotifyTokens? {
        await loadTokens()
    }

    // MARK: - URL building

    private func buildAuthorizationURL(challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "show_dialog", value: "false")
        ]
        return components.url!
    }

    private func extractQueryValue(from url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    // MARK: - ASWebAuthenticationSession

    /// Referencia a la sesión web activa, para poder cancelarla si la Task
    /// muere. Solo se accede desde MainActor.
    private final class WebAuthSessionHolder: @unchecked Sendable {
        var session: ASWebAuthenticationSession?
    }

    @MainActor
    private func openAuthSession(authURL: URL) async throws -> URL {
        let holder = WebAuthSessionHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "radiopremium"
                ) { callbackURL, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: RadioPremiumError.spotifyAuthFailed(reason: "callback nil"))
                        return
                    }
                    continuation.resume(returning: callbackURL)
                }
                session.presentationContextProvider = AuthPresentationProvider.shared
                session.prefersEphemeralWebBrowserSession = false
                holder.session = session
                if !session.start() {
                    continuation.resume(throwing: RadioPremiumError.spotifyAuthFailed(reason: "session.start() devolvió false"))
                }
            }
        } onCancel: {
            // Sin esto, cancelar la Task dejaba la ventana de login huérfana y
            // la continuation suspendida hasta que el usuario la cerrase a mano
            // (y reintentar abría una SEGUNDA ventana encima). session.cancel()
            // dispara el completion con canceledLogin y todo se desmonta limpio.
            Task { @MainActor in
                holder.session?.cancel()
            }
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> SpotifyTokens {
        let now = Date()
        let response: SpotifyTokenResponse = try await http.postForm(
            tokenURL,
            fields: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectUri,
                "client_id": clientId,
                "code_verifier": verifier
            ]
        )
        return SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? "",
            tokenType: response.tokenType ?? "Bearer",
            expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope ?? ""
        )
    }

    private func refreshTokens(refreshToken: String) async throws -> SpotifyTokens {
        let now = Date()
        let response: SpotifyTokenResponse = try await http.postForm(
            tokenURL,
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientId
            ]
        )
        return SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? "",
            tokenType: response.tokenType ?? "Bearer",
            expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope ?? ""
        )
    }

    // MARK: - Persistence

    private func loadTokens() async -> SpotifyTokens? {
        if let cached = cachedTokens { return cached }

        guard let access = try? keychain.get("accessToken"), !access.isEmpty else { return nil }
        let refresh = (try? keychain.get("refreshToken")) ?? nil ?? ""
        let tokenType = (try? keychain.get("tokenType")) ?? nil ?? "Bearer"
        let scope = (try? keychain.get("scope")) ?? nil ?? ""
        let expiresStr = (try? keychain.get("expiresAt")) ?? nil ?? ""

        let formatter = ISO8601DateFormatter()
        let expiresAt = formatter.date(from: expiresStr) ?? Date(timeIntervalSince1970: 0)

        let tokens = SpotifyTokens(
            accessToken: access,
            refreshToken: refresh,
            tokenType: tokenType,
            expiresAt: expiresAt,
            scope: scope
        )
        cachedTokens = tokens
        return tokens
    }

    private func saveTokens(_ tokens: SpotifyTokens) async throws {
        let formatter = ISO8601DateFormatter()
        try keychain.set(tokens.accessToken, for: "accessToken")
        try keychain.set(tokens.refreshToken, for: "refreshToken")
        try keychain.set(tokens.tokenType, for: "tokenType")
        try keychain.set(formatter.string(from: tokens.expiresAt), for: "expiresAt")
        try keychain.set(tokens.scope, for: "scope")
        cachedTokens = tokens
    }
}

// MARK: - DTO interno para parse de respuestas de /api/token

private struct SpotifyTokenResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

// MARK: - Presentation provider para ASWebAuthenticationSession

@MainActor
private final class AuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Para apps menubar (sin ventana principal) creamos un anchor invisible.
        // ASWebAuthenticationSession lo usa para anclar el sheet del navegador.
        if let key = NSApplication.shared.keyWindow {
            return key
        }
        if let any = NSApplication.shared.windows.first {
            return any
        }
        // Fallback: ventana invisible mínima.
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        return window
    }
}
