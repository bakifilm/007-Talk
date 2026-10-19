import AppKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let room: Room

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.showInfo.toggle() } label: {
                    HStack(spacing: 10) {
                        Avatar(name: room.displayName, url: store.avatarURL(for: room), size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(room.displayName).font(Theme.title).lineLimit(1)
                            Text("Media, files and info")
                                .font(Theme.small)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { store.showInfo.toggle() } label: {
                    Image(systemName: store.showInfo ? "sidebar.right" : "photo.on.rectangle.angled")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Media and files")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            Divider()
            MessageList(room: room)
            Divider()
            Composer(readOnly: room.readOnly == 1)
        }
    }
}

// MARK: - Messages

struct MessageList: View {
    @EnvironmentObject var store: AppStore
    let room: Room

    var body: some View {
        let messages = store.messages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.hasMoreHistory {
                        Button("Load earlier messages") { store.loadOlder() }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        let prev: ChatMessage? = index > 0 ? messages[index - 1] : nil
                        let newDay = prev == nil || !Calendar.current.isDate(prev!.date, inSameDayAs: msg.date)
                        let grouped = !newDay && prev != nil && !prev!.isSystem
                            && prev!.actorId == msg.actorId && msg.timestamp - prev!.timestamp < 300
                        VStack(spacing: 2) {
                            if newDay { DaySeparator(date: msg.date) }
                            MessageRow(
                                message: msg,
                                isMine: msg.actorType == "users" && msg.actorId == store.myUserId,
                                showHeader: !grouped,
                                showAvatar: !room.isOneToOne
                            )
                        }
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: messages.last?.id) { id in
                guard let id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = messages.last?.id {
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(Fmt.day(date))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

struct MessageRow: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let isMine: Bool
    let showHeader: Bool
    let showAvatar: Bool
    @State private var hovering = false

    var body: some View {
        if message.isSystem {
            Text(message.attributedText())
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if isMine {
                    Spacer(minLength: 60)
                    actions
                } else if showAvatar {
                    if showHeader {
                        Avatar(name: message.actorDisplayName,
                               url: message.actorType == "users" ? store.userAvatarURL(message.actorId) : nil,
                               size: 30)
                            .padding(.top, 8)
                    } else {
                        Color.clear.frame(width: 30, height: 1)
                    }
                }

                VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                    if showHeader && !isMine {
                        Text(message.actorDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                            .padding(.top, 8)
                    } else if showHeader {
                        Color.clear.frame(height: 6)
                    }
                    bubble
                }

                if !isMine {
                    actions
                    Spacer(minLength: 60)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    /// Reply / forward / copy, shown while the pointer is over the message.
    private var actions: some View {
        HStack(spacing: 2) {
            ActionButton(symbol: "arrowshape.turn.up.left", help: "Reply") { store.replyTo = message }
            ActionButton(symbol: "arrowshape.turn.up.right", help: "Forward") { store.forwarding = message }
            ActionButton(symbol: "doc.on.doc", help: "Copy") { store.copy(message) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .opacity(hovering && !message.isDeleted ? 1 : 0)
        .padding(.top, showHeader ? 30 : 6)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let parent = message.parent?.value {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parent.actorDisplayName).font(.system(size: 12, weight: .semibold))
                        Text(parent.previewText)
                            .font(Theme.caption)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let file = message.file {
                AttachmentView(message: message, file: file)
                if !message.caption.isEmpty {
                    textWithTime(message.attributedText(excludingFile: true))
                } else {
                    Text(Fmt.time(message.timestamp))
                        .font(Theme.small)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else if message.isDeleted {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("Message deleted").italic().foregroundStyle(.secondary).font(Theme.body)
                    Text(Fmt.time(message.timestamp)).font(Theme.small).foregroundStyle(.tertiary)
                }
            } else {
                textWithTime(message.attributedText())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isMine ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
        )
        .contextMenu {
            if !message.isDeleted {
                Button("Reply") { store.replyTo = message }
                Button("Forward…") { store.forwarding = message }
                Button("Copy") { store.copy(message) }
                if let file = message.file {
                    Divider()
                    Button("Open") { store.open(message) }
                    Button("Save to Downloads") { store.saveToDownloads(file) }
                }
            }
        }
    }

    private func textWithTime(_ text: AttributedString) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(text)
                .font(Theme.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(Fmt.time(message.timestamp))
                .font(Theme.small)
                .foregroundStyle(.tertiary)
        }
    }
}

struct ActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Attachments

struct AttachmentView: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let file: MessageParameter

    var body: some View {
        if file.isMedia {
            MediaThumbnail(file: file, maxSize: CGSize(width: 300, height: 320))
                .onTapGesture { store.open(message) }
                .help(file.name ?? "")
        } else {
            FileCard(file: file)
                .onTapGesture { store.openFile(file) }
        }
    }
}

/// Image/video preview sized like WhatsApp: keeps the aspect ratio inside a box.
struct MediaThumbnail: View {
    @EnvironmentObject var store: AppStore
    let file: MessageParameter
    let maxSize: CGSize

    private var size: CGSize {
        guard let w = file.width, let h = file.height, w > 0, h > 0 else {
            return CGSize(width: min(260, maxSize.width), height: min(195, maxSize.height))
        }
        let scale = min(maxSize.width / CGFloat(w), maxSize.height / CGFloat(h), 1)
        return CGSize(width: max(CGFloat(w) * scale, 120), height: max(CGFloat(h) * scale, 90))
    }

    var body: some View {
        ZStack {
            ThumbnailImage(file: file, size: 640, iconSize: 30)
            .frame(width: size.width, height: size.height)
            .clipped()

            if file.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(radius: 4)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct FileCard: View {
    let file: MessageParameter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.symbolName)
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name ?? "File").font(.system(size: 14, weight: .medium)).lineLimit(2)
                if !file.sizeText.isEmpty {
                    Text(file.sizeText).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var store: AppStore
    let readOnly: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !readOnly && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = store.replyTo {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reply to \(reply.actorDisplayName)").font(.system(size: 12, weight: .semibold))
                        Text(reply.previewText).font(Theme.caption).lineLimit(1)
                    }
                    Spacer()
                    Button { store.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(readOnly ? "This conversation is read-only" : "Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(readOnly)
                    .onSubmit(send)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundColor(canSend ? .accentColor : .secondary.opacity(0.5))
                .disabled(!canSend)
                .padding(.bottom, 2)
            }
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: store.replyTo?.id) { _ in focused = true }
    }

    private func send() {
        guard canSend else { return }
        let message = text
        text = ""
        focused = true
        Task {
            if !(await store.send(message)) { text = message }
        }
    }
}
