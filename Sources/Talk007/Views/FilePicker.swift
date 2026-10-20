import SwiftUI

/// Browse the user's Nextcloud storage and share files into the open conversation.
struct NextcloudFilePicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = "/"
    @State private var items: [RemoteFile] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected: [String: RemoteFile] = [:]
    @State private var search = ""

    private var visible: [RemoteFile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var crumbs: [(name: String, path: String)] {
        var result = [(name: store.serverName, path: "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/" + part
            result.append((String(part), acc))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Share from \(store.serverName)").font(Theme.title)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            // Breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if path != "/" {
                        Button { go((path as NSString).deletingLastPathComponent) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                        Button(c.name) { go(c.path) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: i == crumbs.count - 1 ? .semibold : .regular))
                    }
                }
            }

            SearchField(prompt: "Search in this folder", text: $search)

            ZStack {
                if loading {
                    ProgressView()
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if visible.isEmpty {
                    Text(search.isEmpty ? "This folder is empty" : "Nothing found").foregroundStyle(.secondary)
                } else {
                    List(visible) { item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture { tap(item) }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(selected.isEmpty ? "Choose one or more files" : "\(selected.count) selected")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Share") {
                    store.shareRemoteFiles(Array(selected.values))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .task(id: path) { await load() }
    }

    private func row(_ item: RemoteFile) -> some View {
        HStack(spacing: 10) {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                    .frame(width: 38, height: 38)
            } else if item.hasPreview {
                ThumbnailImage(file: MessageParameter(remote: item), size: 96, iconSize: 18)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: MessageParameter(remote: item).symbolName)
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14, weight: item.isFolder ? .semibold : .regular)).lineLimit(1)
                Text(details(item)).font(Theme.small).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isFolder {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            } else {
                Image(systemName: selected[item.path] != nil ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(selected[item.path] != nil ? .accentColor : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func details(_ item: RemoteFile) -> String {
        var parts: [String] = []
        if !item.isFolder, item.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
        if let d = item.modified { parts.append(Fmt.relative(Int(d.timeIntervalSince1970))) }
        return parts.joined(separator: " · ")
    }

    private func tap(_ item: RemoteFile) {
        if item.isFolder {
            go(item.path)
        } else if selected[item.path] != nil {
            selected[item.path] = nil
        } else {
            selected[item.path] = item
        }
    }

    private func go(_ newPath: String) {
        search = ""
        path = newPath.isEmpty ? "/" : newPath
    }

    private func load() async {
        loading = true
        error = nil
        do {
            items = try await store.listRemoteFolder(path)
        } catch {
            items = []
            self.error = "Could not open this folder."
        }
        loading = false
    }
}
