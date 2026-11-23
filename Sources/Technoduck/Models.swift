import Foundation
import Security

enum Proto: String, Codable, CaseIterable, Identifiable {
    case sftp = "SFTP", ftp = "FTP", ftps = "FTPS", webdav = "WebDAV", webdavs = "WebDAV (HTTPS)", local = "Local Disk"
    var id: String { rawValue }
    var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp, .ftps: 21
        case .webdav: 80
        case .webdavs: 443
        case .local: 0
        }
    }
    var symbol: String {
        switch self {
        case .sftp: "lock.shield"
        case .ftp, .ftps: "server.rack"
        case .webdav, .webdavs: "globe"
        case .local: "internaldrive"
        }
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var nickname = ""
    var proto: Proto = .sftp
    var host = ""
    var port = 22
    var user = ""
    var path = ""
    // Optional so bookmarks saved before these existed still decode.
    /// Patterns never synced, e.g. "node_modules, .git, *.log".
    var excludes: String?
    /// The folder pair this server was last synced with; reopened on connect.
    var syncLocal: String?
    var syncRemote: String?
    /// Upload changes in `syncLocal` to `syncRemote` as they happen.
    var autoSync: Bool?
    /// Where one-click backups of this bookmark go.
    var backupFolder: String?
    var excludeList: [String] {
        (excludes ?? "").split { $0 == "," || $0.isNewline }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var title: String { nickname.isEmpty ? (proto == .local ? "Local Disk" : host) : nickname }
    var url: String { url(path) }
    func url(_ p: String) -> String {
        let scheme = switch proto { case .sftp: "sftp"; case .ftp: "ftp"; case .ftps: "ftps"; case .webdav: "http"; case .webdavs: "https"; case .local: "file" }
        return proto == .local ? "file://\(p)" : "\(scheme)://\(user.isEmpty ? "" : user + "@")\(host):\(port)\(p)"
    }
}

struct RemoteFile: Identifiable, Hashable {
    var name: String
    var path: String
    var isDir: Bool
    var size: Int64
    var modified: Date?
    var permissions = ""
    var isLink = false
    var id: String { path }
}

/// What happened on a connection; drives both the transfers list and the timeline.
enum Activity: String, Codable {
    case upload, download, sync, delete, mkdir, rollback
    var symbol: String {
        switch self {
        case .upload: "arrow.up"
        case .download: "arrow.down"
        case .sync: "arrow.triangle.2.circlepath"
        case .delete: "trash"
        case .mkdir: "folder.badge.plus"
        case .rollback: "arrow.uturn.backward"
        }
    }
}

@Observable final class Transfer: Identifiable {
    enum State: Equatable { case running, done, failed(String) }
    let id = UUID()
    let kind: Activity
    let name: String
    let detail: String
    var state: State = .running
    var progress = 0.0
    var recordID: UUID?
    let started = Date()
    init(kind: Activity, name: String, detail: String) { self.kind = kind; self.name = name; self.detail = detail }
}

/// One entry in a connection's timeline.
struct LogEvent: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var bookmarkID: UUID
    var kind: Activity
    var title: String
    var detail = ""
    var bytes: Int64 = 0
    var recordID: UUID?
    var items: [String] = []
}

/// The two ends of a sync or copy: A is the left (or source) pane, B the right (or target).
/// Raw values date from when A was always this Mac and B the server.
enum Side: String, Codable { case a = "local", b = "remote" }

/// A folder on some location, as used by a sync or copy. `location` nil means this Mac's disk.
struct Endpoint {
    let service: FileService
    let root: String
    var location: UUID?
    var bookmark: Bookmark?
    /// The folder's name ("public_html"), or the location's for a root.
    var name: String { let n = (root as NSString).lastPathComponent; return n.isEmpty || n == "/" ? place : n }
    var place: String { bookmark?.title ?? "This Mac" }
}

/// A folder pinned in the sidebar. `bookmarkID` nil means this Mac's disk.
struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var bookmarkID: UUID?
    var path: String
}

/// What syncs through iCloud Drive and gets backed up daily.
struct Library: Codable {
    var bookmarks: [Bookmark]
    var favorites: [Favorite]
}

enum SyncMode: String, CaseIterable, Identifiable {
    case upload, download, both
    var id: String { rawValue }
    /// For the strip: which way, in screen terms.
    func label(stacked: Bool) -> String {
        switch self {
        case .upload: stacked ? "Down" : "To right"
        case .download: stacked ? "Up" : "To left"
        case .both: "Both ways"
        }
    }
    func symbol(stacked: Bool) -> String {
        switch self {
        case .upload: stacked ? "arrow.down" : "arrow.right"
        case .download: stacked ? "arrow.up" : "arrow.left"
        case .both: stacked ? "arrow.up.arrow.down" : "arrow.left.arrow.right"
        }
    }
    /// "Website → public_html": names the folders, so it reads right whatever the layout.
    func phrase(_ a: Endpoint, _ b: Endpoint) -> String {
        switch self {
        case .upload: "\(a.name) → \(b.name)"
        case .download: "\(b.name) → \(a.name)"
        case .both: "\(a.name) ⇄ \(b.name)"
        }
    }
}

/// One step of a sync: create a folder or copy a file to `to`.
struct SyncOp: Codable, Hashable, Identifiable {
    var id = UUID()
    var to: Side
    var rel: String
    var isDir = false
    var size: Int64 = 0
    var modified: Date?
    var overwrite = false
    var reason = ""
    /// Set when this replaces something the user may want to keep, e.g. a newer file.
    var warning: String? = nil
    /// The reason of an op made only to look at a file the sync leaves alone.
    static let notCopied = "Not copied"
}

struct SyncPlan: Identifiable {
    var id = UUID()
    var mode: SyncMode
    var a: Endpoint
    var b: Endpoint
    var ops: [SyncOp]
    /// Set for a copy of picked items: the title it gets in Activity. nil for a sync of two folders.
    var title: String? = nil
    var kind = Activity.sync
    /// Files that differ but that the rules leave alone.
    var skipped: [SkippedFile] = []
    /// Everything compared, for the preview; empty for syncs that run without one.
    var rows: [CompareRow] = []
    func files(to s: Side) -> [SyncOp] { ops.filter { $0.to == s && !$0.isDir } }
    func bytes(to s: Side) -> Int64 { files(to: s).reduce(0) { $0 + $1.size } }
    var summary: String {
        var parts: [String] = []
        for (s, arrow) in [(Side.b, "→"), (.a, "←")] where !files(to: s).isEmpty {
            parts.append("\(arrow) \(files(to: s).count) files, \(fmtBytes(bytes(to: s)))")
        }
        let dirs = ops.filter(\.isDir).count
        if dirs > 0 { parts.append("\(dirs) new folders") }
        return parts.isEmpty ? "Nothing to copy" : parts.joined(separator: "  ·  ")
    }
}

/// A finished step plus where the file it replaced was saved, so it can be put back.
struct Applied: Codable {
    var op: SyncOp
    var backup: String?
}

struct SyncRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// Locations of A and B; nil means this Mac's disk.
    var aBookmarkID: UUID?
    var bookmarkID: UUID?
    var title: String
    // Roots of A and B (names kept so records saved before A could be a server still load).
    var localRoot: String
    var remoteRoot: String
    var applied: [Applied] = []
    var rolledBack = false
}

func fmtBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// Passwords live in the login Keychain, never in the bookmarks file.
enum Keychain {
    // Earlier names of the app (Techno Goose was Technoduck, before that Ferry): passwords stay saved under them.
    private static let services = ["Technoduck", "Ferry"]
    private static func query(_ b: Bookmark, _ service: String = services[0]) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: b.id.uuidString]
    }
    static func get(_ b: Bookmark) -> String {
        for s in services {
            var q = query(b, s); q[kSecReturnData as String] = true
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return String(decoding: d, as: UTF8.self) }
        }
        return ""
    }
    static func set(_ b: Bookmark, _ pw: String) {
        for s in services { SecItemDelete(query(b, s) as CFDictionary) }
        guard !pw.isEmpty else { return }
        var q = query(b); q[kSecValueData as String] = Data(pw.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Parses `ls -l` style lines, as sent by FTP LIST and sftp `ls -l`.
func parseUnixListing(_ text: String, dir: String) -> [RemoteFile] {
    let monthFmt = DateFormatter(); monthFmt.locale = Locale(identifier: "en_US_POSIX")
    let year = Calendar.current.component(.year, from: Date())
    return text.split(whereSeparator: \.isNewline).compactMap { raw in
        let line = String(raw)
        guard let first = line.first, "-dl".contains(first) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9, let size = Int64(parts[4]) else { return nil }
        var name = String(parts[8])
        if first == "l", let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
        if name == "." || name == ".." { return nil }
        let stamp = "\(parts[5]) \(parts[6]) \(parts[7])"
        var date: Date?
        if parts[7].contains(":") { monthFmt.dateFormat = "MMM d HH:mm yyyy"; date = monthFmt.date(from: "\(stamp) \(year)") }
        else { monthFmt.dateFormat = "MMM d yyyy"; date = monthFmt.date(from: stamp) }
        return RemoteFile(name: name, path: joinPath(dir, name), isDir: first == "d" || first == "l", size: size, modified: date, permissions: String(parts[0]), isLink: first == "l")
    }
}

func joinPath(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }
func parentPath(_ p: String) -> String {
    let parent = (p as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
}
