import Foundation
import Security

/// A single generic-password item in the app's keychain.
struct KeychainItem: Sendable {
    let account: String
    private let service = Bundle.main.bundleIdentifier ?? "PocketPilot"

    init(_ account: String) {
        self.account = account
    }

    func read() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData: true]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ value: String?) {
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        let attributes = query.merging([
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
