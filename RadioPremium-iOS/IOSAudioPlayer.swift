//
//  IOSAudioPlayer.swift
//  RadioPremium-iOS
//
//  Wrap de AVPlayer para streams de radio en iOS. Configura AVAudioSession
//  con categoría `.playback` para que el audio siga sonando con el iPhone
//  bloqueado y aparezca en Control Center.
//
//  Para que el audio continúe en background hay que añadir además la
//  capability "Audio, AirPlay, and Picture in Picture" en el target
//  (en Xcode: Signing & Capabilities → + → Background Modes → Audio).
//

import Foundation
import AVFoundation
import Observation
import os

enum IOSPlaybackState: Equatable, Sendable {
    case idle
    case buffering
    case playing
    case paused
    case error(reason: String)

    var isActive: Bool {
        switch self {
        case .buffering, .playing: return true
        default:                   return false
        }
    }
}

@MainActor
@Observable
final class IOSAudioPlayer {

    // MARK: - Observable state

    private(set) var state: IOSPlaybackState = .idle
    private(set) var currentStation: Station?

    var volume: Float {
        didSet {
            let clamped = max(0, min(1, volume))
            if clamped != volume { volume = clamped; return }
            player.volume = clamped
        }
    }

    // MARK: - Internals

    private let player = AVPlayer()
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var bufferLikelyObserver: NSKeyValueObservation?
    private var failedObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "audio")

    init(initialVolume: Float = 0.8) {
        self.volume = max(0, min(1, initialVolume))
        player.volume = self.volume
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        observeRate()
    }

    // MARK: - Public API

    func play(_ station: Station) {
        log.info("play station=\(station.name, privacy: .public) url=\(station.url.absoluteString, privacy: .public)")
        activateAudioSession()
        let item = AVPlayerItem(url: station.url)
        observeItem(item)
        player.replaceCurrentItem(with: item)
        currentStation = station
        state = .buffering
        player.play()
    }

    func pause() {
        log.info("pause")
        player.pause()
    }

    func resume() {
        // Port del fix de macOS (AudioPlayer.resume): tras un corte del stream,
        // player.play() sobre un item roto NO recupera nada — hay que
        // reconstruir el AVPlayerItem. Sin esto, el botón de play quedaba
        // muerto tras cada desconexión hasta re-seleccionar la emisora.
        let itemBroken = player.currentItem == nil || player.currentItem?.status == .failed
        let inErrorState: Bool = {
            if case .error = state { return true }
            return false
        }()
        if itemBroken || inErrorState {
            guard let station = currentStation else { return }
            log.info("resume: item roto o estado error — reconstruyendo AVPlayerItem")
            play(station)
            return
        }
        log.info("resume")
        activateAudioSession()
        player.play()
    }

    func stop() {
        log.info("stop")
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStation = nil
        state = .idle
        // Devolver el audio a quien sonara antes (Apple Music, podcasts…).
        deactivateAudioSession()
    }

    func togglePlayPause() {
        switch state {
        case .playing, .buffering: pause()
        case .paused, .idle, .error: resume()
        }
    }

    // MARK: - AudioSession setup

    /// Solo la CATEGORÍA en el init. La activación se difiere a play()/resume():
    /// activar una sesión .playback (no mezclable) INTERRUMPE el audio de otras
    /// apps en ese instante — con CarPlay, abrir la app para mirar favoritos
    /// silenciaba lo que sonara en el coche sin haber pulsado nada. La guía de
    /// Apple es activar al empezar a reproducir, no al arrancar la app.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            log.debug("AVAudioSession category .playback configurada")
        } catch {
            log.error("AVAudioSession setCategory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("AVAudioSession activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Frecuente e inofensivo si AVPlayer aún drena I/O; solo log.
            log.debug("AVAudioSession deactivate: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - KVO observers

    private func observeRate() {
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            Task { @MainActor in
                let rate = change.newValue ?? 0
                if rate > 0 {
                    // Solo cambiar a .playing si veníamos de buffering/idle
                    if self.state == .buffering || self.state == .idle {
                        self.state = .playing
                    }
                } else {
                    // rate == 0 puede ser .paused o .idle. Si tenemos item y
                    // estado activo, asumimos paused.
                    if self.state.isActive {
                        self.state = .paused
                    }
                }
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        // Limpiar observers anteriores
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        bufferLikelyObserver?.invalidate()
        if let token = failedObserver {
            NotificationCenter.default.removeObserver(token)
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .failed {
                    let reason = item.error?.localizedDescription ?? "no se pudo cargar el stream"
                    self.log.error("item failed: \(reason, privacy: .public)")
                    self.state = .error(reason: reason)
                }
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.isPlaybackBufferEmpty && self.state == .playing {
                    self.state = .buffering
                }
            }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "playback finalizó por error"
            Task { @MainActor in
                self?.log.error("failed to play to end: \(reason, privacy: .public)")
                self?.state = .error(reason: reason)
            }
        }
    }
}
