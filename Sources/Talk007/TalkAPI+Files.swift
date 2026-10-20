import Foundation

/// WebDAV: browse the user's files, upload new ones.
extension TalkAPI {

    private func davRequest(_ path: String, method: String, timeout: TimeInterval = 60) -> URLRequest? {
        guard let url = davURL(path: path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    private func status(_ r: URLRequest) async -> Int {
        guard let result = try? await session.data(for: r) else { return 0 }
        return (result.1 as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Server settings we need: Talk's attachment folder and the instance name ("007 Project").
    func serverInfo() async -> (attachmentsFolder: String, name: String) {
        var folder = "/Talk", name = "Nextcloud"
        guard var comps = URLComponents(url: account.server.appendingPathComponent("ocs/v2.php/cloud/capabilities"),
                                        resolvingAgainstBaseURL: false) else { return (folder, name) }
        comps.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = comps.url else { return (folder, name) }
        var req = URLRequest(url: url)
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let result = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let caps = ((json["ocs"] as? [String: Any])?["data"] as? [String: Any])?["capabilities"] as? [String: Any] {
            let spreedConfig = (caps["spreed"] as? [String: Any])?["config"] as? [String: Any]
            if let f = (spreedConfig?["attachments"] as? [String: Any])?["folder"] as? String, !f.isEmpty {
                folder = f.hasPrefix("/") ? f : "/" + f
            }
            if let n = (caps["theming"] as? [String: Any])?["name"] as? String, !n.isEmpty { name = n }
        }
        return (folder, name)
    }

    func ensureFolder(_ path: String) async {
        guard let r = davRequest(path, method: "MKCOL") else { return }
        _ = await status(r)   // 201 created, 405 already exists
    }

    /// Returns "folder/name", or "folder/name (2).ext" … if that name is taken.
    func uniquePath(folder: String, name: String) async -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 1...200 {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            let path = folder + "/" + candidate
            guard let r = davRequest(path, method: "HEAD") else { return path }
            if await status(r) == 404 { return path }
        }
        return folder + "/" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
    }

    func upload(fileURL: URL, toPath path: String) async throws {
        guard let r = davRequest(path, method: "PUT", timeout: 3600) else { throw APIError.invalidResponse }
        let (_, resp) = try await session.upload(for: r, fromFile: fileURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code) }
    }

    /// Lists a folder ("/" = root). Folders first, then files by name.
    func listFolder(_ path: String) async throws -> [RemoteFile] {
        guard var r = davRequest(path, method: "PROPFIND") else { throw APIError.invalidResponse }
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:prop><d:getlastmodified/><d:getcontentlength/><d:getcontenttype/><d:resourcetype/>
          <oc:fileid/><oc:size/><nc:has-preview/></d:prop>
        </d:propfind>
        """.utf8)
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard code == 207 else { throw APIError.http(code) }

        let marker = "/remote.php/dav/files/"
        let parser = PropfindParser()
        let entries = parser.parse(data)
        let normalized = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return entries.compactMap { e -> RemoteFile? in
            let href = e.href.removingPercentEncoding ?? e.href
            guard let range = href.range(of: marker) else { return nil }
            var rel = String(href[range.upperBound...])       // "user/Photos/a.jpg"
            if let slash = rel.firstIndex(of: "/") { rel = String(rel[slash...]) } else { rel = "/" }
            let trimmed = "/" + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed == normalized { return nil }            // the folder itself
            let name = (trimmed as NSString).lastPathComponent
            if name.hasPrefix(".") { return nil }
            return RemoteFile(path: trimmed, name: name, isFolder: e.isFolder,
                              size: e.size, mimetype: e.isFolder ? "inode/directory" : e.contentType,
                              modified: e.modified, fileId: e.fileId, hasPreview: e.hasPreview)
        }
        .sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Entry {
        var href = "", contentType = "", fileId: String?, modified: Date?
        var size: Int64 = 0, isFolder = false, hasPreview = false
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private static let dateF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parse(_ data: Data) -> [Entry] {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        p.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "response" { current = Entry() }
        if name == "collection" { current?.isFolder = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": current?.href = t
        case "getcontenttype": current?.contentType = t
        case "getcontentlength": if let v = Int64(t) { current?.size = v }
        case "size": if let v = Int64(t), current?.size == 0 { current?.size = v }
        case "fileid": current?.fileId = t
        case "has-preview": current?.hasPreview = (t == "true")
        case "getlastmodified": current?.modified = Self.dateF.date(from: t)
        case "response": if let c = current { entries.append(c) }; current = nil
        default: break
        }
        text = ""
    }
}
