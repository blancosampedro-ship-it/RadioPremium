//
//  AudioPlayer.swift
//  RadioPremium
//
//  Wrap de AVPlayer para streams de radio. @MainActor porque AVPlayer es
//  más predecible en main thread; todas las llamadas y KVO viven aquí.
//
//  @Observable expone state, currentURL y volume; PlayerViewModel observa
//  esto y la UI re-renderiza automáticamente cuando cambian.
//
//  Sleep handler integrado: cuando el sistema va a dormir, pausa el stream
//  (decisión 1F del eng review). NO auto-resume al despertar — usuario decide.
//

import Foundation
import AVFoundation
import AppKit
import os

@MainActor
@Observable
final class AudioPlayer {

    // MARK: - Estado observable

    private(set) var state: PlaybackState = .idle
    private(set) var currentURL: URL?

    var volume: Float {
        didSet {
            let clamped = max(0, min(1, volume))
            if clamped != volume { volume = clamped; return }
            player.volume = clamped
        }
    }

    // MARK: - Internals

    private let player = AVPlayer()
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var bufferLikelyObserver: NSKeyValueObservation?
    private var failedToPlayToEndObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    // MARK: - Init / deinit

    init(initialVolume: Float = 0.8) {
        self.volume = max(0, min(1, initialVolume))
        player.volume = self.volume
        player.automaticallyWaitsToMinimizeStalling = true
        observeRate()
        registerSleepHandler()
    }

    // No custom deinit:
    //   - NSKeyValueObservation handles auto-invalidate al desalojarse.
    //   - Tokens block-based de NotificationCenter / NSWorkspace auto-cancelan
    //     la observación cuando se sueltan.
    // Un deinit MainActor-isolated complicaría sin ganancia.

    // MARK: - Public API

    /// Carga un stream nuevo y empieza a reproducir.
    /// Si ya había algo sonando, lo reemplaza limpiamente.
    func play(url: URL) {
        AppLogger.audio.info("play url=\(url.absoluteString, privacy: .public)")
        let item = AVPlayerItem(url: url)
        observeItem(item)
        player.replaceCurrentItem(with: item)
        currentURL = url
        state = .buffering
        player.play()
    }

    /// Pausa el stream actual sin descargarlo.
    func pause() {
        AppLogger.audio.info("pause")
        player.pause()
        // El observer de rate también detectará esto; ponemos paused
        // explícitamente para que el cambio de UI sea instantáneo.
        if state == .playing || state == .buffering {
            state = .paused
        }
    }

    /// Reanuda el stream pausado. Si no había nada cargado, no-op.
    func resume() {
        guard currentURL != nil else { return }
        AppLogger.audio.info("resume")
        if state == .paused {
            state = .buffering
        }
        player.play()
    }

    /// Para por completo, libera el item, vuelve a idle.
    func stop() {
        AppLogger.audio.info("stop")
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        state = .idle
    }

    // MARK: - Observers

    private func observeRate() {
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            Task { @MainActor in
                self.handleRateChange(change.newValue ?? 0)
            }
        }
    }

    private func handleRateChange(_ rate: Float) {
        if rate > 0 {
            // Reproduciendo (o reanudando tras buffer)
            if state != .playing {
                state = .playing
            }
        } else {
            // rate == 0: pausado, parado o buffering. Si tenemos URL y no
            // estamos en error/paused explícito, asumimos buffering temporal.
            if state == .playing {
                state = .buffering
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        // Status: readyToPlay / failed / unknown
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleItemStatus(item)
            }
        }

        // Buffer estados — útiles para mostrar "Conectando..." vs "Reproduciendo"
        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.isPlaybackBufferEmpty && self.state == .playing {
                    self.state = .buffering
                }
            }
        }

        bufferLikelyObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.isPlaybackLikelyToKeepUp && self.state == .buffering && self.player.rate > 0 {
                    self.state = .playing
                }
            }
        }

        // Stream caído mid-playback
        if let token = failedToPlayToEndObserver {
            NotificationCenter.default.removeObserver(token)
        }
        failedToPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? "stream interrumpido"
            Task { @MainActor in
                guard let self else { return }
                AppLogger.audio.error("failedToPlayToEnd: \(reason, privacy: .public)")
                self.state = .error(reason: reason)
            }
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            // El rate observer manejará la transición a .playing cuando arranque
            break
        case .failed:
            let reason = item.error?.localizedDescription ?? "no se pudo cargar el stream"
            AppLogger.audio.error("item failed: \(reason, privacy: .public)")
            state = .error(reason: reason)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Sleep handler (decisión 1F)

    private func registerSleepHandler() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state.isActive {
                    AppLogger.audio.info("system willSleep → pausing playback")
                    self.pause()
                }
            }
        }
    }
}
