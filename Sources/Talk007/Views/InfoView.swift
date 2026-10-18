import SwiftUI

/// Right-hand panel: who this is, plus the shared media and files archive (WhatsApp-style).
struct ConversationInfoView: View {
    @EnvironmentObject var store: AppStore
    let room: Room
    @State private var tab = 0
    @State private var search = ""

    private func matches(_ item: MediaItem) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty
            || item.name.localizedCaseInsensitiveContains(q)
            || item.actorDisplayName.localizedCaseInsensitiveContains(q)
    }

    private var media: [MediaItem] { store.sharedMedia.filter(matches) }
    private var files: [MediaItem] { store.sharedFiles.filter(matches) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { store.showInfo = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            VStack(spacing: 6) {
                Avatar(name: room.displayName, url: store.avatarURL(for: room), size: 84)
                Text(room.displayName).font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
                if room.isOneToOne && !room.name.isEmpty {
                    Text(room.name).font(Theme.caption).foregroundStyle(.secondary)
                } else if !room.isOneToOne {
                    Text("Group conversation").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            Picker("", selection: $tab) {
                Text("Media (\(store.sharedMedia.count)\(store.mediaHasMore ? "+" : ""))").tag(0)
                Text("Files (\(store.sharedFiles.count)\(store.filesHasMore ? "+" : ""))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)

            SearchField(prompt: tab == 0 ? "Search media" : "Search files", text: $search)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                if store.archiveLoading && store.sharedMedia.isEmpty && store.sharedFiles.isEmpty {
                    ProgressView().padding(30)
                } else if tab == 0 {
                    mediaGrid
                } else {
                    fileList
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mediaGrid: some View {
        VStack(spacing: 10) {
            if media.isEmpty {
                empty(search.isEmpty ? "No photos or videos yet" : "Nothing found")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 3)], spacing: 3) {
                    ForEach(media) { item in
                        ZStack(alignment: .bottomLeading) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    RemoteImage(url: item.file.previewAvailable ? store.previewURL(item.file, size: 256) : nil) {
                                        ZStack {
                                            Color.primary.opacity(0.08)
                                            Image(systemName: item.file.symbolName).foregroundStyle(.secondary)
                                        }
                                    }
                                )
                                .clipped()
                            if item.file.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white)
                                    .padding(5)
                                    .shadow(radius: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.openMedia(item, in: Array(media.reversed())) }
                        .contextMenu {
                            Button("Save to Downloads") { store.saveToDownloads(item.file) }
                        }
                        .help("\(item.name)\n\(item.actorDisplayName) · \(Fmt.full(item.timestamp))")
                    }
                }
                .padding(.horizontal, 3)
            }
            if store.mediaHasMore && search.isEmpty {
                Button("Load more") { store.loadArchive(more: "media") }.buttonStyle(.link).padding(10)
            }
        }
        .padding(.top, 3)
    }

    private var fileList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if files.isEmpty {
                empty(search.isEmpty ? "No files yet" : "Nothing found")
            }
            ForEach(files) { item in
                HoverButton {
                    store.openFile(item.file)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.file.symbolName)
                            .font(.system(size: 18))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text([item.actorDisplayName, Fmt.relative(item.timestamp), item.file.sizeText]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Theme.small)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .contextMenu {
                    Button("Open") { store.openFile(item.file) }
                    Button("Save to Downloads") { store.saveToDownloads(item.file) }
                }
            }
            if store.filesHasMore && search.isEmpty {
                Button("Load more") { store.loadArchive(more: "file") }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            }
        }
        .padding(.vertical, 6)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Theme.preview)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(30)
    }
}
