//
//  NowPlayingHelper.swift
//  RadioPremium-iOS
//
//  Integración con Control Center / lock screen vía MPNowPlayingInfoCenter
//  + MPRemoteCommandCenter. Para radio en directo solo exponemos play/pause
//  (no skip ni seek).
//

import Foundation
import MediaPlayer
import UIKit
import os

@MainActor
final class NowPlayingHelper {

    private weak var player: IOSAudioPlayer?
    private var artworkCache: [URL: UIImage] = [:]
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "nowplaying")

    init(player: IOSAudioPlayer) {
        self.player = player
        registerCommands()
    }

    func update(station: Station?, state: IOSPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()

        guard let station else {
            center.nowPlayingInfo = nil
            return
        }

        // El subtítulo es lo único que el coche puede contarte mientras
        // conduces: durante una reconexión debe decirlo, no quedarse mudo.
        let subtitle: String = {
            switch state {
            case .reconnecting(let attempt):
                return attempt == 1 ? "Reconectando…" : "Reconectando… (\(attempt))"
            case .buffering:
                return "Conectando…"
            default:
                return station.country ?? "Radio Premium"
            }
        }()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: station.name,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]

        if let url = station.favicon {
            if let image = artworkCache[url] {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                Task { [weak self] in
                    await self?.loadAndCacheArtwork(from: url, for: station, currentState: state)
                }
            }
        }

        center.nowPlayingInfo = info
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            Task { @MainActor in p.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            Task { @MainActor in p.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            Task { @MainActor in p.togglePlayPause() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            Task { @MainActor in p.stop() }
            return .success
        }

        // Radio en directo: nada de skip / seek.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func loadAndCacheArtwork(from url: URL, for station: Station, currentState: IOSPlaybackState) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            artworkCache[url] = image
            update(station: station, state: currentState)
        } catch {
            log.debug("artwork load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
