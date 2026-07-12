//
//  AppModel.swift
//  RadioPremium-iOS
//
//  Container observable que cuelga del @main App y se inyecta al árbol de
//  vistas vía .environment(_:). Tiene el player, favoritos, lista de
//  emisoras top y el helper de Now Playing.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class AppModel {

    let player: IOSAudioPlayer
    let favorites: FavoritesStore
    private let api: RadioBrowserAPI
    private let nowPlaying: NowPlayingHelper

    private(set) var topStations: [Station] = []
    private(set) var searchResults: [Station] = []
    private(set) var isLoadingTop = false
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "app")

    init() {
        let player = IOSAudioPlayer()
        self.player = player
        self.favorites = FavoritesStore()
        self.api = RadioBrowserAPI()
        self.nowPlaying = NowPlayingHelper(player: player)
    }

    // MARK: - Browse

    func loadTopStations() async {
        guard !isLoadingTop else { return }
        isLoadingTop = true
        defer { isLoadingTop = false }

        do {
            topStations = try await api.topStations(limit: 50)
            errorMessage = nil
        } catch {
            log.error("topStations failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "No se pudieron cargar las emisoras: \(error.localizedDescription)"
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await api.search(name: trimmed, limit: 50)
            errorMessage = nil
        } catch {
            log.error("search failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Error de búsqueda: \(error.localizedDescription)"
        }
    }

    func clearSearch() {
        searchResults = []
    }

    // MARK: - Playback

    func play(_ station: Station) {
        player.play(station)
        // Update Now Playing inmediato + cuando cambie el estado por KVO
        // re-publicamos vía observer side effect.
        nowPlaying.update(station: station, state: player.state)
        // Observador ad-hoc del cambio de estado:
        Task { @MainActor in
            // Pequeño bucle: cuando cambie el state, refrescar.
            // Con @Observable + el hecho de que las views observan al player
            // directamente, esto solo refresca la metadata del Control Center.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                nowPlaying.update(station: station, state: player.state)
                if case .error = player.state { break }
            }
        }
    }

    func togglePlayPause() {
        player.togglePlayPause()
        if let s = player.currentStation {
            nowPlaying.update(station: s, state: player.state)
        }
    }

    func stop() {
        player.stop()
        nowPlaying.update(station: nil, state: .idle)
    }
}
