//
//  AcrCloudClient.swift
//  RadioPremium
//
//  Cliente de ACRCloud `/v1/identify`. Compone HTTPClient.
//
//  Protocolo de firma (HMAC-SHA1) según docs:
//  https://docs.acrcloud.com/reference/identification-api
//
//    string_to_sign = "POST\n/v1/identify\n{accessKey}\n{dataType}\n{signatureVersion}\n{timestamp}"
//    signature      = base64( HMAC_SHA1( secret, string_to_sign ) )
//
//  Multipart fields requeridos:
//    sample            = audio bytes (PCM int16 mono 8kHz, archivo "sample.pcm")
//    sample_bytes      = longitud en bytes del sample
//    access_key        = ACRCloud access key
//    data_type         = "audio"
//    signature_version = "1"
//    signature         = base64 HMAC-SHA1
//    timestamp         = epoch seconds (string)
//

import Foundation
import CryptoKit
import os

actor AcrCloudClient {
    private let http: HTTPClient
    private let host: String
    private let accessKey: String
    private let accessSecret: String

    /// Init explícito para tests.
    init(http: HTTPClient, host: String, accessKey: String, accessSecret: String) {
        self.http = http
        self.host = host
        self.accessKey = accessKey
        self.accessSecret = accessSecret
    }

    /// Init de conveniencia: lee las claves de Secrets.plist.
    init(http: HTTPClient = HTTPClient()) {
        self.http = http
        self.host = Secrets.acrCloudHost
        self.accessKey = Secrets.acrCloudAccessKey
        self.accessSecret = Secrets.acrCloudAccessSecret
    }

    /// Identifica el sample dado. Devuelve un Track si hay match.
    /// Lanza `.acrCloudNoMatch` si ACRCloud no encontró nada (status.code == 1001),
    /// `.acrCloudFailed(reason:)` para cualquier otro error de ACR.
    ///
    /// El sample se envía como **WAV** (header RIFF/WAVE + PCM). ACRCloud necesita
    /// el header para interpretar correctamente los bytes — PCM crudo se rechaza
    /// con "Can't generate fingerprint" porque ACRCloud no infiere sample rate
    /// ni channel layout sin el header.
    func identify(_ pcmSample: Data, timestamp: Date = Date()) async throws -> Track {
        let url = URL(string: "https://\(host)/v1/identify")!
        let timestampString = String(Int(timestamp.timeIntervalSince1970))
        let dataType = "audio"
        let signatureVersion = "1"

        let signature = AcrCloudClient.computeSignature(
            method: "POST",
            uri: "/v1/identify",
            accessKey: accessKey,
            dataType: dataType,
            signatureVersion: signatureVersion,
            timestamp: timestampString,
            secret: accessSecret
        )

        // PCM int16 mono 8kHz envuelto en header WAV. Estos parámetros tienen
        // que coincidir con AudioConverter.targetFormat (que es lo que sale
        // de ScreenCaptureRecorder.capture).
        let wavData = Self.wrapInWAV(
            pcm: pcmSample,
            sampleRate: 8_000,
            channels: 1,
            bitsPerSample: 16
        )

        let fields: [String: String] = [
            "access_key": accessKey,
            "data_type": dataType,
            "signature_version": signatureVersion,
            "signature": signature,
            "sample_bytes": String(wavData.count),
            "sample_rate": "8000",
            "timestamp": timestampString
        ]

        AppLogger.identify.info(
            "identify POST to \(url.absoluteString, privacy: .public) wav=\(wavData.count, privacy: .public) bytes (pcm=\(pcmSample.count, privacy: .public))"
        )

        let response: ACRResponse = try await http.postMultipart(
            url,
            fields: fields,
            fileFieldName: "sample",
            fileName: "sample.wav",
            fileMimeType: "audio/wav",
            fileData: wavData
        )

        return try Self.mapResponse(response)
    }

    // MARK: - WAV header construction

    /// Construye un blob WAV (header RIFF/WAVE PCM + datos) a partir de PCM crudo.
    /// Header de 44 bytes, signed little-endian, layout estándar.
    /// Internal para que los tests puedan validar la estructura del header.
    static func wrapInWAV(
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize  // tamaño total - 8

        var data = Data(capacity: 44 + dataSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndianUInt32: UInt32(chunkSize))
        data.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndianUInt32: 16)              // subchunk size
        data.append(littleEndianUInt16: 1)               // audio format = PCM
        data.append(littleEndianUInt16: UInt16(channels))
        data.append(littleEndianUInt32: UInt32(sampleRate))
        data.append(littleEndianUInt32: UInt32(byteRate))
        data.append(littleEndianUInt16: UInt16(blockAlign))
        data.append(littleEndianUInt16: UInt16(bitsPerSample))

        // data subchunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndianUInt32: UInt32(dataSize))
        data.append(pcm)

        return data
    }

    // MARK: - HMAC-SHA1 signature

    /// Construye la firma HMAC-SHA1 de ACRCloud. Pública (en realidad
    /// `internal`) para que los tests puedan validarla con vector conocido.
    static func computeSignature(
        method: String,
        uri: String,
        accessKey: String,
        dataType: String,
        signatureVersion: String,
        timestamp: String,
        secret: String
    ) -> String {
        let stringToSign = [method, uri, accessKey, dataType, signatureVersion, timestamp]
            .joined(separator: "\n")

        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: key
        )
        return Data(mac).base64EncodedString()
    }

    // MARK: - Response mapping

    static func mapResponse(_ response: ACRResponse) throws -> Track {
        switch response.status.code {
        case 0:
            guard let music = response.metadata?.music?.first else {
                throw RadioPremiumError.acrCloudFailed(reason: "respuesta OK pero metadata.music vacío")
            }
            return makeTrack(from: music)

        case 1001:
            throw RadioPremiumError.acrCloudNoMatch

        default:
            let msg = response.status.msg ?? "código \(response.status.code)"
            throw RadioPremiumError.acrCloudFailed(reason: msg)
        }
    }

    // MARK: - Track building

    private static func makeTrack(from music: ACRMusic) -> Track {
        let artist = (music.artists?.map { $0.name }.joined(separator: ", ")) ?? "Desconocido"
        let album = music.album?.name
        let isrc = music.externalIds?.isrc
        let spotifyId = music.externalMetadata?.spotify?.track?.id
        let artworkURLString = music.externalMetadata?.spotify?.album?.images?
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first?
            .url
        let artworkURL = artworkURLString.flatMap { URL(string: $0) }

        return Track(
            title: music.title,
            artist: artist,
            album: album,
            isrc: isrc,
            artworkURL: artworkURL,
            durationMs: music.durationMs,
            spotifyId: spotifyId
        )
    }
}

// MARK: - Data little-endian helpers

private extension Data {
    mutating func append(littleEndianUInt32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    mutating func append(littleEndianUInt16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
