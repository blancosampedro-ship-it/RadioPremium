//
//  Secrets.swift
//  RadioPremium
//
//  Acceso tipado al Secrets.plist local (gitignored).
//  Falla loud con fatalError si falta el archivo o una clave.
//  El v1 NO debe arrancar sin secrets correctamente configurados.
//
//  Política de claves: ver memoria del proyecto secrets_policy.md.
//  Las claves se reusan temporalmente desde la app Windows; rotación
//  aplazada hasta que la Mac sustituya a la Windows.
//

import Foundation

enum Secrets {
    private nonisolated static let plist: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") else {
            fatalError("""
                Secrets.plist no encontrado en el bundle.

                Acción: copia Resources/Secrets.example.plist a Resources/Secrets.plist \
                y rellena los valores reales. El archivo está en .gitignore, no se sube nunca.
                """)
        }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            fatalError("Secrets.plist existe pero no se puede parsear como [String: String].")
        }
        return dict
    }()

    private nonisolated static func required(_ key: String) -> String {
        guard let value = plist[key], !value.isEmpty else {
            fatalError("Secrets.plist falta clave requerida: \(key)")
        }
        return value
    }

    nonisolated static var acrCloudHost: String         { required("AcrCloudHost") }
    nonisolated static var acrCloudAccessKey: String    { required("AcrCloudAccessKey") }
    nonisolated static var acrCloudAccessSecret: String { required("AcrCloudAccessSecret") }
    nonisolated static var spotifyClientId: String      { required("SpotifyClientId") }
    nonisolated static var spotifyRedirectUri: String   { required("SpotifyRedirectUri") }
    nonisolated static var radioBrowserBaseUrl: String  { required("RadioBrowserBaseUrl") }
}
