//
//  PlayerDiagnostics.swift
//  RadioPremium-iOS
//
//  Caja negra del reproductor. Los cortes que el usuario oye en el coche no
//  se han podido reproducir en el simulador (red demasiado buena), así que
//  esto registra EN ARCHIVO lo que pasa durante el trayecto real: colchón,
//  velocidad, estado y cada evento (atasco, reconexión, interrupción…).
//
//  No usa os_log porque los niveles info/debug son volátiles y al llegar a
//  casa ya no estarían. Un CSV en Library/Application Support sobrevive, y
//  se extrae desde el Mac con el iPhone conectado:
//
//    xcrun devicectl device copy from --device <UDID> \
//      --domain-type appDataContainer \
//      --domain-identifier com.blancosampedro.RadioPremium-iOS \
//      --source "Library/Application Support/player-diagnostics.csv" \
//      --destination ./diag.csv
//
//  Formato: fecha;evento;colchonCrudo;colchonMedio;rate;estadoPlayer;red;extra
//  Rotación: al pasar de ~800 KB se renombra a .old (se conserva una vuelta).
//

import Foundation

@MainActor
final class PlayerDiagnostics {

    static let shared = PlayerDiagnostics()

    private let url: URL
    private let oldURL: URL
    private var handle: FileHandle?
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let maxBytes: UInt64 = 800_000

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        url = support.appendingPathComponent("player-diagnostics.csv")
        oldURL = support.appendingPathComponent("player-diagnostics.old.csv")
        open()
        line("session-start", extra: "app arrancada")
    }

    /// Registra un evento. `extra` es texto libre corto (sin ';').
    func line(
        _ event: String,
        cushionRaw: Double? = nil,
        cushionAvg: Double? = nil,
        rate: Float? = nil,
        playerStatus: String = "",
        networkUp: Bool? = nil,
        extra: String = ""
    ) {
        rotateIfNeeded()
        let fields: [String] = [
            stamp.string(from: Date()),
            event,
            cushionRaw.map { String(format: "%.1f", $0) } ?? "",
            cushionAvg.map { String(format: "%.1f", $0) } ?? "",
            rate.map { String(format: "%.2f", $0) } ?? "",
            playerStatus,
            networkUp.map { $0 ? "net-ok" : "net-down" } ?? "",
            extra.replacingOccurrences(of: ";", with: ","),
        ]
        guard let data = (fields.joined(separator: ";") + "\n").data(using: .utf8) else { return }
        handle?.write(data)
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data("fecha;evento;colchonCrudo;colchonMedio;rate;estadoPlayer;red;extra\n".utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
              size > maxBytes else { return }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
        open()
        line("rotated", extra: "archivo anterior en .old")
    }
}
