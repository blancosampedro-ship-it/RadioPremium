//
//  RadioPremium_iOSApp.swift
//  RadioPremium-iOS
//
//  Entry point. Instancia el AppModel y lo inyecta vía @Environment.
//

import SwiftUI

@main
struct RadioPremium_iOSApp: App {
    /// La instancia compartida — la escena CarPlay usa la misma, así que el
    /// coche y el iPhone controlan el mismo player y los mismos favoritos.
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
