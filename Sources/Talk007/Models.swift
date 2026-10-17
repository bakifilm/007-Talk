import Foundation

struct OCSResponse<T: Decodable>: Decodable {
    struct Body: Decodable { let data: T }
    let ocs: Body
}

struct Account: Codable {
    let server: URL
    let loginName: String
    var userId: String
    var displayName: String

    var keychainKey: String { "\(loginName)@\(server.absoluteString)" }
}

/// Wraps a recursive value (a message's parent) so the struct stays finite.
final class Box<T: Decodable>: Decodable {
    let value: T
    required init(from decoder: Decoder) throws { value = try T(from: decoder) }
}

struct MessageParameter: Decodable {
    let type: String?
    let name: String?
    let link: String?

    private enum K: String, CodingKey { case type, name, link }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        type = try? c.decode(String.self, forKey: .type)
        name = try? c.decode(String.self, forKey: .name)
        link = try? c.decode(String.self, forKey: .link)
    }
}

struct ChatMessage: Decodable, Identifiable, Equatable {
    let id: Int
    let actorType: String
    let actorId: String
    let actorDisplayName: String
    let timestamp: Int
    let message: String
    let messageParameters: [String: MessageParameter]
    let systemMessage: String
    let messageType: String
    let parent: Box<ChatMessage>?

    private enum K: String, CodingKey {
        case id, actorType, actorId, actorDisplayName, timestamp, message
        case messageParameters, systemMessage, messageType, parent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(Int.self, forKey: .id)
        actorType = (try? c.decode(String.self, forKey: .actorType)) ?? ""
        actorId = (try? c.decode(String.self, forKey: .actorId)) ?? ""
        actorDisplayName = (try? c.decode(String.self, forKey: .actorDisplayName)) ?? ""
        timestamp = (try? c.decode(Int.self, forKey: .timestamp)) ?? 0
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        // The server sends [] instead of {} when there are no parameters.
        messageParameters = (try? c.decode([String: MessageParameter].self, forKey: .messageParameters)) ?? [:]
        systemMessage = (try? c.decode(String.self, forKey: .systemMessage)) ?? ""
        messageType = (try? c.decode(String.self, forKey: .messageType)) ?? "comment"
        parent = try? c.decode(Box<ChatMessage>.self, forKey: .parent)
    }

    static func == (a: ChatMessage, b: ChatMessage) -> Bool {
        a.id == b.id && a.message == b.message && a.messageType == b.messageType
    }
}

struct Room: Decodable, Identifiable {
    var id: String { token }
    let token: String
    let type: Int            // 1 = one-to-one, 2 = group, 3 = public, 4 = changelog, 5 = former 1:1, 6 = note to self
    let displayName: String
    var unreadMessages: Int
    var unreadMention: Bool
    let lastActivity: Int
    let lastMessage: ChatMessage?
    let isFavorite: Bool
    let notificationLevel: Int
    let readOnly: Int

    private enum K: String, CodingKey {
        case token, type, displayName, unreadMessages, unreadMention, lastActivity
        case lastMessage, isFavorite, notificationLevel, readOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        token = try c.decode(String.self, forKey: .token)
        type = (try? c.decode(Int.self, forKey: .type)) ?? 2
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        unreadMessages = (try? c.decode(Int.self, forKey: .unreadMessages)) ?? 0
        unreadMention = (try? c.decode(Bool.self, forKey: .unreadMention)) ?? false
        lastActivity = (try? c.decode(Int.self, forKey: .lastActivity)) ?? 0
        // The server sends [] instead of an object for empty rooms.
        lastMessage = try? c.decode(ChatMessage.self, forKey: .lastMessage)
        isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
        notificationLevel = (try? c.decode(Int.self, forKey: .notificationLevel)) ?? 0
        readOnly = (try? c.decode(Int.self, forKey: .readOnly)) ?? 0
    }

    var isOneToOne: Bool { type == 1 || type == 5 }

    /// Matches Nextcloud Talk's defaults: 1:1 chats notify always, groups only on mention.
    var shouldNotify: Bool {
        switch notificationLevel {
        case 1: return true
        case 2: return unreadMention
        case 3: return false
        default: return isOneToOne || unreadMention
        }
    }

    func preview(me: String?) -> String {
        guard let m = lastMessage else { return "" }
        let text = m.isDeleted ? "Message deleted" : m.renderedText.replacingOccurrences(of: "\n", with: " ")
        if m.isSystem { return text }
        if m.actorId == me { return "You: \(text)" }
        if !isOneToOne, let first = m.actorDisplayName.split(separator: " ").first {
            return "\(first): \(text)"
        }
        return text
    }
}

// MARK: - Message rendering

extension ChatMessage {
    static let hiddenSystemMessages: Set<String> = [
        "reaction", "reaction_deleted", "reaction_revoked",
        "message_deleted", "message_edited", "poll_voted",
    ]

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var isSystem: Bool { messageType == "system" || !systemMessage.isEmpty }
    var isDeleted: Bool { messageType == "comment_deleted" }
    var isHidden: Bool { Self.hiddenSystemMessages.contains(systemMessage) }

    private static let placeholder = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_\\-]+)\\}")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var renderedText: String { String(attributedText().characters) }

    /// Replaces {placeholders} with names, links files and URLs.
    func attributedText() -> AttributedString {
        let ns = message as NSString
        var result = AttributedString()
        var cursor = 0
        for m in Self.placeholder.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                result += Self.linkified(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let key = ns.substring(with: m.range(at: 1))
            if let p = messageParameters[key] {
                var part = AttributedString(display(key: key, p))
                if p.type == "file", let link = p.link, let url = URL(string: link) { part.link = url }
                if key.hasPrefix("mention") { part.inlinePresentationIntent = .stronglyEmphasized }
                result += part
            } else {
                result += AttributedString(ns.substring(with: m.range))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { result += Self.linkified(ns.substring(from: cursor)) }
        return result
    }

    private func display(key: String, _ p: MessageParameter) -> String {
        let name = p.name ?? key
        if key.hasPrefix("mention") { return "@\(name)" }
        if p.type == "file" { return "📎 \(name)" }
        return name
    }

    private static func linkified(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard let detector else { return a }
        for m in detector.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            guard let url = m.url, let r = Range(m.range, in: a) else { continue }
            a[r].link = url
        }
        return a
    }
}

// MARK: - Formatting

enum Fmt {
    private static let timeF: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekdayF: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f
    }()
    private static let shortDateF: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()
    private static let dayF: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy"); return f
    }()

    static func time(_ ts: Int) -> String { timeF.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }

    static func relative(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(d) { return timeF.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return weekdayF.string(from: d) }
        return shortDateF.string(from: d)
    }

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return dayF.string(from: d)
    }
}
