import SwiftUI

struct Avatar: View {
    let name: String
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

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(.white)
            )
    }
}

struct UnreadBadge: View {
    let count: Int
    let strong: Bool

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(strong ? Color.accentColor : Color.secondary.opacity(0.25)))
            .foregroundColor(strong ? .white : .primary)
    }
}

/// One conversation line, used in the sidebar and the menu bar popover.
struct RoomRow: View {
    let room: Room
    let me: String?
    var avatarSize: CGFloat = 32

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: room.displayName, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.displayName)
                        .fontWeight(room.unreadMessages > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if room.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.relative(room.lastActivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(room.preview(me: me))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if room.unreadMessages > 0 {
                        UnreadBadge(count: room.unreadMessages, strong: room.unreadMention || room.isOneToOne)
                    }
                }
            }
        }
        .padding(.vertical, 3)
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
