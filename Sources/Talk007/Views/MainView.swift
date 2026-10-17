import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if store.loginState == .loggedIn {
                HStack(spacing: 0) {
                    SidebarView().frame(width: 270)
                    Divider()
                    if let room = store.selectedRoom {
                        ChatView(room: room).id(room.token)
                    } else {
                        Text("Select a conversation")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 640, minHeight: 420)
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
                .frame(width: 72, height: 72)
            Text("007 Talk").font(.title2.weight(.semibold))
            Text("Sign in with your Nextcloud account")
                .foregroundStyle(.secondary)

            if store.loginState == .waitingForBrowser {
                ProgressView().controlSize(.small).padding(.top, 6)
                Text("Waiting for approval in your browser…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelLogin() }
            } else {
                TextField("cloud.example.com", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(login)
                    .padding(.top, 6)
                Button("Sign in with Browser", action: login)
                    .buttonStyle(.borderedProminent)
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(10)

            List(selection: $store.selectedToken) {
                ForEach(filtered) { room in
                    RoomRow(room: room, me: store.myUserId).tag(room.token)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Avatar(name: store.account?.displayName ?? "", size: 22)
                Text(store.account?.displayName ?? "")
                    .font(.callout)
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
