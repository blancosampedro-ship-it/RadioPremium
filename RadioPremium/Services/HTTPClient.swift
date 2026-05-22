//
//  HTTPClient.swift
//  RadioPremium
//
//  Actor base para llamadas HTTP. Los clientes específicos
//  (RadioBrowserClient, AcrCloudClient, SpotifyApiClient) lo componen
//  y añaden lo suyo: auth, signing, base URL, parseo específico.
//
//  Mapea status codes a RadioPremiumError para que UI haga switch
//  en lugar de parsear strings.
//
//  Decisión 2A de /plan-eng-review.
//

import Foundation
import os

actor HTTPClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: - GET

    func get<T: Decodable>(
        _ url: URL,
        headers: [String: String] = [:]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(headers, to: &request)
        return try await execute(request)
    }

    // MARK: - POST JSON

    func post<T: Decodable, B: Encodable>(
        _ url: URL,
        body: B,
        headers: [String: String] = [:]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(headers, to: &request)
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    // MARK: - POST form-urlencoded

    func postForm<T: Decodable>(
        _ url: URL,
        fields: [String: String],
        headers: [String: String] = [:]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyHeaders(headers, to: &request)
        request.httpBody = encodeFormBody(fields)
        return try await execute(request)
    }

    // MARK: - POST multipart

    /// Multipart POST. Usado por ACRCloud para enviar el audio capturado.
    /// Pasa `nil` en los argumentos de archivo para enviar solo campos de formulario.
    func postMultipart<T: Decodable>(
        _ url: URL,
        fields: [String: String],
        fileFieldName: String? = nil,
        fileName: String? = nil,
        fileMimeType: String? = nil,
        fileData: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        applyHeaders(headers, to: &request)
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            fields: fields,
            fileFieldName: fileFieldName,
            fileName: fileName,
            fileMimeType: fileMimeType,
            fileData: fileData
        )
        return try await execute(request)
    }

    // MARK: - Internals

    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        AppLogger.http.debug(
            "→ \(request.httpMethod ?? "?", privacy: .public) \(request.url?.absoluteString ?? "?", privacy: .public)"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            AppLogger.http.error(
                "Network error: \(urlError.code.rawValue, privacy: .public) \(urlError.localizedDescription, privacy: .public)"
            )
            throw RadioPremiumError.network(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RadioPremiumError.network(URLError(.badServerResponse))
        }

        AppLogger.http.debug(
            "← \(http.statusCode) \(request.url?.absoluteString ?? "?", privacy: .public)"
        )

        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            // Log el body de error: 403/401/etc traen detalle útil de Spotify
            // ("Insufficient client scope", "Service not found", etc.)
            AppLogger.http.error(
                "HTTP \(http.statusCode, privacy: .public) for \(request.url?.absoluteString ?? "?", privacy: .public) — body: \(body ?? "<nil>", privacy: .public)"
            )
            throw RadioPremiumError.httpStatus(code: http.statusCode, body: body)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RadioPremiumError.decodingFailed(underlying: String(describing: error))
        }
    }

    private func encodeFormBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        // Spotify y otros endpoints x-www-form-urlencoded son estrictos:
        // espacios deben ser %20 o +, '+' literal debe escaparse, etc.
        allowed.remove(charactersIn: "+&=")
        let pairs = fields.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private func makeMultipartBody(
        boundary: String,
        fields: [String: String],
        fileFieldName: String?,
        fileName: String?,
        fileMimeType: String?,
        fileData: Data?
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        for (key, value) in fields {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        if let fieldName = fileFieldName, let data = fileData {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            let filenamePart = fileName.map { "; filename=\"\($0)\"" } ?? ""
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"\(filenamePart)\(crlf)".data(using: .utf8)!)
            if let mime = fileMimeType {
                body.append("Content-Type: \(mime)\(crlf)".data(using: .utf8)!)
            }
            body.append(crlf.data(using: .utf8)!)
            body.append(data)
            body.append(crlf.data(using: .utf8)!)
        }

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}
