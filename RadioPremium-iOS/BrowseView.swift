//
//  BrowseView.swift
//  RadioPremium-iOS
//
//  Lista de emisoras top + búsqueda por nombre con debounce 300ms.
//

import SwiftUI

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var searchQuery: String = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Emisoras")
                .searchable(text: $searchQuery, prompt: "Buscar emisora…")
                .onChange(of: searchQuery) { _, newValue in
                    debouncedSearch(newValue)
                }
                .task {
                    if model.topStations.isEmpty {
                        await model.loadTopStations()
                    }
                }
                .refreshable {
                    if searchQuery.isEmpty {
                        await model.loadTopStations()
                    } else {
                        await model.search(searchQuery)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let isSearchMode = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        let stations = isSearchMode ? model.searchResults : model.topStations
        let isLoading = isSearchMode ? model.isSearching : model.isLoadingTop

        if isLoading && stations.isEmpty {
            ProgressView("Cargando emisoras…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.errorMessage, stations.isEmpty {
            ContentUnavailableView(
                "Sin conexión",
                systemImage: "wifi.exclamationmark",
                description: Text(err)
            )
        } else if stations.isEmpty {
            ContentUnavailableView(
                isSearchMode ? "Sin resultados" : "Sin emisoras",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text(isSearchMode
                    ? "No encontramos emisoras para “\(searchQuery)”."
                    : "Tira hacia abajo para recargar.")
            )
        } else {
            List(stations) { station in
                StationRowView(station: station)
            }
            .listStyle(.plain)
        }
    }

    private func debouncedSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.clearSearch()
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await model.search(trimmed)
        }
    }
}

// MARK: - Station row

struct StationRowView: View {
    @Environment(AppModel.self) private var model
    let station: Station

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.body)
                    .lineLimit(1)
                if let country = station.country, !country.isEmpty {
                    Text(country)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !station.tagList.isEmpty {
                    Text(station.tagList.prefix(3).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.favorites.toggle(station)
            } label: {
                Image(systemName: model.favorites.isFavorite(station.id) ? "star.fill" : "star")
                    .foregroundStyle(model.favorites.isFavorite(station.id) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                activate()
            } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { activate() }
    }

    /// Si la fila es la emisora actual, alterna play/pausa; si no, reproduce.
    /// Antes la acción era siempre `play(station)`: el botón mostraba el icono
    /// de pausa pero pulsar recreaba el AVPlayerItem y rebufferizaba desde
    /// cero — era imposible pausar desde la lista.
    private func activate() {
        if model.player.currentStation?.id == station.id {
            model.togglePlayPause()
        } else {
            model.play(station)
        }
    }

    private var isCurrentlyPlaying: Bool {
        guard let current = model.player.currentStation,
              current.id == station.id else { return false }
        return model.player.state == .playing || model.player.state == .buffering
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = station.favicon {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.tint.opacity(0.15))
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
            )
    }
}

#Preview {
    BrowseView()
        .environment(AppModel())
}
