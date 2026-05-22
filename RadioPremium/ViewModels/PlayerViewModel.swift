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

    private(set) var currentStation: Station?

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
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

    init(initialVolume: Float = 0.8) {
        let player = AudioPlayer(initialVolume: initialVolume)
        self.player = player
        self.nowPlaying = NowPlayingCenter(player: player)
        observePlayerState()
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
        guard currentStation != nil else { return }
        switch player.state {
        case .playing, .buffering:
            player.pause()
        case .paused, .idle, .error:
            player.resume()
        }
    }

    /// Para por completo y libera la emisora actual.
    func stop() {
        player.stop()
        currentStation = nil
        nowPlaying.update(station: nil, state: .idle)
    }

    // MARK: - Internals

    /// Observa cambios en el estado del player para mantener Now Playing
    /// sincronizado. Usa `withObservationTracking` para reaccionar al @Observable.
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
