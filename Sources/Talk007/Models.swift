import Foundation
import SwiftUI

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

/// Decoding helpers for fields the server sends sometimes as string, sometimes as number.
private extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int64.self, forKey: key) { return String(i) }
        return nil
    }

    func flexInt(_ key: Key) -> Int64? {
        if let i = try? decode(Int64.self, forKey: key) { return i }
        if let s = try? decode(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}

struct MessageParameter: Decodable {
    let type: String?
    let id: String?
    let name: String?
    let link: String?
    let path: String?
    let mimetype: String?
    let size: Int64?
    let width: Int64?
    let height: Int64?
    let previewAvailable: Bool

    private enum K: String, CodingKey {
        case type, id, name, link, path, mimetype, size, width, height
        case previewAvailable = "preview-available"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        type = c.flexString(.type)
        id = c.flexString(.id)
        name = c.flexString(.name)
        link = c.flexString(.link)
        path = c.flexString(.path)
        mimetype = c.flexString(.mimetype)
        size = c.flexInt(.size)
        width = c.flexInt(.width)
        height = c.flexInt(.height)
        previewAvailable = c.flexString(.previewAvailable) == "yes"
    }

    /// Builds a parameter for a file browsed on the server (not from a chat message).
    init(remote: RemoteFile) {
        type = "file"
        id = remote.fileId
        name = remote.name
        link = nil
        path = remote.path
        mimetype = remote.mimetype
        size = remote.size
        width = nil
        height = nil
        previewAvailable = remote.hasPreview
    }

    var isImage: Bool { mimetype?.hasPrefix("image/") ?? false }
    var isVideo: Bool { mimetype?.hasPrefix("video/") ?? false }
    var isMedia: Bool { isImage || isVideo }

    var symbolName: String {
        let m = mimetype ?? ""
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("video/") { return "film" }
        if m.hasPrefix("audio/") { return "waveform" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.contains("zip") || m.contains("compressed") || m.contains("tar") { return "doc.zipper" }
        if m.contains("sheet") || m.contains("excel") || m.contains("csv") { return "tablecells" }
        if m.contains("presentation") || m.contains("powerpoint") { return "rectangle.on.rectangle" }
        if m.hasPrefix("text/") || m.contains("document") || m.contains("word") { return "doc.text" }
        return "doc"
    }

    var sizeText: String {
        guard let size, size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
    let name: String         // for 1:1 rooms: the other user's id
    let displayName: String
    var unreadMessages: Int
    var unreadMention: Bool
    let lastActivity: Int
    let lastMessage: ChatMessage?
    let isFavorite: Bool
    let notificationLevel: Int
    let readOnly: Int
    let avatarVersion: String?

    private enum K: String, CodingKey {
        case token, type, name, displayName, unreadMessages, unreadMention, lastActivity
        case lastMessage, isFavorite, notificationLevel, readOnly, avatarVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        token = try c.decode(String.self, forKey: .token)
        type = (try? c.decode(Int.self, forKey: .type)) ?? 2
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        unreadMessages = (try? c.decode(Int.self, forKey: .unreadMessages)) ?? 0
        unreadMention = (try? c.decode(Bool.self, forKey: .unreadMention)) ?? false
        lastActivity = (try? c.decode(Int.self, forKey: .lastActivity)) ?? 0
        // The server sends [] instead of an object for empty rooms.
        lastMessage = try? c.decode(ChatMessage.self, forKey: .lastMessage)
        isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
        notificationLevel = (try? c.decode(Int.self, forKey: .notificationLevel)) ?? 0
        readOnly = (try? c.decode(Int.self, forKey: .readOnly)) ?? 0
        avatarVersion = c.flexString(.avatarVersion)
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
        let text = m.previewText
        if m.isSystem { return text }
        if m.actorId == me { return "You: \(text)" }
        if !isOneToOne, let first = m.actorDisplayName.split(separator: " ").first {
            return "\(first): \(text)"
        }
        return text
    }
}

/// A file or folder in the user's Nextcloud storage (from WebDAV).
struct RemoteFile: Identifiable, Hashable {
    let path: String        // relative to the user's root, e.g. "/Photos/a.jpg"
    let name: String
    let isFolder: Bool
    let size: Int64
    let mimetype: String
    let modified: Date?
    let fileId: String?
    let hasPreview: Bool

    var id: String { path }
}

struct UserSuggestion: Decodable, Identifiable {
    let id: String
    let label: String
    let source: String?
}

/// A shared file (image, video or document) with the message it came from.
struct MediaItem: Identifiable {
    let file: MessageParameter
    let messageId: Int
    let actorDisplayName: String
    let timestamp: Int

    var id: String { "\(messageId)-\(file.id ?? file.name ?? "")" }
    var name: String { file.name ?? "File" }

    init?(message: ChatMessage) {
        guard let f = message.file else { return nil }
        file = f
        messageId = message.id
        actorDisplayName = message.actorDisplayName
        timestamp = message.timestamp
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

    /// The attached file, if this message shares one.
    var file: MessageParameter? {
        guard !isDeleted, let f = messageParameters["file"], f.type == "file" else { return nil }
        return f
    }

    /// Text written along with a file ("caption"); empty for plain file shares.
    var caption: String {
        message.replacingOccurrences(of: "{file}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var previewText: String {
        if isDeleted { return "Message deleted" }
        if let f = file, caption.isEmpty {
            if f.isImage { return "📷 Photo" }
            if f.isVideo { return "🎬 Video" }
            return "📎 \(f.name ?? "File")"
        }
        return renderedText.replacingOccurrences(of: "\n", with: " ")
    }

    private static let placeholder = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_\\-]+)\\}")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var renderedText: String { String(attributedText().characters) }

    /// Replaces {placeholders} with names, links files and URLs.
    func attributedText(excludingFile: Bool = false) -> AttributedString {
        let ns = message as NSString
        var result = AttributedString()
        var cursor = 0
        for m in Self.placeholder.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                result += Self.linkified(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let key = ns.substring(with: m.range(at: 1))
            if excludingFile && key == "file" {
                // rendered separately as an attachment
            } else if let p = messageParameters[key] {
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

// MARK: - Look

enum Theme {
    static let body = Font.system(size: 15)
    static let name = Font.system(size: 14, weight: .semibold)
    static let preview = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let title = Font.system(size: 16, weight: .semibold)
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
    private static let mediumF: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func time(_ ts: Int) -> String { timeF.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
    static func full(_ ts: Int) -> String { mediumF.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }

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
