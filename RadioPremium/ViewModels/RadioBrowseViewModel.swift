//
//  RadioBrowseViewModel.swift
//  RadioPremium
//
//  Coordina las búsquedas de emisoras vía RadioBrowserClient + gestiona
//  el estado de favoritos (persistidos en FavoritesRepository).
//
//  Patrón debounce: cada cambio de `query` cancela la búsqueda en curso y
//  programa una nueva tras `debounceMs` ms. Solo la última supera el debounce
//  y dispara request real. Esto evita spam de requests al teclear letra a letra.
//
//  Cuando el query queda vacío, carga "populares" (top votadas globalmente)
//  como entry point: el popover nunca está vacío. Si hay favoritos guardados,
//  la View los renderiza ARRIBA de los populares en una sección propia.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class RadioBrowseViewModel {

    private let client: RadioBrowserClient
    private let favoritesRepo: FavoritesRepository?
    private let debounceMs: Int
    private let limit: Int

    var query: String = ""
    private(set) var results: [Station] = []
    private(set) var favorites: [Station] = []
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var favoritesTask: Task<Void, Never>?

    var sectionTitle: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Populares" }
        return "Resultados para \"\(trimmed)\""
    }

    var emptyStateMessage: String? {
        // Mensajes derivados según D2 del /plan-design-review.
        if isLoading || !results.isEmpty || errorMessage != nil { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Cargando emisoras populares…"
        } else {
            return "Sin resultados para \"\(trimmed)\""
        }
    }

    /// La sección "Favoritos" se renderiza solo cuando hay favoritos guardados
    /// y NO hay query activo (los favoritos no compiten visualmente con
    /// resultados de búsqueda — el usuario está buscando algo concreto).
    var showsFavoritesSection: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty && !favorites.isEmpty
    }

    init(
        client: RadioBrowserClient,
        favoritesRepo: FavoritesRepository? = nil,
        debounceMs: Int = 300,
        limit: Int = 30
    ) {
        self.client = client
        self.favoritesRepo = favoritesRepo
        self.debounceMs = debounceMs
        self.limit = limit
    }

    // MARK: - Comandos

    /// Carga inicial / fallback al limpiar query: top emisoras globales.
    /// Llamar desde la View en `.task` cuando el popover aparece.
    func loadPopular() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoading = true
            self.errorMessage = nil
            do {
                let stations = try await self.client.popular(limit: self.limit)
                if Task.isCancelled { return }
                self.results = stations
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.handleError(error)
            }
        }
    }

    /// Llamar cuando el usuario cambia el query. Debounce + ejecuta search.
    /// Si el query queda vacío, recarga "populares".
    func performSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            loadPopular()
            return
        }

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(self.debounceMs))
            if Task.isCancelled { return }

            self.isLoading = true
            self.errorMessage = nil
            AppLogger.radio.debug("browse search '\(trimmed, privacy: .public)'")

            do {
                let stations = try await self.client.search(query: trimmed, limit: self.limit)
                if Task.isCancelled { return }
                self.results = stations
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.handleError(error)
            }
        }
    }

    /// Cancela cualquier búsqueda en curso (al cerrar popover, etc).
    ///
    /// Restablece `isLoading` aquí y no en los catch de cancelación: cuando la
    /// Task muere por REEMPLAZO (nueva búsqueda), la nueva ya gestiona el flag,
    /// y que la vieja lo apagase después dejaría la carga real sin spinner.
    /// Sin este reset, cerrar el popover a mitad de búsqueda dejaba
    /// isLoading=true para siempre (la vista solo relanza si results está vacío).
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        favoritesTask?.cancel()
        favoritesTask = nil
        isLoading = false
    }

    // MARK: - Favoritos

    /// Carga los favoritos persistidos. Llamar al aparecer el popover.
    /// Idempotente — llamar varias veces es seguro.
    func loadFavorites() {
        favoritesTask?.cancel()
        favoritesTask = Task { @MainActor [weak self] in
            guard let self, let repo = self.favoritesRepo else { return }
            let entries = await repo.load()
            if Task.isCancelled { return }
            self.favorites = entries.map(\.station)
        }
    }

    /// `true` si la emisora está en favoritos (lectura síncrona del estado UI).
    func isFavorite(_ station: Station) -> Bool {
        favorites.contains { $0.id == station.id }
    }

    /// Marca/desmarca como favorita. Persiste en disco y actualiza el array
    /// local optimísticamente para que la UI responda al instante.
    func toggleFavorite(_ station: Station) {
        guard let repo = favoritesRepo else { return }

        // Optimistic update del array local (la UI reacciona ya).
        let wasFavorite = isFavorite(station)
        if wasFavorite {
            favorites.removeAll { $0.id == station.id }
        } else {
            favorites.insert(station, at: 0)
        }

        // Persistencia async — si falla, revertimos.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await repo.toggle(station)
            } catch {
                // Revert en caso de fallo de I/O: recargamos el estado REAL del
                // repo en vez de reconstruirlo a mano — dos toggles rápidos de la
                // misma emisora podían revertir sobre un array ya cambiado y
                // duplicar la entrada.
                AppLogger.storage.error(
                    "toggle favorite failed for '\(station.name, privacy: .public)': \(error.localizedDescription, privacy: .public). Recargando del repo."
                )
                let entries = await repo.load()
                self.favorites = entries.map(\.station)
            }
        }
    }

    // MARK: - Internals

    private func handleError(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        AppLogger.radio.error("browse error: \(msg, privacy: .public)")
        errorMessage = msg
        isLoading = false
        results = []
    }
}
