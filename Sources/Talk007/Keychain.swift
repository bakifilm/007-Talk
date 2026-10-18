import Foundation

/// Stores the account and its revocable Nextcloud app password in a private file
/// (~/Library/Application Support/work.baki.talk007/account.json, readable only by the user).
///
/// The Keychain is not used: the app is ad-hoc signed, so every update changes its signature and
/// macOS would block at launch asking for Keychain access again.
enum CredentialStore {
    struct Saved: Codable {
        let account: Account
        let appPassword: String
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("work.baki.talk007", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("account.json")
    }

    static func load() -> Saved? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ account: Account, password: String) {
        guard let data = try? JSONEncoder().encode(Saved(account: account, appPassword: password)) else { return }
        let url = fileURL
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
