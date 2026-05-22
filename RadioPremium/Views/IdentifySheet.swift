//
//  IdentifySheet.swift
//  RadioPremium
//
//  Vista del flujo identify. Renderiza diferente UI según IdentifyState.
//  Se monta dentro del popover de menubar (no como sheet del sistema —
//  modal sheets desde popovers de MenuBarExtra se ven raros).
//
//  Estados visuales:
//    .explainingPermission    → PermissionExplanationCard (decisión 2A)
//    .requestingPermission    → ProgressView ("Esperando permiso…")
//    .permissionDenied        → PermissionDeniedCard (Open Settings deeplink)
//    .capturing(progress)     → CapturingView (barra 0..1 + "Escuchando…")
//    .processing              → ProcessingView ("Identificando…")
//    .result(history)         → TrackResultView (artwork + título + artista)
//    .noMatch                 → NoMatchView (decisión 2C)
//    .error(reason)           → ErrorView (con retry)
//

import SwiftUI

struct IdentifySheet: View {
    @Bindable var identify: IdentifyViewModel
    @Bindable var spotify: SpotifyViewModel
    @Bindable var appleMusic: AppleMusicViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity)
                .frame(minHeight: 140)
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: identify.isPresented) { _, newValue in
            // Al cerrar el sheet, limpiamos el estado de los servicios de música
            // para que la próxima identify arranque desde idle.
            if !newValue {
                spotify.reset()
                appleMusic.reset()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.tint)
            Text(headerTitle)
                .font(.headline)
            Spacer()
            Button {
                identify.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancelar y cerrar")
        }
    }

    private var headerTitle: String {
        switch identify.state {
        case .idle, .explainingPermission, .requestingPermission, .permissionDenied:
            return "Identificar canción"
        case .capturing:
            return "Escuchando…"
        case .processing:
            return "Identificando…"
        case .result:
            return "Canción identificada"
        case .noMatch:
            return "Sin resultados"
        case .error:
            return "Error"
        }
    }

    // MARK: - Content por state

    @ViewBuilder
    private var content: some View {
        switch identify.state {
        case .idle, .requestingPermission:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .explainingPermission:
            PermissionExplanationCard(onContinue: {
                identify.continueAfterExplanation()
            })

        case .permissionDenied:
            PermissionDeniedCard(onOpenSettings: {
                identify.openSystemSettings()
            })

        case .capturing(let progress):
            CapturingView(progress: progress)

        case .processing:
            ProcessingView()

        case .result(let history):
            TrackResultView(history: history, spotify: spotify, appleMusic: appleMusic)

        case .noMatch:
            NoMatchView(onRetry: {
                identify.retry()
            }, onDismiss: {
                identify.dismiss()
            })

        case .error(let reason):
            ErrorView(reason: reason, onRetry: {
                identify.retry()
            }, onDismiss: {
                identify.dismiss()
            })
        }
    }
}

// MARK: - Permission explanation (decisión 2A)

private struct PermissionExplanationCard: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("¿Por qué pide grabar pantalla?")
                    .font(.subheadline.weight(.semibold))
            }

            Text("macOS llama \"Screen Recording\" al permiso de capturar el audio del sistema. **No grabamos imágenes** ni vemos tu pantalla. Solo escuchamos el audio que sale por tus altavoces durante \(10) segundos para enviarlo a ACRCloud y reconocer la canción.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onContinue()
            } label: {
                Label("Continuar", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Permission denied

private struct PermissionDeniedCard: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Permiso denegado")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Sin permiso de Screen Recording no puedo escuchar el audio del sistema. Abre System Settings, activa RadioPremium en Privacy & Security → Screen Recording, y vuelve a probar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onOpenSettings()
            } label: {
                Label("Abrir System Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Capturing

private struct CapturingView: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Escuchando el audio del sistema…")
                    .font(.callout)
                Spacer()
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityValue("\(Int(progress * 100)) por ciento")

            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("~\(max(1, Int(10 - progress * 10)))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Processing

private struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Consultando ACRCloud…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Track result

private struct TrackResultView: View {
    let history: IdentifiedTrackHistory
    @Bindable var spotify: SpotifyViewModel
    @Bindable var appleMusic: AppleMusicViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkBox(url: history.track.artworkURL, size: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text(history.track.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(history.track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let album = history.track.album {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let stationName = history.stationName {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption2)
                            Text(stationName)
                                .font(.caption)
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            // Botón Apple Music: principal y único con flujo automático de
            // añadir a playlist (la integración con Apple Music sí permite
            // escrituras en biblioteca del usuario).
            AppleMusicAddButton(appleMusic: appleMusic, track: history.track)
            // Botón Spotify: en Development Mode los endpoints de escritura
            // y de lectura de playlists privadas devuelven 403. Mientras
            // tanto el botón solo BUSCA el track en Spotify y lo abre — el
            // usuario añade manualmente a la playlist que prefiera.
            if SpotifyConstants.isUIEnabled {
                SpotifyOpenButton(spotify: spotify, track: history.track)
            }
        }
        .onChange(of: history.id) { _, _ in
            // Si el sheet sigue abierto y se identifica otra canción nueva,
            // resetea el estado de ambos botones.
            spotify.reset()
            appleMusic.reset()
        }
    }
}

// MARK: - Spotify open button (state-aware)
//
// Botón "Abrir en Spotify": busca el track identificado en el catálogo de
// Spotify y abre el URI resultante en la app Spotify (con fallback a web).
// El usuario añade manualmente a la playlist que prefiera. Esto esquiva los
// endpoints de escritura/lectura de playlists privadas que Spotify bloquea
// en Development Mode con 403.

private struct SpotifyOpenButton: View {
    @Bindable var spotify: SpotifyViewModel
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                spotify.openInSpotify(track)
            } label: {
                HStack(spacing: 6) {
                    icon
                    Text(label)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)
            .disabled(isDisabled)

            if let detail = detailMessage {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch spotify.state {
        case .idle, .notFound, .error:
            Image(systemName: "arrow.up.right.square.fill")
        case .authenticating, .processing:
            ProgressView().controlSize(.small)
        case .openedInSpotify:
            Image(systemName: "checkmark.circle.fill")
        case .success:
            // Caso no esperado en este flujo (el flujo "open" usa
            // `.openedInSpotify`). Si llegara aquí, mostramos check neutral.
            Image(systemName: "checkmark.circle.fill")
        }
    }

    private var label: String {
        switch spotify.state {
        case .idle:
            return "Abrir en Spotify"
        case .authenticating:
            return "Conectando con Spotify…"
        case .processing:
            return "Buscando en Spotify…"
        case .openedInSpotify:
            return "Abierto en Spotify"
        case .success:
            return "Abierto en Spotify"
        case .notFound:
            return "Reintentar búsqueda"
        case .error:
            return "Reintentar"
        }
    }

    private var buttonTint: Color {
        switch spotify.state {
        case .openedInSpotify, .success: return .green
        case .notFound, .error: return .orange
        default:
            // Color de marca Spotify (verde).
            return Color(red: 30/255, green: 215/255, blue: 96/255)
        }
    }

    private var isDisabled: Bool {
        switch spotify.state {
        case .authenticating, .processing: return true
        default: return false
        }
    }

    private var detailMessage: String? {
        switch spotify.state {
        case .idle, .authenticating, .processing:
            return nil
        case .openedInSpotify:
            return "Añádela manualmente a la playlist que quieras."
        case .success:
            return "Track abierto en Spotify."
        case .notFound(let query):
            return "Spotify no encontró \"\(query)\". Pulsa para reintentar."
        case .error(let reason):
            return reason
        }
    }
}

// MARK: - Apple Music add button (state-aware)

private struct AppleMusicAddButton: View {
    @Bindable var appleMusic: AppleMusicViewModel
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                appleMusic.addToPlaylist(track)
            } label: {
                HStack(spacing: 6) {
                    icon
                    Text(label)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)
            .disabled(isDisabled)

            if let detail = detailMessage {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch appleMusic.state {
        case .idle, .notFound, .error:
            Image(systemName: "music.note.house.fill")
        case .authenticating, .processing:
            ProgressView().controlSize(.small)
        case .success(.added, _):
            Image(systemName: "checkmark.circle.fill")
        case .success(.alreadyPresent, _):
            Image(systemName: "checkmark.seal.fill")
        }
    }

    private var label: String {
        switch appleMusic.state {
        case .idle:
            return "Añadir a Apple Music"
        case .authenticating:
            return "Autorizando Apple Music…"
        case .processing:
            return "Añadiendo a Radio Likes…"
        case .success(.added, _):
            return "Añadido a Radio Likes"
        case .success(.alreadyPresent, _):
            return "Ya estaba en Radio Likes"
        case .notFound:
            return "Reintentar en Apple Music"
        case .error:
            return "Reintentar"
        }
    }

    private var buttonTint: Color {
        switch appleMusic.state {
        case .success: return .green
        case .notFound, .error: return .orange
        default: return .pink // color de marca Apple Music
        }
    }

    private var isDisabled: Bool {
        switch appleMusic.state {
        case .authenticating, .processing: return true
        default: return false
        }
    }

    private var detailMessage: String? {
        switch appleMusic.state {
        case .idle, .authenticating, .processing:
            return nil
        case .success(.added, _):
            return "Disponible en tu playlist Radio Likes."
        case .success(.alreadyPresent, _):
            return "Ya tenías esta canción en Radio Likes."
        case .notFound(let query):
            return "Apple Music no encontró \"\(query)\". Pulsa para reintentar."
        case .error(let reason):
            return reason
        }
    }
}

// MARK: - No match (decisión 2C)

private struct NoMatchView: View {
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No reconocí esta canción")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Reintenta cuando llegue el estribillo, o si hay voz por encima espera a que pase. ACRCloud reconoce mejor los fragmentos limpios.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cerrar", action: onDismiss)
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    onRetry()
                } label: {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Error

private struct ErrorView: View {
    let reason: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Algo falló")
                    .font(.subheadline.weight(.semibold))
            }

            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cerrar", action: onDismiss)
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    onRetry()
                } label: {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Artwork (variante de la del MenubarView)

private struct ArtworkBox: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:    placeholder
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure:  placeholder
                    @unknown default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        ZStack {
            Color(NSColor.tertiarySystemFill)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
    }
}
