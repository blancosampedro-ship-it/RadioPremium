//
//  PKCEGenerator.swift
//  RadioPremium
//
//  PKCE (Proof Key for Code Exchange) helper para OAuth 2.0.
//  https://datatracker.ietf.org/doc/html/rfc7636
//
//  Verifier: 43-128 chars, charset [A-Z][a-z][0-9]-._~ (base64url-safe).
//  Challenge: base64url(SHA256(verifier)), 43 chars.
//
//  Pure helpers, sin estado. Fácil de testear con vectores conocidos.
//

import Foundation
import CryptoKit

enum PKCEGenerator {

    /// Genera un par (codeVerifier, codeChallenge) aleatorio para un nuevo flujo OAuth.
    /// Verifier ~86 chars (64 bytes random → base64url-encoded).
    static func generate() -> (verifier: String, challenge: String) {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        return (verifier, challenge)
    }

    /// Genera un code verifier aleatorio. 64 bytes random → ~86 chars base64url.
    /// Dentro del rango permitido por RFC 7636 (43-128 chars).
    static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "PKCEGenerator: SecRandomCopyBytes failed")
        return base64URLEncode(Data(bytes))
    }

    /// Calcula el code challenge S256 desde un verifier dado.
    /// challenge = base64url( SHA256(verifier) ).
    static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    /// Genera un state opaque para mitigar CSRF en el callback.
    /// Comparar el state que vuelve con el que enviamos.
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "PKCEGenerator: SecRandomCopyBytes failed")
        return base64URLEncode(Data(bytes))
    }

    // MARK: - Internals

    /// base64url encoding sin padding (`=` removido, `+` → `-`, `/` → `_`).
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
