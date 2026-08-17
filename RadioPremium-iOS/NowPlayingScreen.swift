//
//  NowPlayingScreen.swift
//  RadioPremium-iOS
//
//  Pantalla a tamaño completo de la emisora en reproducción: artwork grande,
//  nombre, país, controles play/pause/stop, volumen.
//

import SwiftUI

struct NowPlayingScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sonando")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let station = model.player.currentStation {
            playingContent(station)
        } else {
            ContentUnavailableView(
                "Nada en reproducción",
                systemImage: "waveform.slash",
                description: Text("Selecciona una emisora desde la pestaña Emisoras o Favoritos.")
            )
        }
    }

    @ViewBuilder
    private func playingContent(_ station: Station) -> some View {
        VStack(spacing: 24) {
            artwork(for: station)
                .frame(maxWidth: 260, maxHeight: 260)
                .padding(.top, 24)

            VStack(spacing: 6) {
                Text(station.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let country = station.country, !country.isEmpty {
                    Text(country)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                statusBadge
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            controls

            Spacer()

            volumeSlider
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func artwork(for station: Station) -> some View {
        Group {
            if let url = station.favicon {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.tint.opacity(0.15))
            .overlay(
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)
            )
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch model.player.state {
            case .idle:        return ("Detenido", .secondary)
            case .buffering:   return ("Cargando…", .orange)
            case .playing:     return ("En directo", .green)
            case .paused:      return ("Pausado", .secondary)
            case .reconnecting(let attempt):
                return (attempt == 1 ? "Reconectando…" : "Reconectando… (\(attempt))", .orange)
            case .error(let r): return ("Error: \(r)", .red)
            }
        }()
        return Label(text, systemImage: model.player.state == .playing ? "dot.radiowaves.left.and.right" : "circle.fill")
            .font(.caption.bold())
            .foregroundStyle(color)
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button(action: { model.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 64, height: 64)

            Button(action: { model.togglePlayPause() }) {
                Image(systemName: playPauseIcon)
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            // Slot vacío para simetría (en el futuro: airplay/output).
            Color.clear.frame(width: 64, height: 64)
        }
    }

    private var playPauseIcon: String {
        switch model.player.state {
        case .playing, .buffering, .reconnecting: return "pause.circle.fill"
        default:                                  return "play.circle.fill"
        }
    }

    private var volumeSlider: some View {
        @Bindable var bindable = model.player
        return HStack(spacing: 12) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: $bindable.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mini-player flotante (usado por ContentView encima del tab bar)

struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    let onTap: () -> Void

    var body: some View {
        guard let station = model.player.currentStation else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 12) {
                artwork(for: station)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(station.name)
                        .font(.footnote.bold())
                        .lineLimit(1)
                    Text(stateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { model.togglePlayPause() }) {
                    Image(systemName: model.player.state.isActive ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        )
    }

    private var stateText: String {
        switch model.player.state {
        case .idle:          return "Detenido"
        case .buffering:     return "Cargando…"
        case .playing:       return "En directo"
        case .paused:        return "Pausado"
        case .reconnecting:  return "Reconectando…"
        case .error:         return "Error"
        }
    }

    @ViewBuilder
    private func artwork(for station: Station) -> some View {
        if let url = station.favicon {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.2))
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.2))
        }
    }
}

#Preview {
    NowPlayingScreen()
        .environment(AppModel())
}
