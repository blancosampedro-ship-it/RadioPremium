//
//  PlayerViewModel.swift
//  RadioPremium
//
//  Coordina AudioPlayer + NowPlayingCenter + estación actual.
//  Expone una API mínima que la UI consume: play(_:), togglePlayPause(),
//  stop(). Estado observable: currentStation, isPlaying, isBuffering, volume.
//
//  Decisión 1B del eng review: per-feature ViewModel, no god object.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class PlayerViewModel {

    let player: AudioPlayer
    private let nowPlaying: NowPlayingCenter

    /// Opcionales para no obligar a los tests existentes a inyectarlos.
    /// En producción los inyecta RadioPremiumApp.
    private let settings: JSONStore<AppSettings>?
    private let recents: RecentStationsStore?

    private(set) var currentStation: Station?

    private var volumeSaveTask: Task<Void, Never>?

    var volume: Float {
        get { player.volume }
        set {
            player.volume = newValue
            scheduleVolumeSave(newValue)
        }
    }

    var state: PlaybackState { player.state }

    var isPlaying: Bool {
        if case .playing = player.state { return true }
        return false
    }

    var isBuffering: Bool {
        if case .buffering = player.state { return true }
        return false
    }

    var hasActiveStation: Bool {
        currentStation != nil
    }

    init(
        initialVolume: Float = 0.8,
        settings: JSONStore<AppSettings>? = nil,
        recents: RecentStationsStore? = nil
    ) {
        let player = AudioPlayer(initialVolume: initialVolume)
        self.player = player
        self.nowPlaying = NowPlayingCenter(player: player)
        self.settings = settings
        self.recents = recents
        observePlayerState()
        restorePersistedState()
    }

    // MARK: - Public commands

    /// Reproduce la emisora dada. Reemplaza la actual sin coste.
    func play(_ station: Station) {
        guard let url = station.streamURL else {
            AppLogger.audio.error("play(_:) station '\(station.name, privacy: .public)' sin streamURL")
            return
        }
        currentStation = station
        player.play(url: url)
        nowPlaying.update(station: station, state: player.state)
    }

    /// Toggle play/pause sobre la emisora actual.
    /// Si no hay emisora activa, no-op.
    func togglePlayPause() {
        guard let station = currentStation else { return }
        switch player.state {
        case .playing, .buffering:
            player.pause(userInitiated: true)
        case .paused, .error:
            player.resume()
        case .idle:
            // .idle con emisora presente = restauración de última emisora
            // al arrancar (player sin item cargado). Arranque fresco.
            if player.currentURL == nil {
                play(station)
            } else {
                player.resume()
            }
        }
    }

    /// Para por completo y libera la emisora actual.
    func stop() {
        player.stop()
        currentStation = nil
        nowPlaying.update(station: nil, state: .idle)
    }

    // MARK: - Internals

    /// Carga estado persistido al arrancar: volumen guardado y última
    /// emisora (precargada en pausa, SIN autoplay — el usuario decide).
    private func restorePersistedState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let settings = self.settings {
                let loaded = await settings.load()
                // Aplicar directo al player (no via self.volume) para no
                // disparar un save redundante del valor recién leído.
                self.player.volume = max(0, min(1, loaded.volume))
            }
            if let recents = self.recents,
               self.currentStation == nil,
               self.player.state == .idle,
               let last = await recents.lastPlayed() {
                // Solo precargar si el usuario no empezó a reproducir ya.
                guard self.currentStation == nil, self.player.state == .idle else { return }
                self.currentStation = last
                AppLogger.audio.info("restored last station '\(last.name, privacy: .public)' (paused)")
            }
        }
    }

    /// Persiste el volumen con debounce de 1s (evita escribir en cada tick
    /// del slider).
    private func scheduleVolumeSave(_ newValue: Float) {
        guard let settings else { return }
        volumeSaveTask?.cancel()
        volumeSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            var current = await settings.load()
            current.volume = newValue
            try? await settings.save(current)
        }
    }

    /// Observa cambios en el estado del player para mantener Now Playing
    /// sincronizado. Usa `withObservationTracking` para reaccionar al @Observable.
    /// También registra la emisora en recientes cuando la reproducción llega
    /// DE VERDAD a .playing (una vez por sesión — el store deduplica por
    /// playbackSessionID, así los rebufferings no re-registran).
    private func observePlayerState() {
        // Un loop continuo que re-suscribe a cada cambio observado.
        // Lightweight: solo se ejecuta cuando @Observable dispara.
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = withObservationTracking {
                    (self.player.state, self.currentStation)
                } onChange: { }
                self.nowPlaying.update(station: snapshot.1, state: snapshot.0)

                if case .playing = snapshot.0, let station = snapshot.1, let recents = self.recents {
                    let sessionID = self.player.playbackSessionID
                    Task {
                        try? await recents.recordPlayed(station, sessionID: sessionID)
                    }
                }

                // Esperamos al siguiente cambio observable.
                await self.waitForNextChange()
            }
        }
    }

    private func waitForNextChange() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = self.player.state
                _ = self.currentStation
            } onChange: {
                cont.resume()
            }
        }
    }
}
