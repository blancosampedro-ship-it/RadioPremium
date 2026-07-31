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

/// Preferencias persistidas (volumen, país por defecto…). Compartidas a
/// nivel de App. nil si Application Support no es accesible (raro).
private let sharedSettingsStore: JSONStore<AppSettings>? = {
    do {
        return try JSONStore(filename: "settings", defaultValue: AppSettings.default)
    } catch {
        AppLogger.app.error("Settings store init failed: \(error.localizedDescription, privacy: .public). Preferencias no persistirán esta sesión.")
        return nil
    }
}()

/// Recientes / última emisora — fuente única de verdad (máx 10, solo local).
private let sharedRecentsStore: RecentStationsStore? = {
    do {
        return try RecentStationsStore()
    } catch {
        AppLogger.app.error("RecentStationsStore init failed: \(error.localizedDescription, privacy: .public). Recientes deshabilitadas esta sesión.")
        return nil
    }
}()

@main
struct RadioPremiumApp: App {
    @State private var player = PlayerViewModel(
        settings: sharedSettingsStore,
        recents: sharedRecentsStore
    )
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

    /// Token del observer de iCloud. El `.task` del MenuBarExtra se re-dispara
    /// en CADA apertura del popover; sin este guard se acumulaba un observer
    /// por apertura y cada cambio de iCloud disparaba N re-merges concurrentes.
    @State private var icloudObserverToken: NSObjectProtocol?

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
        // Registrado UNA sola vez aunque el .task se re-ejecute por apertura.
        guard icloudObserverToken == nil else { return }
        icloudObserverToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { note in
            // El sistema también notifica cuando RECHAZA nuestro push por cuota
            // (1 MB por app en iCloud KV). Sin mirar el reason, ese rechazo se
            // confundía con un cambio remoto normal y el sync moría en silencio.
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                AppLogger.app.error("iCloud KV: cuota superada — el push de favoritos fue rechazado")
            }
            Task { @MainActor in
                AppLogger.app.info("iCloud favorites changed externally → re-mergeando")
                await repo.syncWithIcloud()
                browse.loadFavorites()
            }
        }
    }
}
