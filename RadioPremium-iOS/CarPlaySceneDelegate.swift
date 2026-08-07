//
//  CarPlaySceneDelegate.swift
//  RadioPremium-iOS
//
//  Escena CarPlay (app de audio). Framework CarPlay moderno, basado en
//  templates — nada de MPPlayableContent (deprecated desde iOS 14).
//
//  Estructura:
//    CPTabBarTemplate
//      ├── ★ Favoritos   (CPListTemplate ← FavoritesStore, sync iCloud)
//      └── 📻 Emisoras    (CPListTemplate ← top de Radio Browser)
//    CPNowPlayingTemplate.shared — la pantalla Now Playing es del SISTEMA:
//      se alimenta sola de MPNowPlayingInfoCenter y MPRemoteCommandCenter,
//      que NowPlayingHelper ya mantiene (título, logo, play/pause). Por eso
//      aquí no hay ni una línea de UI de reproducción.
//
//  Comparte AppModel.shared con la escena SwiftUI del iPhone: tocar una
//  emisora en el coche y en el teléfono controla el mismo AVPlayer.
//
//  Decisiones de la revisión adversarial (commit anterior):
//    - La carga del top REINTENTA con backoff mientras la escena viva y la
//      lista siga vacía: arrancar el coche en un garaje sin cobertura dejaba
//      "Cargando emisoras…" clavado toda la sesión (didConnect solo ocurre
//      una vez por conexión; no hay pull-to-refresh en un coche).
//    - Descargas de logos deduplicadas (en vuelo + fallidas) y decodificadas
//      FUERA del MainActor como thumbnail: antes, cada cambio de estado del
//      player relanzaba decenas de descargas duplicadas y decodificaba
//      imágenes a tamaño completo en el hilo que anima la UI del coche.
//    - rebuildLists se salta el trabajo si nada visible cambió (los flips
//      buffering→playing no alteran ninguna fila).
//    - El bucle de observación no retiene self a través del await: el coche
//      puede desconectar y el delegado morir aunque la observación siga
//      esperando un cambio que no llegará.
//
//  La escena se declara en RadioPremium-iOS-Info.plist y requiere el
//  entitlement com.apple.developer.carplay-audio — ver el comentario en
//  RadioPremium-iOS-CarPlay.entitlements sobre el reparto simulador vs
//  dispositivo mientras Apple no conceda el permiso.
//

import CarPlay
import Foundation
import ImageIO
import MediaPlayer
import os

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var favoritesTemplate: CPListTemplate?
    private var browseTemplate: CPListTemplate?
    private var refreshTask: Task<Void, Never>?
    private var topLoadTask: Task<Void, Never>?

    /// Logos ya descargados (reescalados a tamaño CarPlay), URLs con descarga
    /// en curso y URLs que fallaron — para no repetir trabajo en cada rebuild.
    private var artworkCache: [URL: UIImage] = [:]
    private var artworkInFlight: Set<URL> = []
    private var artworkFailed: Set<URL> = []

    /// Firma de lo último pintado: si el modelo cambia pero nada visible
    /// cambió (p. ej. buffering→playing), el rebuild se salta.
    private var lastRenderSignature: String = ""

    private let model = AppModel.shared
    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "carplay")

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        log.info("CarPlay conectado")
        self.interfaceController = interfaceController

        let favorites = CPListTemplate(title: "Favoritos", sections: [])
        favorites.tabTitle = "Favoritos"
        favorites.tabImage = UIImage(systemName: "star.fill")
        favorites.emptyViewTitleVariants = ["Sin favoritos"]
        favorites.emptyViewSubtitleVariants = ["Marca emisoras con ★ en el iPhone"]
        self.favoritesTemplate = favorites

        let browse = CPListTemplate(title: "Emisoras", sections: [])
        browse.tabTitle = "Emisoras"
        browse.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        browse.emptyViewTitleVariants = ["Cargando emisoras…"]
        browse.emptyViewSubtitleVariants = ["Un momento"]
        self.browseTemplate = browse

        let tabBar = CPTabBarTemplate(templates: [favorites, browse])
        interfaceController.setRootTemplate(tabBar, animated: false) { [weak self] _, error in
            if let error {
                self?.log.error("setRootTemplate falló: \(error.localizedDescription, privacy: .public)")
            }
        }

        rebuildLists(force: true)
        startObservingModel()
        startTopStationsLoad()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log.info("CarPlay desconectado")
        refreshTask?.cancel()
        refreshTask = nil
        topLoadTask?.cancel()
        topLoadTask = nil
        self.interfaceController = nil
        favoritesTemplate = nil
        browseTemplate = nil
        lastRenderSignature = ""
    }

    // MARK: - Carga del top con reintento

    /// Carga el top de emisoras y, si falla (garaje sin cobertura, espejos
    /// caídos), reintenta con backoff 5s→60s mientras la escena siga
    /// conectada y la lista vacía. El estado vacío de la pestaña refleja
    /// la situación real en cada momento.
    private func startTopStationsLoad() {
        guard model.topStations.isEmpty else { return }
        topLoadTask?.cancel()
        topLoadTask = Task { @MainActor [weak self] in
            var delaySeconds: UInt64 = 5
            while !Task.isCancelled {
                guard let self, self.interfaceController != nil else { return }
                if !self.model.topStations.isEmpty { return }

                self.setBrowseEmptyState(title: "Cargando emisoras…", subtitle: "Un momento")
                await self.model.loadTopStations()
                if Task.isCancelled { return }
                if !self.model.topStations.isEmpty { return }  // el rebuild llega vía observación

                self.log.warning("carga del top falló — reintento en \(delaySeconds, privacy: .public)s")
                self.setBrowseEmptyState(
                    title: "Sin conexión",
                    subtitle: "Reintentando automáticamente…"
                )
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                delaySeconds = min(delaySeconds * 2, 60)
            }
        }
    }

    private func setBrowseEmptyState(title: String, subtitle: String) {
        browseTemplate?.emptyViewTitleVariants = [title]
        browseTemplate?.emptyViewSubtitleVariants = [subtitle]
    }

    // MARK: - Observación del modelo

    /// Reconstruye las listas cuando cambian favoritos, top de emisoras o el
    /// estado del player. El bucle NO retiene self a través del await: captura
    /// el modelo (singleton) para la observación y re-adquiere self débil solo
    /// después de cada cambio — si el coche desconectó, el bucle muere aquí.
    private func startObservingModel() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            let model = AppModel.shared
            while true {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = model.favorites.stations
                        _ = model.topStations
                        _ = model.player.currentStation
                        _ = model.player.state
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard let self, !Task.isCancelled, self.interfaceController != nil else { return }
                self.rebuildLists(force: false)
            }
        }
    }

    // MARK: - Construcción de listas

    private func rebuildLists(force: Bool) {
        guard favoritesTemplate != nil || browseTemplate != nil else { return }

        // Lo único visible en las filas: qué emisoras hay, cuál suena y si
        // está activa. Si la firma no cambia, no hay nada que repintar.
        let playingId = model.player.currentStation?.id ?? "-"
        let active = model.player.state.isActive
        let signature = """
        \(model.favorites.stations.map(\.id).joined(separator: ","))|\
        \(model.topStations.map(\.id).joined(separator: ","))|\
        \(playingId)|\(active)
        """
        if !force && signature == lastRenderSignature { return }
        lastRenderSignature = signature

        if let favorites = favoritesTemplate {
            let items = model.favorites.stations.map { listItem(for: $0) }
            favorites.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
        }
        if let browse = browseTemplate {
            let items = model.topStations.map { listItem(for: $0) }
            browse.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
        }
    }

    private func listItem(for station: Station) -> CPListItem {
        let cached = station.favicon.flatMap { artworkCache[$0] }
        let item = CPListItem(
            text: station.name,
            detailText: station.country ?? "",
            image: cached ?? placeholderImage
        )

        let isCurrent = model.player.currentStation?.id == station.id
        item.isPlaying = isCurrent && model.player.state.isActive
        item.playingIndicatorLocation = .trailing

        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            self.play(station)
            completion()
        }

        if cached == nil, let faviconURL = station.favicon {
            fetchArtworkIfNeeded(from: faviconURL, for: item)
        }

        return item
    }

    /// Reproducir y llevar al usuario a la pantalla Now Playing del sistema.
    private func play(_ station: Station) {
        log.info("play desde CarPlay: \(station.name, privacy: .public)")
        model.play(station)

        guard let interfaceController else { return }
        // No apilar dos Now Playing si ya está en el stack.
        if !(interfaceController.templates.contains { $0 is CPNowPlayingTemplate }) {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { [weak self] _, error in
                if let error {
                    self?.log.error("pushTemplate NowPlaying falló: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Artwork

    private var placeholderImage: UIImage? {
        UIImage(systemName: "antenna.radiowaves.left.and.right")
    }

    /// Lanza la descarga del logo salvo que ya esté cacheado, en vuelo o
    /// haya fallado antes (los favicons muertos abundan en Radio Browser y
    /// reintentarlos en cada rebuild era una estampida de red).
    private func fetchArtworkIfNeeded(from url: URL, for item: CPListItem) {
        guard artworkCache[url] == nil,
              !artworkInFlight.contains(url),
              !artworkFailed.contains(url) else { return }
        artworkInFlight.insert(url)

        Task { [weak self, weak item] in
            // Descarga + decode como thumbnail FUERA del MainActor.
            let image = await Self.fetchThumbnail(from: url, maxPixelSize: 180)
            guard let self else { return }
            self.artworkInFlight.remove(url)
            if let image {
                self.artworkCache[url] = image
                item?.setImage(image)   // actualiza la fila en vivo si sigue visible
            } else {
                self.artworkFailed.insert(url)
            }
        }
    }

    /// Descarga y decodifica un thumbnail acotado con ImageIO — nunca el
    /// bitmap completo (hay favicons de tamaños absurdos en Radio Browser).
    /// `nonisolated`: con SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, sin esto
    /// la descarga y el decode correrían en el hilo de UI del coche.
    private nonisolated static func fetchThumbnail(from url: URL, maxPixelSize: Int) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumb)
    }
}
