//
//  KeychainStore.swift
//  RadioPremium
//
//  Wrapper sobre Keychain Services para almacenar tokens y secrets dinámicos
//  (los de Spotify cuando llegue el flujo OAuth en Sprint 3).
//  Items tipo Generic Password agrupados por `service`.
//
//  La operación set() hace update-or-add: primero intenta SecItemUpdate,
//  si no existe el item lo añade con SecItemAdd. Más simple que combinar
//  delete + add (evita un agujero atómico entre las dos llamadas).
//
//  Errores: KeychainError.unexpected con el OSStatus crudo.
//  El servicio aislado para tests es "com.blancosampedro.RadioPremium.tests".
//

import Foundation
import Security

struct KeychainStore: Sendable {
    let service: String

    init(service: String = "com.blancosampedro.RadioPremium") {
        self.service = service
    }

    /// Guarda o actualiza el valor para la clave dada.
    func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidValue(key: key)
        }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.unexpected(status: addStatus)
            }
            return
        }

        throw KeychainError.unexpected(status: updateStatus)
    }

    /// Recupera el valor para la clave. Devuelve nil si no existe.
    func get(_ key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }

        guard status == errSecSuccess else {
            throw KeychainError.unexpected(status: status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Borra el valor para la clave. Idempotente — no lanza si no existe.
    func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpected(status: status)
        }
    }

    /// Borra TODOS los items asociados a este `service`. Idempotente.
    ///
    /// Quirk de macOS: SecItemDelete sobre Generic Password puede borrar solo
    /// UN item por llamada cuando hay varios que matchean. Loop hasta
    /// errSecItemNotFound para garantizar limpieza total.
    func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        // Cota dura para evitar bucle infinito si la API se comporta raro.
        for _ in 0..<10_000 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            if status != errSecSuccess {
                throw KeychainError.unexpected(status: status)
            }
        }
        // Si llegamos aquí algo va muy mal — la query sigue matcheando tras 10000 borrados.
        throw KeychainError.unexpected(status: errSecInternalError)
    }
}

enum KeychainError: Error, LocalizedError, Sendable {
    case invalidValue(key: String)
    case unexpected(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let key):
            return "Keychain: valor no codificable como UTF-8 para clave '\(key)'."
        case .unexpected(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
            return "Keychain error \(status): \(msg)"
        }
    }
}
