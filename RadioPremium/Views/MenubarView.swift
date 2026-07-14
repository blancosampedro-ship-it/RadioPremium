//
//  MenubarView.swift
//  RadioPremium
//
//  Popover principal del MenuBarExtra.
//
//  Layout (decisiones D1, D2 de /plan-design-review):
//    [NowPlayingBand]   ← solo si hay emisora activa
//    [Search field]
//    [Section header: "Populares" o "Resultados para X"]
//    [Lista de stations o empty/error state]
//    [Salir ⌘Q]
//

import SwiftUI

struct MenubarView: View {
    @Bindable var player: PlayerViewModel
    @Bindable var browse: RadioBrowseViewModel
    @Bindable var identify: IdentifyViewModel
    @Bindable var spotify: SpotifyViewModel
    @Bindable var appleMusic: AppleMusicViewModel

    var body: some View {
        Group {
            if identify.isPresented {
                IdentifySheet(identify: identify, spotify: spotify, appleMusic: appleMusic)
            } else {
                BrowseAndPlayerContent(player: player, browse: browse, identify: identify)
            }
        }
    }
}

// MARK: - Contenido principal del popover (sin identify activo)

private struct BrowseAndPlayerContent: View {
    @Bindable var player: PlayerViewModel
    @Bindable var browse: RadioBrowseViewModel
    @Bindable var identify: IdentifyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let station = player.currentStation {
                NowPlayingBand(player: player, identify: identify, station: station)
                Divider()
            }

            SearchField(browse: browse)

            BrowseList(player: player, browse: browse)
                .frame(minHeight: 220, maxHeight: 320)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Salir", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
        .task {
            // Carga "populares" la primera vez que aparece el popover.
            // Llamadas siguientes (al reabrir) no hacen request si results
            // ya están en memoria — pero performSearch sí re-fetcha al teclear.
            if browse.results.isEmpty && browse.errorMessage == nil {
                browse.loadPopular()
            }
            // Favoritos: siempre refresh al aparecer (el estado en memoria
            // puede haber quedado obsoleto si otra ventana / sesión los tocó).
            browse.loadFavorites()
        }
        .onDisappear {
            browse.cancel()
        }
    }
}

// MARK: - Now Playing band

private struct NowPlayingBand: View {
    @Bindable var player: PlayerViewModel
    @Bindable var identify: IdentifyViewModel
    let station: Station

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                StationArtwork(url: station.faviconURL, size: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    identify.startIdentify(currentStation: station)
                } label: {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityLabel("Identificar canción que está sonando")
                .help("Identificar canción (⌘I)")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying || player.isBuffering ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Parar y cerrar emisora")
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("Volumen")
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateLabel: String {
        switch player.state {
        case .playing:           return "Reproduciendo"
        case .buffering:         return "Conectando…"
        case .paused:            return "Pausado"
        case .idle:              return "Listo"
        case .error(let reason): return "Error: \(reason)"
        }
    }
}

// MARK: - Search field

private struct SearchField: View {
    @Bindable var browse: RadioBrowseViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar emisora…", text: $browse.query)
                .textFieldStyle(.plain)
                .onChange(of: browse.query) { _, _ in
                    browse.performSearch()
                }
            if !browse.query.isEmpty {
                Button {
                    browse.query = ""
                    browse.performSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpiar búsqueda")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - Browse list (results + states + favoritos)

private struct BrowseList: View {
    @Bindable var player: PlayerViewModel
    @Bindable var browse: RadioBrowseViewModel

    var body: some View {
        // Estados error/empty fuera del scroll (tamaños predecibles, no
        // necesitan scroll). Resto va dentro de un único ScrollView con
        // los section headers inline — favoritos arriba, populares debajo.
        if let error = browse.errorMessage {
            ErrorRow(message: error) { browse.loadPopular() }
        } else if browse.results.isEmpty && !browse.showsFavoritesSection {
            // Sin resultados ni favoritos: solo loader o mensaje empty.
            VStack(alignment: .leading, spacing: 8) {
                if browse.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(browse.emptyStateMessage ?? "Cargando…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let empty = browse.emptyStateMessage {
                    Text(empty)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Sección Favoritos (solo si hay favoritos Y query vacío).
                    if browse.showsFavoritesSection {
                        SectionHeader(title: "Favoritos", systemImage: "star.fill")
                            .padding(.bottom, 4)
                        ForEach(browse.favorites) { station in
                            StationRow(
                                station: station,
                                isPlaying: player.currentStation?.id == station.id,
                                isFavorite: true,
                                onPlay: { player.play(station) },
                                onToggleFavorite: { browse.toggleFavorite(station) }
                            )
                            if station.id != browse.favorites.last?.id {
                                Divider().opacity(0.4)
                            }
                        }
                        Divider().padding(.vertical, 8)
                    }

                    // Header de la sección principal con loading spinner inline.
                    HStack(spacing: 6) {
                        SectionHeader(
                            title: browse.sectionTitle,
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        if browse.isLoading {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.bottom, 4)

                    // Filas de la sección principal (populares o resultados).
                    ForEach(browse.results) { station in
                        StationRow(
                            station: station,
                            isPlaying: player.currentStation?.id == station.id,
                            isFavorite: browse.isFavorite(station),
                            onPlay: { player.play(station) },
                            onToggleFavorite: { browse.toggleFavorite(station) }
                        )
                        if station.id != browse.results.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Section header reutilizable

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Station row

private struct StationRow: View {
    let station: Station
    let isPlaying: Bool
    let isFavorite: Bool
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Zona principal pulsable: artwork + nombre + metadata + indicador
            // de "sonando ahora". Click → play. `.frame(maxWidth: .infinity)`
            // fuerza al Button a estirarse a todo el ancho disponible — sin
            // esto el outer HStack lo ve con tamaño intrínseco y la estrella
            // queda pegada al texto en lugar de al borde derecho.
            Button(action: onPlay) {
                HStack(spacing: 8) {
                    StationArtwork(url: station.faviconURL, size: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(station.name)
                            .font(.callout)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(metadata)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Sonando ahora")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Botón aparte para toggle favorito. Aislado del Button de play
            // para que el click no dispare el play del row entero.
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.callout)
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos")
            .help(isFavorite ? "Quitar de favoritos" : "Añadir a favoritos")
        }
    }

    private var metadata: String {
        var parts: [String] = []
        if let cc = station.countryCode, !cc.isEmpty { parts.append(cc) }
        if let codec = station.codec, !codec.isEmpty { parts.append(codec) }
        if let bitrate = station.bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - Error row

private struct ErrorRow: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button("Reintentar", action: onRetry)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Artwork

private struct StationArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 32 ? 6 : 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size > 32 ? 6 : 4, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        ZStack {
            Color(NSColor.tertiarySystemFill)
            Image(systemName: "music.note")
                .font(size > 32 ? .title3 : .caption)
                .foregroundStyle(.secondary)
        }
    }
}
