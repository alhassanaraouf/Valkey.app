import Foundation
import Security

/// Passwords live in the login Keychain, not in the saved server list.
enum Keychain {
    private static let service = "app.valkey.Valkey"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// What this process last read or wrote per account ("" = no item). Every save passes every password,
    /// so without this each one was deleted and re-added; with an unsigned (ad-hoc) build, macOS asks for
    /// the Keychain password on each of those after an update.
    private static var known: [String: String] = [:]
    private static var readFailed = false, writeFailed = false
    private static let lock = NSLock()

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        let value = status == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        lock.withLock {
            known[account] = value ?? ""
            if status != errSecSuccess && status != errSecItemNotFound { readFailed = true }   // e.g. access denied
        }
        return value
    }

    /// Keychain items remember the code identity that created them. Items made by an ad-hoc build (each
    /// identified by its own hash) ask for the Keychain password after every update, so once a build with a
    /// stable signature (see scripts/sign-app.sh) has read every password, `resave` re-creates them under
    /// its identity. Skipped if any read failed, so a password that couldn't be read is never lost.
    static func adoptItems(resave: () -> Void) {
        let ownerKey = "keychainOwner"
        guard let identity = stableIdentity, !lock.withLock({ readFailed }),
              UserDefaults.standard.string(forKey: ownerKey) != identity else { return }
        lock.withLock { known.removeAll(); writeFailed = false }   // so every password is written again
        resave()
        if !lock.withLock({ writeFailed }) { UserDefaults.standard.set(identity, forKey: ownerKey) }
    }

    /// This build's designated requirement if it's signed with a certificate; nil for ad-hoc builds.
    private static var stableIdentity: String? {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text = text as String?,
              !text.hasPrefix("cdhash") else { return nil }
        return text
    }

    /// nil or empty deletes the item. Unchanged values don't touch the Keychain.
    static func set(_ account: String, _ value: String?) {
        let new = value ?? ""
        guard lock.withLock({ known[account] }) != new else { return }
        lock.withLock { known[account] = new }
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            lock.withLock { writeFailed = true }
            NSLog("Valkey: couldn't save a password to the Keychain (\(status))")
        }
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
