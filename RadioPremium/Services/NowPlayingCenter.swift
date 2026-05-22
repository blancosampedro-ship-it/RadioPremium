//
//  NowPlayingCenter.swift
//  RadioPremium
//
//  Integración con MediaPlayer del sistema. Expone metadata via
//  MPNowPlayingInfoCenter (lo que ves en Control Center) y registra
//  comandos remotos para que play/pause del Control Center hablen
//  con nuestro AudioPlayer.
//
//  Para una emisora de radio (live stream sin duración), llenamos:
//    - MPMediaItemPropertyTitle      → nombre de la emisora (o título de canción si la sabemos)
//    - MPMediaItemPropertyArtist     → "Radio Premium" o el país de la emisora
//    - MPNowPlayingInfoPropertyIsLiveStream → true
//    - MPMediaItemPropertyArtwork    → favicon de la emisora cuando esté
//

import Foundation
import MediaPlayer
import AppKit
import os

@MainActor
final class NowPlayingCenter {

    private weak var player: AudioPlayer?
    private var artworkCache: [URL: NSImage] = [:]

    init(player: AudioPlayer) {
        self.player = player
        registerCommands()
    }

    /// Actualiza el Control Center con el estado actual y la emisora dada.
    /// Llamar cuando cambia la emisora o el estado del player.
    func update(station: Station?, state: PlaybackState) {
        let center = MPNowPlayingInfoCenter.default()

        guard let station else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: station.name,
            MPMediaItemPropertyArtist: station.country ?? "Radio Premium",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0
        ]

        if let url = station.faviconURL {
            if let image = artworkCache[url] {
                info[MPMediaItemPropertyArtwork] = makeArtwork(from: image)
            } else {
                Task { [weak self] in
                    await self?.loadAndCacheArtwork(from: url, for: station, currentState: state)
                }
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = mapToMPState(state)
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.resume()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            switch player.state {
            case .playing, .buffering:
                player.pause()
            case .paused, .idle, .error:
                player.resume()
            }
            return .success
        }

        center.stopCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.stop()
            return .success
        }

        // Comandos no soportados por radio en directo: skip/seek.
        // Los desactivamos para que el Control Center no muestre los botones.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    // MARK: - State mapping

    private func mapToMPState(_ state: PlaybackState) -> MPNowPlayingPlaybackState {
        switch state {
        case .idle:                  return .stopped
        case .buffering, .playing:   return .playing
        case .paused:                return .paused
        case .error:                 return .interrupted
        }
    }

    // MARK: - Artwork loading

    private func loadAndCacheArtwork(from url: URL, for station: Station, currentState: PlaybackState) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else { return }
            artworkCache[url] = image
            // Re-update si la emisora todavía es la activa
            update(station: station, state: currentState)
        } catch {
            AppLogger.audio.debug("artwork load failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeArtwork(from image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
