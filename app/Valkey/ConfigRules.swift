import Foundation

/// Server-setting rules shared by Server Settings and `valkey-app set`/`create`, so both accept the
/// same values. Foundation-only so Tests/CLITests.swift can compile it standalone.
enum ConfigRules {
    /// An edit must still refer to the snapshot it started from after asynchronous work.
    static func editProblem<T: Equatable>(original: T, current: T?) -> String? {
        guard let current else { return "This server was deleted while saving. Reload the server list and retry." }
        guard current == original else { return "This server changed while saving. Reload its settings and retry." }
        return nil
    }

    static let evictionPolicies = ["noeviction", "allkeys-lru", "allkeys-lfu", "allkeys-random",
                                   "volatile-lru", "volatile-lfu", "volatile-random", "volatile-ttl"]

    static func maxMemoryProblem(_ value: String?) -> String? {
        guard let value, value.range(of: #"^\d+([kmg]b?|b)?$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return "Max Memory must be a size like 256mb or 2gb."
    }

    static func usersProblem(_ users: [(name: String, password: String)]) -> String? {
        var seen: Set<String> = ["default"]
        for user in users {
            if user.name.isEmpty || user.name.contains(where: { $0.isWhitespace || $0.isNewline }) {
                return "User names can't be empty or contain spaces."
            }
            if !seen.insert(user.name).inserted { return "User “\(user.name)” is listed twice (or is “default”)." }
            if user.password.isEmpty { return "Give user “\(user.name)” a password." }
        }
        return nil
    }

    /// on/off, yes/no, true/false, 1/0.
    static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: return nil
        }
    }
}
