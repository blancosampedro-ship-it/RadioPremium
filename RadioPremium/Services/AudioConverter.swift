//
//  AudioConverter.swift
//  RadioPremium
//
//  Resampling de audio del sistema (SCStream output) al formato esperado
//  por ACRCloud:
//
//    SOURCE (SCStream):  PCM Float32, 48 kHz, 2 canales (estéreo, planar)
//    TARGET (ACRCloud):  PCM Int16,    8 kHz, 1 canal  (mono, interleaved, signed LE)
//
//  Estrategia: acumular AVAudioPCMBuffer durante la captura, hacer UNA
//  conversión grande al final. ~3.7 MB pico para 10s. AVAudioConverter
//  hace el downsampling y mezcla a mono internamente.
//
//  AudioConverter es Sendable y stateless por instancia: una conversión por
//  llamada `convert(_:)`, no comparte estado entre invocaciones.
//

import Foundation
import AVFoundation
import CoreMedia

final class AudioConverter: Sendable {

    /// Formato esperado por ACRCloud.
    static let targetFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("AudioConverter: no se pudo construir el formato target (8kHz mono int16).")
        }
        return f
    }()

    /// Convierte un AVAudioPCMBuffer source al formato target. Devuelve los bytes
    /// PCM crudos (signed int16 little-endian, mono interleaved 8kHz) listos
    /// para enviar a ACRCloud.
    func convert(_ source: AVAudioPCMBuffer) throws -> Data {
        guard let converter = AVAudioConverter(from: source.format, to: Self.targetFormat) else {
            throw RadioPremiumError.audioFormatUnsupported(detail: "AVAudioConverter init falló para \(source.format)")
        }

        // Capacidad de salida: frames source * (8000/sourceRate) + holgura.
        let ratio = Self.targetFormat.sampleRate / source.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outFrameCapacity) else {
            throw RadioPremiumError.audioFormatUnsupported(detail: "no se pudo asignar buffer de salida")
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return source
        }

        if status == .error, let error {
            throw RadioPremiumError.audioFormatUnsupported(detail: error.localizedDescription)
        }
        guard output.frameLength > 0, let int16Data = output.int16ChannelData else {
            throw RadioPremiumError.audioFormatUnsupported(detail: "salida vacía tras conversión")
        }

        // Buffer de salida es interleaved mono → un solo canal contiguo.
        let frameCount = Int(output.frameLength)
        let bufferPtr = UnsafeBufferPointer(start: int16Data[0], count: frameCount)
        return Data(buffer: bufferPtr)
    }

    // MARK: - Construcción de AVAudioPCMBuffer desde CMSampleBuffer

    /// Extrae el contenido de audio de un CMSampleBuffer en un AVAudioPCMBuffer.
    /// Útil para ir acumulando muestras durante la captura.
    static func makeBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        // Copiar audio de CMBlockBuffer al AVAudioPCMBuffer.
        var blockBuffer: CMBlockBuffer?
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { audioBufferList.unsafeMutablePointer.deallocate() }

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList.unsafeMutablePointer,
            bufferListSize: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * Int(format.channelCount - 1),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        // pcmBuffer.audioBufferList es UnsafePointer<AudioBufferList>; mutateamos
        // la copia mutable obtenida con .mutableAudioBufferList.
        let dstABL = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let srcABL = UnsafeMutableAudioBufferListPointer(audioBufferList.unsafeMutablePointer)

        for i in 0..<min(dstABL.count, srcABL.count) {
            let bytesToCopy = min(Int(dstABL[i].mDataByteSize), Int(srcABL[i].mDataByteSize))
            if let dst = dstABL[i].mData, let src = srcABL[i].mData {
                memcpy(dst, src, bytesToCopy)
            }
            dstABL[i].mDataByteSize = UInt32(bytesToCopy)
        }

        return pcmBuffer
    }

    // MARK: - Acumulación

    /// Concatena múltiples AVAudioPCMBuffer del mismo formato en uno solo.
    /// Útil para juntar todos los samples capturados antes de la conversión final.
    ///
    /// Implementación: usa `srcABL[i].mDataByteSize` directamente (lo que la API
    /// considera "datos válidos" en cada AudioBuffer del list) en lugar de calcular
    /// bytes manualmente desde mBytesPerFrame. Para non-interleaved, mBytesPerFrame
    /// es el valor POR CANAL (no por frame total), y dividirlo por channelCount
    /// produce solo la mitad de los datos correctos — bug que causaba "Can't
    /// generate fingerprint" en ACRCloud porque la otra mitad era memoria sin init.
    static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let totalFrames = buffers.reduce(0) { $0 + $1.frameLength }

        guard totalFrames > 0,
              let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)
        else { return nil }
        combined.frameLength = 0

        let dstABL = UnsafeMutableAudioBufferListPointer(combined.mutableAudioBufferList)

        // Track write offset por buffer slot. Para interleaved hay 1 slot;
        // para non-interleaved hay channelCount slots (uno por canal).
        var writeOffsets = Array(repeating: 0, count: dstABL.count)

        for buf in buffers {
            guard buf.format == format else { continue }
            let srcABL = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)

            for i in 0..<min(dstABL.count, srcABL.count) {
                let srcSize = Int(srcABL[i].mDataByteSize)
                guard srcSize > 0,
                      let dst = dstABL[i].mData,
                      let src = srcABL[i].mData
                else { continue }
                memcpy(dst.advanced(by: writeOffsets[i]), src, srcSize)
                writeOffsets[i] += srcSize
            }
            combined.frameLength += buf.frameLength
        }

        // Sincronizar mDataByteSize con lo realmente escrito.
        for i in 0..<dstABL.count {
            dstABL[i].mDataByteSize = UInt32(writeOffsets[i])
        }

        return combined
    }
}
