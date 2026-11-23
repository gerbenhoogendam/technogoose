import Foundation

/// Everything below `root`, keyed by path relative to it, read level by level.
/// Symlinks are skipped so loops and dangling links can't hurt; `strict` fails when any folder can't be read.
func walk(_ svc: FileService, _ root: String, hidden: Bool, strict: Bool, limit: Int = .max, exclude: [String] = []) async throws -> (files: [String: RemoteFile], complete: Bool) {
    // Relative paths are built from names: listed paths may differ from `root` (e.g. /tmp vs /private/tmp).
    var out: [String: RemoteFile] = [:], level = [(path: root, rel: "")]
    while !level.isEmpty {
        try Task.checkCancellation()
        var next: [(path: String, rel: String)] = []
        for (dir, list) in zip(level, await svc.listMany(level.map(\.path))) {
            guard let list else { if strict { throw ServiceError("Could not list \(dir.path)") }; continue }
            for f in list where !f.isLink && f.name != ".DS_Store" && (hidden || !f.name.hasPrefix(".")) {
                let rel = dir.rel.isEmpty ? f.name : dir.rel + "/" + f.name
                if isExcluded(f.name, rel, exclude) { continue }
                out[rel] = f
                if f.isDir { next.append((f.path, rel)) }
            }
        }
        if out.count > limit { return (out, false) }
        level = next
    }
    return (out, true)
}

/// Shell-style patterns, matched against the name or the relative path ("node_modules", "*.log", "cache/*").
func isExcluded(_ name: String, _ rel: String, _ patterns: [String]) -> Bool {
    patterns.contains { fnmatch($0, name, 0) == 0 || fnmatch($0, rel, 0) == 0 }
}

/// What a sync does with a file that exists on both sides but differs. Set in the Rules panel, used for every sync.
struct SyncRules: Codable, Equatable {
    enum Compare: String, Codable, CaseIterable { case dateAndSize, sizeOnly }
    enum Replace: String, Codable, CaseIterable { case whenDifferent, onlyNewer, never }
    enum Conflict: String, Codable, CaseIterable { case newest, a, b, skip }
    var compare = Compare.dateAndSize
    var replace = Replace.whenDifferent
    var conflict = Conflict.newest

    static func load() -> SyncRules {
        UserDefaults.standard.data(forKey: "syncRules").flatMap { try? JSONDecoder().decode(SyncRules.self, from: $0) } ?? SyncRules()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "syncRules") }
}

/// A file that differs on both sides but that the rules leave alone; the preview lists these.
struct SkippedFile: Identifiable, Hashable {
    var rel: String
    var why: String
    var id: String { rel }
}

/// Decides what to copy; never deletes anything.
/// One way: copy what's missing; a file that differs (size, or the source more than a minute newer) follows `rules.replace`.
/// Both ways: a side that misses something gets a copy; when sizes differ `rules.conflict` picks the winner.
/// `force` copies every file (used for copying a selection).
// shortcut: both-ways ignores same-size edits so files don't ping-pong; add checksums if that matters.
func makePlan(local: [String: RemoteFile], remote: [String: RemoteFile], mode: SyncMode, force: Bool = false, rules: SyncRules = SyncRules()) -> [SyncOp] {
    planSync(local: local, remote: remote, mode: mode, force: force, rules: rules).ops
}

func planSync(local: [String: RemoteFile], remote: [String: RemoteFile], mode: SyncMode, force: Bool = false, rules: SyncRules = SyncRules()) -> (ops: [SyncOp], skipped: [SkippedFile]) {
    var ops: [SyncOp] = [], skipped: [SkippedFile] = []
    func date(_ f: RemoteFile) -> Date { f.modified ?? .distantPast }
    func copy(_ rel: String, _ s: RemoteFile, to side: Side, over d: RemoteFile?) {
        if let d, d.isDir != s.isDir { skipped.append(SkippedFile(rel: rel, why: "A file on one side, a folder on the other")); return }
        if s.isDir { if d == nil { ops.append(SyncOp(to: side, rel: rel, isDir: true, reason: "New folder")) }; return }
        guard let d else { ops.append(SyncOp(to: side, rel: rel, size: s.size, modified: s.modified, reason: "New")); return }
        if force { ops.append(SyncOp(to: side, rel: rel, size: s.size, modified: s.modified, overwrite: true, reason: "Replace")); return }
        let newer = date(s) > date(d).addingTimeInterval(60), older = date(d) > date(s).addingTimeInterval(60)
        let differs = s.size != d.size || (rules.compare == .dateAndSize && newer)
        guard differs else { return }
        switch rules.replace {
        case .never: skipped.append(SkippedFile(rel: rel, why: "Differs, but the rules only add new files"))
        case .onlyNewer where !newer: skipped.append(SkippedFile(rel: rel, why: older ? "The copy there is newer" : "Not newer here"))
        default:
            ops.append(SyncOp(to: side, rel: rel, size: s.size, modified: s.modified, overwrite: true,
                              reason: s.size != d.size ? "Size differs" : "Newer", warning: older ? "The file it replaces is newer" : nil))
        }
    }
    // Sorted, so a folder always comes before what's inside it.
    for rel in Set(local.keys).union(remote.keys).sorted() {
        let l = local[rel], r = remote[rel]
        switch mode {
        case .upload: if let l { copy(rel, l, to: .b, over: r) }
        case .download: if let r { copy(rel, r, to: .a, over: l) }
        case .both:
            guard let l, let r else {
                if let l { copy(rel, l, to: .b, over: nil) }
                if let r { copy(rel, r, to: .a, over: nil) }
                continue
            }
            if l.isDir != r.isDir { skipped.append(SkippedFile(rel: rel, why: "A file on one side, a folder on the other")); continue }
            guard !l.isDir, l.size != r.size else { continue }
            let lm = date(l), rm = date(r)
            let toB = SyncOp(to: .b, rel: rel, size: l.size, modified: l.modified, overwrite: true, reason: "Newer here")
            let toA = SyncOp(to: .a, rel: rel, size: r.size, modified: r.modified, overwrite: true, reason: "Newer there")
            switch rules.conflict {
            case .newest:
                if lm > rm { ops.append(toB) } else if rm > lm { ops.append(toA) }
                else { skipped.append(SkippedFile(rel: rel, why: "Same date, different size: no newest")) }
            case .a: ops.append(SyncOp(to: .b, rel: rel, size: l.size, modified: l.modified, overwrite: true, reason: "This side wins", warning: rm > lm ? "The file it replaces is newer" : nil))
            case .b: ops.append(SyncOp(to: .a, rel: rel, size: r.size, modified: r.modified, overwrite: true, reason: "Other side wins", warning: lm > rm ? "The file it replaces is newer" : nil))
            case .skip: skipped.append(SkippedFile(rel: rel, why: "Changed on both sides: left alone"))
            }
        }
    }
    return (ops, skipped)
}

/// One path in a comparison of two folders: what is on each side and how they differ.
struct CompareRow: Identifiable, Hashable {
    enum Status: Hashable { case same, onlyA, onlyB, newerA, newerB, differs }
    var rel: String
    var a: RemoteFile?
    var b: RemoteFile?
    var status: Status
    /// Why the rules leave it alone, when they do.
    var why: String?
    var id: String { rel }
    var isDir: Bool { (a ?? b)?.isDir ?? false }
}

/// Every file on either side, plus folders that exist on one side only. Folders on both sides aren't listed: their files are.
func compareRows(_ a: [String: RemoteFile], _ b: [String: RemoteFile], skipped: [SkippedFile]) -> [CompareRow] {
    let why = Dictionary(skipped.map { ($0.rel, $0.why) }, uniquingKeysWith: { x, _ in x })
    func date(_ f: RemoteFile) -> Date { f.modified ?? .distantPast }
    return Set(a.keys).union(b.keys).sorted().compactMap { rel in
        let l = a[rel], r = b[rel]
        guard let l, let r else { return CompareRow(rel: rel, a: l, b: r, status: l == nil ? .onlyB : .onlyA, why: why[rel]) }
        if l.isDir && r.isDir { return nil }
        let newerA = date(l) > date(r).addingTimeInterval(60), newerB = date(r) > date(l).addingTimeInterval(60)
        let status: CompareRow.Status
        if l.isDir != r.isDir { status = .differs }
        else if why[rel] == sameContents { status = .same }
        else if newerA { status = .newerA } else if newerB { status = .newerB }
        else { status = l.size == r.size ? .same : .differs }
        return CompareRow(rel: rel, a: l, b: r, status: status, why: why[rel])
    }
}
let sameContents = "Same contents, only the date differs"

/// The plan with the choices made in the preview: `side` says where each row's file goes (nil: left alone).
/// Steps the rules already planned are kept as they are; a folder a file needs on the other side is created first.
func applyChoices(_ rows: [CompareRow], _ planned: [SyncOp], side: (CompareRow) -> Side?) -> [SyncOp] {
    let byRel = Dictionary(planned.map { ($0.rel, $0) }, uniquingKeysWith: { x, _ in x })
    var out: [SyncOp] = []
    for r in rows {
        guard let to = side(r) else { continue }
        if let op = byRel[r.rel], op.to == to { out.append(op); continue }
        guard let src = to == .b ? r.a : r.b else { continue }
        let dst = to == .b ? r.b : r.a
        if src.isDir { if dst == nil { out.append(SyncOp(to: to, rel: r.rel, isDir: true, reason: "New folder")) }; continue }
        let replacesNewer = dst.map { ($0.modified ?? .distantPast) > (src.modified ?? .distantPast).addingTimeInterval(60) } ?? false
        out.append(SyncOp(to: to, rel: r.rel, size: src.size, modified: src.modified, overwrite: dst != nil,
                          reason: "Your choice", warning: replacesNewer ? "The file it replaces is newer" : nil))
    }
    let missing: [Side: Set<String>] = [.a: Set(rows.filter { $0.isDir && $0.a == nil }.map(\.rel)),
                                        .b: Set(rows.filter { $0.isDir && $0.b == nil }.map(\.rel))]
    var have = Set(out.filter(\.isDir).map { "\($0.to.rawValue):\($0.rel)" })
    for op in out {
        var parent = (op.rel as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if missing[op.to]!.contains(parent), have.insert("\(op.to.rawValue):\(parent)").inserted {
                out.append(SyncOp(to: op.to, rel: parent, isDir: true, reason: "New folder"))
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }
    return out.sorted { $0.rel < $1.rel }  // a folder always before what goes in it
}

/// Applies and undoes single steps between any two locations. Every file that gets replaced is saved under `backups` first.
struct SyncEngine {
    let a: FileService, b: FileService
    let aRoot: String, bRoot: String
    /// nil skips backups (and with them undo), as for backup snapshots.
    let backups: URL?

    func service(_ s: Side) -> FileService { s == .a ? a : b }
    func path(_ s: Side, _ rel: String) -> String { joinPath(s == .a ? aRoot : bRoot, rel) }

    func apply(_ op: SyncOp) async throws -> Applied {
        let fm = FileManager.default, from: Side = op.to == .a ? .b : .a
        let dst = service(op.to), dest = path(op.to, op.rel)
        if op.isDir {
            if dst is LocalService { try fm.createDirectory(atPath: dest, withIntermediateDirectories: true) } else { try await dst.mkdir(dest) }
            return Applied(op: op)
        }
        let b = backups?.appendingPathComponent(op.to.rawValue).appendingPathComponent(op.rel)
        if let b { try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var backup: String?
        if dst is LocalService {
            // Checked on disk, not from the plan: a case-insensitive Mac can map two server names to one file.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dest, isDirectory: &isDir) {
                guard !isDir.boolValue else { throw ServiceError("A folder named \(op.rel) is in the way") }
                if let b { try fm.moveItem(atPath: dest, toPath: b.path); backup = b.path } else { try fm.removeItem(atPath: dest) }
            }
            do { try await transfer(service(from), path(from, op.rel), dst, dest) } catch {
                if let backup { try? fm.removeItem(atPath: dest); try? fm.moveItem(atPath: backup, toPath: dest) }
                throw error
            }
            if let m = op.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dest) }
        } else {
            // Some FTP servers leave dotfiles out of listings, so try to save one even when the plan thinks it's new.
            if let b, op.overwrite || (op.rel as NSString).lastPathComponent.hasPrefix(".") {
                do { try await dst.download(dest, to: b); backup = b.path } catch {
                    try? fm.removeItem(at: b)
                    if op.overwrite { throw error }
                }
            }
            try await transfer(service(from), path(from, op.rel), dst, dest)
        }
        return Applied(op: op, backup: backup)
    }

    /// Copies one file between any two locations; server to server goes through a temp file.
    private func transfer(_ src: FileService, _ from: String, _ dst: FileService, _ to: String) async throws {
        if src is LocalService { return try await dst.upload(URL(fileURLWithPath: from), to: to) }
        if dst is LocalService { return try await src.download(from, to: URL(fileURLWithPath: to)) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await src.download(from, to: tmp)
        try await dst.upload(tmp, to: to)
    }

    func undo(_ a: Applied) async throws {
        let fm = FileManager.default, svc = service(a.op.to), dest = path(a.op.to, a.op.rel)
        let file = RemoteFile(name: (dest as NSString).lastPathComponent, path: dest, isDir: a.op.isDir, size: 0)
        if a.op.isDir {
            // Only folders that are still empty go; anything added since stays.
            guard (try? await svc.list(dest))?.isEmpty == true else { return }
            if svc is LocalService { try fm.removeItem(atPath: dest) } else { try await svc.delete(file) }
        } else if let backup = a.backup {
            if svc is LocalService {
                try? fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
                try fm.moveItem(atPath: backup, toPath: dest)
            } else { try await svc.upload(URL(fileURLWithPath: backup), to: dest) }
        } else if svc is LocalService {
            try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
        } else {
            try await svc.delete(file)
        }
    }
}
