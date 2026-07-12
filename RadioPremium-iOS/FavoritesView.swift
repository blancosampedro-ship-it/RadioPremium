//
//  FavoritesView.swift
//  RadioPremium-iOS
//
//  Lista de emisoras marcadas como favoritas. Swipe-left para eliminar,
//  tap para reproducir, estrella ya está marcada.
//

import SwiftUI

struct FavoritesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Favoritos")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.favorites.stations.isEmpty {
            ContentUnavailableView(
                "Sin favoritos",
                systemImage: "star.slash",
                description: Text("Pulsa la estrella ★ en cualquier emisora para guardarla aquí.")
            )
        } else {
            List {
                ForEach(model.favorites.stations) { station in
                    StationRowView(station: station)
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        let s = model.favorites.stations[idx]
                        model.favorites.remove(s)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

#Preview {
    FavoritesView()
        .environment(AppModel())
}
