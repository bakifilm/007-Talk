import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    enum LoginState { case loggedOut, waitingForBrowser, loggedIn }

    @Published private(set) var account: Account?
    @Published private(set) var loginState: LoginState = .loggedOut
    @Published var loginError: String?
    @Published private(set) var rooms: [Room] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var connectionError: String?
    @Published var replyTo: ChatMessage?
    @Published var selectedToken: String? {
        didSet { if oldValue != selectedToken { openChat() } }
    }

    // Settings
    @Published var showInDock: Bool = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInDock, forKey: "showInDock"); applyDockPolicy() }
    }
    @Published var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notifications") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                connectionError = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    /// True while the main window is the key window (the user is looking at the chat).
    var isChatVisible = false {
        didSet { if isChatVisible && !oldValue { markSelectedRead() } }
    }

    private var api: TalkAPI?
    private var roomsTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var lastSeenMessage: [String: Int] = [:]
    private var firstRoomsLoad = true

    init() {
        if let data = UserDefaults.standard.data(forKey: "account"),
           let acc = try? JSONDecoder().decode(Account.self, from: data),
           let pw = Keychain.read(account: acc.keychainKey) {
            activate(acc, password: pw)
        }
    }

    // MARK: Derived

    var sortedRooms: [Room] {
        rooms.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.lastActivity > b.lastActivity
        }
    }

    var recentRooms: [Room] { Array(rooms.sorted { $0.lastActivity > $1.lastActivity }.prefix(3)) }
    var unreadRoomCount: Int { rooms.filter { $0.unreadMessages > 0 }.count }
    var selectedRoom: Room? { rooms.first { $0.token == selectedToken } }
    var myUserId: String? { account?.userId }

    // MARK: Login

    func startLogin(serverInput: String) {
        loginError = nil
        guard let server = Self.normalize(serverInput) else {
            loginError = "Please enter a valid server address."
            return
        }
        loginState = .waitingForBrowser
        loginTask?.cancel()
        loginTask = Task {
            do {
                let start = try await LoginFlow.start(server: server)
                if let url = URL(string: start.login) { NSWorkspace.shared.open(url) }
                let result = try await LoginFlow.poll(start)

                let serverURL = Self.normalize(result.server) ?? server
                var acc = Account(server: serverURL, loginName: result.loginName,
                                  userId: result.loginName, displayName: result.loginName)
                if let me = try? await TalkAPI(account: acc, password: result.appPassword).currentUser() {
                    acc.userId = me.id
                    acc.displayName = me.displayName
                }
                Keychain.save(result.appPassword, account: acc.keychainKey)
                UserDefaults.standard.set(try? JSONEncoder().encode(acc), forKey: "account")
                activate(acc, password: result.appPassword)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard !Task.isCancelled else { return }
                loginState = .loggedOut
                loginError = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginState = .loggedOut
    }

    func logout() {
        let oldAPI = api
        Task { try? await oldAPI?.revoke() }
        if let acc = account { Keychain.delete(account: acc.keychainKey) }
        UserDefaults.standard.removeObject(forKey: "account")
        roomsTask?.cancel()
        chatTask?.cancel()
        api = nil
        account = nil
        rooms = []
        messages = []
        selectedToken = nil
        connectionError = nil
        loginState = .loggedOut
    }

    private func activate(_ acc: Account, password: String) {
        account = acc
        api = TalkAPI(account: acc, password: password)
        loginState = .loggedIn
        firstRoomsLoad = true
        lastSeenMessage = [:]
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        startRoomsLoop()
    }

    private static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: Conversations

    private func startRoomsLoop() {
        roomsTask?.cancel()
        roomsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRooms()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func refreshRooms() async {
        guard let api else { return }
        do {
            let new = try await api.rooms()
            guard self.api === api else { return }
            connectionError = nil
            notifyNewMessages(in: new)
            rooms = new
            if isChatVisible, let room = selectedRoom, room.unreadMessages > 0 { markSelectedRead() }
        } catch APIError.unauthorized {
            logout()
            loginError = APIError.unauthorized.errorDescription
        } catch {
            if !Task.isCancelled { connectionError = "Can't reach the server." }
        }
    }

    // MARK: Chat

    private func openChat() {
        chatTask?.cancel()
        messages = []
        replyTo = nil
        hasMoreHistory = false
        guard let token = selectedToken, let api else { return }
        chatTask = Task { [weak self] in await self?.chatLoop(token: token, api: api) }
    }

    private func chatLoop(token: String, api: TalkAPI) async {
        var lastKnown = 0

        // Initial history
        while !Task.isCancelled {
            do {
                let batch = try await api.messages(token: token, future: false, lastKnown: nil, setReadMarker: isChatVisible)
                guard !Task.isCancelled else { return }
                merge(batch)
                hasMoreHistory = batch.count >= 100
                lastKnown = batch.map(\.id).max() ?? 0
                if isChatVisible { setLocalRead(token) }
                break
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        // Long polling for new messages
        while !Task.isCancelled {
            do {
                let batch = try await api.messages(token: token, future: true, lastKnown: lastKnown, setReadMarker: isChatVisible)
                guard !Task.isCancelled else { return }
                if !batch.isEmpty {
                    merge(batch)
                    lastKnown = max(lastKnown, batch.map(\.id).max() ?? 0)
                    if isChatVisible { setLocalRead(token) }
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func loadOlder() {
        guard let token = selectedToken, let api, let first = messages.first?.id else { return }
        Task {
            guard let batch = try? await api.messages(token: token, future: false, lastKnown: first, setReadMarker: false),
                  selectedToken == token else { return }
            merge(batch)
            hasMoreHistory = batch.count >= 100
        }
    }

    private func merge(_ incoming: [ChatMessage]) {
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for m in incoming {
            // Edits and deletions arrive as system messages carrying the updated original.
            if m.systemMessage == "message_edited" || m.systemMessage == "message_deleted",
               let p = m.parent?.value, byId[p.id] != nil {
                byId[p.id] = p
            }
            if m.isHidden { continue }
            byId[m.id] = m
        }
        messages = byId.values.sorted { $0.id < $1.id }
    }

    /// Returns false if sending failed, so the composer can restore the text.
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = selectedToken, let api else { return false }
        let reply = replyTo?.id
        replyTo = nil
        do {
            if let m = try await api.send(token: token, text: trimmed, replyTo: reply), selectedToken == token {
                merge([m])
            }
            Task { await refreshRooms() }
            return true
        } catch {
            connectionError = "Message could not be sent."
            return false
        }
    }

    func markSelectedRead() {
        guard let token = selectedToken, let api, let room = selectedRoom, room.unreadMessages > 0 else { return }
        setLocalRead(token)
        Task { try? await api.markRead(token: token) }
    }

    private func setLocalRead(_ token: String) {
        if let i = rooms.firstIndex(where: { $0.token == token }), rooms[i].unreadMessages > 0 {
            rooms[i].unreadMessages = 0
            rooms[i].unreadMention = false
        }
        clearDeliveredNotifications(for: token)
    }

    // MARK: Notifications

    private func notifyNewMessages(in new: [Room]) {
        defer { firstRoomsLoad = false }
        for room in new {
            guard let msg = room.lastMessage else { continue }
            let previous = lastSeenMessage[room.token]
            lastSeenMessage[room.token] = msg.id
            if firstRoomsLoad { continue }
            if let previous, msg.id <= previous { continue }
            guard notificationsEnabled, room.unreadMessages > 0, !msg.isSystem,
                  msg.actorId != myUserId, room.shouldNotify else { continue }
            if isChatVisible && room.token == selectedToken { continue }

            let content = UNMutableNotificationContent()
            content.title = room.displayName
            let text = msg.renderedText
            content.body = room.isOneToOne ? text : "\(msg.actorDisplayName): \(text)"
            content.sound = .default
            content.threadIdentifier = room.token
            content.userInfo = ["token": room.token]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "\(room.token)-\(msg.id)", content: content, trigger: nil)
            )
        }
    }

    private func clearDeliveredNotifications(for token: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { list in
            let ids = list.filter { $0.request.content.threadIdentifier == token }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: Dock

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
