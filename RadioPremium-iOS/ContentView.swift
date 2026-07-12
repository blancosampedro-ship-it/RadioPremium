//
//  ContentView.swift
//  RadioPremium-iOS
//
//  Raíz: TabView con 3 tabs (Emisoras, Favoritos, Reproduciendo) +
//  mini-player flotante encima del tab bar cuando hay algo sonando.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab: Tab = .browse

    enum Tab: Hashable {
        case browse, favorites, now
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                BrowseView()
                    .tabItem { Label("Emisoras", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(Tab.browse)

                FavoritesView()
                    .tabItem { Label("Favoritos", systemImage: "star.fill") }
                    .tag(Tab.favorites)

                NowPlayingScreen()
                    .tabItem { Label("Sonando", systemImage: "waveform") }
                    .tag(Tab.now)
            }

            // Mini-player flotante. Solo visible si hay algo sonando o pausado.
            if model.player.currentStation != nil, selectedTab != .now {
                MiniPlayerBar(onTap: { selectedTab = .now })
                    .padding(.horizontal, 8)
                    .padding(.bottom, 52)  // por encima del tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.player.currentStation?.id)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
