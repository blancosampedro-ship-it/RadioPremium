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
    private var keepUpObserver: NSKeyValueObservation?
    private var failedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "audio")

    /// Intención del usuario: `true` entre play() y pause()/stop(). La
    /// reconexión automática SOLO actúa si es true — si pausaste tú, el
    /// silencio es deliberado y la app no debe resucitar nada.
    private var shouldBePlaying = false

    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// Instante desde el que NO entra ni un byte. nil mientras haya progreso.
    private var stalledSince: Date?

    /// Final del buffer cargado en la última comprobación. Si crece, están
    /// llegando datos aunque no suene — señal floja, pero stream vivo.
    private var lastBufferedEnd: TimeInterval = 0

    // Red
    private let pathMonitor = NWPathMonitor()
    private var isNetworkUp = true
    /// Continuations esperando a que vuelva la red (las despierta el monitor).
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []

    /// Cuánto se tolera SIN QUE ENTRE NADA antes de dar el stream por muerto.
    /// Ojo: no es "sin oír audio" — con señal débil AVPlayer deja de sonar
    /// mientras rellena el buffer, y eso es normal y recuperable. Este reloj
    /// solo corre cuando no llega ni un byte, que sí es un stream muerto.
    private let stallToleranceSeconds: TimeInterval = 30

    /// Margen para que un stream recién abierto arranque. Con cobertura pobre
    /// AVPlayer puede tardar bastante en tener buffer suficiente; rendirse
    /// antes solo provoca reconexiones en cadena que arrancan igual de mal.
    private let startupGraceSeconds = 25

    /// Colchón que pedimos conservar. El servidor manda lo que quiera (7-18 s
    /// en las emisoras medidas); esto solo evita que iOS lo recorte.
    private let forwardBufferSeconds: TimeInterval = 30

    // MARK: - Recuperación del colchón
    //
    // Una radio EN DIRECTO solo regala colchón al conectar (la ráfaga inicial:
    // 7-18 s en las emisoras del usuario). A partir de ahí emite en tiempo
    // real, así que cada bajón de cobertura consume reserva que NO se recupera
    // sola: el servidor no tiene "audio del futuro" que darte para ponerte al
    // día. Tras un rato de trayecto el colchón queda a cero y cualquier
    // bajadita leve ya se oye como un corte.
    //
    // Solución: cuando la reserva está baja, reproducir un pelín más despacio.
    // A 0,97x se gana ~1 s de colchón cada 33 s de música, y con corrección de
    // tono es inaudible. El precio es ir unos segundos por detrás del directo,
    // irrelevante en radio. Al recuperar el colchón se vuelve a 1,0x.

    /// Colchón objetivo. Por debajo, se reproduce más lento para rellenar.
    private let targetCushionSeconds: TimeInterval = 20

    /// A partir de aquí se considera recuperado y se vuelve a velocidad normal.
    /// La histéresis evita ir cambiando de velocidad continuamente.
    ///
    /// 26 s es MÁS de lo que da la ráfaga inicial del servidor (15-18 s): el
    /// frenado permite acumular por encima de lo que regala el servidor, así
    /// que el colchón en régimen estable acaba siendo mayor que el que tendría
    /// una conexión recién abierta. Es margen extra ante cada bajada, y estar
    /// 26 s por detrás del directo es irrelevante en radio.
    private let healthyCushionSeconds: TimeInterval = 26

    /// Colchón por debajo del cual la situación es crítica: cualquier bajón
    /// se oiría ya. Aquí se rellena más deprisa.
    private let criticalCushionSeconds: TimeInterval = 6

    /// Velocidades de recuperación, escalonadas. Medido: a 0,97x se gana 1 s
    /// de colchón cada 33 s — demasiado lento para volver de un bache serio
    /// (7 minutos desde 5 s). A 0,94x se gana 1 s cada 17 s, que recupera en
    /// ~3,5 minutos. Ambas son inaudibles con corrección de tono espectral;
    /// la agresiva solo entra cuando de verdad hace falta.
    private let refillRateCritical: Float = 0.94
    private let refillRateGentle: Float = 0.97

    /// `true` mientras se está rellenando el colchón a velocidad reducida.
    private var isRefillingCushion = false

    /// Últimas lecturas del colchón, para suavizar. `loadedTimeRanges` NO es
    /// continuo: AVPlayer lo actualiza a trozos al completar cada segmento
    /// descargado, así que la lectura cruda es una SIERRA (salta +10 s de
    /// golpe, baja linealmente, vuelve a saltar). Medido: oscilaba 19↔30 s
    /// cada 15 s con la red perfectamente estable. Sin suavizar, el regulador
    /// perseguía cada diente y cambiaba de velocidad 14 veces en 4 minutos.
    private var cushionHistory: [TimeInterval] = []
    private let cushionHistorySize = 6   // 6 lecturas × 2 s = 12 s de ventana

    /// Ticks consecutivos con el colchón por debajo del umbral. La velocidad
    /// solo se toca cuando la situación PERSISTE, no ante un diente de sierra.
    private var lowCushionTicks = 0
    private let lowCushionTicksRequired = 4   // 8 s seguidos bajo

    init(initialVolume: Float = 0.8) {
        self.volume = max(0, min(1, initialVolume))
        player.volume = self.volume
        // FALSE a propósito. Con TRUE, AVPlayer ante cualquier micro-bajón del
        // buffer PARA y no reanuda hasta estar "seguro" de que no volverá a
        // parar — un criterio pensado para vídeo bajo demanda, donde puede
        // descargar por adelantado. En radio EN DIRECTO ese "seguro" nunca
        // llega del todo, así que cada bache de red de 2-3 s se convertía en
        // una pausa de 5-15 s: justo el "corta breve, vuelve sola, cada pocos
        // minutos" del coche. Con FALSE reanuda en cuanto hay audio que sonar,
        // que es lo que queremos: el colchón de 26 s ya absorbe los baches.
        player.automaticallyWaitsToMinimizeStalling = false
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
        isRefillingCushion = false
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
        isRefillingCushion = false
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
        // Corrección de tono: sin esto, reproducir a 0,97x bajaría el tono y
        // se notaría. Con .spectral el cambio de velocidad es inaudible.
        item.audioTimePitchAlgorithm = .spectral
        observeItem(item)
        player.replaceCurrentItem(with: item)
        stalledSince = nil
        lastBufferedEnd = 0
        cushionHistory.removeAll()
        lowCushionTicks = 0
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
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.shouldBePlaying else { return }
                self.checkForStall()
                self.adjustRateForCushion()
                tick += 1
                // Salud del colchón cada 10 s. Sirve para diagnosticar desde
                // el coche por qué se oye un corte: si aquí se ve el buffer
                // cayendo a cero, el problema es reserva agotada, no red rota.
                if tick % 5 == 0 { self.logBufferHealth() }
            }
        }
    }

    /// Segundos de audio ya descargados por delante de donde suena.
    private func bufferedAhead() -> TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let now = CMTimeGetSeconds(item.currentTime())
        let end = item.loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.end) }
            .filter { $0.isFinite }
            .max() ?? 0
        guard now.isFinite else { return 0 }
        return max(0, end - now)
    }

    /// Ajusta la velocidad para reconstruir el colchón cuando está bajo.
    ///
    /// Solo actúa mientras suena de verdad: si está atascado o reconectando,
    /// tocar la velocidad no ayudaría y enturbiaría el diagnóstico.
    private func adjustRateForCushion() {
        guard shouldBePlaying, player.timeControlStatus == .playing else {
            // Al salir de reproducción normal, no dejar el player frenado.
            if isRefillingCushion { restoreNormalRate() }
            return
        }

        let cushion = smoothedCushion()

        if cushion >= healthyCushionSeconds {
            lowCushionTicks = 0
            if isRefillingCushion {
                restoreNormalRate()
                log.info("colchón recuperado (\(String(format: "%.1f", cushion), privacy: .public)s) — velocidad normal")
            }
            return
        }

        if cushion < targetCushionSeconds {
            lowCushionTicks += 1
        } else if !isRefillingCushion {
            lowCushionTicks = 0
            return
        }

        // Solo actuar si el colchón lleva un rato bajo (no un diente de sierra),
        // o si ya estábamos rellenando (mantener hasta llegar a sano).
        guard isRefillingCushion || lowCushionTicks >= lowCushionTicksRequired else { return }

        // Cuanto más bajo el colchón, más deprisa se rellena.
        let wanted = cushion < criticalCushionSeconds ? refillRateCritical : refillRateGentle
        if !isRefillingCushion {
            log.info("colchón bajo (\(String(format: "%.1f", cushion), privacy: .public)s sostenido) — rellenando a \(wanted, privacy: .public)x")
            isRefillingCushion = true
        }
        if abs(player.rate - wanted) > 0.001 {
            log.info("colchón \(String(format: "%.1f", cushion), privacy: .public)s → velocidad \(wanted, privacy: .public)x")
            player.rate = wanted
        }
    }

    private func restoreNormalRate() {
        isRefillingCushion = false
        if player.timeControlStatus != .paused || shouldBePlaying {
            player.rate = 1.0
        }
    }

    /// Colchón suavizado: media móvil de las últimas lecturas. Es lo que usa
    /// el regulador; la lectura cruda solo se loguea.
    private func smoothedCushion() -> TimeInterval {
        let raw = bufferedAhead()
        cushionHistory.append(raw)
        if cushionHistory.count > cushionHistorySize { cushionHistory.removeFirst() }
        return cushionHistory.reduce(0, +) / Double(cushionHistory.count)
    }

    private func logBufferHealth() {
        let raw = bufferedAhead()
        let avg = cushionHistory.isEmpty ? raw : cushionHistory.reduce(0, +) / Double(cushionHistory.count)
        log.info("buffer: \(String(format: "%.1f", avg), privacy: .public)s (cruda \(String(format: "%.1f", raw), privacy: .public)s) rate=\(self.player.rate, privacy: .public)")
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        stalledSince = nil
    }

    private func checkForStall() {
        guard shouldBePlaying, currentStation != nil else { return }
        if case .reconnecting = state { return }  // ya se está reintentando
        guard let item = player.currentItem else { return }

        // 1. Suena de verdad → sano.
        if player.timeControlStatus == .playing {
            noteProgress()
            return
        }

        // 2. Sin red no es culpa del stream. El monitor de red disparará la
        //    reconexión en cuanto vuelva; no acumular tiempo muerto aquí.
        if !isNetworkUp {
            noteProgress()
            return
        }

        // 3. ¿Entran datos aunque no suene? Con cobertura pobre AVPlayer para
        //    la reproducción y sigue rellenando el buffer: el stream está VIVO,
        //    solo va despacio. Matarlo aquí era el bug — forzaba una reconexión
        //    que, con la misma señal floja, arrancaba igual de mal o peor.
        if bufferIsGrowing(item) {
            noteProgress()
            return
        }

        // 4. Ni suena ni entra nada: ahora sí corre el reloj.
        let since = stalledSince ?? Date()
        if stalledSince == nil { stalledSince = since }
        let dead = Date().timeIntervalSince(since)
        if dead >= stallToleranceSeconds {
            log.error("watchdog: \(Int(dead), privacy: .public)s sin datos ni audio — stream muerto, reconectando")
            beginReconnect()
        }
    }

    /// `true` si el final del buffer cargado ha avanzado desde la última
    /// comprobación — o sea, si están llegando bytes.
    private func bufferIsGrowing(_ item: AVPlayerItem) -> Bool {
        let end = item.loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.end) }
            .filter { $0.isFinite }
            .max() ?? 0
        if end > lastBufferedEnd + 0.2 {
            lastBufferedEnd = end
            return true
        }
        return false
    }

    private func noteProgress() {
        stalledSince = nil
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
                self.lastBufferedEnd = 0
                self.player.play()

                // Esperar con paciencia: mientras entren datos seguimos
                // esperando aunque tarde. Juzgar a los 6 s fijos hacía que con
                // cobertura pobre nos rindiéramos justo cuando estaba a punto
                // de arrancar, encadenando reconexiones inútiles.
                let flowing = await self.awaitStreamStart()
                if Task.isCancelled { return }
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

    /// Espera a que el stream arranque de verdad. Devuelve `true` en cuanto
    /// suena. Da margen extra mientras el buffer siga creciendo (señal lenta),
    /// y se rinde solo si además deja de entrar nada.
    private func awaitStreamStart() async -> Bool {
        var quietTicks = 0
        for _ in 0..<startupGraceSeconds {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return false }
            if player.timeControlStatus == .playing { return true }
            guard let item = player.currentItem else { continue }
            if item.status == .failed { return false }
            if bufferIsGrowing(item) {
                quietTicks = 0          // sigue llegando audio: paciencia
            } else {
                quietTicks += 1
                if quietTicks >= 10 { return false }   // 10 s sin nada: muerto
            }
        }
        return player.timeControlStatus == .playing
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
                // 0,97x es reproducción normal para nosotros (relleno de
                // colchón), no una pausa: cualquier rate > 0 es "sonando".
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
        keepUpObserver?.invalidate()
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

        // Con waitsToMinimizeStalling=false, AVPlayer puede quedarse en rate 0
        // tras vaciarse el buffer. En cuanto vuelva a haber algo que sonar
        // (isPlaybackLikelyToKeepUp), empujamos la reanudación nosotros para
        // no depender de su criterio conservador.
        keepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldBePlaying else { return }
                if case .reconnecting = self.state { return }
                if item.isPlaybackLikelyToKeepUp, self.player.timeControlStatus != .playing {
                    self.log.debug("buffer recuperado — reanudando sin esperar")
                    self.player.play()
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
