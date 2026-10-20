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
        didSet { if oldValue != selectedToken { openChat(); resetArchive() } }
    }

    // UI state
    @Published var showInfo = false { didSet { if showInfo && !oldValue { loadArchive() } } }
    @Published var showNewConversation = false
    @Published var forwarding: ChatMessage?
    @Published var toast: String?

    // Shared media/files of the selected conversation
    @Published private(set) var sharedMedia: [MediaItem] = []
    @Published private(set) var sharedFiles: [MediaItem] = []
    @Published private(set) var archiveLoading = false
    @Published private(set) var mediaHasMore = false
    @Published private(set) var filesHasMore = false

    let media = MediaCache()

    // Sending files
    @Published private(set) var uploadStatus: String?
    @Published var showFilePicker = false
    @Published private(set) var serverName = "Nextcloud"
    private var attachmentsFolder = "/Talk"

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
        // Old versions kept the password in the Keychain; reading it would block the launch, so just forget it.
        UserDefaults.standard.removeObject(forKey: "account")
        if let saved = CredentialStore.load() {
            activate(saved.account, password: saved.appPassword)
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
                CredentialStore.save(acc, password: result.appPassword)
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
        CredentialStore.delete()
        roomsTask?.cancel()
        chatTask?.cancel()
        api = nil
        account = nil
        rooms = []
        messages = []
        selectedToken = nil
        connectionError = nil
        showInfo = false
        media.clear()
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
        let api = self.api
        Task {
            guard let info = await api?.serverInfo(), self.api === api else { return }
            attachmentsFolder = info.attachmentsFolder
            serverName = info.name
        }
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

    // MARK: Media & files

    var apiClient: TalkAPI? { api }

    func previewURL(_ file: MessageParameter, size: Int) -> URL? {
        guard let id = file.id else { return nil }
        return api?.previewURL(fileId: id, size: size)
    }

    func userAvatarURL(_ userId: String) -> URL? { api?.userAvatarURL(userId) }

    func avatarURL(for room: Room) -> URL? {
        if room.isOneToOne, !room.name.isEmpty { return api?.userAvatarURL(room.name) }
        return api?.roomAvatarURL(room)
    }

    /// Images and videos of the open conversation, oldest first (for the viewer's arrows).
    var conversationMedia: [MediaItem] {
        messages.compactMap { MediaItem(message: $0) }.filter { $0.file.isMedia }
    }

    func openMedia(_ item: MediaItem, in list: [MediaItem]) {
        let index = list.firstIndex { $0.id == item.id } ?? 0
        AppDelegate.shared?.showViewer(items: list.isEmpty ? [item] : list, index: list.isEmpty ? 0 : index)
    }

    func open(_ message: ChatMessage) {
        guard let item = MediaItem(message: message) else { return }
        if item.file.isMedia { openMedia(item, in: conversationMedia) } else { openFile(item.file) }
    }

    func openFile(_ file: MessageParameter) {
        guard let api else { return }
        toast = "Downloading \(file.name ?? "file")…"
        Task {
            do {
                let url = try await media.localFile(for: file, api: api)
                toast = nil
                NSWorkspace.shared.open(url)
            } catch {
                toast = "Could not download the file."
            }
        }
    }

    func saveToDownloads(_ file: MessageParameter) {
        guard let api else { return }
        Task {
            do {
                let local = try await media.localFile(for: file, api: api)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let name = (file.name ?? local.lastPathComponent).replacingOccurrences(of: "/", with: "-")
                var target = downloads.appendingPathComponent(name)
                var n = 1
                let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
                while FileManager.default.fileExists(atPath: target.path) {
                    target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                }
                try FileManager.default.copyItem(at: local, to: target)
                NSWorkspace.shared.activateFileViewerSelecting([target])
                toast = "Saved to Downloads"
            } catch {
                toast = "Could not save the file."
            }
        }
    }

    // MARK: Sending files

    /// Uploads local files to the Talk folder (like the web app) and shares them into the open conversation.
    func uploadFiles(_ urls: [URL]) {
        guard let token = selectedToken, let api, !urls.isEmpty else { return }
        let folder = attachmentsFolder
        Task {
            await api.ensureFolder(folder)
            var failed = 0
            for (i, url) in urls.enumerated() {
                let name = url.lastPathComponent
                uploadStatus = urls.count > 1 ? "Sending \(i + 1) of \(urls.count): \(name)" : "Sending \(name)…"
                do {
                    let target = await api.uniquePath(folder: folder, name: name)
                    try await api.upload(fileURL: url, toPath: target)
                    try await api.shareFile(path: target, toRoom: token)
                } catch {
                    failed += 1
                }
            }
            uploadStatus = nil
            toast = failed == 0 ? (urls.count > 1 ? "\(urls.count) files sent" : "File sent")
                                : "\(failed) file(s) could not be sent"
            await refreshRooms()
        }
    }

    /// Shares files that are already in the user's Nextcloud.
    func shareRemoteFiles(_ files: [RemoteFile]) {
        guard let token = selectedToken, let api, !files.isEmpty else { return }
        Task {
            var failed = 0
            for (i, f) in files.enumerated() {
                uploadStatus = files.count > 1 ? "Sharing \(i + 1) of \(files.count): \(f.name)" : "Sharing \(f.name)…"
                do { try await api.shareFile(path: f.path, toRoom: token) } catch { failed += 1 }
            }
            uploadStatus = nil
            toast = failed == 0 ? (files.count > 1 ? "\(files.count) files shared" : "File shared")
                                : "\(failed) file(s) could not be shared"
            await refreshRooms()
        }
    }

    func listRemoteFolder(_ path: String) async throws -> [RemoteFile] {
        guard let api else { return [] }
        return try await api.listFolder(path)
    }

    // MARK: Archive

    private func resetArchive() {
        sharedMedia = []
        sharedFiles = []
        mediaHasMore = false
        filesHasMore = false
        if showInfo { loadArchive() }
    }

    func loadArchive(more kind: String? = nil) {
        guard let token = selectedToken, let api else { return }
        archiveLoading = true
        Task {
            defer { archiveLoading = false }
            if kind == nil || kind == "media" {
                let before = kind == nil ? nil : sharedMedia.last?.messageId
                if let batch = try? await api.sharedItems(token: token, objectType: "media", before: before),
                   selectedToken == token {
                    let items = batch.compactMap { MediaItem(message: $0) }
                    sharedMedia = kind == nil ? items : sharedMedia + items
                    mediaHasMore = batch.count >= 100
                }
            }
            if kind == nil || kind == "file" {
                let before = kind == nil ? nil : sharedFiles.last?.messageId
                if let batch = try? await api.sharedItems(token: token, objectType: "file", before: before),
                   selectedToken == token {
                    let items = batch.compactMap { MediaItem(message: $0) }
                    sharedFiles = kind == nil ? items : sharedFiles + items
                    filesHasMore = batch.count >= 100
                }
            }
        }
    }

    // MARK: New conversation & forwarding

    func searchUsers(_ term: String) async -> [UserSuggestion] {
        guard let api else { return [] }
        let users = (try? await api.searchUsers(term)) ?? []
        return users.filter { $0.id != myUserId }
    }

    func startChat(with userId: String) async {
        guard let api else { return }
        do {
            let room = try await api.createOneToOne(userId: userId)
            await refreshRooms()
            selectedToken = room.token
        } catch {
            toast = "Could not start the conversation."
        }
    }

    func forward(_ message: ChatMessage, to token: String) async {
        guard let api else { return }
        let target = rooms.first { $0.token == token }?.displayName ?? "conversation"
        do {
            if let file = message.file, let path = file.path {
                try await api.shareFile(path: path, toRoom: token)
                if !message.caption.isEmpty {
                    _ = try await api.send(token: token, text: String(message.attributedText(excludingFile: true).characters), replyTo: nil)
                }
            } else {
                _ = try await api.send(token: token, text: message.renderedText, replyTo: nil)
            }
            toast = "Forwarded to \(target)"
            await refreshRooms()
        } catch {
            toast = "Could not forward the message."
        }
    }

    func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        let text = message.file != nil && message.caption.isEmpty ? (message.file?.name ?? "") : message.renderedText
        NSPasteboard.general.setString(text, forType: .string)
        toast = "Copied"
    }

    // MARK: Dock

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
