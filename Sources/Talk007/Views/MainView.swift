import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if store.loginState == .loggedIn {
                HStack(spacing: 0) {
                    SidebarView().frame(width: 290).background(Color.black.opacity(0.40))
                    Divider()
                    if let room = store.selectedRoom {
                        ChatView(room: room).id(room.token)
                        if store.showInfo {
                            Divider()
                            ConversationInfoView(room: room).frame(width: 320)
                        }
                    } else {
                        Text("Select a conversation")
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(ToastView())
                .sheet(isPresented: $store.showNewConversation) {
                    NewConversationView().environmentObject(store)
                }
                .sheet(isPresented: $store.showFilePicker) {
                    NextcloudFilePicker().environmentObject(store)
                }
                .sheet(item: $store.forwarding) { message in
                    ForwardView(message: message).environmentObject(store)
                }
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .background(AppBackground())
        .preferredColorScheme(.dark)
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("lastServer") private var server = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("007 Talk").font(.system(size: 22, weight: .semibold))
            Text("Sign in with your Nextcloud account")
                .font(Theme.body)
                .foregroundStyle(.secondary)

            if store.loginState == .waitingForBrowser {
                ProgressView().controlSize(.small).padding(.top, 6)
                Text("Waiting for approval in your browser…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelLogin() }
            } else {
                TextField("cloud.example.com", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .frame(width: 300)
                    .onSubmit(login)
                    .padding(.top, 6)
                Button("Sign in with Browser", action: login)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = store.loginError {
                Text(error).font(.callout).foregroundColor(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func login() { store.startLogin(serverInput: server) }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""

    private var filtered: [Room] {
        let all = store.sortedRooms
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(prompt: "Search", text: $search)
                Button { store.showNewConversation = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New conversation")
            }
            .padding(10)

            List(selection: $store.selectedToken) {
                ForEach(filtered) { room in
                    RoomRow(room: room).tag(room.token)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 8) {
                Avatar(name: store.account?.displayName ?? "",
                       url: store.account.flatMap { store.userAvatarURL($0.userId) }, size: 26)
                Text(store.account?.displayName ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let error = store.connectionError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help(error)
                }
                SettingsMenu()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - New conversation

struct NewConversationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var users: [UserSuggestion] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("New Conversation").font(Theme.title)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            SearchField(prompt: "Search people", text: $search)

            if loading && users.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if users.isEmpty {
                Text("No one found").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(users) { user in
                    HoverButton {
                        Task {
                            await store.startChat(with: user.id)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Avatar(name: user.label, url: store.userAvatarURL(user.id), size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.label).font(Theme.name)
                                Text(user.id).font(Theme.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 380, height: 460)
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            loading = true
            users = await store.searchUsers(search)
            loading = false
        }
    }
}

// MARK: - Forward

struct ForwardView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    @State private var search = ""

    private var rooms: [Room] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let all = store.sortedRooms.filter { $0.readOnly == 0 }
        return q.isEmpty ? all : all.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Forward to…").font(Theme.title)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(message.previewText)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            SearchField(prompt: "Search conversations", text: $search)
            List(rooms) { room in
                HoverButton {
                    let m = message
                    dismiss()
                    Task { await store.forward(m, to: room.token) }
                } label: {
                    HStack(spacing: 10) {
                        Avatar(name: room.displayName, url: store.avatarURL(for: room), size: 32)
                        Text(room.displayName).font(Theme.name)
                        Spacer()
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding(16)
        .frame(width: 380, height: 480)
    }
}
