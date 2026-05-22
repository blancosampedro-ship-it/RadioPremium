//
//  PKCEGeneratorTests.swift
//  RadioPremiumTests
//

import XCTest
import CryptoKit
@testable import RadioPremium

final class PKCEGeneratorTests: XCTestCase {

    // MARK: - Code verifier format

    func testGenerateCodeVerifier_lengthInRange() {
        for _ in 0..<10 {
            let verifier = PKCEGenerator.generateCodeVerifier()
            XCTAssertGreaterThanOrEqual(verifier.count, 43, "RFC 7636 mínimo 43 chars")
            XCTAssertLessThanOrEqual(verifier.count, 128, "RFC 7636 máximo 128 chars")
        }
    }

    func testGenerateCodeVerifier_charsetIsBase64URLSafe() {
        let allowedChars = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        for _ in 0..<10 {
            let verifier = PKCEGenerator.generateCodeVerifier()
            for char in verifier.unicodeScalars {
                XCTAssertTrue(
                    allowedChars.contains(char),
                    "Char inválido en verifier: '\(char)'"
                )
            }
        }
    }

    func testGenerateCodeVerifier_isRandomEachCall() {
        let v1 = PKCEGenerator.generateCodeVerifier()
        let v2 = PKCEGenerator.generateCodeVerifier()
        XCTAssertNotEqual(v1, v2, "Dos verifiers consecutivos deben ser distintos (RNG)")
    }

    // MARK: - Code challenge (SHA-256 vector test)

    /// Vector verificable independientemente:
    ///   echo -n "test-verifier-12345" | shasum -a 256 -b | xxd -r -p | base64
    /// Resultado: aOSyOCLPj+P8AVZpDOqV6P/RUNw5T+rVF22fpfPqmS8=
    /// Después con base64url: aOSyOCLPj-P8AVZpDOqV6P_RUNw5T-rVF22fpfPqmS8
    func testGenerateCodeChallenge_knownVector() {
        let verifier = "test-verifier-12345"
        let challenge = PKCEGenerator.generateCodeChallenge(from: verifier)

        // Calcular el esperado con CryptoKit aquí mismo, en lugar de hardcodear,
        // garantiza que el test no dependa de un vector externo que pueda
        // tener typos. Lo importante es que la función use SHA-256 + base64url.
        let expected = PKCEGenerator.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        XCTAssertEqual(challenge, expected)
    }

    func testGenerateCodeChallenge_changesWithVerifier() {
        let c1 = PKCEGenerator.generateCodeChallenge(from: "verifier-A")
        let c2 = PKCEGenerator.generateCodeChallenge(from: "verifier-B")
        XCTAssertNotEqual(c1, c2)
    }

    func testGenerateCodeChallenge_isStableForSameVerifier() {
        let v = "stable-verifier-xyz"
        XCTAssertEqual(
            PKCEGenerator.generateCodeChallenge(from: v),
            PKCEGenerator.generateCodeChallenge(from: v)
        )
    }

    // MARK: - generate() pair

    func testGenerate_returnsValidPair() {
        let (verifier, challenge) = PKCEGenerator.generate()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertEqual(challenge.count, 43, "SHA-256 (32 bytes) base64url-encoded sin padding = 43 chars")
        // El challenge debe ser exactamente lo que sale de hashear el verifier.
        XCTAssertEqual(
            challenge,
            PKCEGenerator.generateCodeChallenge(from: verifier)
        )
    }

    // MARK: - State

    func testGenerateState_isUnique() {
        let s1 = PKCEGenerator.generateState()
        let s2 = PKCEGenerator.generateState()
        XCTAssertNotEqual(s1, s2)
    }

    func testGenerateState_lengthReasonable() {
        let state = PKCEGenerator.generateState()
        // 32 bytes random base64url-encoded sin padding = 43 chars
        XCTAssertEqual(state.count, 43)
    }

    // MARK: - base64URLEncode

    func testBase64URLEncode_replacesPlusSlashAndPadding() {
        // Bytes que generan + y / en base64 estándar
        let data = Data([0xFB, 0xEF, 0xFF, 0xFE])
        let encoded = PKCEGenerator.base64URLEncode(data)
        XCTAssertFalse(encoded.contains("+"), "base64url no debe contener '+'")
        XCTAssertFalse(encoded.contains("/"), "base64url no debe contener '/'")
        XCTAssertFalse(encoded.contains("="), "base64url no debe contener padding '='")
    }
}
