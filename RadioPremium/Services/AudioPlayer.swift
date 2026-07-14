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
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import CoreAudio
#endif

@MainActor
@Observable
final class AudioPlayer {

    // MARK: - Estado observable

    private(set) var state: PlaybackState = .idle
    private(set) var currentURL: URL?

    /// Identificador de la sesión de reproducción actual. Se regenera en cada
    /// `play()` (acción de usuario / cambio de emisora) y en `stop()`.
    /// Los consumidores (p.ej. RecentStationsStore) lo usan para deduplicar
    /// eventos dentro de una misma reproducción: rebufferings y transiciones
    /// de estado de la misma sesión comparten ID. Fase 2 añadirá reintentos
    /// internos que CONSERVAN este ID (vía startPlayback) y pause(reason:).
    private(set) var playbackSessionID = UUID()

    /// `true` solo cuando la última pausa vino de una acción DELIBERADA del
    /// usuario (botón pausa de la UI). Las pausas por causas externas
    /// (detección de oído de los AirPods vía comando de media, sleep del
    /// sistema) lo dejan en `false`. Gobierna el auto-resume por cambio de
    /// ruta de audio: si tú pausaste a propósito, un cambio de dispositivo
    /// NO reanuda.
    private var lastPauseWasUserInitiated = false

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
    #if os(macOS)
    /// Bloque del listener de Core Audio para el cambio de dispositivo de
    /// salida por defecto. Se guarda para poder retirarlo si hiciera falta.
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    #endif

    // MARK: - Init / deinit

    init(initialVolume: Float = 0.8) {
        self.volume = max(0, min(1, initialVolume))
        player.volume = self.volume
        player.automaticallyWaitsToMinimizeStalling = true
        observeRate()
        configureAudioSession()
        registerSleepHandler()
        registerOutputDeviceListener()
    }

    /// Configura `AVAudioSession` para reproducción de streams de radio en iOS.
    /// `.playback` permite que el audio suene aunque el iPhone esté bloqueado
    /// y aparece en Control Center. En macOS no hay AVAudioSession.
    private func configureAudioSession() {
        #if canImport(UIKit) && !os(watchOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            AppLogger.audio.error("AVAudioSession setup failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    // No custom deinit:
    //   - NSKeyValueObservation handles auto-invalidate al desalojarse.
    //   - Tokens block-based de NotificationCenter / NSWorkspace auto-cancelan
    //     la observación cuando se sueltan.
    // Un deinit MainActor-isolated complicaría sin ganancia.

    // MARK: - Public API

    /// Carga un stream nuevo y empieza a reproducir.
    /// Si ya había algo sonando, lo reemplaza limpiamente.
    /// Acción de usuario: regenera la sesión de reproducción.
    func play(url: URL) {
        AppLogger.audio.info("play url=\(url.absoluteString, privacy: .public)")
        playbackSessionID = UUID()
        lastPauseWasUserInitiated = false
        loadAndPlay(url: url)
    }

    /// Carga el item y arranca SIN regenerar la sesión. Uso interno para
    /// reanudaciones automáticas (p.ej. auto-resume por cambio de ruta de
    /// audio) que deben preservar la sesión para no ensuciar "recientes".
    private func loadAndPlay(url: URL) {
        let item = AVPlayerItem(url: url)
        observeItem(item)
        player.replaceCurrentItem(with: item)
        currentURL = url
        state = .buffering
        player.play()
    }

    /// Pausa el stream actual sin descargarlo.
    /// - Parameter userInitiated: `true` cuando lo dispara el usuario a
    ///   propósito (botón pausa). En ese caso, un cambio de ruta de audio
    ///   posterior NO reanudará automáticamente. Las pausas externas
    ///   (detección de oído, sleep) pasan `false`.
    func pause(userInitiated: Bool = false) {
        AppLogger.audio.info("pause (userInitiated: \(userInitiated, privacy: .public))")
        lastPauseWasUserInitiated = userInitiated
        player.pause()
        // El observer de rate también detectará esto; ponemos paused
        // explícitamente para que el cambio de UI sea instantáneo.
        if state == .playing || state == .buffering {
            state = .paused
        }
    }

    /// Reanuda el stream pausado. Si no había nada cargado, no-op.
    ///
    /// Caso especial: si el item interno se quedó roto (state `.error`, item
    /// status `.failed`, o `currentItem` nil tras un route change — p.ej.
    /// desconexión de cascos), `player.play()` por sí solo NO recupera el
    /// stream. En esos casos recreamos el AVPlayerItem desde `currentURL`,
    /// que sí restaura el playback. Antes de este fix, la única forma de
    /// recuperar tras una desconexión era cerrar y reabrir la app.
    func resume() {
        guard let url = currentURL else { return }
        AppLogger.audio.info("resume")

        // `.error` lleva associated value (reason: String), no se puede comparar
        // con ==; usamos pattern matching `if case`.
        let inErrorState: Bool
        if case .error = state { inErrorState = true } else { inErrorState = false }

        let itemNeedsRebuild = player.currentItem == nil
            || player.currentItem?.status == .failed
            || inErrorState
        if itemNeedsRebuild {
            AppLogger.audio.info("resume: item en mal estado → recreando AVPlayerItem")
            play(url: url)
            return
        }

        if state == .paused || inErrorState {
            state = .buffering
        }
        player.play()
    }

    /// Para por completo, libera el item, vuelve a idle.
    /// Invalida la sesión de reproducción: nada pendiente de una sesión
    /// anterior (reintentos, reanudaciones) debe sobrevivir a un stop.
    func stop() {
        AppLogger.audio.info("stop")
        playbackSessionID = UUID()
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

    /// macOS: cuando el sistema va a dormir, pausa el stream. iOS no
    /// necesita esto — `AVAudioSession` + background mode "audio" gestionan
    /// las interrupciones (call, otra app, etc.) automáticamente.
    private func registerSleepHandler() {
        #if canImport(AppKit)
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
        #endif
    }

    // MARK: - Auto-resume por cambio de ruta de audio (macOS)

    #if os(macOS)
    /// Registra un listener de Core Audio sobre el dispositivo de salida por
    /// defecto. Cuando la salida vuelve a un dispositivo EXTERNO (cascos,
    /// AirPods, etc.) tras una pausa no deliberada, reanuda solo.
    ///
    /// Limitación conocida: quitar/poner UN solo AirPod NO cambia el
    /// dispositivo de salida (la ruta sigue en los AirPods), así que ese
    /// gesto concreto no dispara este listener — macOS no expone ninguna
    /// señal pública para él. Sí cubre: quitar los dos AirPods (la salida
    /// cae a los altavoces y vuelve), desconexión/reconexión Bluetooth, y
    /// cambio manual de dispositivo de salida.
    private func registerOutputDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // El listener se invoca en la cola main que pasamos abajo, pero
            // Swift Concurrency no lo sabe: saltamos explícitamente al actor.
            Task { @MainActor in self?.handleOutputDeviceChanged() }
        }
        outputDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        // No lo retiramos en deinit: AudioPlayer vive lo que vive la app
        // (instancia única); la terminación del proceso lo limpia.
    }

    private func handleOutputDeviceChanged() {
        guard let url = currentURL else { return }           // nada cargado / stop
        guard !lastPauseWasUserInitiated else {              // pausa deliberada → respetar
            AppLogger.audio.info("route change: pausa fue del usuario, no auto-resume")
            return
        }
        // Solo reanudamos si estamos pausados o en error (no si ya suena).
        let eligibleState: Bool
        switch state {
        case .paused, .error: eligibleState = true
        case .idle, .playing, .buffering: eligibleState = false
        }
        guard eligibleState else { return }

        // Solo si la nueva salida es un dispositivo EXTERNO. Volver a los
        // altavoces internos NO debe soltar audio de golpe (guía de Apple).
        let newDevice = Self.defaultOutputDevice()
        guard !Self.isBuiltInSpeakers(newDevice) else {
            AppLogger.audio.info("route change → altavoces internos, no auto-resume")
            return
        }

        AppLogger.audio.info("route change → dispositivo externo, auto-resume (rebuild, sesión preservada)")
        loadAndPlay(url: url)   // preserva playbackSessionID
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func isBuiltInSpeakers(_ id: AudioDeviceID) -> Bool {
        guard id != 0 else { return false }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        guard status == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
    #else
    private func registerOutputDeviceListener() {}
    #endif
}
