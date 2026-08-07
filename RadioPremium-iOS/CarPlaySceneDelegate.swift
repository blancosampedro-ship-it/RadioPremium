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
//  La escena se declara en RadioPremium-iOS-Info.plist
//  (CPTemplateApplicationSceneSessionRoleApplication) y requiere el
//  entitlement com.apple.developer.carplay-audio — ver el comentario en
//  RadioPremium-iOS-CarPlay.entitlements sobre cómo está repartido entre
//  simulador y dispositivo mientras Apple no conceda el permiso.
//

import CarPlay
import Foundation
import MediaPlayer
import os

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var favoritesTemplate: CPListTemplate?
    private var browseTemplate: CPListTemplate?
    private var refreshTask: Task<Void, Never>?

    /// Cache de logos ya descargados. Las CPListItem se recrean en cada
    /// refresco; sin cache, cada refresco relanzaría todas las descargas.
    private var artworkCache: [URL: UIImage] = [:]

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
        browse.emptyViewSubtitleVariants = ["Comprueba la conexión del iPhone"]
        self.browseTemplate = browse

        let tabBar = CPTabBarTemplate(templates: [favorites, browse])
        interfaceController.setRootTemplate(tabBar, animated: false) { [weak self] _, error in
            if let error {
                self?.log.error("setRootTemplate falló: \(error.localizedDescription, privacy: .public)")
            }
        }

        rebuildLists()
        startObservingModel()

        // El coche puede arrancar con la app fría: cargar el top si falta.
        if model.topStations.isEmpty {
            Task { [weak self] in
                await self?.model.loadTopStations()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log.info("CarPlay desconectado")
        refreshTask?.cancel()
        refreshTask = nil
        self.interfaceController = nil
        favoritesTemplate = nil
        browseTemplate = nil
    }

    // MARK: - Observación del modelo

    /// Reconstruye las listas cada vez que cambian favoritos, top de emisoras
    /// o el estado del player (para el indicador ▶ de la fila sonando).
    /// Mismo patrón withObservationTracking que AppModel usa para Now Playing.
    private func startObservingModel() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.interfaceController != nil else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.model.favorites.stations
                        _ = self.model.topStations
                        _ = self.model.player.currentStation
                        _ = self.model.player.state
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.rebuildLists()
            }
        }
    }

    // MARK: - Construcción de listas

    private func rebuildLists() {
        guard favoritesTemplate != nil || browseTemplate != nil else { return }

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
        let item = CPListItem(
            text: station.name,
            detailText: station.country ?? "",
            image: artworkCache[station.favicon ?? URL(fileURLWithPath: "/")] ?? placeholderImage
        )

        let isCurrent = model.player.currentStation?.id == station.id
        item.isPlaying = isCurrent && model.player.state.isActive
        item.playingIndicatorLocation = .trailing

        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            self.play(station)
            completion()
        }

        // Logo real en segundo plano; al llegar se actualiza la fila en vivo.
        if let faviconURL = station.favicon, artworkCache[faviconURL] == nil {
            Task { [weak self, weak item] in
                guard let self, let image = await Self.fetchArtwork(from: faviconURL) else { return }
                self.artworkCache[faviconURL] = image
                item?.setImage(image)
            }
        }

        return item
    }

    /// Reproducir y llevar al usuario a la pantalla Now Playing del sistema.
    private func play(_ station: Station) {
        log.info("play desde CarPlay: \(station.name, privacy: .public)")
        model.play(station)

        guard let interfaceController else { return }
        // No apilar dos Now Playing si el usuario toca otra emisora desde
        // la lista mientras la pantalla ya está en el stack.
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

    private static func fetchArtwork(from url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
