//
//  RetryTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class RetryTests: XCTestCase {

    func testSucceedsOnFirstTry_noRetry() async throws {
        let attempts = Box(0)
        let result: Int = try await retry(times: 3, initialDelayMs: 1) {
            attempts.value += 1
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(attempts.value, 1)
    }

    func testRetriesOnTransient_succeedsEventually() async throws {
        let attempts = Box(0)
        let result: Int = try await retry(times: 3, initialDelayMs: 1) {
            attempts.value += 1
            if attempts.value < 2 {
                throw RadioPremiumError.network(URLError(.timedOut))
            }
            return 99
        }
        XCTAssertEqual(result, 99)
        XCTAssertEqual(attempts.value, 2)
    }

    func testGivesUpAfterLimit_throwsLastError() async {
        let attempts = Box(0)
        do {
            let _: Int = try await retry(times: 3, initialDelayMs: 1) {
                attempts.value += 1
                throw RadioPremiumError.network(URLError(.timedOut))
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 3, "Should have tried exactly 3 times")
        }
    }

    func testNonTransient_doesNotRetry() async {
        let attempts = Box(0)
        do {
            let _: Int = try await retry(times: 3, initialDelayMs: 1) {
                attempts.value += 1
                throw RadioPremiumError.spotifyAuthRequired
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 1, "Non-transient errors must not retry")
        }
    }

    func testHttpStatus500_isTransient() async {
        let attempts = Box(0)
        do {
            let _: Int = try await retry(times: 3, initialDelayMs: 1) {
                attempts.value += 1
                throw RadioPremiumError.httpStatus(code: 503, body: nil)
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 3)
        }
    }

    func testHttpStatus400_notTransient() async {
        let attempts = Box(0)
        do {
            let _: Int = try await retry(times: 3, initialDelayMs: 1) {
                attempts.value += 1
                throw RadioPremiumError.httpStatus(code: 400, body: nil)
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 1, "4xx (except 408/429) must not retry")
        }
    }

    func testHttpStatus429_isTransient() async {
        let attempts = Box(0)
        do {
            let _: Int = try await retry(times: 3, initialDelayMs: 1) {
                attempts.value += 1
                throw RadioPremiumError.httpStatus(code: 429, body: nil)
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 3, "429 (rate limit) should retry")
        }
    }

    func testURLErrorTimeout_isTransient() async {
        let attempts = Box(0)
        do {
            let _: Int = try await retry(times: 3, initialDelayMs: 1) {
                attempts.value += 1
                throw URLError(.timedOut)
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 3)
        }
    }

    func testCustomTransientPredicate() async {
        let attempts = Box(0)
        // Caso: queremos que un error específico sea transient
        struct CustomError: Error { }

        do {
            let _: Int = try await retry(
                times: 2,
                initialDelayMs: 1,
                isTransient: { $0 is CustomError }
            ) {
                attempts.value += 1
                throw CustomError()
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(attempts.value, 2)
        }
    }
}
