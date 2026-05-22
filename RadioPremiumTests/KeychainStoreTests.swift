//
//  KeychainStoreTests.swift
//  RadioPremiumTests
//
//  Los tests usan service "com.blancosampedro.RadioPremium.tests" aislado
//  del de producción. setUp/tearDown limpian todos los items para que cada
//  test arranque y termine en estado limpio.
//

import XCTest
@testable import RadioPremium

final class KeychainStoreTests: XCTestCase {

    private let testService = "com.blancosampedro.RadioPremium.tests"
    private var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: testService)
        try store.clearAll()
    }

    override func tearDownWithError() throws {
        try? store.clearAll()
        store = nil
    }

    // MARK: - Set + Get

    func testSet_get_roundtrip() throws {
        try store.set("hello-world", for: "greeting")
        let value = try store.get("greeting")
        XCTAssertEqual(value, "hello-world")
    }

    func testGet_returnsNil_whenKeyMissing() throws {
        let value = try store.get("nonexistent-key")
        XCTAssertNil(value)
    }

    func testSet_overwritesExistingValue() throws {
        try store.set("first", for: "key1")
        try store.set("second", for: "key1")
        let value = try store.get("key1")
        XCTAssertEqual(value, "second")
    }

    // MARK: - Delete

    func testDelete_removesKey() throws {
        try store.set("value", for: "to-delete")
        try store.delete("to-delete")
        let value = try store.get("to-delete")
        XCTAssertNil(value)
    }

    func testDelete_idempotent_whenKeyMissing() {
        XCTAssertNoThrow(try store.delete("nonexistent-key"))
    }

    // MARK: - ClearAll

    func testClearAll_removesAllKeysForService() throws {
        try store.set("v1", for: "k1")
        try store.set("v2", for: "k2")
        try store.set("v3", for: "k3")

        try store.clearAll()

        XCTAssertNil(try store.get("k1"))
        XCTAssertNil(try store.get("k2"))
        XCTAssertNil(try store.get("k3"))
    }

    func testClearAll_doesNotAffectOtherServices() throws {
        let otherService = "com.blancosampedro.RadioPremium.tests.other"
        let otherStore = KeychainStore(service: otherService)
        defer { try? otherStore.clearAll() }

        try store.set("v1", for: "k1")
        try otherStore.set("other-v1", for: "k1")

        try store.clearAll()

        XCTAssertNil(try store.get("k1"))
        XCTAssertEqual(try otherStore.get("k1"), "other-v1")
    }

    func testClearAll_idempotent_whenEmpty() {
        XCTAssertNoThrow(try store.clearAll())
        XCTAssertNoThrow(try store.clearAll())
    }

    // MARK: - Unicode + edge values

    func testRoundtrip_unicodeValues() throws {
        let unicode = "🎵 música ñoño 中文"
        try store.set(unicode, for: "unicode-key")
        XCTAssertEqual(try store.get("unicode-key"), unicode)
    }

    func testRoundtrip_longValue() throws {
        let long = String(repeating: "abc123-", count: 200)  // ~1.4 KB
        try store.set(long, for: "long-key")
        XCTAssertEqual(try store.get("long-key"), long)
    }
}
