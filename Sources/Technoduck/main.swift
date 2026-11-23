import AppKit
import SwiftUI

/// `--screenshot out.png`: open without taking focus, draw ~120 frames (2 s), save the window and quit.
let shotPath: String? = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap { i in
    i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = Store()
    var window: NSWindow!
    var settings: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        store.appIcon.apply()
        NSApp.servicesProvider = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView().environment(store))
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(shotPath == nil ? "Main" : "")
        window.center()
        window.isReleasedWhenClosed = false

        guard let shotPath else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        window.orderFront(nil)
        // `--scene name` stages a demo scene first (see Store.stage); every visible window is saved, sheets as out-1.png, …
        let args = CommandLine.arguments, scene = args.firstIndex(of: "--scene").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if scene == "four" || scene == "timeline" { window.setContentSize(NSSize(width: 1900, height: 900)) }
        Task { @MainActor [self] in
            if let scene { await store.stage(scene) }
            if scene == "settings" { showSettings(nil) }
            try? await Task.sleep(for: .seconds(scene == nil ? 2 : 3))
            let shot = URL(fileURLWithPath: shotPath)
            try? FileManager.default.createDirectory(at: shot.deletingLastPathComponent(), withIntermediateDirectories: true)
            let windows = [window!] + NSApp.windows.filter { $0 !== window && $0.isVisible && ($0.sheetParent != nil || $0 === settings) }
            for (i, w) in windows.enumerated() {
                let view = w.contentView!.superview ?? w.contentView!
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = i == 0 ? shot : shot.deletingPathExtension().appendingPathExtension("\(i).png")
                do { try rep.representation(using: .png, properties: [:])!.write(to: url) }
                catch { fputs("screenshot failed: \(error)\n", stderr); exit(1) }
            }
            exit(0)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// `open -a "Techno Goose" folder [folder]`, or folders dropped on the Dock icon.
    func application(_ app: NSApplication, open urls: [URL]) {
        guard shotPath == nil else { return }  // the screenshot's own path isn't a folder to open
        Task { await store.openFolders(urls) }
    }
    /// Finder › Services › Open in Techno Goose (NSServices in Info.plist): one folder opens, two are compared.
    @objc func openFolders(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        Task { await store.openFolders(urls) }
    }

    @objc func toggleHidden(_ sender: Any?) { store.showHidden.toggle() }
    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(store)))
            w.title = "Settings"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        settings!.contentView?.superview?.setGreyscale(store.theme.grayscale > 0)  // RootView greys it on later theme changes
        settings!.makeKeyAndOrderFront(nil)
    }
    @objc func refreshAll(_ sender: Any?) { Task { await store.refreshAll() } }
    @objc func showActivity(_ sender: Any?) { store.showInspector.toggle() }
    @objc func addPane(_ sender: Any?) { store.addPane() }
    @objc func toggleStacked(_ sender: Any?) { store.stacked.toggle() }
    @objc func setTheme(_ sender: NSMenuItem) { store.theme = Theme(rawValue: sender.representedObject as? String ?? "") ?? .system }
    @objc func toggleICloud(_ sender: Any?) { store.setICloud(!store.iCloud) }
    @objc func restoreBookmarks(_ sender: Any?) { store.restoreLibrary() }
    @objc func importCyberduck(_ sender: Any?) { store.importCyberduck() }
    @objc func showBookmarkBackups(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: store.libraryBackups, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.libraryBackups)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleHidden(_:)) { item.state = store.showHidden ? .on : .off }
        if item.action == #selector(toggleICloud(_:)) { item.state = store.iCloud ? .on : .off }
        if item.action == #selector(setTheme(_:)) { item.state = store.theme.rawValue == item.representedObject as? String ? .on : .off }
        if item.action == #selector(addPane(_:)) { return store.panes.count < 4 }
        if item.action == #selector(toggleStacked(_:)) { item.state = store.stacked ? .on : .off; return store.panes.count == 2 }
        return true
    }
}

@MainActor func mainMenu() -> NSMenu {
    let menu = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "About Techno Goose", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Techno Goose", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Quit Techno Goose", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Show Hidden Files", action: #selector(AppDelegate.toggleHidden(_:)), keyEquivalent: ".").keyEquivalentModifierMask = [.command, .shift]
    view.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refreshAll(_:)), keyEquivalent: "r")
    view.addItem(withTitle: "Add Browser Pane", action: #selector(AppDelegate.addPane(_:)), keyEquivalent: "t")
    view.addItem(withTitle: "Two Panes Top and Bottom", action: #selector(AppDelegate.toggleStacked(_:)), keyEquivalent: "d").keyEquivalentModifierMask = [.command, .option]
    view.addItem(.separator())
    let themes = NSMenu(title: "Theme")
    for t in Theme.allCases {
        themes.addItem(withTitle: t.title, action: #selector(AppDelegate.setTheme(_:)), keyEquivalent: "").representedObject = t.rawValue
        if t == .system { themes.addItem(.separator()) }
    }
    view.addItem(withTitle: "Theme", action: nil, keyEquivalent: "").submenu = themes
    view.addItem(.separator())
    view.addItem(withTitle: "Transfers & Timeline", action: #selector(AppDelegate.showActivity(_:)), keyEquivalent: "t").keyEquivalentModifierMask = [.command, .option]
    let marks = NSMenu(title: "Bookmarks")
    marks.addItem(withTitle: "Sync Bookmarks with iCloud Drive", action: #selector(AppDelegate.toggleICloud(_:)), keyEquivalent: "")
    marks.addItem(.separator())
    marks.addItem(withTitle: "Import from Cyberduck…", action: #selector(AppDelegate.importCyberduck(_:)), keyEquivalent: "")
    marks.addItem(withTitle: "Restore Bookmarks from Backup…", action: #selector(AppDelegate.restoreBookmarks(_:)), keyEquivalent: "")
    marks.addItem(withTitle: "Show Bookmark Backups in Finder", action: #selector(AppDelegate.showBookmarkBackups(_:)), keyEquivalent: "")
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    for sub in [app, edit, view, marks, window] { let item = NSMenuItem(); item.submenu = sub; menu.addItem(item) }
    return menu
}

func syncPlanSelfTest() {
    let d0 = Date(timeIntervalSince1970: 1_000_000), d1 = d0.addingTimeInterval(3600)
    func f(_ n: String, _ size: Int64, _ d: Date, dir: Bool = false) -> RemoteFile { RemoteFile(name: n, path: "/x/" + n, isDir: dir, size: size, modified: d) }
    let l = ["a": f("a", 1, d1), "b": f("b", 2, d0), "same": f("same", 5, d0), "d": f("d", 0, d0, dir: true), "d/e": f("e", 3, d0)]
    let r = ["a": f("a", 1, d0), "b": f("b", 9, d1), "same": f("same", 5, d0), "r": f("r", 4, d0)]
    precondition(makePlan(local: l, remote: r, mode: .upload).map(\.rel) == ["a", "b", "d", "d/e"])
    precondition(makePlan(local: l, remote: r, mode: .download).map(\.rel) == ["b", "r"])
    let both = makePlan(local: l, remote: r, mode: .both).map { "\($0.rel)>\($0.to.rawValue)" }
    precondition(both == ["b>local", "d>remote", "d/e>remote", "r>local"], "\(both)")
    precondition(makePlan(local: ["same": f("same", 5, d0)], remote: ["same": f("same", 5, d0)], mode: .upload, force: true).first?.overwrite == true)
    // Rules: "b" is newer and bigger on the right, "a" only newer on the left.
    let strict = SyncRules(replace: .onlyNewer, conflict: .skip)
    let p1 = planSync(local: l, remote: r, mode: .upload, rules: strict)
    precondition(p1.ops.map(\.rel) == ["a", "d", "d/e"] && p1.skipped.map(\.rel) == ["b"], "\(p1)")
    precondition(makePlan(local: l, remote: r, mode: .upload).first { $0.rel == "b" }?.warning != nil)
    precondition(planSync(local: l, remote: r, mode: .both, rules: strict).skipped.map(\.rel) == ["b"])
    precondition(makePlan(local: l, remote: r, mode: .both, rules: SyncRules(conflict: .a)).contains { $0.rel == "b" && $0.to == .b })
    precondition(makePlan(local: l, remote: r, mode: .upload, rules: SyncRules(replace: .never)).map(\.rel) == ["d", "d/e"])
    precondition(!makePlan(local: l, remote: r, mode: .upload, rules: SyncRules(compare: .sizeOnly)).contains { $0.rel == "a" })
    // Drop zones: a folder offers Open and Copy, a file only Copy, a pane grip neither; an empty pane only opens.
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()), file = tmpDir.appendingPathComponent("x.txt")
    let z1 = dropZones(urls: [tmpDir], refs: [], folder: "public_html")
    precondition(z1.open?.title == "Open “\(tmpDir.lastPathComponent)” instead of “public_html”" && z1.copy?.title == "Copy to “public_html”", "\(z1)")
    precondition(dropZones(urls: [file], refs: [], folder: "site").open == nil)
    precondition(dropZones(urls: [], refs: ["technoduck-pane:x"], folder: "site") == DropZones())
    precondition(dropZones(urls: [tmpDir], refs: [], folder: nil).copy == nil)
    precondition(dropZones(urls: [tmpDir, tmpDir], refs: [], folder: "a").open?.title.hasPrefix("Compare") == true)
    precondition(dropZones(urls: [], refs: ["technoduck-item:id:/srv/logo.svg"], folder: "a").copy?.detail == "“logo.svg” is copied into this folder.")
    // Comparison rows: every file, folders only where one side lacks them; then choices per file.
    let rows = compareRows(l, r, skipped: [SkippedFile(rel: "same", why: sameContents)])
    let st = Dictionary(uniqueKeysWithValues: rows.map { ($0.rel, $0.status) })
    precondition(st == ["a": .newerA, "b": .newerB, "same": .same, "d": .onlyA, "d/e": .onlyA, "r": .onlyB], "\(st)")
    let planned = makePlan(local: l, remote: r, mode: .upload)
    precondition(applyChoices(rows, planned) { r in planned.first { $0.rel == r.rel }?.to }.map(\.id) == planned.map(\.id))
    // Send "b" back left, keep "a" here, and copy only "d/e": its folder "d" comes along.
    let mine: [String: Side] = ["b": .a, "d/e": .b, "r": .a]
    let chosen = applyChoices(rows, planned) { mine[$0.rel] }.map { "\($0.rel)>\($0.to.rawValue)\($0.overwrite ? "!" : "")" }
    precondition(chosen == ["b>local!", "d>remote", "d/e>remote", "r>local"], "\(chosen)")
    precondition(applyChoices(rows, planned) { $0.rel == "a" ? .a : nil }.first?.warning != nil)  // the older right "a" over the newer left one
    precondition(applyChoices(rows, planned) { $0.rel == "r" ? .a : nil }.first?.warning == nil)  // a new file replaces nothing
    // Diff: lines, words inside an edited line, and unchanged runs folded away.
    let d = diffText("one\ntwo\nthree\n", "one\n2\nthree\nfour\n")
    precondition(d.lines.map(\.kind) == [.same, .removed, .added, .same, .added, .same] && d.added == 2 && d.removed == 1)
    let w = diffText("<p>hello world</p>", "<p>hello there</p>").lines[0].text
    precondition(w.runs.contains { $0.backgroundColor != nil && String(w[$0.range].characters) == "world" })
    let many = (1...20).map(String.init)
    precondition(diffText(many.joined(separator: "\n"), many.map { $0 == "10" ? "ten" : $0 }.joined(separator: "\n")).rows().count == 10)
    precondition(diffText("", "a\nb").lines.allSatisfy { $0.kind != .same || $0.text.characters.isEmpty })
    // Quick Look picks a comparison by kind; UTF-16 text reads as text; a pixel diff counts what changed.
    let txt = Data("x".utf8)
    for (name, kind) in [("a.CSS", FileKind.text), ("logo.svg", .text), ("p.jpg", .image), ("p.webp", .image), ("d.pdf", .pdf),
                         ("f.woff2", .font), ("v.mp4", .media), ("s.mp3", .media), ("a.zip", .archive), ("a.tar.gz", .archive)] {
        precondition(FileKind.of(name, txt) == kind, name)
    }
    precondition(FileKind.of("x.bin", Data([0, 1, 2])) == .binary && FileKind.of("x", Data("%PDF-1.4".utf8)) == .pdf)
    precondition(decodeText("Hallo".data(using: .utf16)!) == "Hallo")
    func square(_ x: Int) -> NSImage {
        let c = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 10, height: 10)); c.setFillColor(.black); c.fill(CGRect(x: x, y: 0, width: 2, height: 2))
        return NSImage(cgImage: c.makeImage()!, size: NSSize(width: 10, height: 10))
    }
    precondition(pixelDiff(square(0), square(0))?.changed == 0 && pixelDiff(square(0), square(5))?.changed == 0.08)
    precondition(isExcluded("x.log", "a/x.log", ["*.log"]) && isExcluded("node_modules", "node_modules", ["node_modules"]))
    precondition(isExcluded("y", "cache/y", ["cache/*"]) && !isExcluded("a.txt", "a.txt", ["*.log", "cache/*"]))
    precondition(Bookmark(excludes: " .git,node_modules\n*.log ").excludeList == [".git", "node_modules", "*.log"])
    // Bookmarks saved before the sync fields existed must still load.
    let old = try! JSONDecoder().decode(Bookmark.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","nickname":"","proto":"SFTP","host":"h","port":22,"user":"","path":""}"#.utf8))
    precondition(old.host == "h" && old.autoSync == nil && old.excludeList.isEmpty && old.backupFolder == nil)
    // Sync records saved before panes could be servers on both sides must still load.
    let rec = try! JSONDecoder().decode(SyncRecord.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"bookmarkID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","localRoot":"/l","remoteRoot":"/r","applied":[{"op":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","to":"remote","rel":"x","isDir":false,"size":1,"overwrite":false,"reason":""}}],"rolledBack":false}"#.utf8))
    precondition(rec.aBookmarkID == nil && rec.applied[0].op.to == .b)
}

/// Syncs two temp folders through LocalService, then undoes it and checks everything is back.
func syncEngineSelfTest() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("technoduck-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let L = root.appendingPathComponent("L").path, R = root.appendingPathComponent("R").path
    try fm.createDirectory(atPath: L + "/sub", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: R, withIntermediateDirectories: true)
    func put(_ p: String, _ s: String) throws { try s.write(toFile: p, atomically: true, encoding: .utf8) }
    func get(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
    try put(L + "/a.txt", "new"); try put(L + "/sub/b.txt", "two"); try put(L + "/.hidden", "x"); try put(L + "/sub/skip.log", "no"); try put(R + "/a.txt", "old content")
    /// LocalService, but deleting for real so the test leaves nothing in the Trash.
    struct TestDisk: FileService {
        let disk: LocalService
        func start() async throws -> String { disk.root }
        func list(_ dir: String) async throws -> [RemoteFile] { try await disk.list(dir) }
        func download(_ remote: String, to local: URL) async throws { try await disk.download(remote, to: local) }
        func upload(_ local: URL, to remote: String) async throws { try await disk.upload(local, to: remote) }
        func delete(_ f: RemoteFile) async throws { try FileManager.default.removeItem(atPath: f.path) }
        func mkdir(_ path: String) async throws { try await disk.mkdir(path) }
    }
    let remote = TestDisk(disk: LocalService(root: R))
    let lw = try await walk(LocalService(root: L), L, hidden: false, strict: true, exclude: ["*.log"]), rw = try await walk(remote, R, hidden: false, strict: true)
    let ops = makePlan(local: lw.files, remote: rw.files, mode: .upload)
    precondition(ops.map(\.rel) == ["a.txt", "sub", "sub/b.txt"], "\(ops.map(\.rel))")
    let engine = SyncEngine(a: LocalService(root: L), b: remote, aRoot: L, bRoot: R, backups: root.appendingPathComponent("backup"))
    var applied: [Applied] = []
    for op in ops { applied.append(try await engine.apply(op)) }
    precondition(get(R + "/a.txt") == "new" && get(R + "/sub/b.txt") == "two" && get(R + "/.hidden") == nil)
    precondition(applied[0].backup != nil && applied[2].backup == nil)
    for a in applied.reversed() { try await engine.undo(a) }
    precondition(get(R + "/a.txt") == "old content" && !fm.fileExists(atPath: R + "/sub"))

    // Server to server goes through a temp file: two non-local services.
    let S = root.appendingPathComponent("S").path
    try fm.createDirectory(atPath: S, withIntermediateDirectories: true)
    let s2s = SyncEngine(a: remote, b: TestDisk(disk: LocalService(root: S)), aRoot: R, bRoot: S, backups: nil)
    _ = try await s2s.apply(SyncOp(to: .b, rel: "a.txt", size: 11))
    precondition(get(S + "/a.txt") == "old content")
}

if CommandLine.arguments.contains("--self-test") {
    let l = parseUnixListing("""
    sftp> ls -la /srv
    drwxr-xr-x    2 bob  staff     4096 Jan 01 12:00 .
    drwxr-xr-x    2 bob  staff     4096 Jan 01 12:00 my docs
    -rw-r--r--    1 bob  staff      123 Mar 05  2021 a file.txt
    lrwxrwxrwx    1 bob  staff        7 Mar 05  2021 link -> target
    """, dir: "/srv")
    precondition(l.map(\.name) == ["my docs", "a file.txt", "link"] && l[0].isDir && l[1].size == 123 && l[1].path == "/srv/a file.txt" && l[1].modified != nil)
    let b = bookmark(fromQuickConnect: "ftp://ann@example.com:2121/pub")
    precondition(b.proto == .ftp && b.user == "ann" && b.host == "example.com" && b.port == 2121 && b.path == "/pub")
    precondition(bookmark(fromQuickConnect: "example.com").proto == .sftp)
    let cd = bookmark(fromCyberduck: ["Protocol": "davs", "Hostname": "dav.example.com", "Port": "8443", "Username": "ann", "Nickname": "Docs", "Path": "/files", "UUID": "02A48079-3F4F-4D87-91E6-4997090D217A"])
    precondition(cd?.proto == .webdavs && cd?.port == 8443 && cd?.nickname == "Docs" && cd?.path == "/files" && cd?.id.uuidString == "02A48079-3F4F-4D87-91E6-4997090D217A")
    precondition(bookmark(fromCyberduck: ["Protocol": "s3", "Hostname": "s3.amazonaws.com"]) == nil && bookmark(fromCyberduck: ["Protocol": "ftp", "Hostname": "h"])?.port == 21)
    precondition(parentPath("/a/b") == "/a" && parentPath("/a") == "/")
    precondition(l[2].isLink && !l[1].isLink)
    // The watcher behind auto-upload and editor saves must notice a new file.
    let wdir = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-watch-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: wdir, withIntermediateDirectories: true)
    var fired = false
    let watcher = FolderWatcher(wdir.path, latency: 0.2) { fired = true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try! "x".write(to: wdir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(5)
    while !fired && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    precondition(watcher != nil && fired, "folder watcher did not fire")
    try? FileManager.default.removeItem(at: wdir)
    syncPlanSelfTest()
    let done = DispatchSemaphore(value: 0)
    Task.detached { do { try await syncEngineSelfTest() } catch { fatalError("sync engine: \(error)") }; done.signal() }
    done.wait()
    print("self-test ok"); exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = mainMenu()
    app.run()
}
