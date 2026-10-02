import Foundation
import Security

/// Passwords live in the login Keychain, not in the saved server list.
enum Keychain {
    private static let service = "app.valkey.Valkey"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil or empty deletes the item.
    static func set(_ account: String, _ value: String?) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Valkey: couldn't save a password to the Keychain (\(status))") }
    }
}

/// A valkey.conf argument that survives spaces, quotes and any other byte (non-alphanumerics become \xHH).
func confQuote(_ s: String) -> String {
    let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-".utf8)
    return "\"" + s.utf8.map { plain.contains($0) ? String(UnicodeScalar($0)) : String(format: "\\x%02x", $0) }.joined() + "\""
}

extension ValkeyServer.Config {
    private var secretAccount: String { id.uuidString }
    func userAccount(_ user: User) -> String { "\(id.uuidString)/\(user.id.uuidString)" }

    mutating func loadSecrets() {
        password = Keychain.get(secretAccount)
        for i in accounts.indices { accounts[i].password = Keychain.get(userAccount(accounts[i])) ?? "" }
    }

    func saveSecrets() {
        Keychain.set(secretAccount, password)
        for user in accounts { Keychain.set(userAccount(user), user.password) }
    }

    func deleteSecrets() {
        Keychain.set(secretAccount, nil)
        for user in accounts { Keychain.set(userAccount(user), nil) }
    }
}
