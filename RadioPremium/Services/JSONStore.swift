//
//  JSONStore.swift
//  RadioPremium
//
//  Almacén genérico de objetos Codable en disco vía JSON.
//  Ubicación estándar: ~/Library/Application Support/com.blancosampedro.RadioPremium/{filename}.json
//
//  Recovery graceful: si el JSON está corrupto, log warning + borra el archivo
//  + devuelve el defaultValue. Evita que un único archivo dañado tumbe la app.
//
//  Atomic writes: save() usa Data.write con `.atomic` para evitar archivos
//  truncados si el sistema corta la operación a la mitad.
//

import Foundation
import os

actor JSONStore<T: Codable & Sendable> {
    private let url: URL
    private let defaultValue: T
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Init estándar: resuelve a Application Support/com.blancosampedro.RadioPremium/{filename}.json.
    init(filename: String, defaultValue: T) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = support.appendingPathComponent(
            "com.blancosampedro.RadioPremium",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        self.url = appDir.appendingPathComponent("\(filename).json")
        self.defaultValue = defaultValue
        self.decoder = JSONDecoder()

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
    }

    /// Init con URL custom — usado en tests para evitar tocar Application Support real.
    init(url: URL, defaultValue: T) {
        self.url = url
        self.defaultValue = defaultValue
        self.decoder = JSONDecoder()

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
    }

    /// Carga desde disco. Devuelve `defaultValue` si el archivo no existe o si
    /// el JSON está corrupto (en cuyo caso también borra el archivo dañado).
    func load() async -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.storage.warning(
                "JSONStore corrupted at \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Reseteando a default."
            )
            try? FileManager.default.removeItem(at: url)
            return defaultValue
        }
    }

    /// Guarda atómicamente. Lanza si encoding o write falla.
    func save(_ value: T) async throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    /// Borra el archivo. Idempotente — no falla si no existe.
    func reset() async {
        try? FileManager.default.removeItem(at: url)
    }

    /// URL del archivo en disco. Útil para tests y diagnóstico.
    nonisolated var fileURL: URL { url }
}
