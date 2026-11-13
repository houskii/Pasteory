import Foundation
import Security

enum AICredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "app.pasteory.Pasteory") + ".ai-provider" }
    private static let account = "default-provider"
    static func load() throws -> String {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
    static func save(_ value: String) throws {
        if value.isEmpty { let status = SecItemDelete(identity as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }; return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = identity
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
