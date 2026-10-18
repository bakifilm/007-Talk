import AppKit
import Foundation

/// In-memory image cache plus an on-disk cache for downloaded files.
@MainActor
final class MediaCache {
    private let images = NSCache<NSURL, NSImage>()
    private var failed = Set<URL>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var downloads: [String: Task<URL, Error>] = [:]

    init() { images.countLimit = 600 }

    func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    func image(_ url: URL, api: TalkAPI) async -> NSImage? {
        if let img = cached(url) { return img }
        if failed.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let data = try? await api.fetch(url), let img = NSImage(data: data) else { return nil }
            return img
        }
        inFlight[url] = task
        let img = await task.value
        inFlight[url] = nil
        if let img { images.setObject(img, forKey: url as NSURL) } else { failed.insert(url) }
        return img
    }

    func clear() {
        images.removeAllObjects()
        failed.removeAll()
    }

    // MARK: Files

    static var filesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("work.baki.talk007/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads a shared file once and returns its local copy.
    func localFile(for file: MessageParameter, api: TalkAPI) async throws -> URL {
        guard let path = file.path, let remote = api.davURL(path: path) else { throw APIError.invalidResponse }
        let safeName = (file.name ?? "file").replacingOccurrences(of: "/", with: "-")
        let key = "\(file.id ?? "x")-\(safeName)"
        let local = Self.filesDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let task = downloads[key] { return try await task.value }
        let task = Task<URL, Error> {
            try await api.download(remote, to: local)
            return local
        }
        downloads[key] = task
        defer { downloads[key] = nil }
        return try await task.value
    }
}
