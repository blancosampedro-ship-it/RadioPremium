//
//  RadioBrowseViewModelTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

@MainActor
final class RadioBrowseViewModelTests: XCTestCase {

    private var vm: RadioBrowseViewModel!
    private var favoritesRepo: FavoritesRepository!
    private var tempDir: URL!
    private let baseURL = URL(string: "https://test.example.com/json")!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            MockURLProtocol.reset()
        }
        // Repo de favoritos en tempDir para no tocar Application Support real.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        favoritesRepo = FavoritesRepository(url: tempDir.appendingPathComponent("favorites.json"))

        let http = HTTPClient(session: URLSession.mocked())
        let client = RadioBrowserClient(http: http, baseURL: baseURL, userAgent: "Test/1.0")
        vm = RadioBrowseViewModel(client: client, favoritesRepo: favoritesRepo, debounceMs: 1)
    }

    override func tearDown() async throws {
        await MainActor.run {
            MockURLProtocol.reset()
            vm.cancel()
            vm = nil
        }
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        favoritesRepo = nil
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private static let stationJSON = """
    {
        "stationuuid": "rp-1",
        "name": "Radio Paradise",
        "url": "http://stream.radioparadise.com",
        "url_resolved": "http://stream.radioparadise.com",
        "countrycode": "US",
        "tags": "rock",
        "codec": "AAC",
        "bitrate": 320,
        "lastcheckok": 1
    }
    """

    private func setHandler(returning body: String) {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8))
        }
    }

    private func setHandler(throwing error: Error) {
        MockURLProtocol.setHandler { _ in throw error }
    }

    /// Espera hasta `timeoutMs` a que `condition` sea true.
    /// Necesario porque las búsquedas son async + debounced — sin esto los
    /// asserts fallarían por timing antes de que el state se actualice.
    private func waitFor(
        timeoutMs: Int = 500,
        _ condition: @autoclosure () -> Bool
    ) async {
        let stepMs = 5
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(stepMs))
            elapsed += stepMs
        }
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.results, [])
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.sectionTitle, "Populares")
    }

    // MARK: - loadPopular

    func testLoadPopular_populatesResults() async {
        setHandler(returning: "[\(Self.stationJSON)]")

        vm.loadPopular()
        await waitFor(!vm.results.isEmpty)

        XCTAssertEqual(vm.results.count, 1)
        XCTAssertEqual(vm.results.first?.name, "Radio Paradise")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadPopular_setsIsLoadingDuringFetch() async {
        // Handler que tarda un poco para que isLoading sea observable
        MockURLProtocol.setHandler { request in
            Thread.sleep(forTimeInterval: 0.05)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "[]".data(using: .utf8))
        }

        vm.loadPopular()
        // Justo después del trigger, isLoading debe ser true (todavía no resolvió)
        await waitFor(timeoutMs: 30, vm.isLoading)
        XCTAssertTrue(vm.isLoading)

        // Y eventualmente resuelve a false
        await waitFor(!vm.isLoading)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - performSearch

    func testPerformSearch_withQuery_callsSearchEndpoint() async {
        setHandler(returning: "[\(Self.stationJSON)]")

        vm.query = "paradise"
        vm.performSearch()
        await waitFor(!vm.results.isEmpty)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/json/stations/search")
        XCTAssertEqual(url?.queryValue(for: "name"), "paradise")
        XCTAssertEqual(vm.results.count, 1)
    }

    func testPerformSearch_emptyQuery_callsPopularEndpoint() async {
        setHandler(returning: "[]")

        vm.query = ""
        vm.performSearch()
        await waitFor(MockURLProtocol.lastRequest != nil)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertTrue(url?.path.hasPrefix("/json/stations/topvote/") ?? false,
                      "Query vacía debe llamar a topvote, no a search. Path: \(url?.path ?? "nil")")
    }

    func testPerformSearch_whitespaceQuery_treatedAsEmpty() async {
        setHandler(returning: "[]")

        vm.query = "   \n  "
        vm.performSearch()
        await waitFor(MockURLProtocol.lastRequest != nil)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertTrue(url?.path.hasPrefix("/json/stations/topvote/") ?? false,
                      "Whitespace query debe llamar a topvote. Path: \(url?.path ?? "nil")")
    }

    // MARK: - Section title

    func testSectionTitle_emptyQuery() {
        vm.query = ""
        XCTAssertEqual(vm.sectionTitle, "Populares")
    }

    func testSectionTitle_withQuery() {
        vm.query = "rock"
        XCTAssertEqual(vm.sectionTitle, "Resultados para \"rock\"")
    }

    func testSectionTitle_trimmedQuery() {
        vm.query = "  rock  "
        XCTAssertEqual(vm.sectionTitle, "Resultados para \"rock\"")
    }

    // MARK: - Error handling

    func testError_populatesErrorMessage_andClearsResults() async {
        // primero llenamos results para verificar que error las limpia
        setHandler(returning: "[\(Self.stationJSON)]")
        vm.query = "ok"
        vm.performSearch()
        await waitFor(!vm.results.isEmpty)
        XCTAssertEqual(vm.results.count, 1)

        // ahora forzamos error
        setHandler(throwing: URLError(.notConnectedToInternet))
        vm.query = "fails"
        vm.performSearch()
        await waitFor(vm.errorMessage != nil)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.results, [])
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - Debounce

    func testRapidQueryChanges_lastQueryWins() async {
        setHandler(returning: "[]")

        vm.query = "r"; vm.performSearch()
        vm.query = "ro"; vm.performSearch()
        vm.query = "roc"; vm.performSearch()
        vm.query = "rock"; vm.performSearch()

        await waitFor(!vm.isLoading && vm.results.isEmpty == false || MockURLProtocol.lastRequest != nil)
        // Esperar un poco más a que cualquier task pendiente termine
        try? await Task.sleep(for: .milliseconds(50))

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.queryValue(for: "name"), "rock",
                       "Solo el query final debe haber salido. Path actual: \(url?.absoluteString ?? "nil")")
    }

    // MARK: - emptyStateMessage

    func testEmptyStateMessage_initiallyShowsLoadingHint() {
        // Sin haber llamado loadPopular, results está vacío y no hay loading aún
        XCTAssertEqual(vm.emptyStateMessage, "Cargando emisoras populares…")
    }

    func testEmptyStateMessage_withQueryNoResults() async {
        setHandler(returning: "[]")
        vm.query = "no-such-station-anywhere"
        vm.performSearch()
        await waitFor(!vm.isLoading)

        XCTAssertEqual(vm.emptyStateMessage, "Sin resultados para \"no-such-station-anywhere\"")
    }

    func testEmptyStateMessage_nilWhenResultsPresent() async {
        setHandler(returning: "[\(Self.stationJSON)]")
        vm.query = "paradise"
        vm.performSearch()
        await waitFor(!vm.results.isEmpty)

        XCTAssertNil(vm.emptyStateMessage)
    }

    func testEmptyStateMessage_nilWhenError() async {
        setHandler(throwing: URLError(.notConnectedToInternet))
        vm.query = "fail"
        vm.performSearch()
        await waitFor(vm.errorMessage != nil)

        XCTAssertNil(vm.emptyStateMessage,
                     "Cuando hay error, ErrorRow se muestra en lugar de empty state.")
    }

    // MARK: - Favoritos

    private static let testStation = Station(
        id: "fav-1",
        name: "Mi Emisora",
        streamURL: URL(string: "https://example.com/stream"),
        countryCode: "ES",
        codec: "MP3",
        bitrate: 128
    )

    func testFavorites_emptyInitially() {
        XCTAssertEqual(vm.favorites, [])
        XCTAssertFalse(vm.isFavorite(Self.testStation))
        XCTAssertFalse(vm.showsFavoritesSection)
    }

    func testToggleFavorite_addsStation() async {
        vm.toggleFavorite(Self.testStation)

        await waitFor(!vm.favorites.isEmpty)
        XCTAssertEqual(vm.favorites.count, 1)
        XCTAssertTrue(vm.isFavorite(Self.testStation))
    }

    func testToggleFavorite_removesStation() async {
        vm.toggleFavorite(Self.testStation)
        await waitFor(!vm.favorites.isEmpty)

        vm.toggleFavorite(Self.testStation)
        await waitFor(vm.favorites.isEmpty)

        XCTAssertEqual(vm.favorites.count, 0)
        XCTAssertFalse(vm.isFavorite(Self.testStation))
    }

    func testToggleFavorite_optimisticUpdate() {
        // El array local debe actualizarse SINCRÓNICAMENTE para que la UI
        // responda al instante. La persistencia ocurre en background.
        XCTAssertFalse(vm.isFavorite(Self.testStation))
        vm.toggleFavorite(Self.testStation)
        XCTAssertTrue(vm.isFavorite(Self.testStation),
                      "Optimistic update: favoritos debe reflejar el cambio sin esperar a disco")
    }

    func testLoadFavorites_readsFromRepo() async throws {
        // Pre-poblamos el repo, luego llamamos loadFavorites.
        try await favoritesRepo.add(Self.testStation)

        vm.loadFavorites()
        await waitFor(!vm.favorites.isEmpty)

        XCTAssertEqual(vm.favorites.count, 1)
        XCTAssertEqual(vm.favorites[0].id, "fav-1")
    }

    func testShowsFavoritesSection_trueWhenFavoritesExistAndQueryEmpty() async {
        vm.toggleFavorite(Self.testStation)
        await waitFor(!vm.favorites.isEmpty)

        vm.query = ""
        XCTAssertTrue(vm.showsFavoritesSection)
    }

    func testShowsFavoritesSection_falseWhenQueryNonEmpty() async {
        // Cuando hay query activo, no mostramos favoritos para no competir
        // con resultados de búsqueda.
        vm.toggleFavorite(Self.testStation)
        await waitFor(!vm.favorites.isEmpty)

        vm.query = "rock"
        XCTAssertFalse(vm.showsFavoritesSection)
    }

    func testShowsFavoritesSection_falseWhenNoFavorites() {
        vm.query = ""
        XCTAssertFalse(vm.showsFavoritesSection)
    }

    func testFavorites_persistAcrossViewModels() async throws {
        // Toggle desde el VM original.
        vm.toggleFavorite(Self.testStation)
        await waitFor(!vm.favorites.isEmpty)

        // Esperar a que la persistencia background acabe (la VM hace optimistic
        // update + Task async).
        try await Task.sleep(for: .milliseconds(100))

        // Crear un nuevo VM apuntando al mismo repo.
        let http = HTTPClient(session: URLSession.mocked())
        let client = RadioBrowserClient(http: http, baseURL: baseURL, userAgent: "Test/1.0")
        let vm2 = RadioBrowseViewModel(client: client, favoritesRepo: favoritesRepo, debounceMs: 1)
        vm2.loadFavorites()

        await waitFor(!vm2.favorites.isEmpty)
        XCTAssertEqual(vm2.favorites.count, 1)
        XCTAssertEqual(vm2.favorites[0].id, "fav-1")
    }
}

// MARK: - Test helpers

private extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
