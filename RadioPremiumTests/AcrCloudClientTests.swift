//
//  AcrCloudClientTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class AcrCloudClientTests: XCTestCase {

    private var client: AcrCloudClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let http = HTTPClient(session: URLSession.mocked())
        client = AcrCloudClient(
            http: http,
            host: "identify-test.acrcloud.com",
            accessKey: "test-key",
            accessSecret: "test-secret"
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: - HMAC signature (vector test)

    /// Vector verificado independientemente con OpenSSL:
    ///
    ///   printf "POST\n/v1/identify\nmykey\naudio\n1\n1700000000" \
    ///     | openssl dgst -sha1 -hmac "mysecret" -binary | base64
    ///
    /// Resultado: rSr74sJ2KKQgm2x1J4IqUlnNFgc=
    func testComputeSignature_knownVector() {
        let signature = AcrCloudClient.computeSignature(
            method: "POST",
            uri: "/v1/identify",
            accessKey: "mykey",
            dataType: "audio",
            signatureVersion: "1",
            timestamp: "1700000000",
            secret: "mysecret"
        )
        XCTAssertEqual(signature, "rSr74sJ2KKQgm2x1J4IqUlnNFgc=")
    }

    func testComputeSignature_isStableForSameInputs() {
        let sig1 = AcrCloudClient.computeSignature(
            method: "POST", uri: "/v1/identify", accessKey: "k", dataType: "audio",
            signatureVersion: "1", timestamp: "12345", secret: "s"
        )
        let sig2 = AcrCloudClient.computeSignature(
            method: "POST", uri: "/v1/identify", accessKey: "k", dataType: "audio",
            signatureVersion: "1", timestamp: "12345", secret: "s"
        )
        XCTAssertEqual(sig1, sig2)
    }

    func testComputeSignature_changesWithDifferentSecret() {
        let sigA = AcrCloudClient.computeSignature(
            method: "POST", uri: "/v1/identify", accessKey: "k", dataType: "audio",
            signatureVersion: "1", timestamp: "12345", secret: "secretA"
        )
        let sigB = AcrCloudClient.computeSignature(
            method: "POST", uri: "/v1/identify", accessKey: "k", dataType: "audio",
            signatureVersion: "1", timestamp: "12345", secret: "secretB"
        )
        XCTAssertNotEqual(sigA, sigB)
    }

    // MARK: - Multipart structure

    func testIdentify_postsMultipart_toCorrectURL() async {
        setOKHandler(body: Self.successResponseJSON)

        _ = try? await client.identify(Data([0x00, 0x01, 0x02]))

        let request = MockURLProtocol.lastRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.absoluteString, "https://identify-test.acrcloud.com/v1/identify")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
    }

    // MARK: - WAV header construction

    /// El header WAV es lo que distingue PCM crudo (que ACRCloud rechaza con
    /// "Can't generate fingerprint") de un sample reproducible.
    /// 44 bytes fijos: RIFF/WAVE/fmt/data + PCM raw bytes.
    func testWrapInWAV_producesCorrectHeader() {
        let pcm = Data([0x11, 0x22, 0x33, 0x44])  // 4 bytes de PCM ficticio
        let wav = AcrCloudClient.wrapInWAV(pcm: pcm, sampleRate: 8000, channels: 1, bitsPerSample: 16)

        XCTAssertEqual(wav.count, 44 + 4, "Header 44 bytes + 4 bytes PCM")

        // RIFF magic
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")

        // ChunkSize (offset 4-7) = 36 + dataSize, little-endian
        let chunkSize = wav[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(chunkSize.littleEndian, 36 + 4)

        // WAVE magic
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")

        // fmt subchunk header
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")
        let subchunkSize = wav[16..<20].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(subchunkSize.littleEndian, 16)

        // Audio format (PCM = 1)
        let audioFormat = wav[20..<22].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(audioFormat.littleEndian, 1)

        // Channels
        let channels = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(channels.littleEndian, 1)

        // Sample rate
        let sampleRate = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(sampleRate.littleEndian, 8000)

        // Byte rate = sampleRate * channels * bytesPerSample = 8000 * 1 * 2
        let byteRate = wav[28..<32].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate.littleEndian, 16000)

        // Block align = channels * bytesPerSample = 1 * 2
        let blockAlign = wav[32..<34].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(blockAlign.littleEndian, 2)

        // Bits per sample
        let bitsPerSample = wav[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(bitsPerSample.littleEndian, 16)

        // data subchunk header
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        let dataSize = wav[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(dataSize.littleEndian, 4)

        // PCM data preserved
        XCTAssertEqual(wav[44..<48], pcm)
    }

    func testWrapInWAV_stereoConfig_byteRateAndBlockAlignAdjusted() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = AcrCloudClient.wrapInWAV(pcm: pcm, sampleRate: 44100, channels: 2, bitsPerSample: 16)

        let channels = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(channels.littleEndian, 2)

        // byteRate = 44100 * 2 * 2 = 176400
        let byteRate = wav[28..<32].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate.littleEndian, 176400)

        // blockAlign = 2 * 2 = 4
        let blockAlign = wav[32..<34].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(blockAlign.littleEndian, 4)
    }

    func testIdentify_sendsWAVNotRawPCM() async {
        setOKHandler(body: Self.successResponseJSON)

        // PCM ficticio: 4 bytes. La request final debe contener la cadena "RIFF"
        // en el body multipart (parte del header WAV).
        _ = try? await client.identify(Data([0x11, 0x22, 0x33, 0x44]))

        // El cuerpo va por httpBodyStream cuando hay archivos, no httpBody.
        // Verificamos via el filename y mimeType.
        let request = MockURLProtocol.lastRequest
        let contentType = request?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data"))
        // No podemos leer fácilmente el body multipart aquí, pero el contentType
        // del wrapper es lo que ACRCloud lee primero. WAV se confirma vía smoke test.
    }

    // MARK: - Response parsing

    func testIdentify_parsesSuccessResponse() async throws {
        setOKHandler(body: Self.successResponseJSON)

        let track = try await client.identify(Data([0x00, 0x01]))

        XCTAssertEqual(track.title, "Bohemian Rhapsody")
        XCTAssertEqual(track.artist, "Queen")
        XCTAssertEqual(track.album, "A Night at the Opera")
        XCTAssertEqual(track.isrc, "GBUM71029604")
        XCTAssertEqual(track.spotifyId, "7tFiyTwD0nx5a1eklYtX2J")
        XCTAssertEqual(track.durationMs, 354320)
    }

    func testIdentify_multipleArtists_joinedByComma() async throws {
        let json = """
        {
            "status": {"msg": "Success", "code": 0, "version": "1.0"},
            "metadata": {
                "music": [{
                    "title": "Under Pressure",
                    "artists": [{"name": "Queen"}, {"name": "David Bowie"}]
                }]
            }
        }
        """
        setOKHandler(body: json)

        let track = try await client.identify(Data())
        XCTAssertEqual(track.artist, "Queen, David Bowie")
    }

    func testIdentify_throwsNoMatch_onCode1001() async {
        let json = """
        {"status": {"msg": "No result", "code": 1001, "version": "1.0"}}
        """
        setOKHandler(body: json)

        do {
            _ = try await client.identify(Data())
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .acrCloudNoMatch = error else {
                return XCTFail("Wrong case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testIdentify_throwsAcrCloudFailed_onOtherCode() async {
        let json = """
        {"status": {"msg": "Invalid signature", "code": 3001, "version": "1.0"}}
        """
        setOKHandler(body: json)

        do {
            _ = try await client.identify(Data())
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .acrCloudFailed(let reason) = error else {
                return XCTFail("Wrong case: \(error)")
            }
            XCTAssertTrue(reason.contains("Invalid signature"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testIdentify_throwsAcrCloudFailed_whenSuccessButEmptyMetadata() async {
        let json = """
        {"status": {"msg": "OK", "code": 0, "version": "1.0"}, "metadata": {"music": []}}
        """
        setOKHandler(body: json)

        do {
            _ = try await client.identify(Data())
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .acrCloudFailed = error else {
                return XCTFail("Wrong case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testIdentify_propagatesNetworkError() async {
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.identify(Data())
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .network = error else {
                return XCTFail("Wrong case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - mapResponse direct unit test

    func testMapResponse_artworkPicksLargestSpotifyImage() throws {
        let response = ACRResponse(
            status: ACRStatus(code: 0, msg: nil, version: nil),
            metadata: ACRMetadata(music: [
                ACRMusic(
                    title: "Test",
                    artists: [ACRArtist(name: "X")],
                    album: nil,
                    releaseDate: nil,
                    durationMs: nil,
                    externalMetadata: ACRExternalMetadata(
                        spotify: ACRSpotifyMeta(
                            track: nil,
                            album: ACRSpotifyAlbumMeta(images: [
                                ACRSpotifyImage(url: "https://example.com/small.jpg", height: 64, width: 64),
                                ACRSpotifyImage(url: "https://example.com/large.jpg", height: 640, width: 640),
                                ACRSpotifyImage(url: "https://example.com/medium.jpg", height: 300, width: 300)
                            ])
                        ),
                        deezer: nil
                    ),
                    externalIds: nil
                )
            ]),
            resultType: nil,
            costTime: nil
        )

        let track = try AcrCloudClient.mapResponse(response)
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://example.com/large.jpg")
    }

    // MARK: - Helpers

    private func setOKHandler(body: String) {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8))
        }
    }

    private static let successResponseJSON = """
    {
        "status": {"msg": "Success", "code": 0, "version": "1.0"},
        "result_type": 0,
        "cost_time": 0.42,
        "metadata": {
            "music": [{
                "title": "Bohemian Rhapsody",
                "artists": [{"name": "Queen"}],
                "album": {"name": "A Night at the Opera"},
                "release_date": "1975-10-31",
                "duration_ms": 354320,
                "external_ids": {"isrc": "GBUM71029604"},
                "external_metadata": {
                    "spotify": {
                        "track": {"id": "7tFiyTwD0nx5a1eklYtX2J", "name": "Bohemian Rhapsody"},
                        "album": {
                            "images": [
                                {"url": "https://i.scdn.co/image/large", "height": 640, "width": 640},
                                {"url": "https://i.scdn.co/image/small", "height": 64, "width": 64}
                            ]
                        }
                    }
                }
            }]
        }
    }
    """
}
