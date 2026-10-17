import AppKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let room: Room

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(room.displayName).font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
            MessageList()
            Divider()
            Composer(readOnly: room.readOnly == 1)
        }
    }
}

// MARK: - Messages

struct MessageList: View {
    @EnvironmentObject var store: AppStore

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
                                showHeader: !grouped
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
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

struct MessageRow: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let isMine: Bool
    let showHeader: Bool

    var body: some View {
        if message.isSystem {
            Text(message.attributedText())
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if isMine { Spacer(minLength: 80) }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                    if showHeader && !isMine {
                        Text(message.actorDisplayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                            .padding(.top, 8)
                    } else if showHeader {
                        Color.clear.frame(height: 6)
                    }
                    bubble
                }
                if !isMine { Spacer(minLength: 80) }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let parent = message.parent?.value {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parent.actorDisplayName).font(.caption.weight(.semibold))
                        Text(parent.isDeleted ? "Message deleted" : parent.renderedText)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Group {
                    if message.isDeleted {
                        Text("Message deleted").italic().foregroundStyle(.secondary)
                    } else {
                        Text(message.attributedText())
                    }
                }
                .textSelection(.enabled)
                Text(Fmt.time(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isMine ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
        )
        .contextMenu {
            if !message.isDeleted {
                Button("Reply") { store.replyTo = message }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.renderedText, forType: .string)
                }
            }
        }
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
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                    Text("\(reply.actorDisplayName): \(reply.renderedText)").lineLimit(1)
                    Spacer()
                    Button { store.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(readOnly ? "This conversation is read-only" : "Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(readOnly)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
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
