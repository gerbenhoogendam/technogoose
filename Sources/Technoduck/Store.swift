import Foundation
import AppKit
import UniformTypeIdentifiers

/// One file browser. Shows this Mac's disk or a server; without a location it offers the bookmarks.
@MainActor @Observable final class Pane: Identifiable {
    let id = UUID()
    var service: FileService?
    var bookmark: Bookmark?
    /// The folder this location starts in.
    var home = "/"
    var path = "/"
    var files: [RemoteFile] = []
    var selection = Set<RemoteFile.ID>()
    var history: [String] = []
    var busy = false
    var error: String?
    /// Folder path → whether its computed size is complete.
    var sized: [String: Bool] = [:]
    var sizing = false
    @ObservationIgnored private var sizeTask: Task<Void, Never>?

    init(service: FileService? = nil) { self.service = service }

    var selected: [RemoteFile] { files.filter { selection.contains($0.id) } }
    var isLocal: Bool { service is LocalService }
    var title: String { service == nil ? "No Location" : bookmark?.title ?? "This Mac" }
    /// Identifies the location for favorites and undo: nil is this Mac's disk.
    var locationID: UUID? { isLocal ? nil : bookmark?.id }
    var endpoint: Endpoint? { service.map { Endpoint(service: $0, root: path, location: locationID, bookmark: bookmark) } }

    func open(_ dir: String, remember: Bool = true) async {
        guard let service else { return }
        busy = true
        do {
            let list = try await service.list(dir)
            if remember, dir != path { history.append(path) }
            // Listing sizes of folders (often 4096) mean nothing; the real totals are measured below.
            files = list.map { var f = $0; if f.isDir { f.size = 0 }; return f }
            path = dir; error = nil
            measure()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    func back() async { if let p = history.popLast() { await open(p, remember: false) } }
    func refresh() async { await open(path, remember: false) }
    func close() {
        sizeTask?.cancel(); sizing = false
        service = nil; bookmark = nil; files = []; history = []; selection = []; sized = [:]; error = nil
    }

    /// Works out every subfolder's total size in the background, one folder at a time.
    private func measure() {
        sizeTask?.cancel()
        sized = [:]
        guard let service else { return }
        guard UserDefaults.standard.object(forKey: "folderSizes") as? Bool ?? true else { sizing = false; return }  // Settings › Calculate folder sizes
        let dirs = files.filter { $0.isDir && !$0.isLink }.map(\.path)
        sizing = !dirs.isEmpty
        sizeTask = Task {
            for d in dirs {
                let r = await service.folderSize(d)
                if Task.isCancelled { return }
                if let i = files.firstIndex(where: { $0.path == d }) { files[i].size = r.bytes; sized[d] = r.complete }
            }
            sizing = false
        }
    }
}

@MainActor @Observable final class Store {
    enum Tab { case transfers, timeline }

    var bookmarks: [Bookmark] = [] { didSet { libraryChanged(before: Library(bookmarks: oldValue, favorites: favorites)) } }
    var favorites: [Favorite] = [] { didSet { libraryChanged(before: Library(bookmarks: bookmarks, favorites: oldValue)) } }
    var panes: [Pane] = []
    var activeID: UUID?
    var transfers: [Transfer] = []
    var log: [LogEvent] = []
    var records: [SyncRecord] = []
    var showInspector = false
    var inspectorTab = Tab.transfers
    var showHidden = UserDefaults.standard.bool(forKey: "showHidden") { didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") } }
    var iCloud = !isDemo && UserDefaults.standard.bool(forKey: "iCloudSync")
    var message = ""
    var planning = false
    var plan: SyncPlan?
    /// The two panes the open sync preview compares, for its auto-upload switch.
    var planPanes: (Pane, Pane)?
    var rules = SyncRules.load() { didSet { rules.save() } }
    /// The last sync or copy, offered as Undo in the status bar while it can still be undone.
    var lastUndo: UUID?
    /// Top and bottom instead of side by side; only with two panes.
    var stacked = UserDefaults.standard.bool(forKey: "stackedPanes") { didSet { UserDefaults.standard.set(stacked, forKey: "stackedPanes") } }
    var theme = Theme(rawValue: ProcessInfo.processInfo.environment["TECHNODUCK_THEME"] ?? UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system {
        didSet { if !isDemo { UserDefaults.standard.set(theme.rawValue, forKey: "theme") } }
    }
    // Settings (Techno Goose › Settings…).
    var folderSizes = UserDefaults.standard.object(forKey: "folderSizes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(folderSizes, forKey: "folderSizes"); Task { await refreshAll() } }  // Pane.measure reads the key
    }
    var autoShowActivity = UserDefaults.standard.object(forKey: "autoShowActivity") as? Bool ?? true { didSet { UserDefaults.standard.set(autoShowActivity, forKey: "autoShowActivity") } }
    var doneSound = UserDefaults.standard.bool(forKey: "doneSound") { didSet { UserDefaults.standard.set(doneSound, forKey: "doneSound") } }
    /// How many syncs and copies can be undone; older backups are deleted.
    var undoLimit = UserDefaults.standard.object(forKey: "undoLimit") as? Int ?? 30 { didSet { UserDefaults.standard.set(undoLimit, forKey: "undoLimit") } }
    var appIcon = AppIcon(rawValue: UserDefaults.standard.string(forKey: "appIcon") ?? "") ?? .goggles {
        didSet { UserDefaults.standard.set(appIcon.rawValue, forKey: "appIcon"); appIcon.apply() }
    }

    private static let support = URL(fileURLWithPath: homeDir).appendingPathComponent("Library/Application Support")
    // Folders keep the app's earlier name, Technoduck, so bookmarks, undo backups and iCloud sync carry over.
    private let dir = support.appendingPathComponent("Technoduck")
    private var backups: URL { dir.appendingPathComponent("Backups") }
    private let editDir = URL(fileURLWithPath: homeDir).appendingPathComponent("Library/Caches/Technoduck/Edit")
    private let cloudDir = URL(fileURLWithPath: homeDir).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Technoduck")
    private var cloudFile: URL { cloudDir.appendingPathComponent("library.json") }
    var libraryBackups: URL { (iCloud ? cloudDir : dir).appendingPathComponent("Bookmark Backups") }

    @ObservationIgnored private var loading = true
    @ObservationIgnored private var applyingCloud = false
    @ObservationIgnored private var cloudStamp: Date?
    @ObservationIgnored private var cloudWatcher: FolderWatcher?
    @ObservationIgnored private var watchers: [UUID: (path: String, watcher: FolderWatcher)] = [:]
    @ObservationIgnored private var autoBusy = Set<UUID>()
    @ObservationIgnored private var autoAgain = Set<UUID>()
    private struct Edit { let remote: String; let location: UUID?; let bookmark: Bookmark?; let pane: Pane; var stamp: Date? }
    @ObservationIgnored private var edits: [String: Edit] = [:]
    @ObservationIgnored private var editWatcher: FolderWatcher?

    init() {
        let old = Self.support.appendingPathComponent("Ferry/bookmarks.json")  // where bookmarks lived before the rename
        bookmarks = load("bookmarks.json") ?? (try? JSONDecoder().decode([Bookmark].self, from: Data(contentsOf: old)))
            ?? [Bookmark(nickname: "Home Folder", proto: .local, port: 0, path: homeDir)]
        favorites = load("favorites.json") ?? []
        log = load("log.json") ?? []
        records = load("syncs.json") ?? []
        loading = false
        save(bookmarks, "bookmarks.json")
        if iCloud { readCloud(); watchCloud() }
        updateWatchers()
        let local = Pane(service: LocalService(root: homeDir)), empty = Pane()
        panes = [local, empty]
        activeID = empty.id  // so the first bookmark you click opens on the right
        Task { await local.open(homeDir, remember: false) }
    }
    private func load<T: Decodable>(_ name: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name))) }
    private func save<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    func visible(_ files: [RemoteFile]) -> [RemoteFile] { showHidden ? files : files.filter { !$0.name.hasPrefix(".") } }

    // MARK: Panes

    var active: Pane? { panes.first { $0.id == activeID } ?? panes.first }

    func addPane() {
        guard panes.count < 4 else { return }
        let p = Pane(); panes.append(p); activeID = p.id
    }
    func closePane(_ p: Pane) {
        guard panes.count > 1 else { return }
        p.close(); panes.removeAll { $0 === p }
        if activeID == p.id { activeID = panes.last?.id }
    }
    func movePane(_ id: UUID, to target: Pane) {
        guard let from = panes.firstIndex(where: { $0.id == id }), let to = panes.firstIndex(where: { $0 === target }), from != to else { return }
        panes.insert(panes.remove(at: from), at: to)
    }
    func refreshAll() async { for p in panes { await p.refresh() } }

    /// Where a bookmark opened from the sidebar goes: the active pane if it's empty, else any empty pane, else the active pane.
    private var connectTarget: Pane {
        if let a = active, a.service == nil { return a }
        return panes.first { $0.service == nil } ?? active ?? panes[0]
    }

    func connect(_ b: Bookmark, password: String? = nil, in pane: Pane? = nil, at path: String? = nil) async {
        let p = pane ?? connectTarget
        activeID = p.id
        let svc = makeService(b, password: password ?? Keychain.get(b))
        p.busy = true; message = "Connecting to \(b.title)…"
        do {
            let start = try await svc.start()
            p.close()
            p.service = svc; p.bookmark = b; p.home = start
            message = ""
            await p.open(path ?? start, remember: false)
            if path != nil, p.error != nil { await p.open(start, remember: false) }
        } catch {
            p.busy = false
            message = "Connection failed: \(error.localizedDescription)"
        }
    }
    func openLocal(in pane: Pane? = nil, at path: String = homeDir) async {
        let p = pane ?? connectTarget
        activeID = p.id
        p.close()
        p.service = LocalService(root: homeDir); p.home = homeDir
        await p.open(path, remember: false)
    }

    /// The service for a saved location, connected or not. nil is this Mac's disk.
    func service(for id: UUID?) -> FileService? {
        guard let id else { return LocalService(root: homeDir) }
        if let s = panes.first(where: { $0.locationID == id })?.service { return s }
        return bookmarks.first { $0.id == id }.map { makeService($0, password: Keychain.get($0)) }
    }
    func excludes(_ e: Endpoint) -> [String] {
        guard let b = e.bookmark else { return [] }
        return (bookmarks.first { $0.id == b.id } ?? b).excludeList
    }

    // MARK: Favorites and start folders

    func canFavorite(_ p: Pane) -> Bool { p.isLocal || bookmarks.contains { $0.id == p.bookmark?.id } }
    func favorite(_ p: Pane, _ path: String) -> Favorite? { favorites.first { $0.bookmarkID == p.locationID && $0.path == path } }
    func toggleFavorite(_ p: Pane, _ path: String) {
        if let f = favorite(p, path) { favorites.removeAll { $0.id == f.id } }
        else if canFavorite(p) { favorites.append(Favorite(bookmarkID: p.locationID, path: path)) }
    }
    /// Opens a favorite in a pane already showing its location (the active one first), else like a bookmark.
    func open(_ f: Favorite) async {
        let showing = [active].compactMap { $0 } + panes
        if let p = showing.first(where: { $0.service != nil && $0.locationID == f.bookmarkID }) {
            activeID = p.id; await p.open(f.path); return
        }
        guard let id = f.bookmarkID else { await openLocal(at: f.path); return }
        guard let b = bookmarks.first(where: { $0.id == id }) else { message = "The server of this favorite was deleted."; return }
        await connect(b, at: f.path)
    }

    func canSetStart(_ p: Pane) -> Bool { bookmarks.contains { $0.id == p.bookmark?.id } }
    /// Makes `path` the folder this pane's bookmark opens in.
    func setStartFolder(_ path: String, for p: Pane) {
        guard let i = bookmarks.firstIndex(where: { $0.id == p.bookmark?.id }) else { return }
        bookmarks[i].path = path; p.bookmark?.path = path; p.home = path
        message = "\(bookmarks[i].title) now starts in \(path)"
    }

    // MARK: Timeline

    func addLog(_ e: LogEvent) {
        log.append(e)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        save(log, "log.json")
    }
    func canUndo(_ id: UUID) -> Bool { records.contains { $0.id == id && !$0.rolledBack } }

    // MARK: Copy, sync, undo

    /// Copies `items`, which sit in `src.root`, into `dest`'s current folder.
    func copy(_ items: [RemoteFile], from src: Endpoint, to dest: Pane) async {
        guard let dst = dest.endpoint, !items.isEmpty else { return }
        if src.root == dst.root, src.location == dst.location, (src.service is LocalService) == (dst.service is LocalService) { return }  // onto itself
        let ex = excludes(src) + excludes(dst)  // applies inside folders; an item you pick yourself is always copied
        message = "Preparing copy…"
        do {
            var a: [String: RemoteFile] = [:], b: [String: RemoteFile] = [:]
            for item in items {
                a[item.name] = item
                if item.isDir { for (k, v) in try await walk(src.service, item.path, hidden: true, strict: true, exclude: ex).files { a[item.name + "/" + k] = v } }
                guard let d = dest.files.first(where: { $0.name == item.name }) else { continue }
                b[item.name] = d
                if d.isDir { for (k, v) in try await walk(dst.service, d.path, hidden: true, strict: true, exclude: ex).files { b[item.name + "/" + k] = v } }
            }
            message = ""
            let p = SyncPlan(mode: .upload, a: src, b: dst, ops: makePlan(local: a, remote: b, mode: .upload, force: true),
                             title: "Copied " + (items.count == 1 ? items[0].name : "\(items.count) items") + " to \(dest.title)",
                             kind: dst.service is LocalService ? .download : .upload)
            // Replacing files: show what first. Only new files: just copy, the status bar offers Undo.
            if p.ops.contains(where: \.overwrite) { planPanes = nil; plan = p } else { await run(p, title: p.title!, kind: p.kind) }
        } catch { message = "Copy failed: \(error.localizedDescription)" }
    }

    /// Files dropped from Finder or from a pane showing this Mac.
    func drop(urls: [URL], into pane: Pane) async {
        for (parent, group) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent().path }) {
            let items = group.map { u in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return RemoteFile(name: u.lastPathComponent, path: u.path, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
            }
            await copy(items, from: Endpoint(service: LocalService(root: parent), root: parent), to: pane)
        }
    }
    /// Server items dragged from another pane ("technoduck-item:<pane>:<path>"), or a pane header ("technoduck-pane:<pane>").
    func drop(refs: [String], into pane: Pane) async {
        if let id = refs.first(where: { $0.hasPrefix("technoduck-pane:") }).flatMap({ UUID(uuidString: String($0.dropFirst(16))) }) {
            movePane(id, to: pane); return
        }
        var bySource: [UUID: Set<String>] = [:]
        for r in refs where r.hasPrefix("technoduck-item:") {
            let rest = r.dropFirst(16)
            guard let colon = rest.firstIndex(of: ":"), let id = UUID(uuidString: String(rest[..<colon])) else { continue }
            bySource[id, default: []].insert(String(rest[rest.index(after: colon)...]))
        }
        for (id, paths) in bySource {
            guard let src = panes.first(where: { $0.id == id }), let e = src.endpoint else { continue }
            await copy(src.files.filter { paths.contains($0.path) }, from: e, to: pane)
        }
    }

    /// Compares two panes' folders; a dry run only shows the plan.
    func sync(_ mode: SyncMode, _ left: Pane, _ right: Pane, dryRun: Bool) async {
        guard let a = left.endpoint, let b = right.endpoint else { return }
        rememberPair(a, b)
        if dryRun { planPanes = (left, right) }
        await sync(mode, a, b, dryRun: dryRun)
    }
    /// `auto` runs quietly for auto-upload.
    func sync(_ mode: SyncMode, _ a: Endpoint, _ b: Endpoint, dryRun: Bool, auto: Bool = false) async {
        let hidden = showHidden, ex = excludes(a) + excludes(b)
        planning = true; message = auto ? "" : "Comparing \(a.root) with \(b.root)…"
        defer { planning = false }
        do {
            async let l = walk(a.service, a.root, hidden: hidden, strict: true, limit: 100_000, exclude: ex)
            async let r = walk(b.service, b.root, hidden: hidden, strict: true, limit: 100_000, exclude: ex)
            let (lw, rw) = try await (l, r)
            guard lw.complete, rw.complete else { throw ServiceError("More than 100,000 files — pick a smaller folder.") }
            var (ops, skipped) = planSync(local: lw.files, remote: rw.files, mode: mode, rules: rules)
            if !auto { (ops, skipped) = await dropSameContent(ops, skipped, a, b) }
            var p = SyncPlan(mode: mode, a: a, b: b, ops: ops, skipped: skipped)
            message = ""
            if dryRun {
                if let open = plan, open.title == nil { p.id = open.id }  // a new direction in an open preview updates it in place
                plan = p
            }
            else if p.ops.isEmpty { if !auto { message = "Already in sync — nothing to copy." } }
            else { await run(p, title: (auto ? "Auto-sync " : "Sync ") + mode.phrase(a, b), kind: .sync, quiet: auto) }
        } catch { message = "Compare failed: \(error.localizedDescription)" }
    }

    /// Files whose size matches and only the date is newer are checked byte for byte; identical ones are left out.
    /// Servers often set their own date on upload, so this keeps a sync from "replacing" files with themselves.
    // shortcut: only up to 50 files of 5 MB each are checked; past that the date decides, as before.
    private func dropSameContent(_ ops: [SyncOp], _ skipped: [SkippedFile], _ a: Endpoint, _ b: Endpoint) async -> ([SyncOp], [SkippedFile]) {
        let check = ops.filter { $0.overwrite && $0.reason == "Newer" && $0.size <= 5_000_000 }
        guard !check.isEmpty, check.count <= 50 else { return (ops, skipped) }
        var same = Set<UUID>()
        for (n, op) in check.enumerated() {
            message = "Checking contents of files with a newer date (\(n + 1) of \(check.count))…"
            if let v = try? await fetchVersions(op, a, b), v.old == v.new { same.insert(op.id) }
        }
        message = ""
        return (ops.filter { !same.contains($0.id) },
                skipped + ops.filter { same.contains($0.id) }.map { SkippedFile(rel: $0.rel, why: "Same contents, only the date differs") })
    }

    /// `undoable` false skips the backups of replaced files (for backup snapshots).
    func run(_ p: SyncPlan, title: String, kind: Activity = .sync, quiet: Bool = false, undoable: Bool = true) async {
        var rec = SyncRecord(aBookmarkID: p.a.location, bookmarkID: p.b.location, title: title, localRoot: p.a.root, remoteRoot: p.b.root)
        let engine = SyncEngine(a: p.a.service, b: p.b.service, aRoot: p.a.root, bRoot: p.b.root,
                                backups: undoable ? backups.appendingPathComponent(rec.id.uuidString) : nil)
        let t = Transfer(kind: kind, name: title, detail: p.summary)
        transfers.insert(t, at: 0)
        if !quiet && autoShowActivity { showInspector = true; inspectorTab = .transfers }
        var errors: [String] = [], bytes: Int64 = 0
        for (n, op) in p.ops.enumerated() {
            do { rec.applied.append(try await engine.apply(op)); bytes += op.size } catch { errors.append("\(op.rel): \(error.localizedDescription)") }
            t.progress = Double(n + 1) / Double(p.ops.count)
        }
        let canUndo = undoable && !rec.applied.isEmpty
        if canUndo {
            records.append(rec)
            while records.count > undoLimit { try? FileManager.default.removeItem(at: backups.appendingPathComponent(records.removeFirst().id.uuidString)) }
            save(records, "syncs.json")
            t.recordID = rec.id
            if !quiet {
                lastUndo = rec.id
                // Edit › Undo (⌘Z) in the main window; a no-op if it was undone from Activity first.
                let id = rec.id, um = (NSApp.delegate as? AppDelegate)?.window?.undoManager
                um?.registerUndo(withTarget: self) { s in Task { await s.rollback(id) } }
                um?.setActionName(title)
            }
        }
        t.state = errors.isEmpty ? .done : .failed("\(errors.count) of \(p.ops.count) failed — \(errors[0])")
        if doneSound && !quiet { NSSound(named: errors.isEmpty ? "Glass" : "Basso")?.play() }
        for id in Set([p.a.bookmark?.id, p.b.bookmark?.id].compactMap { $0 }) {
            addLog(LogEvent(bookmarkID: id, kind: kind, title: errors.isEmpty ? title : "\(title) (\(errors.count) failed)",
                            detail: "\(p.a.root)  ⇄  \(p.b.root)\n\(p.summary)", bytes: bytes, recordID: canUndo ? rec.id : nil,
                            items: rec.applied.map { ($0.op.to == .b ? "→ " : "← ") + $0.op.rel + ($0.op.isDir ? "/" : "") }))
        }
        await refreshAll()
    }

    /// Puts back what a sync or copy changed: replaced files come from the backup, new files go to the Trash (this Mac) or are deleted (server).
    func rollback(_ id: UUID) async {
        guard let rec = records.first(where: { $0.id == id }), !rec.rolledBack else { return }
        guard let a = service(for: rec.aBookmarkID), let b = service(for: rec.bookmarkID) else {
            message = "Its server bookmark was deleted, so this can't be undone."; return
        }
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].rolledBack = true; save(records, "syncs.json") }  // first, so a second click can't run it twice
        let dir = backups.appendingPathComponent(rec.id.uuidString)
        let engine = SyncEngine(a: a, b: b, aRoot: rec.localRoot, bRoot: rec.remoteRoot, backups: dir)
        let t = Transfer(kind: .rollback, name: "Undo: \(rec.title)", detail: "\(rec.applied.count) changes")
        transfers.insert(t, at: 0); if autoShowActivity { showInspector = true }
        var errors: [String] = []
        for (n, step) in rec.applied.reversed().enumerated() {
            do { try await engine.undo(step) } catch { errors.append("\(step.op.rel): \(error.localizedDescription)") }
            t.progress = Double(n + 1) / Double(rec.applied.count)
        }
        if errors.isEmpty { try? FileManager.default.removeItem(at: dir) }
        message = errors.isEmpty ? "Undone: \(rec.title)" : "Undo of \(rec.title) partly failed — see Activity"
        t.state = errors.isEmpty ? .done : .failed("\(errors.count) could not be undone — \(errors[0]). Backups kept in \(dir.path)")
        for bid in Set([rec.aBookmarkID, rec.bookmarkID].compactMap { $0 }) {
            addLog(LogEvent(bookmarkID: bid, kind: .rollback, title: "Undid \(rec.title)",
                            detail: errors.isEmpty ? "Restored \(rec.applied.count) changes" : "\(errors.count) could not be undone; backups kept in \(dir.path)",
                            items: errors))
        }
        await refreshAll()
    }

    /// Disk space taken by the backups that make undo possible.
    func undoBackupSize() -> Int64 {
        let files = FileManager.default.enumerator(at: backups, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
    }
    /// Forgets every undo step and deletes its backups. Files on disk and servers are left as they are.
    func clearUndoHistory() {
        try? FileManager.default.removeItem(at: backups)
        records = []; save(records, "syncs.json")
    }

    // MARK: One-click backup

    /// Asks where backups of `b` go and remembers it.
    @discardableResult func chooseBackupFolder(for b: Bookmark) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use for Backups"; p.message = "Where should backups of \(b.title) go?"
        guard p.runModal() == .OK, let u = p.url, let i = bookmarks.firstIndex(where: { $0.id == b.id }) else { return nil }
        bookmarks[i].backupFolder = u.path
        return u.path
    }

    /// Copies the bookmark's start folder into <backup folder>/<name>/<date and time>. The previous snapshot is
    /// copied first (APFS clones files, so that's instant and takes no space) and only what changed is downloaded.
    func backUp(_ b: Bookmark) async {
        guard let saved = bookmarks.first(where: { $0.id == b.id }) else { return }
        guard let folder = saved.backupFolder ?? chooseBackupFolder(for: saved) else { return }
        let fm = FileManager.default
        let svc = panes.first { $0.bookmark?.id == b.id }?.service ?? makeService(saved, password: Keychain.get(saved))
        let base = URL(fileURLWithPath: folder).appendingPathComponent(saved.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dest = base.appendingPathComponent(stamp.string(from: Date()))
        message = "Backing up \(saved.title)…"
        do {
            let root = try await svc.start()
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            if let previous = (try? fm.contentsOfDirectory(atPath: base.path))?.filter({ !$0.hasPrefix(".") }).sorted().last {
                try fm.copyItem(at: base.appendingPathComponent(previous), to: dest)
            } else {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            let disk = LocalService(root: dest.path)
            let server = try await walk(svc, root, hidden: true, strict: true, exclude: saved.excludeList).files
            var local = try await walk(disk, dest.path, hidden: true, strict: true).files
            // Mirror the server: drop what it no longer has (deepest first), then fetch what's new or changed.
            for rel in local.keys.sorted(by: >) where server[rel]?.isDir != local[rel]?.isDir {
                try? fm.removeItem(atPath: joinPath(dest.path, rel)); local[rel] = nil
            }
            let p = SyncPlan(mode: .download, a: Endpoint(service: disk, root: dest.path),
                             b: Endpoint(service: svc, root: root, location: saved.proto == .local ? nil : saved.id, bookmark: saved),
                             ops: makePlan(local: local, remote: server, mode: .download))
            await run(p, title: "Backup of \(saved.title)", kind: .download, undoable: false)
            message = "Backed up \(saved.title) to \(dest.path)"
        } catch {
            try? fm.removeItem(at: dest)
            message = "Backup of \(saved.title) failed: \(error.localizedDescription)"
        }
    }

    // MARK: Auto-upload

    /// The folder pair a local ⇄ server sync used, remembered on the server's bookmark for auto-upload.
    private func rememberPair(_ a: Endpoint, _ b: Endpoint) {
        let (local, server) = a.service is LocalService ? (a, b) : (b, a)
        guard local.service is LocalService, !(server.service is LocalService),
              let i = bookmarks.firstIndex(where: { $0.id == server.bookmark?.id }),
              bookmarks[i].syncLocal != local.root || bookmarks[i].syncRemote != server.root else { return }
        bookmarks[i].syncLocal = local.root; bookmarks[i].syncRemote = server.root
    }
    /// The bookmark auto-upload can pair for these two panes: exactly one shows this Mac, the other a saved server.
    func pairable(_ l: Pane, _ r: Pane) -> Bookmark? {
        guard l.service != nil, r.service != nil, l.isLocal != r.isLocal else { return nil }
        let server = l.isLocal ? r : l
        return bookmarks.first { $0.id == server.bookmark?.id }
    }
    func autoSyncOn(_ l: Pane, _ r: Pane) -> Bool {
        guard let b = pairable(l, r) else { return false }
        let local = l.isLocal ? l : r, server = l.isLocal ? r : l
        return b.autoSync == true && b.syncLocal == local.path && b.syncRemote == server.path
    }
    func setAutoSync(_ on: Bool, _ l: Pane, _ r: Pane) {
        guard let b = pairable(l, r), let i = bookmarks.firstIndex(where: { $0.id == b.id }) else { return }
        if on { bookmarks[i].syncLocal = (l.isLocal ? l : r).path; bookmarks[i].syncRemote = (l.isLocal ? r : l).path }
        bookmarks[i].autoSync = on
    }

    /// One watcher per bookmark with auto-upload on; they run while the app is open, connected or not.
    func updateWatchers() {
        var want: [UUID: String] = [:]
        for b in bookmarks where b.autoSync == true && b.syncRemote != nil { want[b.id] = b.syncLocal }
        for (id, w) in watchers where want[id] != w.path { watchers[id] = nil }
        for (id, path) in want where watchers[id] == nil {
            if let w = FolderWatcher(path, onChange: { [weak self] in MainActor.assumeIsolated { self?.autoUpload(id) } }) { watchers[id] = (path, w) }
        }
    }
    private func autoUpload(_ id: UUID) {
        guard let b = bookmarks.first(where: { $0.id == id }), let lp = b.syncLocal, let rp = b.syncRemote, let svc = service(for: id) else { return }
        if autoBusy.contains(id) { autoAgain.insert(id); return }  // changes during a run get their own run afterwards
        autoBusy.insert(id)
        Task {
            repeat {
                autoAgain.remove(id)
                await sync(.upload, Endpoint(service: LocalService(root: lp), root: lp), Endpoint(service: svc, root: rp, location: id, bookmark: b), dryRun: false, auto: true)
            } while autoAgain.contains(id)
            autoBusy.remove(id)
        }
    }

    // MARK: Edit a server file in a local app

    /// Downloads to a private folder and opens it in its default app; every save is uploaded back (and can be undone).
    func edit(_ f: RemoteFile, in pane: Pane) async {
        guard let svc = pane.service, !f.isDir else { return }
        let url = editDir.appendingPathComponent(UUID().uuidString).appendingPathComponent(f.name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await svc.download(f.path, to: url)
            edits[url.path] = Edit(remote: f.path, location: pane.locationID, bookmark: pane.bookmark, pane: pane, stamp: modified(url.path))
            if editWatcher == nil { editWatcher = FolderWatcher(editDir.path, latency: 0.5) { [weak self] in MainActor.assumeIsolated { self?.editsChanged() } } }
            NSWorkspace.shared.open(url)
            message = "Editing \(f.name) — every save is uploaded to \(pane.title)."
        } catch { message = "Could not open \(f.name): \(error.localizedDescription)" }
    }

    private func editsChanged() {
        for (path, e) in edits {
            guard let m = modified(path), m != e.stamp else { continue }
            edits[path]?.stamp = m
            let name = (path as NSString).lastPathComponent
            // A saved bookmark works even after disconnecting; a quick connection needs its pane.
            guard let svc = e.location.flatMap({ service(for: $0) }) ?? e.pane.service else {
                message = "\(name) was saved, but its server isn't connected — reconnect and save again."; continue
            }
            let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
            let dir = (path as NSString).deletingLastPathComponent
            let p = SyncPlan(mode: .upload, a: Endpoint(service: LocalService(root: dir), root: dir),
                             b: Endpoint(service: svc, root: parentPath(e.remote), location: e.location, bookmark: e.bookmark),
                             ops: [SyncOp(to: .b, rel: name, size: size, overwrite: true, reason: "Edited")])
            Task { await run(p, title: "Saved \(name)", kind: .upload, quiet: true) }
        }
    }
    private func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

    // MARK: Bookmarks in iCloud Drive, daily backups

    private func libraryChanged(before: Library) {
        guard !loading else { return }
        save(bookmarks, "bookmarks.json"); save(favorites, "favorites.json")
        updateWatchers()
        backUpLibrary(before)
        if !applyingCloud { writeCloud() }  // changes that came from iCloud aren't echoed back
    }

    /// Keeps one file per day with the bookmarks as they were before that day's first change; the newest 30 stay.
    private func backUpLibrary(_ lib: Library) {
        let fm = FileManager.default, day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let file = libraryBackups.appendingPathComponent("Bookmarks \(day.string(from: Date())).json")
        guard !fm.fileExists(atPath: file.path) else { return }
        try? fm.createDirectory(at: libraryBackups, withIntermediateDirectories: true)
        try? JSONEncoder().encode(lib).write(to: file, options: .atomic)
        let all = ((try? fm.contentsOfDirectory(atPath: libraryBackups.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for old in all.dropLast(30) { try? fm.removeItem(at: libraryBackups.appendingPathComponent(old)) }
    }

    func restoreLibrary() {
        let p = NSOpenPanel()
        p.directoryURL = libraryBackups; p.allowedContentTypes = [.json]; p.prompt = "Restore"
        p.message = "Pick a bookmarks backup. Your current bookmarks are replaced (and saved in today's backup if there isn't one yet)."
        guard p.runModal() == .OK, let u = p.url else { return }
        guard let lib = try? JSONDecoder().decode(Library.self, from: Data(contentsOf: u)) else { message = "That file isn't a Techno Goose bookmarks backup."; return }
        bookmarks = lib.bookmarks; favorites = lib.favorites
        message = "Restored \(lib.bookmarks.count) bookmarks and \(lib.favorites.count) favorites."
    }

    /// Bookmarks and favorites sync through a file in iCloud Drive; passwords stay in this Mac's Keychain.
    func setICloud(_ on: Bool) {
        if on, !FileManager.default.fileExists(atPath: cloudDir.deletingLastPathComponent().path) {
            message = "iCloud Drive is off on this Mac. Turn it on in System Settings › your Apple Account › iCloud."; return
        }
        iCloud = on
        UserDefaults.standard.set(on, forKey: "iCloudSync")
        if on {
            // Merge with what other Macs already put there, then share the result.
            if let lib = try? JSONDecoder().decode(Library.self, from: Data(contentsOf: cloudFile)) {
                applyingCloud = true
                bookmarks += lib.bookmarks.filter { c in !bookmarks.contains { $0.id == c.id } }
                favorites += lib.favorites.filter { c in !favorites.contains { $0.id == c.id } }
                applyingCloud = false
            }
            writeCloud()
            message = "Bookmarks now sync through iCloud Drive. Passwords stay in each Mac's Keychain."
        }
        watchCloud()
    }
    private func watchCloud() {
        cloudWatcher = nil
        guard iCloud else { return }
        try? FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        cloudWatcher = FolderWatcher(cloudDir.path) { [weak self] in MainActor.assumeIsolated { self?.readCloud() } }
    }
    private func writeCloud() {
        guard iCloud else { return }
        try? FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Library(bookmarks: bookmarks, favorites: favorites)).write(to: cloudFile, options: .atomic)
        cloudStamp = modified(cloudFile.path)
    }
    /// Takes the iCloud copy when another Mac changed it (last change wins).
    private func readCloud() {
        guard iCloud, let m = modified(cloudFile.path), m != cloudStamp,
              let lib = try? JSONDecoder().decode(Library.self, from: Data(contentsOf: cloudFile)) else { return }
        cloudStamp = m
        applyingCloud = true
        bookmarks = lib.bookmarks; favorites = lib.favorites
        applyingCloud = false
    }

    // MARK: Single-pane actions

    func delete(_ items: [RemoteFile], in pane: Pane) async {
        guard let service = pane.service else { return }
        for f in items {
            do { try await service.delete(f) } catch { pane.error = "Could not delete \(f.name): \(error.localizedDescription)"; break }
            if let b = pane.bookmark {
                addLog(LogEvent(bookmarkID: b.id, kind: .delete, title: "Deleted \(f.name)", detail: f.path, bytes: f.isDir ? 0 : f.size))
            }
        }
        await pane.refresh()
    }

    func mkdir(_ name: String, in pane: Pane) async {
        guard let service = pane.service, !name.isEmpty else { return }
        let p = joinPath(pane.path, name)
        do {
            try await service.mkdir(p)
            if let b = pane.bookmark { addLog(LogEvent(bookmarkID: b.id, kind: .mkdir, title: "Created folder \(name)", detail: p)) }
            await pane.refresh()
        } catch { pane.error = error.localizedDescription }
    }
}

/// Turns "sftp://user@host:2222/path" into a bookmark for the connection sheet.
func bookmark(fromQuickConnect text: String) -> Bookmark {
    var b = Bookmark()
    let s = text.trimmingCharacters(in: .whitespaces)
    guard let u = URL(string: s.contains("://") ? s : "sftp://" + s), let host = u.host else { b.host = s; return b }
    switch u.scheme?.lowercased() {
    case "ftp": b.proto = .ftp
    case "ftps": b.proto = .ftps
    case "http", "dav", "webdav": b.proto = .webdav
    case "https", "davs", "webdavs": b.proto = .webdavs
    default: b.proto = .sftp
    }
    b.host = host; b.user = u.user ?? ""; b.port = u.port ?? b.proto.defaultPort; b.path = u.path
    return b
}

/// A Cyberduck .duck bookmark (a plist) as a Techno Goose bookmark; nil for protocols we don't speak (S3, Dropbox…).
func bookmark(fromCyberduck d: [String: Any]) -> Bookmark? {
    let proto: Proto
    switch (d["Protocol"] as? String)?.lowercased() {
    case "sftp": proto = .sftp
    case "ftp": proto = .ftp
    case "ftps": proto = .ftps   // Cyberduck's FTP-SSL is explicit TLS, like ours
    case "dav": proto = .webdav
    case "davs": proto = .webdavs
    default: return nil
    }
    guard let host = d["Hostname"] as? String, !host.isEmpty else { return nil }
    var b = Bookmark()
    b.proto = proto; b.host = host
    b.port = Int(d["Port"] as? String ?? "") ?? (d["Port"] as? Int) ?? proto.defaultPort
    b.user = d["Username"] as? String ?? ""
    b.nickname = d["Nickname"] as? String ?? ""
    b.path = d["Path"] as? String ?? ""
    if let id = (d["UUID"] as? String).flatMap(UUID.init) { b.id = id }   // importing twice finds the same ids
    return b
}

extension Store {
    /// Adds Cyberduck's bookmarks, skipping ones already here. Passwords stay in Cyberduck's Keychain items;
    /// Techno Goose asks for each one on first connect.
    func importCyberduck() {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let folders = ["Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks",
                       "Library/Application Support/Cyberduck/Bookmarks"].map { home.appendingPathComponent($0) }
        var files = folders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "duck" }
        if files.isEmpty {
            let p = NSOpenPanel()
            p.allowsMultipleSelection = true; p.canChooseDirectories = false
            p.allowedContentTypes = [UTType(filenameExtension: "duck") ?? .propertyList]
            p.prompt = "Import"; p.message = "Cyberduck's bookmarks weren't found. Pick .duck files (drag bookmarks out of Cyberduck to get them)."
            guard p.runModal() == .OK else { return }
            files = p.urls
        }
        let found = files.compactMap { u in
            (try? PropertyListSerialization.propertyList(from: Data(contentsOf: u), format: nil) as? [String: Any]).flatMap(bookmark(fromCyberduck:))
        }
        let same = { (a: Bookmark, b: Bookmark) in a.id == b.id || (a.proto == b.proto && a.host == b.host && a.port == b.port && a.user == b.user && a.path == b.path) }
        let new = found.filter { f in !bookmarks.contains { same($0, f) } }
        bookmarks += new
        let skipped = files.count - found.count
        message = "Imported \(new.count) bookmark\(new.count == 1 ? "" : "s") from Cyberduck"
            + (found.count > new.count ? ", \(found.count - new.count) already here" : "")
            + (skipped > 0 ? ", \(skipped) skipped (S3 and other services aren't supported)" : "") + "."
    }
}

// MARK: Demo scenes (for screenshots; only with TECHNODUCK_HOME set)

extension Store {
    /// Puts the window in one of the scenes used for the promo video, using the demo fixtures in TECHNODUCK_HOME.
    func stage(_ scene: String) async {
        guard isDemo, scene != "empty" else { return }
        let servers = bookmarks.filter { $0.proto == .webdav }
        guard servers.count >= 2 else { return }
        await panes[0].open(homeDir + "/Sites/duckpond", remember: false)
        await connect(servers[0], in: panes[1])
        switch scene {
        case "four":
            addPane(); await connect(servers[1], in: panes[2])
            addPane(); await openLocal(in: panes[3], at: homeDir + "/Backups")
        case "dryrun":
            await sync(.upload, panes[0], panes[1], dryRun: true)
        case "timeline":
            await sync(.upload, panes[0], panes[1], dryRun: false)
            showInspector = true; inspectorTab = .timeline
        default: break
        }
        let pick = panes[0].files.filter { ["index.html", "styles.css", "assets"].contains($0.name) }
        panes[0].selection = Set(pick.map(\.id))
        activeID = panes[0].id
    }
}
