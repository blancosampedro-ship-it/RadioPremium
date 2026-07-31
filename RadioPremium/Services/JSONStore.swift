//
//  JSONStore.swift
//  RadioPremium
//
//  Almacén genérico de objetos Codable en disco vía JSON.
//  Ubicación estándar: ~/Library/Application Support/com.blancosampedro.RadioPremium/{filename}.json
//
//  Recovery graceful: si el JSON está corrupto, log warning + se aparta el
//  archivo a `<nombre>.json.corrupt` + devuelve el defaultValue. Evita que un
//  único archivo dañado tumbe la app, sin destruir los datos: un decode fallido
//  también ocurre si un esquema futuro añade un campo obligatorio, y borrar
//  significaba perder favoritos/historial sin posibilidad de recuperación.
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
    /// el JSON no decodifica (en cuyo caso el archivo se aparta a `.corrupt`,
    /// nunca se borra). Un fallo de LECTURA (I/O transitorio) no toca el archivo:
    /// la próxima carga reintentará.
    func load() async -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLogger.storage.warning(
                "JSONStore read failed at \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Devolviendo default sin tocar el archivo."
            )
            return defaultValue
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.storage.warning(
                "JSONStore corrupted at \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Apartando a .corrupt y devolviendo default."
            )
            quarantineCorruptFile()
            return defaultValue
        }
    }

    /// Aparta el archivo ilegible a `<nombre>.json.corrupt` (reemplazando una
    /// cuarentena anterior si existía). Conservarlo permite recuperar los datos
    /// a mano si el "corrupto" era en realidad un esquema más nuevo/viejo.
    private func quarantineCorruptFile() {
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
        } catch {
            AppLogger.storage.error(
                "quarantine failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
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
