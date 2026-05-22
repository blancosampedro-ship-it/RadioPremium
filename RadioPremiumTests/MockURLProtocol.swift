//
//  MockURLProtocol.swift
//  RadioPremiumTests
//
//  URLProtocol custom para mockear URLSession sin red real.
//  Patrón estándar de testing en Swift.
//
//  Uso:
//      let session = URLSession.mocked()
//      MockURLProtocol.setHandler { request in
//          let response = HTTPURLResponse(url: request.url!, statusCode: 200, ...)!
//          return (response, jsonData)
//      }
//

import Foundation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) private static var _lastRequest: URLRequest?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data?)) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
        _lastRequest = nil
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _handler = nil
        _lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let h = Self._handler
        Self._lastRequest = request
        Self.lock.unlock()

        guard let handler = h else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

extension URLSession {
    /// Devuelve una URLSession ephemeral con MockURLProtocol como único protocolo.
    /// Usar en tests para evitar tocar la red real.
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
