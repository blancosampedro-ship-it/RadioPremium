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
//  RECONEXIÓN AUTOMÁTICA (el caso del coche)
//  ------------------------------------------
//  Escuchando por CarPlay, atravesar un túnel o una zona sin cobertura mataba
//  la reproducción y NO volvía sola: había que tocar el iPhone o la pantalla
//  del coche. Tres cosas lo causaban:
//
//   1. Con `automaticallyWaitsToMinimizeStalling = true`, AVPlayer ante una
//      conexión muerta NO da error: se queda esperando datos indefinidamente.
//      Sin estado .error, `resume()` (que sí sabe reconstruir el item) nunca
//      se disparaba. Silencio permanente sin ningún síntoma detectable.
//   2. Aunque hubiera error, nada lo reintentaba: solo un toque del usuario.
//   3. Sin saber cuándo vuelve la red, reintentar era a ciegas.
//
//  Ahora: un watchdog detecta el atasco (no solo el error), un bucle
//  reintenta con backoff mientras el usuario QUIERA estar escuchando
//  (`shouldBePlaying`), y NWPathMonitor dispara el reintento en cuanto la red
//  vuelve, en vez de esperar al siguiente tick.
//
//  Sobre el buffer: en radio EN DIRECTO no se puede acumular mucho — el
//  servidor emite en tiempo real, no hay "audio del futuro". El único colchón
//  real es la ráfaga que cada servidor manda al conectar (medido en las
//  emisoras del usuario: 7-18 s). `preferredForwardBufferDuration` pide
//  conservar todo lo que den; más allá de eso no hay margen físico, por lo
//  que la reconexión es la que de verdad resuelve los cortes largos.
//

import Foundation
import AVFoundation
import Network
import Observation
import os

enum IOSPlaybackState: Equatable, Sendable {
    case idle
    case buffering
    case playing
    case paused
    /// Se perdió el stream y se está reintentando solo. `attempt` empieza en 1.
    case reconnecting(attempt: Int)
    case error(reason: String)

    /// `true` cuando la app está reproduciendo o intentando hacerlo — la UI lo
    /// usa para pintar el botón de pausa y el indicador ▶ de la fila.
    var isActive: Bool {
        switch self {
        case .buffering, .playing, .reconnecting: return true
        default:                                  return false
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
    private var failedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "audio")

    /// Intención del usuario: `true` entre play() y pause()/stop(). La
    /// reconexión automática SOLO actúa si es true — si pausaste tú, el
    /// silencio es deliberado y la app no debe resucitar nada.
    private var shouldBePlaying = false

    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// Instante en que dejamos de oír audio de verdad. nil mientras suena.
    private var stalledSince: Date?

    // Red
    private let pathMonitor = NWPathMonitor()
    private var isNetworkUp = true
    /// Continuations esperando a que vuelva la red (las despierta el monitor).
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []

    /// Cuánto tolera el watchdog sin audio antes de dar el stream por muerto.
    /// Por debajo de ~10 s nos pelearíamos con los micro-cortes que el buffer
    /// tapa solo; por encima, el silencio en el coche se hace largo.
    private let stallToleranceSeconds: TimeInterval = 12

    /// Colchón que pedimos conservar. El servidor manda lo que quiera (7-18 s
    /// en las emisoras medidas); esto solo evita que iOS lo recorte.
    private let forwardBufferSeconds: TimeInterval = 30

    init(initialVolume: Float = 0.8) {
        self.volume = max(0, min(1, initialVolume))
        player.volume = self.volume
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        observeRate()
        startNetworkMonitor()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Public API

    func play(_ station: Station) {
        log.info("play station=\(station.name, privacy: .public) url=\(station.url.absoluteString, privacy: .public)")
        shouldBePlaying = true
        currentStation = station
        cancelReconnect()
        startItem(for: station)
        startWatchdog()
    }

    func pause() {
        log.info("pause (usuario)")
        shouldBePlaying = false
        cancelReconnect()
        stopWatchdog()
        player.pause()
    }

    func resume() {
        guard let station = currentStation else { return }
        shouldBePlaying = true
        cancelReconnect()

        // Tras un corte, player.play() sobre un item roto NO recupera nada:
        // hay que reconstruir el AVPlayerItem.
        let itemBroken = player.currentItem == nil || player.currentItem?.status == .failed
        let needsRebuild: Bool = {
            if itemBroken { return true }
            switch state {
            case .error, .reconnecting: return true
            default: return false
            }
        }()

        if needsRebuild {
            log.info("resume: item roto o estado degradado — reconstruyendo AVPlayerItem")
            startItem(for: station)
        } else {
            log.info("resume")
            activateAudioSession()
            player.play()
        }
        startWatchdog()
    }

    func stop() {
        log.info("stop")
        shouldBePlaying = false
        cancelReconnect()
        stopWatchdog()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStation = nil
        state = .idle
        // Devolver el audio a quien sonara antes (Apple Music, podcasts…).
        deactivateAudioSession()
    }

    func togglePlayPause() {
        switch state {
        case .playing, .buffering, .reconnecting: pause()
        case .paused, .idle, .error:              resume()
        }
    }

    // MARK: - Arranque del item

    private func startItem(for station: Station) {
        activateAudioSession()
        let item = AVPlayerItem(url: station.url)
        // Conservar todo el colchón que el servidor dé (ver cabecera).
        item.preferredForwardBufferDuration = forwardBufferSeconds
        observeItem(item)
        player.replaceCurrentItem(with: item)
        stalledSince = nil
        if case .reconnecting = state {} else { state = .buffering }
        player.play()
    }

    // MARK: - Watchdog de atasco

    /// Vigila que realmente esté saliendo audio. Necesario porque una conexión
    /// muerta NO produce error en AVPlayer: se queda esperando datos para
    /// siempre, y sin este vigilante nadie se enteraría nunca.
    private func startWatchdog() {
        stopWatchdog()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.shouldBePlaying else { return }
                self.checkForStall()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        stalledSince = nil
    }

    private func checkForStall() {
        guard shouldBePlaying else { return }
        if case .reconnecting = state { return }  // ya se está reintentando

        let item = player.currentItem
        // "Sale audio" = el player avanza y el buffer no está seco.
        let flowing = player.timeControlStatus == .playing
            && !(item?.isPlaybackBufferEmpty ?? true)

        if flowing {
            stalledSince = nil
            return
        }

        let since = stalledSince ?? Date()
        if stalledSince == nil { stalledSince = since }

        if Date().timeIntervalSince(since) >= stallToleranceSeconds {
            log.error("watchdog: sin audio \(Int(self.stallToleranceSeconds), privacy: .public)s — el stream está muerto, reconectando")
            beginReconnect()
        }
    }

    // MARK: - Reconexión automática

    /// Arranca (si no lo estaba) el bucle de reconexión. Reintenta mientras el
    /// usuario quiera escuchar, esperando a que vuelva la red antes de cada
    /// intento para no golpear a ciegas dentro del túnel.
    private func beginReconnect() {
        guard shouldBePlaying, currentStation != nil, reconnectTask == nil else { return }
        stopWatchdog()

        reconnectTask = Task { @MainActor [weak self] in
            var attempt = 0
            // Backoff suave: en el coche interesa reintentar a menudo, no
            // escalar a minutos. Tope de 15 s.
            let delays: [TimeInterval] = [2, 3, 5, 8, 12, 15]

            while !Task.isCancelled {
                guard let self, self.shouldBePlaying, let station = self.currentStation else { return }
                attempt += 1
                self.state = .reconnecting(attempt: attempt)
                self.log.info("reconectando intento \(attempt, privacy: .public)")

                // Esperar a tener red: dentro del túnel no tiene sentido probar.
                await self.waitForNetwork()
                if Task.isCancelled { return }

                self.activateAudioSession()
                let item = AVPlayerItem(url: station.url)
                item.preferredForwardBufferDuration = self.forwardBufferSeconds
                self.observeItem(item)
                self.player.replaceCurrentItem(with: item)
                self.player.play()

                // Darle margen a arrancar antes de juzgar.
                try? await Task.sleep(for: .seconds(6))
                if Task.isCancelled { return }

                let flowing = self.player.timeControlStatus == .playing
                    && !(self.player.currentItem?.isPlaybackBufferEmpty ?? true)
                if flowing {
                    self.log.info("reconexión OK en el intento \(attempt, privacy: .public)")
                    self.state = .playing
                    self.stalledSince = nil
                    self.reconnectTask = nil
                    self.startWatchdog()
                    return
                }

                let delay = delays[min(attempt - 1, delays.count - 1)]
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Monitor de red

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasDown = !self.isNetworkUp
                self.isNetworkUp = up
                if up {
                    // Despertar a quien esperaba red.
                    let waiters = self.networkWaiters
                    self.networkWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                    if wasDown {
                        self.log.info("red recuperada")
                        // Volvimos de un túnel y debíamos estar sonando:
                        // reintentar ya, sin esperar al watchdog.
                        if self.shouldBePlaying, self.reconnectTask == nil {
                            self.beginReconnect()
                        }
                    }
                } else {
                    self.log.info("red perdida")
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.blancosampedro.RadioPremium-iOS.network"))
    }

    /// Vuelve en cuanto haya red. Si ya la hay, no espera.
    private func waitForNetwork() async {
        if isNetworkUp { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            networkWaiters.append(continuation)
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let rate = change.newValue ?? 0
                if rate > 0 {
                    if self.state == .buffering || self.state == .idle {
                        self.state = .playing
                    }
                } else {
                    // rate == 0 durante una reconexión es esperado: no lo
                    // confundas con una pausa del usuario.
                    if case .reconnecting = self.state { return }
                    if self.shouldBePlaying { return }
                    if self.state.isActive { self.state = .paused }
                }
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        if let token = failedObserver { NotificationCenter.default.removeObserver(token) }
        if let token = stalledObserver { NotificationCenter.default.removeObserver(token) }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .failed {
                    let reason = item.error?.localizedDescription ?? "no se pudo cargar el stream"
                    self.log.error("item failed: \(reason, privacy: .public)")
                    // Si el usuario quería escuchar, esto no es un error final:
                    // es un corte del que hay que recuperarse solo.
                    if self.shouldBePlaying {
                        self.beginReconnect()
                    } else {
                        self.state = .error(reason: reason)
                    }
                }
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.error("failed to play to end: \(reason, privacy: .public)")
                if self.shouldBePlaying {
                    self.beginReconnect()
                } else {
                    self.state = .error(reason: reason)
                }
            }
        }

        // Señal explícita de atasco: complementa al watchdog acortando la
        // detección cuando iOS sí la emite.
        stalledObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldBePlaying else { return }
                self.log.info("playbackStalled — el watchdog decidirá si hay que reconectar")
                if self.stalledSince == nil { self.stalledSince = Date() }
            }
        }
    }
}
