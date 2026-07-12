//
//  RadioPremiumApp.swift
//  RadioPremium
//
//  Punto de entrada. App menubar-only (LSUIElement = true en Info.plist).
//

import SwiftUI
import os

/// Repo de favoritos compartido a nivel de App. Se guarda aquí para poder
/// disparar `syncWithIcloud()` en arranque y observar cambios externos.
private let sharedFavoritesRepo: FavoritesRepository? = {
    do {
        return try FavoritesRepository()
    } catch {
        AppLogger.app.error("FavoritesRepository init failed: \(error.localizedDescription, privacy: .public). Favoritos deshabilitados esta sesión.")
        return nil
    }
}()

@main
struct RadioPremiumApp: App {
    @State private var player = PlayerViewModel()
    @State private var browse: RadioBrowseViewModel = RadioBrowseViewModel(
        client: RadioBrowserClient(),
        favoritesRepo: sharedFavoritesRepo
    )
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
            .task {
                await setupIcloudFavoritesSync()
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Arranca el sync de favoritos con iCloud y registra observer para
    /// cambios externos (cuando el iPhone añade/quita un favorito).
    private func setupIcloudFavoritesSync() async {
        guard let repo = sharedFavoritesRepo else { return }
        await repo.syncWithIcloud()
        // Recargar la VM porque el merge pudo haber cambiado el set local.
        browse.loadFavorites()

        // Listener para cambios externos vía iCloud (otra device).
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            Task {
                AppLogger.app.info("iCloud favorites changed externally → re-mergeando")
                await repo.syncWithIcloud()
                browse.loadFavorites()
            }
        }
    }
}
