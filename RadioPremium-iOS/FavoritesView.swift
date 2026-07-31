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
                    // Resolver las víctimas ANTES de borrar: iterar el IndexSet
                    // mutando el array invalida los índices siguientes en un
                    // borrado múltiple (podía borrar la emisora equivocada).
                    let victims = indexSet.map { model.favorites.stations[$0] }
                    for station in victims {
                        model.favorites.remove(station)
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
