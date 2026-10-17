import SwiftUI

/// Popover shown from the menu bar icon: the 3 most recent conversations.
struct MenuBarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("007 Talk").font(.headline)
                Spacer()
                if let error = store.connectionError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help(error)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if store.loginState != .loggedIn {
                Button("Sign in…") { AppDelegate.shared?.showMainWindow() }
                    .padding(14)
            } else if store.rooms.isEmpty {
                Text("No conversations yet")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ForEach(store.recentRooms) { room in
                    HoverButton {
                        AppDelegate.shared?.showMainWindow(select: room.token)
                    } label: {
                        RoomRow(room: room, me: store.myUserId, avatarSize: 30)
                    }
                }
            }

            Divider().padding(.top, 6)

            HStack {
                Button("Open 007 Talk") { AppDelegate.shared?.showMainWindow() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Spacer()
                SettingsMenu()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }
}

struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
