import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Session expired. Please sign in again."
        case .http(let code): return "Server error (\(code))."
        case .invalidResponse: return "Unexpected server response."
        }
    }
}

let userAgent = "007 Talk (macOS)"

/// Minimal Nextcloud Talk (spreed) client: conversations, chat, send, read marker.
final class TalkAPI {
    let account: Account
    private let password: String
    let session: URLSession

    init(account: Account, password: String) {
        self.account = account
        self.password = password
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 70
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: Core

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        guard var comps = URLComponents(url: account.server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidResponse }

        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let cred = Data("\(account.loginName):\(password)".utf8).base64EncodedString()
        r.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if !(200..<300).contains(http.statusCode) && http.statusCode != 304 { throw APIError.http(http.statusCode) }
        return (data, http)
    }

    // MARK: Endpoints

    func currentUser() async throws -> (id: String, displayName: String) {
        struct User: Decodable { let id: String; let displayname: String? }
        let (data, _) = try await request("ocs/v2.php/cloud/user")
        let u = try JSONDecoder().decode(OCSResponse<User>.self, from: data).ocs.data
        return (u.id, u.displayname ?? u.id)
    }

    func rooms() async throws -> [Room] {
        let (data, _) = try await request("ocs/v2.php/apps/spreed/api/v4/room")
        return try JSONDecoder().decode(OCSResponse<[Room]>.self, from: data).ocs.data
    }

    /// `future == false`: history older than `lastKnown` (or newest if nil).
    /// `future == true`: long-polls up to `timeout` seconds for messages newer than `lastKnown`.
    func messages(token: String, future: Bool, lastKnown: Int?, limit: Int = 100,
                  timeout: Int = 30, setReadMarker: Bool) async throws -> [ChatMessage] {
        var q = [
            URLQueryItem(name: "lookIntoFuture", value: future ? "1" : "0"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "setReadMarker", value: setReadMarker ? "1" : "0"),
        ]
        if future { q.append(URLQueryItem(name: "timeout", value: String(timeout))) }
        if let lastKnown { q.append(URLQueryItem(name: "lastKnownMessageId", value: String(lastKnown))) }

        let (data, http) = try await request("ocs/v2.php/apps/spreed/api/v1/chat/\(token)", query: q,
                                             timeout: future ? TimeInterval(timeout + 20) : 30)
        if http.statusCode == 304 || data.isEmpty { return [] }
        return try JSONDecoder().decode(OCSResponse<[ChatMessage]>.self, from: data).ocs.data
    }

    func send(token: String, text: String, replyTo: Int?) async throws -> ChatMessage? {
        var body: [String: Any] = ["message": text]
        if let replyTo { body["replyTo"] = replyTo }
        let (data, _) = try await request("ocs/v2.php/apps/spreed/api/v1/chat/\(token)", method: "POST", body: body)
        return try? JSONDecoder().decode(OCSResponse<ChatMessage>.self, from: data).ocs.data
    }

    func markRead(token: String) async throws {
        _ = try await request("ocs/v2.php/apps/spreed/api/v1/chat/\(token)/read", method: "POST")
    }

    /// Deletes the app password on the server (shows up under Settings → Security → Devices).
    func revoke() async throws {
        _ = try await request("ocs/v2.php/core/apppassword", method: "DELETE")
    }

    // MARK: Files, previews, avatars

    var authorizationHeader: String {
        "Basic " + Data("\(account.loginName):\(password)".utf8).base64EncodedString()
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(url: account.server.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    func previewURL(fileId: String, size: Int) -> URL? {
        url("index.php/core/preview", query: [
            URLQueryItem(name: "fileId", value: fileId),
            URLQueryItem(name: "x", value: String(size)),
            URLQueryItem(name: "y", value: String(size)),
            URLQueryItem(name: "a", value: "1"),
        ])
    }

    func userAvatarURL(_ userId: String, size: Int = 128) -> URL? {
        guard let id = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: account.server.absoluteString + "/index.php/avatar/\(id)/\(size)")
    }

    func roomAvatarURL(_ room: Room) -> URL? {
        url("ocs/v2.php/apps/spreed/api/v1/room/\(room.token)/avatar",
            query: [URLQueryItem(name: "v", value: room.avatarVersion ?? "0")])
    }

    /// WebDAV address of a file in the user's storage (path as given by Talk, e.g. "Talk/photo.jpg").
    func davURL(path: String) -> URL? {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
        }.joined(separator: "/")
        guard let user = account.userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: account.server.absoluteString + "/remote.php/dav/files/\(user)/\(encoded)")
    }

    /// Authorized GET of any server URL (previews, avatars, file downloads).
    func fetch(_ url: URL, timeout: TimeInterval = 60) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        r.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return data
    }

    func download(_ url: URL, to destination: URL) async throws {
        var r = URLRequest(url: url, timeoutInterval: 600)
        r.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await session.download(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    // MARK: Shared items, users, conversations

    /// objectType: "media" (images/videos), "file", "audio", "voice", ...
    func sharedItems(token: String, objectType: String, before: Int?, limit: Int = 100) async throws -> [ChatMessage] {
        var q = [
            URLQueryItem(name: "objectType", value: objectType),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before { q.append(URLQueryItem(name: "lastKnownMessageId", value: String(before))) }
        let (data, _) = try await request("ocs/v2.php/apps/spreed/api/v1/chat/\(token)/share", query: q)
        // A dictionary keyed by message id, or [] when empty.
        if let dict = try? JSONDecoder().decode(OCSResponse<[String: ChatMessage]>.self, from: data) {
            return dict.ocs.data.values.sorted { $0.id > $1.id }
        }
        return []
    }

    func searchUsers(_ term: String) async throws -> [UserSuggestion] {
        let (data, _) = try await request("ocs/v2.php/core/autocomplete/get", query: [
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "itemType", value: "call"),
            URLQueryItem(name: "itemId", value: "new"),
            URLQueryItem(name: "shareTypes[]", value: "0"),
            URLQueryItem(name: "limit", value: "50"),
        ])
        return try JSONDecoder().decode(OCSResponse<[UserSuggestion]>.self, from: data).ocs.data
    }

    /// Opens (or creates) the one-to-one conversation with a user.
    func createOneToOne(userId: String) async throws -> Room {
        let (data, _) = try await request("ocs/v2.php/apps/spreed/api/v4/room", method: "POST",
                                          body: ["roomType": 1, "invite": userId])
        return try JSONDecoder().decode(OCSResponse<Room>.self, from: data).ocs.data
    }

    /// Shares an existing file into a conversation (used for forwarding attachments).
    func shareFile(path: String, toRoom token: String) async throws {
        let p = path.hasPrefix("/") ? path : "/" + path
        _ = try await request("ocs/v2.php/apps/files_sharing/api/v1/shares", method: "POST",
                              body: ["shareType": 10, "shareWith": token, "path": p])
    }
}

/// Nextcloud Login Flow v2: the user approves in the browser, the app receives an app password.
enum LoginFlow {
    struct Start: Decodable {
        struct Poll: Decodable { let token: String; let endpoint: String }
        let poll: Poll
        let login: String
    }

    struct Result: Decodable {
        let server: String
        let loginName: String
        let appPassword: String
    }

    static func start(server: URL) async throws -> Start {
        var r = URLRequest(url: server.appendingPathComponent("index.php/login/v2"))
        r.httpMethod = "POST"
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(Start.self, from: data)
    }

    static func poll(_ start: Start) async throws -> Result {
        guard let url = URL(string: start.poll.endpoint) else { throw APIError.invalidResponse }
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data("token=\(start.poll.token)".utf8)
            if let response = try? await URLSession.shared.data(for: r),
               (response.1 as? HTTPURLResponse)?.statusCode == 200,
               let result = try? JSONDecoder().decode(Result.self, from: response.0) {
                return result
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw APIError.http(408)
    }
}
