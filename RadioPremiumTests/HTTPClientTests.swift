//
//  HTTPClientTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class HTTPClientTests: XCTestCase {
    var client: HTTPClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        client = HTTPClient(session: URLSession.mocked())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    private struct DummyResponse: Decodable, Equatable {
        let id: Int
        let name: String
    }

    private struct DummyBody: Encodable {
        let value: String
    }

    // MARK: - GET happy path

    func testGet_200_returnsDecodedValue() async throws {
        MockURLProtocol.setHandler { request in
            let body = #"{"id":42,"name":"hello"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let result: DummyResponse = try await client.get(URL(string: "https://example.com/test")!)
        XCTAssertEqual(result, DummyResponse(id: 42, name: "hello"))
    }

    func testGet_passesHeaders() async throws {
        MockURLProtocol.setHandler { request in
            let body = #"{"id":1,"name":"x"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let _: DummyResponse = try await client.get(
            URL(string: "https://example.com/test")!,
            headers: ["Authorization": "Bearer test123", "X-Custom": "yes"]
        )

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test123")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Custom"), "yes")
    }

    // MARK: - Status code mapping

    func testGet_401_throwsHttpStatus() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, "Unauthorized".data(using: .utf8))
        }

        do {
            let _: DummyResponse = try await client.get(URL(string: "https://example.com/test")!)
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .httpStatus(let code, let body) = error else {
                return XCTFail("Wrong error case: \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(body, "Unauthorized")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testGet_503_throwsHttpStatus() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }

        do {
            let _: DummyResponse = try await client.get(URL(string: "https://example.com/test")!)
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("Wrong error case: \(error)")
            }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Network errors

    func testGet_notConnected_throwsNetwork() async {
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            let _: DummyResponse = try await client.get(URL(string: "https://example.com/test")!)
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .network(let urlError) = error else {
                return XCTFail("Wrong error case: \(error)")
            }
            XCTAssertEqual(urlError.code, .notConnectedToInternet)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testGet_timeout_throwsNetwork() async {
        MockURLProtocol.setHandler { _ in
            throw URLError(.timedOut)
        }

        do {
            let _: DummyResponse = try await client.get(URL(string: "https://example.com/test")!)
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .network(let urlError) = error else {
                return XCTFail("Wrong error case: \(error)")
            }
            XCTAssertEqual(urlError.code, .timedOut)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Decoding

    func testGet_invalidJSON_throwsDecodingFailed() async {
        MockURLProtocol.setHandler { request in
            let body = "not json".data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        do {
            let _: DummyResponse = try await client.get(URL(string: "https://example.com/test")!)
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .decodingFailed = error else {
                return XCTFail("Wrong error case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - POST JSON

    func testPost_sendsJSONContentType() async throws {
        MockURLProtocol.setHandler { request in
            let body = #"{"id":1,"name":"posted"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let body = DummyBody(value: "test")
        let _: DummyResponse = try await client.post(
            URL(string: "https://example.com/test")!,
            body: body
        )

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - POST form

    func testPostForm_sendsFormContentType() async throws {
        MockURLProtocol.setHandler { request in
            let body = #"{"id":1,"name":"x"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let _: DummyResponse = try await client.postForm(
            URL(string: "https://example.com/token")!,
            fields: ["grant_type": "authorization_code", "code": "abc123"]
        )

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
    }

    // MARK: - POST multipart

    func testPostMultipart_setsBoundaryContentType() async throws {
        MockURLProtocol.setHandler { request in
            let body = #"{"id":1,"name":"x"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let _: DummyResponse = try await client.postMultipart(
            URL(string: "https://example.com/identify")!,
            fields: ["access_key": "test"],
            fileFieldName: "sample",
            fileName: "audio.pcm",
            fileMimeType: "audio/pcm",
            fileData: Data([0x00, 0x01, 0x02])
        )

        let contentType = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
    }
}
