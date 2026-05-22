//
//  RadioPremiumErrorTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class RadioPremiumErrorTests: XCTestCase {

    func testAllCasesHaveErrorDescription() {
        let errors: [RadioPremiumError] = [
            .network(URLError(.notConnectedToInternet)),
            .httpStatus(code: 500, body: nil),
            .httpStatus(code: 401, body: "Unauthorized"),
            .decodingFailed(underlying: "test"),
            .acrCloudFailed(reason: "test"),
            .acrCloudNoMatch,
            .spotifyAuthRequired,
            .spotifyAuthFailed(reason: "test"),
            .spotifyTrackNotFound(query: "test"),
            .screenRecordingPermissionDenied,
            .audioFormatUnsupported(detail: "test"),
            .settingsCorrupted,
            .invalidConfiguration(missing: "test"),
        ]

        for error in errors {
            let description = error.errorDescription
            XCTAssertNotNil(description, "Missing errorDescription for \(error)")
            XCTAssertFalse(description?.isEmpty ?? true, "Empty errorDescription for \(error)")
        }
    }

    func testScreenRecordingPermission_includesActionableHint() {
        let error = RadioPremiumError.screenRecordingPermissionDenied
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("System Settings") || description.contains("Screen Recording"),
            "Expected actionable hint about System Settings, got: \(description)"
        )
    }

    func testHttpStatus_includesCode() {
        let error = RadioPremiumError.httpStatus(code: 503, body: nil)
        XCTAssertTrue(
            error.errorDescription?.contains("503") ?? false,
            "Expected status code in description, got: \(error.errorDescription ?? "")"
        )
    }

    func testHttpStatus_truncatesLongBody() {
        let longBody = String(repeating: "x", count: 500)
        let error = RadioPremiumError.httpStatus(code: 500, body: longBody)
        let description = error.errorDescription ?? ""
        XCTAssertLessThan(description.count, 250, "Long body should be truncated")
    }

    func testInvalidConfiguration_namesMissingKey() {
        let error = RadioPremiumError.invalidConfiguration(missing: "AcrCloudAccessKey")
        XCTAssertTrue(
            error.errorDescription?.contains("AcrCloudAccessKey") ?? false,
            "Expected missing key name in description"
        )
    }

    func testAcrCloudNoMatch_hintsRetry() {
        let error = RadioPremiumError.acrCloudNoMatch
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("Reintenta") || description.contains("estribillo"),
            "Expected retry hint in description"
        )
    }
}
