//
//  RadioPremiumApp.swift
//  RadioPremium
//
//  Punto de entrada. App menubar-only (LSUIElement = true en Info.plist).
//

import SwiftUI
import os

@main
struct RadioPremiumApp: App {
    @State private var player = PlayerViewModel()
    @State private var browse: RadioBrowseViewModel = {
        // Favoritos persisten en Application Support. Si el directorio no se
        // puede crear (caso muy raro: disco lleno o permisos), seguimos sin
        // repo y la app simplemente no muestra estrellas. Mejor que crashear.
        let favoritesRepo: FavoritesRepository?
        do {
            favoritesRepo = try FavoritesRepository()
        } catch {
            AppLogger.app.error("FavoritesRepository init failed: \(error.localizedDescription, privacy: .public). Favoritos deshabilitados esta sesión.")
            favoritesRepo = nil
        }
        return RadioBrowseViewModel(
            client: RadioBrowserClient(),
            favoritesRepo: favoritesRepo
        )
    }()
    @State private var identify: IdentifyViewModel = {
        // IdentifiedTracksRepository.init() lanza si no puede crear el directorio
        // de Application Support. Si eso falla, la app está rota — fatalError.
        let repo: IdentifiedTracksRepository
        do {
            repo = try IdentifiedTracksRepository()
        } catch {
            fatalError("No se pudo iniciar IdentifiedTracksRepository: \(error)")
        }
        return IdentifyViewModel(
            recorder: ScreenCaptureRecorder(),
            client: AcrCloudClient(),
            repo: repo
        )
    }()
    @State private var spotify = SpotifyViewModel()
    @State private var appleMusic = AppleMusicViewModel()

    var body: some Scene {
        MenuBarExtra("Radio Premium", systemImage: "dot.radiowaves.left.and.right") {
            MenubarView(
                player: player,
                browse: browse,
                identify: identify,
                spotify: spotify,
                appleMusic: appleMusic
            )
        }
        .menuBarExtraStyle(.window)
    }
}
