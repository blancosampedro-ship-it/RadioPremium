# Radio Premium — memoria del proyecto

## Estado a 28 abr 2026

App macOS menubar nativa, instalada en `/Applications/Radio Premium.app`. Funcional para uso diario.

---

## Coordenadas

| Concepto | Valor |
|---|---|
| **Repo de código** | `/Users/winfin/RadioPremium/` |
| **Bundle ID** | `com.blancosampedro.RadioPremium` |
| **Team ID Apple Developer** | `886836VWWK` (Juan Blanco) |
| **Apple ID asociado** | `twetter@gmail.com` |
| **Cert actual de firma** | Apple Development (en Keychain, válido para tu Mac) |
| **macOS deployment target** | 14.0 (Sonoma) |
| **Sandbox** | OFF (incompatible con ScreenCaptureKit + AVAudioConverter) |
| **Hardened Runtime** | ON |
| **Tests** | 211/211 pasando |

---

## Arquitectura — qué hay y dónde

```
RadioPremium/
├── App/
│   └── RadioPremiumApp.swift        ← entry point, instancia ViewModels
├── Models/
│   ├── Station.swift                ← emisora (Radio Browser API compatible)
│   ├── Track.swift                  ← canción identificada
│   ├── SpotifyModels.swift          ← DTOs Spotify + SpotifyConstants
│   ├── AcrCloudResponse.swift
│   ├── PlaybackState.swift
│   ├── IdentifiedTrackHistory.swift
│   └── AppSettings.swift
├── Services/
│   ├── HTTPClient.swift             ← actor wrapper sobre URLSession
│   ├── RadioBrowserClient.swift     ← API de Radio Browser (búsquedas)
│   ├── ScreenCaptureRecorder.swift  ← ScreenCaptureKit (audio sistema)
│   ├── AudioConverter.swift         ← AVAudioConverter (48k stereo → 8k mono)
│   ├── AcrCloudClient.swift         ← API ACRCloud (HMAC-SHA1, WAV wrap)
│   ├── AudioPlayer.swift            ← AVPlayer + Now Playing Center
│   ├── NowPlayingCenter.swift       ← MPNowPlayingInfoCenter integration
│   ├── KeychainStore.swift          ← wrapper sobre SecItem*
│   ├── SpotifyAuthClient.swift      ← OAuth PKCE + ASWebAuthenticationSession
│   ├── SpotifyApiClient.swift       ← Web API Spotify (oculto en UI)
│   ├── AppleMusicClient.swift       ← MusicKit + REST api.music.apple.com
│   ├── JSONStore.swift              ← persistencia genérica Codable → JSON
│   ├── IdentifiedTracksRepository.swift  ← historial canciones
│   ├── FavoritesRepository.swift    ← emisoras favoritas
│   ├── PermissionsHelper.swift
│   └── Retry.swift
├── ViewModels/
│   ├── PlayerViewModel.swift
│   ├── RadioBrowseViewModel.swift   ← búsqueda + favoritos
│   ├── IdentifyViewModel.swift      ← state machine identify flow
│   ├── SpotifyViewModel.swift       ← (oculto en UI)
│   └── AppleMusicViewModel.swift
├── Views/
│   ├── MenubarView.swift            ← popover principal + BrowseList + StationRow
│   └── IdentifySheet.swift          ← sheet de identify + AppleMusicAddButton
├── Helpers/
│   ├── AppLogger.swift              ← os.Logger por categoría
│   ├── RadioPremiumError.swift      ← error type central (LocalizedError)
│   ├── PKCEGenerator.swift
│   └── Secrets.swift                ← lee Secrets.plist
├── Resources/
│   ├── Secrets.plist                ← claves ACRCloud + Spotify (NO commit)
│   └── Secrets.example.plist
├── Assets.xcassets/
│   └── AppIcon.appiconset/          ← 10 PNGs (16-1024 1x/2x)
└── Info.plist                        ← URL scheme + ATS + Apple Music desc

scripts/
└── install-locally.sh                ← rebuild + sign + install /Applications

RadioPremium.entitlements             ← actualmente vacío (sandbox OFF)
RadioPremium.xcodeproj                ← config build, signing, INFOPLIST_KEY_*
```

---

## Funcionalidades implementadas

1. **Browse de emisoras** vía Radio Browser API (top 30 + búsqueda con debounce 300ms).
2. **Streaming** vía AVPlayer, integrado con Now Playing Center (Control Center, Touch Bar, AirPods).
3. **Identify** de canción que está sonando:
   - ScreenCaptureKit captura 10s de audio del sistema.
   - AVAudioConverter resamplea 48kHz stereo Float32 → 8kHz mono Int16.
   - WAV wrap manual (RIFF/WAVE 44 bytes).
   - HMAC-SHA1 firma para ACRCloud.
   - Multipart POST a `identify-eu-west-1.acrcloud.com`.
4. **Apple Music**: añade canción identificada a playlist "Radio Likes" en biblioteca personal.
   - MusicKit nativo para auth + búsqueda catálogo (ISRC + fallback título/artista).
   - REST `api.music.apple.com` para crear/leer/escribir playlist (las APIs nativas `MusicLibrary.shared.createPlaylist` son iOS-only).
5. **Favoritos** de emisoras: estrella ★ por fila, persistencia JSON, sección dedicada en el popover.
6. **Historial** de canciones identificadas: persistido en `~/Library/Application Support/com.blancosampedro.RadioPremium/identified-tracks.json` (sin vista UI todavía — el repo está hecho).

---

## Feature flags y cosas dormidas

| Flag/área | Estado | Cómo reactivar |
|---|---|---|
| `SpotifyConstants.isUIEnabled` (`Models/SpotifyModels.swift`) | `false` | Cuando Spotify apruebe la **Extended Quota Mode** review (~1-3 semanas tras solicitud), pones `true` y el botón vuelve. Solicitud en https://developer.spotify.com/dashboard → app → "Extensions". |
| `MusicKit App Service` | Activo en developer.apple.com sobre el App ID | No tocar a menos que quites MusicKit. |
| Vista de historial de canciones identificadas | Backend hecho, UI no | Crear `Views/HistoryView.swift` que use `IdentifiedTracksRepository.load()`. |
| Sleep timer | No implementado | Añadir a `PlayerViewModel` un timer + acción "stop in N min". |
| ICY metadata del stream | No implementado | AVPlayer expone `AVPlayerItem.timedMetadata` para títulos en stream Shoutcast/Icecast. |
| Auto-update tipo Sparkle | No implementado | Innecesario para uso personal; relevante si distribuyes fuera del App Store. |

---

## Apple Developer setup (lo que está activo)

- **App ID**: `com.blancosampedro.RadioPremium` registrado como explicit en developer.apple.com.
- **Capabilities marcadas en App ID**: ninguna (Capabilities tab vacía).
- **App Services marcados**: **MusicKit** ✓ (ShazamKit y WeatherKit sin marcar).
- **Provisioning profile**: gestionado automáticamente por Xcode.
- **Cert "Developer ID Application"**: NO creado (no hace falta para uso personal). Si algún día quieres distribuir, créalo en Xcode → Settings → Accounts → Manage Certificates → +.
- **App-specific password**: guardado en Keychain con nombre `RadioPremium.AppleID.AppPassword` (lo guardaste tú). Solo se usa para notarización; no necesario mientras no distribuyas.

---

## Cómo hacer cambios y reinstalar

### Cambio rápido y test (durante desarrollo)

Abre el proyecto en Xcode (`open "/Users/winfin/RadioPremium/RadioPremium.xcodeproj"`), edita, `Cmd+R` para correr Debug. Esa es una build aparte que vive en DerivedData, no toca la de `/Applications`.

### Reinstalar la versión en /Applications con tus cambios

```bash
cd "/Users/winfin/RadioPremium"
./scripts/install-locally.sh
```

Tarda ~30 segundos. El script: cierra la app si está abierta, build Release sin firmar, limpia xattrs (`com.apple.FinderInfo` se cuela en los bundles firmados y rompe codesign), firma con tu cert de development, copia a `/Applications/Radio Premium.app`.

### Si añades nuevos assets gráficos (PNG/JPG)

macOS les añade `com.apple.quarantine` y `com.apple.FinderInfo` que rompen codesign. El script ya lo limpia, pero si la build falla con _"resource fork, Finder information, or similar detritus not allowed"_ ya sabes el origen — el script tiene la función `strip_detritus()` que se ocupa.

### Si actualizas macOS o Xcode

Posibles regresiones:
- **Swift 6 strict concurrency**: el código tiene warnings que pueden volverse errores. Las anotaciones `nonisolated`, `@MainActor`, `@unchecked Sendable` ya están donde toca.
- **MusicKit API changes**: si Apple cambia los métodos `MusicLibrary.shared.*`, revisa `AppleMusicClient.swift`.
- **Provisioning profile expirado**: Xcode debería renovarlo automáticamente con "Automatically manage signing".

### Si quieres distribuir a otro Mac (notarización)

Está prácticamente todo listo:
1. Crear cert "Developer ID Application" en Xcode (no lo tienes aún).
2. Reconstruir el script `release.sh` (borrado tras decidir uso solo personal): hace build Release con Developer ID → notarytool submit → staple → empaqueta DMG. El password ya está en Keychain como `RadioPremium.AppleID.AppPassword`. Si quieres reactivarlo en el futuro pídelo y se reconstruye.

---

## Secrets

Los archivos con claves API:

- `Resources/Secrets.plist` — claves ACRCloud (host, accessKey, accessSecret) + Spotify Client ID + redirect URI.
- `Resources/Secrets.example.plist` — plantilla pública (sin claves reales).

**Importante**: estos viajan dentro del `.app` instalado. Quien tenga la `.app` puede sacar las claves. Para uso personal: irrelevante. Para distribución pública futura: habría que mover ACRCloud a backend o reemplazar por ShazamKit (gratis, sin clave).

---

## Datos del usuario en disco

| Qué | Dónde |
|---|---|
| Tokens Spotify | Keychain, service `com.blancosampedro.RadioPremium.spotify` |
| Sesión MusicKit | Gestionada por macOS (cuenta Apple Music del sistema) |
| Historial de canciones identificadas | `~/Library/Application Support/com.blancosampedro.RadioPremium/identified-tracks.json` |
| Favoritos de emisoras | `~/Library/Application Support/com.blancosampedro.RadioPremium/favorites.json` |
| Logs | Console.app, subsystem `com.blancosampedro.RadioPremium`, categorías: `app`, `radio`, `identify`, `spotify`, `applemusic`, `audio`, `http`, `storage` |

---

## Cuando vuelvas en el futuro

Si pasa tiempo y quieres retomar, los puntos de entrada útiles:

- Para abrir el proyecto: `open "/Users/winfin/RadioPremium/RadioPremium.xcodeproj"`.
- Para ejecutar todos los tests: en Xcode `Cmd+U`, o por terminal `xcodebuild -scheme RadioPremium -destination "platform=macOS" test -only-testing:RadioPremiumTests`.
- Para ver los logs en vivo: Console.app → filter `subsystem:com.blancosampedro.RadioPremium`.
- Para reinstalar: `./scripts/install-locally.sh`.

Si pides "retomar Radio Premium" más adelante, lee este archivo para reconstruir contexto rápido.
