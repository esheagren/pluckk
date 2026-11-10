import Foundation
import CryptoKit
import WebKit
import UniformTypeIdentifiers

// Pluckk keeps its files on this Mac: card pictures and audio (MediaStore), the user's own modules
// (LocalModules), and the built-in modules and maps, which ship inside the app. Web views reach
// all of them through pluckk-app:// (AppSchemeHandler), so modules work offline. The folder can
// live in iCloud Drive to share it between Macs (see PluckkFiles.root).

enum PluckkFiles {
    static let iCloudKey = "files.inICloudDrive"

    /// ~/Library/Application Support/Pluckk, or iCloud Drive/Pluckk when chosen in Settings.
    static var root: URL {
        if UserDefaults.standard.bool(forKey: iCloudKey), let cloud = iCloudFolder { return cloud }
        return localFolder
    }

    static var localFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pluckk", isDirectory: true)
    }

    /// iCloud Drive's Pluckk folder, if iCloud Drive is on.
    static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Pluckk", isDirectory: true)
    }

    static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Move media and modules between this Mac and iCloud Drive; the setting changes only if it works.
    static func moveFiles(toICloud: Bool) throws {
        guard let cloud = iCloudFolder else { throw CocoaError(.fileNoSuchFile) }
        let from = toICloud ? localFolder : cloud, to = toICloud ? cloud : localFolder
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in ["media", "modules"] {
            let src = from.appendingPathComponent(name), dst = to.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(atPath: src.path) {
                let a = src.appendingPathComponent(file), b = dst.appendingPathComponent(file)
                if fm.fileExists(atPath: b.path) { continue }
                try fm.copyItem(at: a, to: b)
            }
        }
        UserDefaults.standard.set(toICloud, forKey: iCloudKey)
    }
}

/// Card media, named by the SHA-256 of its bytes and referred to on cards as
/// "pluckk-media:<sha256>.<ext>". The same picture added twice is stored once.
enum MediaStore {
    static let scheme = "pluckk-media:"

    static var folder: URL { PluckkFiles.folder("media") }

    /// Store bytes and return the card reference.
    @discardableResult
    static func add(_ data: Data, ext: String) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(hash).\(ext.lowercased())"
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return scheme + name
    }

    static func isLocal(_ ref: String?) -> Bool { ref?.hasPrefix(scheme) == true }

    /// The file for a reference, if it's on this Mac.
    static func file(_ ref: String) -> URL? {
        guard ref.hasPrefix(scheme) else { return nil }
        let name = String(ref.dropFirst(scheme.count))
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Something to show or play for a card's image or audio: the local file for a reference, or
    /// the web address as it was.
    static func displayURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix(scheme) { return file(value) }
        return URL(string: value)
    }
}

/// The user's own modules on this Mac:
///   modules/<slug>/<draft | 1 | 2 …>/{index.html, manifest.json}
/// used on cards as "me/<slug>@<n>", served at pluckk-app://app/um/<anything>/<slug>/<n>/index.html.
enum LocalModules {
    static var folder: URL { PluckkFiles.folder("modules") }

    struct Info { let slug: String; var versions: [Int]; var draft: Bool }

    static func all() -> [Info] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return slugs.sorted().compactMap { slug in
            guard let vers = try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(slug).path) else { return nil }
            let has = { (v: String) in fm.fileExists(atPath: folder.appendingPathComponent("\(slug)/\(v)/index.html").path) }
            let versions = vers.compactMap(Int.init).filter { has(String($0)) }.sorted()
            return Info(slug: slug, versions: versions, draft: has("draft"))
        }
    }

    static func file(_ slug: String, _ version: String, _ name: String) -> URL {
        folder.appendingPathComponent(slug).appendingPathComponent(version).appendingPathComponent(name)
    }

    static func read(_ slug: String, _ version: String, _ name: String) -> String? {
        try? String(contentsOf: file(slug, version, name), encoding: .utf8)
    }

    static func manifest(_ slug: String, _ version: String) -> [String: Any]? {
        read(slug, version, "manifest.json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    static func saveDraft(slug: String, html: String, manifest: [String: Any]) throws {
        let dir = folder.appendingPathComponent(slug).appendingPathComponent("draft")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        var m = manifest
        m["id"] = "me/\(slug)"
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("manifest.json"))
    }

    /// Freeze the draft as the next version; returns it.
    static func publish(slug: String) throws -> Int {
        let info = all().first { $0.slug == slug }
        guard info?.draft == true else { throw CocoaError(.fileNoSuchFile) }
        let next = (info?.versions.max() ?? 0) + 1
        let from = folder.appendingPathComponent(slug).appendingPathComponent("draft")
        let to = folder.appendingPathComponent(slug).appendingPathComponent(String(next))
        try FileManager.default.copyItem(at: from, to: to)
        return next
    }

    static func delete(slug: String) throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(slug))
    }

    /// The module catalogue the editor, the Modules page and the assistant read: the built-ins
    /// shipped in the app plus the user's own, each with use, title, slots, describe, props, samples.
    static func catalogue() -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let url = AppSchemeHandler.bundled("modules/index.json"), let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            out = json["modules"] as? [[String: Any]] ?? []
        }
        for info in all() {
            let version = info.versions.max().map(String.init) ?? "draft"
            var m = manifest(info.slug, version) ?? [:]
            m["slug"] = info.slug
            m["owner"] = "mine"
            m["versions"] = info.versions
            m["has_draft"] = info.draft
            if let latest = info.versions.max() { m["use"] = "me/\(info.slug)@\(latest)" } else { m.removeValue(forKey: "use") }
            out.append(m)
        }
        return out
    }

    /// The base the card API puts in front of "me/" module sources; any value works locally.
    static let userBase = "/um/local"
}

/// Serves pluckk-app://app/… to web views: built-in modules and maps from the app bundle, the
/// user's modules and media from this Mac. Anything built in that the bundle lacks (a module
/// added on the server since this build) is fetched from the API.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pluckk-app"
    static let shared = AppSchemeHandler()

    /// A file inside the app's copy of the API's public folder.
    static func bundled(_ path: String) -> URL? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("public", isDirectory: true) else { return nil }
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(base.standardizedFileURL.path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The pluckk-app:// address for a module page source from the API ("/modules/…", "/um/…").
    static func pageURL(for src: String) -> URL? { URL(string: "\(scheme)://app\(src)") }

    // Same-origin plus the big CDNs, nothing to post to: what the API serves user modules under.
    private static let userModuleCSP = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com",
        "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com https://fonts.googleapis.com",
        "font-src 'self' data: https://fonts.gstatic.com https://cdn.jsdelivr.net",
        "img-src 'self' data: blob: https:", "media-src 'self' data: blob: https:",
        "connect-src 'self' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://unpkg.com",
        "worker-src 'self' blob:", "frame-src 'none'", "form-action 'none'", "base-uri 'none'",
    ].joined(separator: "; ")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let parts = url.path.split(separator: "/").map(String.init)
        var file: URL?
        var csp: String?
        if parts.first == "um", parts.count == 5 {
            // /um/<anyone>/<slug>/<version>/<file>
            file = LocalModules.file(parts[2], parts[3], parts[4])
            csp = Self.userModuleCSP
        } else if parts.first == "media", parts.count == 2 {
            file = MediaStore.file(MediaStore.scheme + parts[1])
        } else {
            file = Self.bundled(parts.joined(separator: "/"))
            if file == nil, let remote = URL(string: Config.backendURL + url.path) {
                fetchRemote(remote, for: task)
                return
            }
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            respond(task, url: url, status: 404, data: Data("Not found".utf8), type: "text/plain", csp: nil)
            return
        }
        respond(task, url: url, status: 200, data: data, type: Self.mimeType(file.pathExtension), csp: csp)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fetchRemote(_ remote: URL, for task: WKURLSchemeTask) {
        URLSession.shared.dataTask(with: remote) { data, response, _ in
            DispatchQueue.main.async {
                let http = response as? HTTPURLResponse
                self.respond(task, url: task.request.url ?? remote, status: http?.statusCode ?? 502, data: data ?? Data(),
                             type: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream", csp: nil)
            }
        }.resume()
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, data: Data, type: String, csp: String?) {
        var headers = ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        if let csp { headers["Content-Security-Policy"] = csp }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript"
        case "json": return "application/json"
        case "css": return "text/css"
        case "svg": return "image/svg+xml"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
