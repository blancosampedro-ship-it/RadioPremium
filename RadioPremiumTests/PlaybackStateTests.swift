//
//  PlaybackStateTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class PlaybackStateTests: XCTestCase {

    func testEquality_simpleCases() {
        XCTAssertEqual(PlaybackState.idle, PlaybackState.idle)
        XCTAssertEqual(PlaybackState.playing, PlaybackState.playing)
        XCTAssertEqual(PlaybackState.paused, PlaybackState.paused)
        XCTAssertEqual(PlaybackState.buffering, PlaybackState.buffering)
        XCTAssertNotEqual(PlaybackState.idle, PlaybackState.playing)
        XCTAssertNotEqual(PlaybackState.playing, PlaybackState.paused)
    }

    func testEquality_errorCase_byReason() {
        XCTAssertEqual(
            PlaybackState.error(reason: "x"),
            PlaybackState.error(reason: "x")
        )
        XCTAssertNotEqual(
            PlaybackState.error(reason: "x"),
            PlaybackState.error(reason: "y")
        )
    }

    func testIsActive_truePlayingAndBuffering() {
        XCTAssertTrue(PlaybackState.playing.isActive)
        XCTAssertTrue(PlaybackState.buffering.isActive)
    }

    func testIsActive_falseIdlePausedError() {
        XCTAssertFalse(PlaybackState.idle.isActive)
        XCTAssertFalse(PlaybackState.paused.isActive)
        XCTAssertFalse(PlaybackState.error(reason: "any").isActive)
    }

    func testErrorCase_carriesReason() {
        let state = PlaybackState.error(reason: "stream interrumpido")
        guard case .error(let reason) = state else {
            return XCTFail("Expected .error case")
        }
        XCTAssertEqual(reason, "stream interrumpido")
    }
}
