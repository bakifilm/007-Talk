import AppKit
import AVFoundation
import ImageIO
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

    /// Thumbnail for an image or video. Order: server preview → (images) small local copy →
    /// (videos) a frame grabbed from the stream. Works even when the server makes no previews.
    func thumbnail(for file: MessageParameter, size: Int, api: TalkAPI) async -> NSImage? {
        let key = URL(string: "thumb://\(file.id ?? file.path ?? "x")/\(size)")!
        if let img = cached(key) { return img }
        if failed.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task<NSImage?, Never> { [weak self] in
            if file.previewAvailable, let id = file.id, let url = api.previewURL(fileId: id, size: size),
               let img = await self?.image(url, api: api) {
                return img
            }
            if file.isImage, (file.size ?? 0) < 40_000_000,
               let local = try? await self?.localFile(for: file, api: api) {
                return await Task.detached { Self.downsample(local, maxPixels: size) }.value
            }
            if file.isVideo, let path = file.path, let url = api.davURL(path: path) {
                return await Self.videoFrame(url: url, auth: api.authorizationHeader, maxPixels: size)
            }
            return nil
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img { images.setObject(img, forKey: key as NSURL) } else { failed.insert(key) }
        return img
    }

    nonisolated private static func downsample(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated private static func videoFrame(url: URL, auth: String, maxPixels: Int) async -> NSImage? {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": auth]])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            }
        }
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
