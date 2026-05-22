//
//  PermissionsHelper.swift
//  RadioPremium
//
//  Estado del permiso "Screen Recording" + deeplink a System Settings.
//
//  macOS no expone una API pública directa para preguntar el estado del
//  permiso ScreenCaptureKit. La forma probada de detectarlo: intentar
//  `SCShareableContent.current()`. Si lanza, está denegado o aún no concedido.
//  Si retorna, está concedido.
//
//  Para abrir Settings usamos el URL scheme oficial de macOS 13+ que apunta
//  directamente al panel Privacy & Security → Screen Recording.
//

import Foundation
import ScreenCaptureKit
import AppKit
import os

enum ScreenRecordingPermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
}

enum PermissionsHelper {

    /// Comprueba el permiso de Screen Recording sin disparar el dialog del sistema.
    /// Devuelve `.granted` si SCShareableContent es accesible, `.denied` o
    /// `.notDetermined` (no podemos distinguir bien los dos sin disparar TCC).
    ///
    /// Conservadoramente, mapeamos cualquier fallo a `.denied`. La UX será:
    /// "necesito permiso → abre Settings". Si era `.notDetermined`, la primera
    /// llamada real a SCStream disparará el dialog del sistema.
    static func screenRecordingStatus() async -> ScreenRecordingPermissionStatus {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return .granted
        } catch {
            AppLogger.identify.debug("screenRecordingStatus probe failed: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }

    /// Abre System Settings → Privacy & Security → Screen Recording.
    /// Llamar después de detectar `.denied` para que el usuario pueda activar
    /// el toggle manualmente.
    static func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        guard let url = URL(string: urlString) else {
            AppLogger.identify.error("PermissionsHelper: deeplink URL inválido")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
