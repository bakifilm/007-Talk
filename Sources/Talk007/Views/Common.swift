import SwiftUI

/// Loads an image from the Nextcloud server with the account's credentials.
struct RemoteImage<Placeholder: View>: View {
    @EnvironmentObject var store: AppStore
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, let api = store.apiClient else { image = nil; return }
            if let cached = store.media.cached(url) { image = cached; return }
            image = await store.media.image(url, api: api)
        }
    }
}

struct Avatar: View {
    let name: String
    var url: URL? = nil
    var size: CGFloat = 32

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 0.80), Color(red: 0.30, green: 0.64, blue: 0.60),
        Color(red: 0.55, green: 0.44, blue: 0.78), Color(red: 0.85, green: 0.55, blue: 0.33),
        Color(red: 0.80, green: 0.42, blue: 0.55), Color(red: 0.42, green: 0.62, blue: 0.38),
        Color(red: 0.58, green: 0.50, blue: 0.42), Color(red: 0.40, green: 0.48, blue: 0.58),
    ]

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    private var color: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Self.palette[hash % Self.palette.count]
    }

    private var initialsView: some View {
        Circle()
            .fill(color)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(.white)
            )
    }

    var body: some View {
        RemoteImage(url: url) { initialsView }
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

struct UnreadBadge: View {
    let count: Int
    let strong: Bool

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(strong ? Color.red : Color.secondary.opacity(0.25)))
            .foregroundColor(strong ? .white : .primary)
    }
}

/// One conversation line, used in the sidebar and the menu bar popover.
struct RoomRow: View {
    @EnvironmentObject var store: AppStore
    let room: Room
    var avatarSize: CGFloat = 38

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: room.displayName, url: store.avatarURL(for: room), size: avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.displayName)
                        .font(.system(size: 14, weight: room.unreadMessages > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    if room.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.relative(room.lastActivity))
                        .font(Theme.small)
                        .foregroundColor(room.unreadMessages > 0 ? .red : .secondary)
                }
                HStack(spacing: 6) {
                    Text(room.preview(me: store.myUserId))
                        .font(Theme.preview)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if room.unreadMessages > 0 {
                        UnreadBadge(count: room.unreadMessages, strong: room.unreadMention || room.isOneToOne)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // New messages: soft red background behind the conversation.
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(room.unreadMessages > 0 ? Color.red.opacity(0.32) : Color.clear)
        )
        .padding(.horizontal, -6)
    }
}

/// Small search field used in the sidebar, archive and pickers.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.10)))
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Menu {
            Toggle("Launch at Login", isOn: $store.launchAtLogin)
            Toggle("Show in Dock", isOn: $store.showInDock)
            Toggle("Notifications", isOn: $store.notificationsEnabled)
            Divider()
            if store.loginState == .loggedIn {
                Button("Sign Out") { store.logout() }
            }
            Button("Quit 007 Talk") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $store.launchAtLogin)
            Toggle("Show in Dock", isOn: $store.showInDock)
            Toggle("Notifications", isOn: $store.notificationsEnabled)
            if let acc = store.account {
                LabeledContent("Account", value: "\(acc.displayName) — \(acc.server.host ?? "")")
                Button("Sign Out") { store.logout() }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Short message at the bottom of the window ("Copied", "Forwarded to …").
struct ToastView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack {
            Spacer()
            if let text = store.toast {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.bottom, 80)
                    .transition(.opacity)
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        if store.toast == text { withAnimation { store.toast = nil } }
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: store.toast)
    }
}

/// Image/video thumbnail with spinner while loading and a file icon if nothing can be shown.
struct ThumbnailImage: View {
    @EnvironmentObject var store: AppStore
    let file: MessageParameter
    let size: Int
    var iconSize: CGFloat = 28
    @State private var image: NSImage?
    @State private var done = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.08)
                if done {
                    Image(systemName: file.symbolName).font(.system(size: iconSize)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: "\(file.id ?? "")-\(size)") {
            guard let api = store.apiClient else { done = true; return }
            image = await store.media.thumbnail(for: file, size: size, api: api)
            done = true
        }
    }
}


/// The window's background photo, darkened so light text stays readable.
struct AppBackground: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "background", withExtension: "jpg")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        ZStack {
            Color.black
            if let img = Self.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.15), .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }
}
