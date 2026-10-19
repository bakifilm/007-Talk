import AVKit
import SwiftUI

/// Full-size photo / video viewer with arrows to move through the conversation's media.
struct MediaViewer: View {
    @EnvironmentObject var store: AppStore
    let items: [MediaItem]
    @State var index: Int

    private var item: MediaItem { items[min(max(index, 0), items.count - 1)] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if item.file.isVideo {
                    VideoContent(file: item.file)
                } else {
                    PhotoContent(file: item.file)
                }
            }
            .id(item.id)

            if items.count > 1 {
                HStack {
                    navButton("chevron.left", enabled: index > 0) { index -= 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    navButton("chevron.right", enabled: index < items.count - 1) { index += 1 }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.horizontal, 14)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .preferredColorScheme(.dark)
        .frame(minWidth: 520, minHeight: 400)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(item.actorDisplayName) · \(Fmt.full(item.timestamp))")
                    .font(Theme.small)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if items.count > 1 {
                Text("\(index + 1) / \(items.count)").font(Theme.caption).foregroundStyle(.secondary)
            }
            Button { store.saveToDownloads(item.file) } label: { Image(systemName: "arrow.down.circle") }
                .help("Save to Downloads")
            Button { store.openFile(item.file) } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in default app")
            Button { NSApp.keyWindow?.close() } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .help("Close")
        }
        .buttonStyle(.plain)
        .font(.system(size: 16))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.top, 30)   // room for the window buttons
        .padding(.bottom, 10)
        .background(Color.black.opacity(0.85))
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }
}

/// Shows the preview instantly, then swaps in the original file once downloaded.
struct PhotoContent: View {
    @EnvironmentObject var store: AppStore
    let file: MessageParameter
    @State private var full: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let full {
                Image(nsImage: full).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RemoteImage(url: file.previewAvailable ? store.previewURL(file, size: 1600) : nil, contentMode: .fit) {
                    Color.clear
                }
                if !failed {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
        }
        .padding(8)
        .task {
            guard let api = store.apiClient else { return }
            if let url = try? await store.media.localFile(for: file, api: api), let img = NSImage(contentsOf: url) {
                full = img
            } else {
                failed = true
            }
        }
    }
}

/// AppKit's player view. (SwiftUI's VideoPlayer crashes in apps built with Swift Package Manager.)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// Streams the video from WebDAV and starts playing right away.
struct VideoContent: View {
    @EnvironmentObject var store: AppStore
    let file: MessageParameter
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                PlayerView(player: player)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .onAppear {
            guard player == nil, let api = store.apiClient, let path = file.path, let url = api.davURL(path: path) else { return }
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": api.authorizationHeader],
            ])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
