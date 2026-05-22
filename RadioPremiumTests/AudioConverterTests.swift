//
//  AudioConverterTests.swift
//  RadioPremiumTests
//
//  Tests sintéticos del pipeline de audio (concatenate + convert) sin necesidad
//  de SCStream real. Cubren específicamente el formato non-interleaved Float32
//  estéreo a 48 kHz que es el output de ScreenCaptureKit.
//

import XCTest
import AVFoundation
@testable import RadioPremium

final class AudioConverterTests: XCTestCase {

    // MARK: - Helpers

    private func makeNonInterleavedFloat32Format(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    /// Construye un AVAudioPCMBuffer non-interleaved Float32 con valores
    /// constantes por canal, para que sea fácil verificar después.
    private func makeBuffer(
        format: AVAudioFormat,
        frameCount: Int,
        valueChannel0: Float,
        valueChannel1: Float
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ch0 = buffer.floatChannelData![0]
        let ch1 = buffer.floatChannelData![1]
        for i in 0..<frameCount {
            ch0[i] = valueChannel0
            ch1[i] = valueChannel1
        }
        return buffer
    }

    // MARK: - concatenate

    func testConcatenate_nonInterleavedFloat32_preservesAllBytes() throws {
        // Reproduce el escenario real de SCStream: Float32 stereo non-interleaved 48k.
        let format = makeNonInterleavedFloat32Format()

        let buf1 = makeBuffer(format: format, frameCount: 100, valueChannel0: 1.0, valueChannel1: 2.0)
        let buf2 = makeBuffer(format: format, frameCount: 100, valueChannel0: 3.0, valueChannel1: 4.0)

        let combined = try XCTUnwrap(AudioConverter.concatenate([buf1, buf2]))

        XCTAssertEqual(combined.frameLength, 200, "Frame count debe sumar")

        let ch0 = combined.floatChannelData![0]
        let ch1 = combined.floatChannelData![1]

        // Primeros 100 frames vienen de buf1 (1.0 / 2.0)
        for i in 0..<100 {
            XCTAssertEqual(ch0[i], 1.0, accuracy: 0.0001, "ch0[\(i)] (buf1)")
            XCTAssertEqual(ch1[i], 2.0, accuracy: 0.0001, "ch1[\(i)] (buf1)")
        }
        // Frames 100..200 vienen de buf2 (3.0 / 4.0)
        for i in 100..<200 {
            XCTAssertEqual(ch0[i], 3.0, accuracy: 0.0001, "ch0[\(i)] (buf2) — si esto falla, hay garbage en lugar de buf2")
            XCTAssertEqual(ch1[i], 4.0, accuracy: 0.0001, "ch1[\(i)] (buf2)")
        }
    }

    func testConcatenate_threeBuffers_preservesAllBytes() throws {
        let format = makeNonInterleavedFloat32Format()

        var bufs: [AVAudioPCMBuffer] = []
        for i in 0..<3 {
            let v0: Float = Float(i + 1)
            let v1: Float = Float((i + 1) * 10)
            bufs.append(makeBuffer(format: format, frameCount: 50, valueChannel0: v0, valueChannel1: v1))
        }

        let combined = try XCTUnwrap(AudioConverter.concatenate(bufs))
        XCTAssertEqual(combined.frameLength, 150)

        let ch0 = combined.floatChannelData![0]
        let ch1 = combined.floatChannelData![1]

        // Cada buffer escribe 50 frames con su valor distintivo.
        for bufIndex in 0..<3 {
            let expected0: Float = Float(bufIndex + 1)
            let expected1: Float = Float((bufIndex + 1) * 10)
            for offsetWithinBuf in 0..<50 {
                let i = bufIndex * 50 + offsetWithinBuf
                XCTAssertEqual(ch0[i], expected0, accuracy: 0.0001, "ch0[\(i)]")
                XCTAssertEqual(ch1[i], expected1, accuracy: 0.0001, "ch1[\(i)]")
            }
        }
    }

    func testConcatenate_emptyArray_returnsNil() {
        XCTAssertNil(AudioConverter.concatenate([]))
    }

    func testConcatenate_singleBuffer_preservesContent() throws {
        let format = makeNonInterleavedFloat32Format()
        let buf = makeBuffer(format: format, frameCount: 100, valueChannel0: 0.5, valueChannel1: -0.5)

        let combined = try XCTUnwrap(AudioConverter.concatenate([buf]))
        XCTAssertEqual(combined.frameLength, 100)

        for i in 0..<100 {
            XCTAssertEqual(combined.floatChannelData![0][i], 0.5, accuracy: 0.0001)
            XCTAssertEqual(combined.floatChannelData![1][i], -0.5, accuracy: 0.0001)
        }
    }

    // MARK: - convert (resampling)

    func testConvert_resamples48kStereoToTargetFormat() throws {
        // Sintetiza 1 segundo de tono (Float32 stereo 48k) y verifica que la
        // conversión produce ~8000 muestras de int16 mono (8kHz × 1s).
        let format = makeNonInterleavedFloat32Format()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000

        // Sine wave 440 Hz para que NO sea silencio.
        let ch0 = buffer.floatChannelData![0]
        let ch1 = buffer.floatChannelData![1]
        let twoPi: Double = 2.0 * .pi
        let frequency: Double = 440.0
        let sampleRate: Double = 48_000.0
        for i in 0..<48_000 {
            let phase: Double = twoPi * frequency * Double(i) / sampleRate
            let sample: Float = Float(sin(phase)) * 0.5
            ch0[i] = sample
            ch1[i] = sample
        }

        let converter = AudioConverter()
        let pcm = try converter.convert(buffer)

        // Esperado: ~8000 muestras × 2 bytes (int16) = ~16000 bytes,
        // con holgura por padding del resampler.
        XCTAssertGreaterThan(pcm.count, 14_000, "Output debe tener ~16k bytes (1s @ 8kHz mono int16)")
        XCTAssertLessThan(pcm.count, 18_000, "Output no debe tener mucho padding extra")

        // Verifica que NO es todo silencio (la mitad de los samples deben tener amplitud > 0).
        let int16Samples = pcm.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Int16.self))
        }
        let nonSilentCount = int16Samples.filter { abs($0) > 100 }.count
        XCTAssertGreaterThan(
            nonSilentCount,
            int16Samples.count / 4,
            "La conversión debe preservar el tono, no producir silencio mayoritario"
        )
    }

    func testConvert_silentInput_producesSilentOutput() throws {
        // Sanity check inverso: input silencioso → output silencioso (no garbage).
        let format = makeNonInterleavedFloat32Format()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        // floatChannelData se inicializa a cero por AVAudioPCMBuffer

        let converter = AudioConverter()
        let pcm = try converter.convert(buffer)

        XCTAssertGreaterThan(pcm.count, 0)

        let int16Samples = pcm.withUnsafeBytes { rawBytes in
            Array(rawBytes.bindMemory(to: Int16.self))
        }
        // Todos cerca de cero — confirma que NO hay basura (memoria sin init)
        // en el output. Esto era el síntoma del bug original.
        let suspicious = int16Samples.filter { abs($0) > 1000 }
        XCTAssertEqual(suspicious.count, 0, "Input silente → output silente (cero garbage)")
    }
}
