//
//  RadioPremium_iOSApp.swift
//  RadioPremium-iOS
//
//  Entry point. Instancia el AppModel y lo inyecta vía @Environment.
//

import SwiftUI

@main
struct RadioPremium_iOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
