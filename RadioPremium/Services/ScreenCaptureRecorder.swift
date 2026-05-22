//
//  ScreenCaptureRecorder.swift
//  RadioPremium
//
//  Captura el audio del sistema usando ScreenCaptureKit.
//  La API se llama "Screen Recording" en macOS por convención de TCC,
//  aunque solo capturamos audio (no pixels).
//
//  Config aplicada (decisión 4A del eng review):
//    - capturesAudio = true
//    - excludesCurrentProcessAudio = true (no nos grabamos a nosotros)
//    - sample rate 48000 Hz, 2 canales (defaults SCStream)
//    - no captura de display (filter incluye display pero sin tamaño)
//
//  Resultado: Data en formato PCM int16 mono 8 kHz, listo para ACRCloud.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import os

final class ScreenCaptureRecorder: Sendable {

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var buffers: [AVAudioPCMBuffer] = []

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            buffers.append(buffer)
        }

        func snapshot() -> [AVAudioPCMBuffer] {
            lock.lock(); defer { lock.unlock() }
            return buffers
        }
    }

    private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
        let onAudio: @Sendable (CMSampleBuffer) -> Void
        init(onAudio: @escaping @Sendable (CMSampleBuffer) -> Void) {
            self.onAudio = onAudio
            super.init()
        }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            guard sampleBuffer.isValid else { return }
            onAudio(sampleBuffer)
        }
    }

    init() {}

    /// Captura `duration` segundos de audio del sistema y devuelve los bytes
    /// listos para ACRCloud. `onProgress` recibe valores 0...1 a intervalos
    /// regulares (~20 ticks).
    ///
    /// - Throws: `RadioPremiumError.screenRecordingPermissionDenied` si el
    ///   usuario no concedió permiso, `.audioFormatUnsupported` si el resampling
    ///   falla, `.acrCloudFailed` si la captura no produjo audio.
    func capture(
        duration: Duration,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        // 1. Pedir contenido (esto dispara el system dialog la primera vez
        //    y lanza si el usuario denegó).
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            AppLogger.identify.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            throw RadioPremiumError.screenRecordingPermissionDenied
        }

        guard let display = content.displays.first else {
            throw RadioPremiumError.audioFormatUnsupported(detail: "no displays disponibles para SCStream")
        }

        // 2. Filtro: incluir display, NO excluir nuestra propia app.
        //
        // IMPORTANTE: el caso de uso de RadioPremium es identificar la radio
        // que ESTAMOS REPRODUCIENDO nosotros mismos vía AVPlayer (PlayerViewModel).
        // Si excluimos current-process-audio, capturamos silencio del resto del
        // sistema y ACRCloud responde "Can't generate fingerprint".
        //
        // Esto contradice la decisión 4A del /plan-eng-review original, que
        // asumía que capturábamos audio de OTRA app. En este producto el audio
        // a identificar viene de nosotros — incluirlo es lo que queremos.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48_000
        config.channelCount = 2

        // 3. Construir stream y conectar output handler.
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let state = State()

        let output = StreamOutput { sampleBuffer in
            if let pcm = AudioConverter.makeBuffer(from: sampleBuffer) {
                state.append(pcm)
            }
        }
        let outputQueue = DispatchQueue(
            label: "com.blancosampedro.RadioPremium.capture",
            qos: .userInitiated
        )
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
        } catch {
            throw RadioPremiumError.audioFormatUnsupported(detail: "addStreamOutput: \(error.localizedDescription)")
        }

        // 4. Arrancar.
        do {
            try await stream.startCapture()
        } catch {
            AppLogger.identify.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
            throw RadioPremiumError.screenRecordingPermissionDenied
        }
        AppLogger.identify.info("capture started, duration=\(duration.components.seconds, privacy: .public)s")

        // 5. Esperar `duration` mientras reportamos progreso.
        let totalSeconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1e18
        let stepCount = 20
        let stepMs = max(1, Int((totalSeconds * 1000) / Double(stepCount)))

        for step in 1...stepCount {
            try await Task.sleep(for: .milliseconds(stepMs))
            if let onProgress {
                let p = Double(step) / Double(stepCount)
                onProgress(p)
            }
        }

        // 6. Parar y recopilar resultado.
        try? await stream.stopCapture()

        let collected = state.snapshot()
        AppLogger.identify.info("capture stopped, buffers=\(collected.count, privacy: .public)")

        guard !collected.isEmpty,
              let combined = AudioConverter.concatenate(collected),
              combined.frameLength > 0
        else {
            throw RadioPremiumError.acrCloudFailed(reason: "no se capturó audio del sistema")
        }

        // 7. Resamplear al formato ACRCloud.
        let converter = AudioConverter()
        let pcm = try converter.convert(combined)

        // Diagnóstico de amplitud: si el peak del PCM es < 100 sobre Int16,
        // el audio es básicamente silencio y ACRCloud no podrá fingerprint.
        // Loguearlo aquí ayuda a distinguir bug de pipeline vs bug de captura.
        let peak = pcm.withUnsafeBytes { rawBytes -> Int16 in
            let samples = rawBytes.bindMemory(to: Int16.self)
            return samples.reduce(Int16(0)) { max($0, abs($1 == .min ? .max : $1)) }
        }
        AppLogger.identify.info(
            "resampled to \(pcm.count, privacy: .public) bytes (int16 mono 8kHz), peak=\(peak, privacy: .public)/32767"
        )
        if peak < 100 {
            AppLogger.identify.warning(
                "captured audio is near-silent (peak=\(peak)). Probable causa: configuración de SCStream excluyendo el proceso que produce el audio."
            )
        }

        return pcm
    }
}
