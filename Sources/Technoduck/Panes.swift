import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var editing: Bookmark?
    @State private var quick = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(editing: $editing).themed(store.theme)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            // Dividers between panes can be dragged; a pane's grip (≡) drags the pane itself to another spot.
            // The status bar sits below the panes, not over them, so Label Lime's pane frame shows all four corners.
            VStack(spacing: 0) {
            if store.stacked && store.panes.count == 2 {
                VSplitView {
                    PaneView(pane: store.panes[0], editing: $editing).frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity).clipped()
                    VStack(spacing: 0) {
                        Divider()
                        CenterStrip(left: store.panes[0], right: store.panes[1], stacked: true)
                        Divider()
                        PaneView(pane: store.panes[1], editing: $editing).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    }
                    .frame(minHeight: 250, maxHeight: .infinity)
                }
                .id(store.panes.map(\.id))
            } else {
            HSplitView {
                ForEach(Array(store.panes.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 0) {
                        if i > 0 { CenterStrip(left: store.panes[i - 1], right: p); Divider() }
                        // Clipped, so a table wider than its pane can't push the strip out of view.
                        PaneView(pane: p, editing: $editing).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                    }
                    .frame(minWidth: i > 0 ? 360 : 300, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .id(store.panes.map(\.id))
            }
            StatusBar()
            }
            .themed(store.theme)
        }
        .inspector(isPresented: $store.showInspector) {
            InspectorView().themed(store.theme).inspectorColumnWidth(min: 280, ideal: 330)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { editing = Bookmark() } label: { Label("Open Connection", systemImage: "plus.circle") }
                    .help("Open a new connection")
            }
            ToolbarItem(placement: .principal) {
                TextField("Quick Connect — sftp://user@server", text: $quick)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 220, idealWidth: 320)
                    .onSubmit { if !quick.isEmpty { editing = bookmark(fromQuickConnect: quick); quick = "" } }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.panes.count == 2 {
                    Button { store.stacked.toggle() } label: {
                        Label(store.stacked ? "Side by Side" : "Top and Bottom", systemImage: store.stacked ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    }
                    .help(store.stacked ? "Put the two panes side by side (⌥⌘D)" : "Put the two panes above each other (⌥⌘D)")
                }
                Button { store.addPane() } label: { Label("Add Browser", systemImage: "rectangle.split.3x1") }
                    .help("Add a browser pane (up to 4)").disabled(store.panes.count >= 4)
                Button { store.showInspector.toggle() } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .help("Transfers and timeline")
            }
        }
        .tint(store.theme.accent)
        .onChange(of: store.theme, initial: true) {
            NSApp.appearance = store.theme.appearance
            // SwiftUI's .grayscale on the split view breaks the toolbar's safe area, so the window frame gets a Core Image filter.
            for w in NSApp.windows where w.sheetParent == nil { w.contentView?.superview?.setGreyscale(store.theme.grayscale > 0) }
        }
        .sheet(item: $editing) { b in ConnectionSheet(bookmark: b).themed(store.theme).grayscale(store.theme.grayscale) }
        .sheet(item: $store.plan) { p in SyncPlanSheet(plan: p).themed(store.theme).grayscale(store.theme.grayscale) }
        .navigationTitle("Techno Goose")
        .navigationSubtitle(store.active?.title ?? "")
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var editing: Bookmark?

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                if store.favorites.isEmpty {
                    Text("Right-click a folder › Add to Favorites").themedFont(.caption).foregroundStyle(.tertiary)
                }
                ForEach(store.favorites) { f in FavoriteRow(f: f) }
                    .onMove { store.favorites.move(fromOffsets: $0, toOffset: $1) }
            } header: { sectionTitle("Favorites") }
            Section {
                ForEach(store.bookmarks) { b in
                    Button { Task { await store.connect(b) } } label: {
                        Label { Text(b.title).lineLimit(1).themedFont(nil) } icon: { Image(systemName: b.proto.symbol) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(store.panes.contains { $0.bookmark?.id == b.id } ? .semibold : .regular)
                    .contextMenu { BookmarkMenu(b: b, editing: $editing) }
                }
            } header: { sectionTitle("Bookmarks") }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(store.theme.sidebar == nil ? .automatic : .hidden)
        .background(store.theme.sidebar ?? .clear)
    }

    @ViewBuilder private func sectionTitle(_ t: String) -> some View {
        if store.theme.label { Eyebrow(t).padding(.bottom, 2) } else { Text(t) }
    }
}

/// A favorite folder: where it lives in bold (this Mac or the server's domain), the end of its path in grey.
struct FavoriteRow: View {
    @Environment(Store.self) private var store
    let f: Favorite

    var body: some View {
        let b = store.bookmarks.first { $0.id == f.bookmarkID }
        let place = f.bookmarkID == nil ? "This Mac" : b.map { $0.host.isEmpty ? $0.title : $0.host } ?? "Deleted server"
        Button { Task { await store.open(f) } } label: {
            HStack(spacing: 8) {
                Image(systemName: f.bookmarkID == nil ? "laptopcomputer" : b?.proto.symbol ?? "questionmark.folder")
                    .foregroundStyle(f.bookmarkID == nil ? Color.secondary : store.theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place).fontWeight(.semibold).lineLimit(1).themedFont(nil)
                    // Head truncation keeps the last folders visible, with "…" standing in for the rest.
                    Text(f.path).themedFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(b.map { $0.url(f.path) } ?? f.path)
        .contextMenu {
            Button("Open") { Task { await store.open(f) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(b.map { $0.url(f.path) } ?? f.path, forType: .string) }
            Divider()
            Button("Remove from Favorites", role: .destructive) { store.favorites.removeAll { $0.id == f.id } }
        }
    }
}

/// One file browser: path bar on top, files below. Empty panes offer the bookmarks.
struct PaneView: View {
    @Environment(Store.self) private var store
    @Bindable var pane: Pane
    @Binding var editing: Bookmark?
    @State private var sort = [KeyPathComparator(\RemoteFile.name)]
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var confirmDelete = false
    /// While something is dragged over this pane: the drop zones it offers, and whether it hovers the Open one.
    @State private var drag: DropZones?
    @State private var overOpen = false
    @State private var height: CGFloat = 400

    private var rows: [RemoteFile] { store.visible(pane.files).sorted(using: sort).sorted { $0.isDir && !$1.isDir } }
    private var isActive: Bool { store.active === pane }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pane.service == nil { EmptyPane(pane: pane, editing: $editing) } else { table }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if store.theme.label && isActive && store.panes.count > 1 { ActiveFrame(color: store.theme.accent) } }
        .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { height = $1 } })
        .overlay { if let drag { dropOverlay(drag) } }
        .onDrop(of: [.fileURL, .utf8PlainText], delegate: PaneDrop(zones: $drag, overOpen: $overOpen, height: height, folder: folderName(pane)) { open, urls, refs in
            let target = pane
            Task {
                if open { await store.openFolders(urls, in: target); return }
                await store.drop(urls: urls, into: target)
                await store.drop(refs: refs, into: target)
            }
        })
        .simultaneousGesture(TapGesture().onEnded { store.activeID = pane.id })
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { let n = folderName; folderName = ""; Task { await store.mkdir(n, in: pane) } }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
        .confirmationDialog(pane.isLocal ? "Move \(pane.selected.count) item(s) to the Trash?" : "Delete \(pane.selected.count) item(s)? This cannot be undone on the server.",
                            isPresented: $confirmDelete) {
            Button(pane.isLocal ? "Move to Trash" : "Delete", role: .destructive) {
                let items = pane.selected; pane.selection = []
                Task { await store.delete(items, in: pane) }
            }
        }
        .onChange(of: pane.path) { pane.selection = [] }
        .onChange(of: pane.selection) { if !pane.selection.isEmpty { store.activeID = pane.id } }
    }

    /// Two rows: where you are and what's in it, then the buttons.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .frame(width: 14, height: 22).contentShape(Rectangle())
                    .draggable("technoduck-pane:\(pane.id.uuidString)")
                    .help("Drag onto another pane to swap places")
                Image(systemName: pane.service == nil ? "circle.dashed" : pane.isLocal ? "laptopcomputer" : (pane.bookmark?.proto.symbol ?? "server.rack"))
                    .foregroundStyle(isActive ? store.theme.accent : Color.secondary)
                if pane.service != nil {
                    Menu {
                        ForEach(ancestors, id: \.self) { p in Button(p) { Task { await pane.open(p) } } }
                        if pane.isLocal { Divider(); Button("Choose Folder…") { chooseFolder() } }
                    } label: {
                        pathLabel
                    }
                    .menuStyle(.borderlessButton).fixedSize().help(pane.path)
                    Spacer(minLength: 6)
                    if let e = pane.error {
                        Text(e).foregroundStyle(.red).lineLimit(1).truncationMode(.middle).help(e)
                    } else if store.theme.label {
                        Text(summary.uppercased()).font(bebas(17)).tracking(0.5).foregroundStyle(store.theme.accent).lineLimit(1)
                    } else {
                        Text(summary).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                } else {
                    Text("Choose a location").foregroundStyle(.secondary)
                    Spacer()
                }
                Menu {
                    if pane.service != nil {
                        if let b = saved {
                            Button("Back Up \(b.title) Now", systemImage: "externaldrive.badge.timemachine") { Task { await store.backUp(b) } }
                            Button("Set Current Folder as Start Folder", systemImage: "house") { store.setStartFolder(pane.path, for: pane) }
                        }
                        Button(pane.isLocal ? "Close Location" : "Disconnect", systemImage: "eject") { pane.close() }
                    }
                    if store.panes.count > 1 { Button("Close Pane", systemImage: "xmark") { store.closePane(pane) } }
                    if store.panes.count < 4 { Button("Add Browser Pane", systemImage: "plus") { store.addPane() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .frame(height: store.theme.label ? 38 : 30)
            if pane.service != nil {
                HStack(spacing: 10) {
                    Button { Task { await pane.back() } } label: { Image(systemName: "chevron.left") }.disabled(pane.history.isEmpty).help("Back")
                    Button { Task { await pane.open(parentPath(pane.path)) } } label: { Image(systemName: "chevron.up") }.disabled(pane.path == "/").help("Enclosing folder")
                    Divider().frame(height: 14)
                    Button { store.toggleFavorite(pane, pane.path) } label: {
                        Image(systemName: store.favorite(pane, pane.path) == nil ? "star" : "star.fill")
                    }
                    .help("Favorite this folder").disabled(!store.canFavorite(pane))
                    Button { newFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(pane.selection.isEmpty).help(pane.isLocal ? "Move to Trash" : "Delete")
                    Button { Task { await pane.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                    Spacer(minLength: 8)
                    Text(pane.isLocal ? (pane.path as NSString).abbreviatingWithTildeInPath : pane.path)
                        .themedFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled).help(pane.path)
                }
                .frame(height: 24).padding(.bottom, 3)
            }
        }
        .buttonStyle(.borderless)
        .themedFont(.callout)
        .padding(.horizontal, store.theme.label ? 12 : 10)
        .themeBackground(store.theme.bar, .bar)
        .overlay(alignment: .top) {
            if isActive && !store.theme.label {
                if store.theme == .mac512 { // the pinstripes of an active 1984 title bar
                    VStack(spacing: 1) { ForEach(0..<3, id: \.self) { _ in Rectangle().frame(height: 1) } }
                } else { Rectangle().fill(store.theme.gradient).frame(height: 2) }
            }
        }
    }

    /// The pane's folder name for the drop zones; nil for an empty pane.
    private func folderName(_ p: Pane) -> String? {
        p.service == nil ? nil : p.path == "/" ? p.title : (p.path as NSString).lastPathComponent
    }

    /// Two zones while something is dragged in: Open (top) and Copy (bottom), or just the one that applies.
    @ViewBuilder private func dropOverlay(_ z: DropZones) -> some View {
        let zones = [z.open.map { (true, $0) }, z.copy.map { (false, $0) }].compactMap { $0 }
        if zones.isEmpty {
            RoundedRectangle(cornerRadius: store.theme.corner(4)).strokeBorder(store.theme.accent, lineWidth: 3).allowsHitTesting(false)
        } else {
            VStack(spacing: 8) {
                ForEach(zones, id: \.0) { isOpen, zone in
                    let on = zones.count == 1 || overOpen == isOpen
                    VStack(spacing: 8) {
                        Image(systemName: isOpen ? "folder.fill" : "doc.on.doc.fill").font(.system(size: 30, weight: .semibold))
                        Text(zone.title).themedFont(.title3.bold()).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                        Text(zone.detail).themedFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .padding(16)
                    .foregroundStyle(on ? store.theme.accent : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: store.theme.corner(12)).fill(store.theme.accent.opacity(on ? 0.22 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: store.theme.corner(12))
                        .strokeBorder(store.theme.accent.opacity(on ? 1 : 0.45), style: StrokeStyle(lineWidth: on ? 3 : 1.5, dash: on ? [] : [7, 5])))
                    .animation(.easeOut(duration: 0.12), value: on)
                }
            }
            .padding(10)
            .background((store.theme.bar ?? Color(nsColor: .windowBackgroundColor)))
            .allowsHitTesting(false)
        }
    }

    /// "Server — folder"; in Label Lime small spaced capitals, then the folder in condensed capitals.
    private var pathLabel: Text {
        let last = pane.path == "/" ? "/" : (pane.path as NSString).lastPathComponent
        guard store.theme.label else { return Text("\(pane.title) — \(last)").fontWeight(isActive ? .semibold : .regular) }
        return Text(pane.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundColor(.secondary)
            + Text("  ") + Text(last.uppercased()).font(bebas(23)).tracking(0.4).foregroundColor(isActive ? store.theme.accent : .primary)
    }

    private var saved: Bookmark? { store.bookmarks.first { $0.id == pane.bookmark?.id } }

    private var table: some View {
        Table(of: RemoteFile.self, selection: $pane.selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { f in
                Label { Text(f.name).opacity(f.name.hasPrefix(".") ? 0.55 : 1) } icon: {
                    Image(nsImage: f.isDir ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 16, height: 16)
                }
            }
            .width(min: 100, ideal: 240)
            TableColumn("Size", value: \.size) { f in sizeText(f).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 56, ideal: 80)
            TableColumn("Modified") { f in Text(f.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 140)
            TableColumn("Permissions") { f in Text(f.permissions).themedFont(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 90)
        } rows: {
            ForEach(rows) { f in TableRow(f).itemProvider { dragItem(f) } }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            let items = pane.files.filter { ids.contains($0.id) }
            if !items.isEmpty {
                let others = store.panes.filter { $0 !== pane && $0.service != nil }
                if !others.isEmpty {
                    Menu("Copy To") {
                        ForEach(others) { o in Button("\(o.title) — \(o.path)") { copy(items, to: o) } }
                    }
                }
                if items.count == 1, items[0].isDir {
                    Button(store.favorite(pane, items[0].path) == nil ? "Add to Favorites" : "Remove from Favorites") { store.toggleFavorite(pane, items[0].path) }
                        .disabled(!store.canFavorite(pane))
                    if store.canSetStart(pane) {
                        Button("Set as Start Folder for \(pane.title)") { store.setStartFolder(items[0].path, for: pane) }
                    }
                }
                if pane.isLocal {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) }) }
                } else {
                    if items.count == 1, !items[0].isDir {
                        Button("Edit in Default App") { Task { await store.edit(items[0], in: pane) } }
                            .help("Opens a copy; every save is uploaded back to the server")
                    }
                    Button("Copy URL") { copyURL(items) }
                }
                Divider()
                Button(pane.isLocal ? "Move to Trash" : "Delete…", role: .destructive) { pane.selection = ids; confirmDelete = true }
            }
            Button("New Folder…") { newFolder = true }
        } primaryAction: { ids in
            let items = pane.files.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDir { Task { await pane.open(items[0].path) } }
            else if pane.isLocal { items.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0.path)) } }
            else if let o = store.panes.first(where: { $0 !== pane && $0.isLocal }) { copy(items, to: o) }
        }
        .scrollContentBackground(store.theme.canvas == nil ? .automatic : .hidden)
        .alternatingRowBackgrounds(store.theme.canvas == nil ? .automatic : .disabled)
        .background(store.theme.canvas ?? .clear)
        .overlay { if pane.busy { ProgressView().controlSize(.large) } }
    }

    /// Files on this Mac drag as real files (so Finder takes them too); server files as a reference to this pane.
    private func dragItem(_ f: RemoteFile) -> NSItemProvider {
        if pane.isLocal, let p = NSItemProvider(contentsOf: URL(fileURLWithPath: f.path)) { return p }
        return NSItemProvider(object: "technoduck-item:\(pane.id.uuidString):\(f.path)" as NSString)
    }
    private func copy(_ items: [RemoteFile], to other: Pane) {
        guard let e = pane.endpoint else { return }
        Task { await store.copy(items, from: e, to: other) }
    }
    private func sizeText(_ f: RemoteFile) -> Text {
        guard f.isDir else { return Text(fmtBytes(f.size)) }
        if let complete = pane.sized[f.path] { return Text((complete ? "" : "≥ ") + fmtBytes(f.size)) }
        return Text(pane.sizing && !f.isLink ? "…" : "--")
    }
    private var summary: String {
        let known = rows.filter { !$0.isDir || pane.sized[$0.path] != nil }.reduce(Int64(0)) { $0 + $1.size }
        return "\(rows.count) items · \(fmtBytes(known))\(pane.sizing ? "…" : "")"
    }
    private var ancestors: [String] {
        var out = [pane.path], p = pane.path
        while p != "/" && p != "." && !p.isEmpty { p = parentPath(p); out.append(p) }
        return out
    }
    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: pane.path)
        if p.runModal() == .OK, let u = p.url { Task { await pane.open(u.path) } }
    }
    private func copyURL(_ items: [RemoteFile]) {
        guard let c = pane.bookmark else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { c.url($0.path) }.joined(separator: "\n"), forType: .string)
    }
}

/// What a drag over a pane can do. A zone is nil when it doesn't apply.
struct DropZones: Equatable {
    struct Zone: Equatable { var title: String; var detail: String }
    var open: Zone?
    var copy: Zone?
}

/// Open: folders from Finder (or this Mac's panes) replace the pane's folder; two are compared side by side.
/// Copy: anything dragged in is copied into the pane's folder. A dragged pane grip offers neither: it swaps panes.
/// `folder` is the pane's folder name; nil for an empty pane, which can only open.
func dropZones(urls: [URL], refs: [String], folder: String?) -> DropZones {
    if refs.contains(where: { $0.hasPrefix("technoduck-pane:") }) { return DropZones() }
    let isDir = { (u: URL) in (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    let dirs = urls.filter(isDir)
    var z = DropZones()
    if dirs.count >= 2 {
        z.open = .init(title: "Compare “\(dirs[0].lastPathComponent)” with “\(dirs[1].lastPathComponent)”", detail: "Opens both side by side and shows what differs. Nothing is copied.")
    } else if let d = dirs.first {
        z.open = .init(title: "Open “\(d.lastPathComponent)”" + (folder.map { " instead of “\($0)”" } ?? " here"), detail: "This pane shows that folder. Nothing is copied.")
    } else if folder == nil, let u = urls.first {
        z.open = .init(title: "Open “\(u.deletingLastPathComponent().lastPathComponent)” here", detail: "The folder this file is in. Nothing is copied.")
    }
    let names = urls.map(\.lastPathComponent) + refs.filter { $0.hasPrefix("technoduck-item:") }.map { ($0 as NSString).lastPathComponent }
    if let folder, !names.isEmpty {
        z.copy = .init(title: "Copy to “\(folder)”", detail: (names.count == 1 ? "“\(names[0])” is" : "\(names.count) items are") + " copied into this folder.")
    }
    return z
}

/// Drops on a pane: the top half is Open, the bottom half Copy (when both apply). Names fill in once the drag is read.
struct PaneDrop: DropDelegate {
    @Binding var zones: DropZones?
    @Binding var overOpen: Bool
    let height: CGFloat
    let folder: String?
    let perform: (_ open: Bool, _ urls: [URL], _ refs: [String]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .utf8PlainText]) }
    func dropEntered(info: DropInfo) {
        // Until the names are read: Open for files from Finder, Copy when there's a folder to copy into.
        zones = DropZones(open: info.hasItemsConforming(to: [.fileURL]) ? .init(title: folder.map { "Open the dragged folder instead of “\($0)”" } ?? "Open the dragged folder here", detail: "Nothing is copied.") : nil,
                          copy: folder.map { .init(title: "Copy to “\($0)”", detail: "Copied into this folder.") })
        let providers = info.itemProviders(for: [.fileURL, .utf8PlainText])
        Task { @MainActor in
            let (urls, refs) = await loadDrop(providers)
            if zones != nil, !(urls.isEmpty && refs.isEmpty) { zones = dropZones(urls: urls, refs: refs, folder: folder) }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        overOpen = isOpen(info)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { zones = nil }
    private func isOpen(_ info: DropInfo) -> Bool {
        guard let z = zones, z.open != nil else { return false }
        return z.copy == nil || info.location.y < height / 2
    }
    func performDrop(info: DropInfo) -> Bool {
        let open = isOpen(info)
        zones = nil
        let providers = info.itemProviders(for: [.fileURL, .utf8PlainText])
        Task { @MainActor in let (urls, refs) = await loadDrop(providers); perform(open, urls, refs) }
        return true
    }
}

/// Reads what was dropped: file URLs (Finder, or a pane on this Mac) and Techno Goose references (server panes, pane grips).
func loadDrop(_ providers: [NSItemProvider]) async -> (urls: [URL], refs: [String]) {
    var urls: [URL] = [], refs: [String] = []
    for p in providers {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) {
            if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) } else if let u = item as? URL { urls.append(u) }
        } else if p.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier), let item = try? await p.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) {
            if let d = item as? Data, let s = String(data: d, encoding: .utf8) { refs.append(s) } else if let s = item as? String { refs.append(s) }
        }
    }
    return (urls, refs)
}

/// A pane without a location: pick this Mac or a bookmark.
struct EmptyPane: View {
    @Environment(Store.self) private var store
    let pane: Pane
    @Binding var editing: Bookmark?
    private let cols = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 14) {
                Button { Task { await store.openLocal(in: pane) } } label: {
                    LocationCard(symbol: "laptopcomputer", title: "This Mac", subtitle: homeDir, kind: "Local Disk")
                }
                .buttonStyle(.plain)
                ForEach(store.bookmarks) { b in
                    Button { Task { await store.connect(b, in: pane) } } label: {
                        LocationCard(symbol: b.proto.symbol, title: b.title,
                                     subtitle: b.proto == .local ? b.path : "\(b.user.isEmpty ? "" : b.user + "@")\(b.host)", kind: b.proto.rawValue)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { BookmarkMenu(b: b, editing: $editing) }
                }
                Button { editing = Bookmark() } label: {
                    VStack(spacing: 8) { Image(systemName: "plus").font(.title); Text("New Bookmark") }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .foregroundStyle(.secondary)
                        .background(RoundedRectangle(cornerRadius: store.theme.corner(12)).strokeBorder(style: StrokeStyle(lineWidth: store.theme.label ? 1 : 1.5, dash: [6])).foregroundStyle(.quaternary))
                        .contentShape(Rectangle())  // the whole tile is the button, not just the + and label
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(store.theme.canvas ?? .clear)
    }
}

struct LocationCard: View {
    @Environment(Store.self) private var store
    let symbol: String, title: String, subtitle: String, kind: String
    var body: some View {
        let t = store.theme
        HStack(spacing: 12) {
            if t.label {   // an outlined tile with the symbol in the accent
                Image(systemName: symbol).font(.title3).foregroundStyle(t.accent)
                    .frame(width: 42, height: 42).background(Color(hex: 0x0B0B0C)).overlay(Rectangle().strokeBorder(Color(hex: 0x2A2A2A)))
            } else {
                Image(systemName: symbol).font(.title2).foregroundStyle(t.onAccent)
                    .frame(width: 42, height: 42).background(LinearGradient(colors: [t.accent, t.accent2], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(t.label ? title.uppercased() : title).themedFont(.headline).lineLimit(1)
                Text(subtitle).themedFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if t.label {
                    Text(kind.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Color(hex: 0xB5B5B5))
                        .padding(.horizontal, 5).padding(.vertical, 1).overlay(Rectangle().strokeBorder(Color(hex: 0x3A3A3A)))
                } else {
                    Text(kind).themedFont(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(t.label ? AnyShapeStyle(Color(hex: 0x141415)) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: t.corner(12)))
        .overlay(RoundedRectangle(cornerRadius: t.corner(12)).strokeBorder(t.label ? AnyShapeStyle(Color(hex: 0x2A2A2A)) : AnyShapeStyle(.separator)))
        .contentShape(Rectangle())
    }
}

/// The strip between two panes: pick a direction, then preview a sync of the two folders. Selected files can be copied across.
/// `stacked`: the panes sit top and bottom, so the strip lies flat between them.
struct CenterStrip: View {
    @Environment(Store.self) private var store
    let left: Pane, right: Pane
    var stacked = false
    @AppStorage("syncMode") private var mode = SyncMode.upload
    @State private var showHelp = false
    @State private var showRules = false
    @State private var hover: Task<Void, Never>?

    private var ready: Bool { left.service != nil && right.service != nil }
    private func name(_ p: Pane) -> String { p.endpoint?.name ?? p.title }

    var body: some View {
        let layout = stacked ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
        layout {
            Spacer()
            directions
            syncButton
            Button { showRules.toggle() } label: { Label("Rules", systemImage: "slider.horizontal.3").themedFont(.caption) }
                .controlSize(.small)
                .popover(isPresented: $showRules, arrowEdge: stacked ? .top : .trailing) { SyncRulesForm(stacked: stacked) }
                .help("What wins when a file differs on both sides")
            Spacer()
            if ready && !(left.selection.isEmpty && right.selection.isEmpty) { selectionCopy }
        }
        .padding(stacked ? .horizontal : .vertical, 10)
        .labelButtons(store.theme.label, accent: store.theme.accent)
        .buttonStyle(.bordered)
        .frame(width: stacked ? nil : 104, height: stacked ? 72 : nil)
        .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
        .themeBackground(store.theme.strip, .background.secondary)
    }

    /// Three buttons, one lit: which way the sync goes.
    private var directions: some View {
        let stack = stacked ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        return stack {
            ForEach(SyncMode.allCases) { m in
                let on = mode == m, t = store.theme
                Button { mode = m } label: {
                    VStack(spacing: 2) {
                        Image(systemName: m.symbol(stacked: stacked)).font(.system(size: 15, weight: .bold))
                        Text(m.label(stacked: stacked)).themedFont(.caption2.weight(on ? .bold : .regular)).lineLimit(1)
                    }
                    .frame(width: 78, height: 40)
                    .foregroundStyle(on ? t.onAccent : Color.primary)
                    .background(RoundedRectangle(cornerRadius: t.corner(7)).fill(on ? AnyShapeStyle(t.accent) : AnyShapeStyle(Color.secondary.opacity(0.1))))
                    .overlay(RoundedRectangle(cornerRadius: t.corner(7)).strokeBorder(on ? t.accent : Color.secondary.opacity(0.35)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(ready ? 1 : 0.5)
                .help(explain(m))
                .accessibilityLabel("Sync \(m.label(stacked: stacked))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func explain(_ m: SyncMode) -> String {
        switch m {
        case .upload: "Copy new and changed files from \(name(left)) to \(name(right)). \(name(left)) stays as it is."
        case .download: "Copy new and changed files from \(name(right)) to \(name(left)). \(name(right)) stays as it is."
        case .both: "Each side gets what it misses; when a file differs, the rules pick the winner (newest by default)."
        }
    }

    /// What the chosen direction touches, in plain words.
    private var changes: String {
        switch mode {
        case .upload: "Only \(name(right)) changes"
        case .download: "Only \(name(left)) changes"
        case .both: "Both sides can change"
        }
    }

    /// Never syncs straight away: it opens the preview, where Sync is the last step.
    private var syncButton: some View {
        let label = store.theme.label
        let stack = stacked ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))
        return stack {
            Button { hover?.cancel(); showHelp = false; Task { await store.sync(mode, left, right, dryRun: true) } } label: {
                Image(systemName: "eye")
                    .font(.title3.weight(.semibold)).foregroundStyle(ready ? store.theme.onAccent : .white)
                    .frame(width: stacked ? 34 : 44, height: stacked ? 34 : 44)
                    .background(Circle().fill(ready ? AnyShapeStyle(LinearGradient(colors: [store.theme.accent, store.theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.secondary.opacity(0.4))))
                    .shadow(color: label && ready ? store.theme.accent.opacity(0.55) : .clear, radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(!ready || store.planning)
            .accessibilityLabel("Preview sync")
            .onHover { on in
                hover?.cancel()
                if on && ready { hover = Task { try? await Task.sleep(for: .milliseconds(450)); if !Task.isCancelled { showHelp = true } } }
                else { showHelp = false }
            }
            .popover(isPresented: $showHelp, arrowEdge: stacked ? .top : .trailing) { help }
            VStack(spacing: 1) {
                if store.planning { ProgressView().controlSize(.mini) }
                else if label { Text("PREVIEW SYNC").font(bebas(15)).tracking(0.5).foregroundStyle(ready ? store.theme.accent : .secondary) }
                else { Text("Preview sync").themedFont(.caption.weight(.semibold)).foregroundStyle(ready ? .primary : .secondary) }
                if ready {
                    Text(changes).themedFont(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: stacked ? 150 : 96).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(ready ? "" : "Open a location on both sides to sync")
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How sync works").themedFont(.headline)
            Label("Pick the direction with the buttons above. The lit one is used.", systemImage: "1.circle")
            Label("Click here: you see every file that would change. Nothing changes yet. Space shows what changes inside a file.", systemImage: "2.circle")
            Label("Click Sync in the preview. Changed your mind? Undo in the status bar, with ⌘Z or in Activity.", systemImage: "3.circle")
            Text("Nothing is ever deleted. Files that get replaced are backed up first. Rules sets which version wins.").themedFont(.caption).foregroundStyle(.secondary)
        }
        .themedFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14).frame(width: 300)
    }

    /// Shown only while files are selected, so it's never mistaken for the sync direction.
    private var selectionCopy: some View {
        let stack = stacked ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        return stack {
            Text("Selected").themedFont(.caption2).foregroundStyle(.secondary)
            if !left.selection.isEmpty { copyButton(from: left, to: right, symbol: stacked ? "arrow.down" : "arrow.right", trailing: true) }
            if !right.selection.isEmpty { copyButton(from: right, to: left, symbol: stacked ? "arrow.up" : "arrow.left", trailing: false) }
        }
    }

    private func copyButton(from: Pane, to: Pane, symbol: String, trailing: Bool) -> some View {
        let n = from.selection.count
        return Button { copy(from, to) } label: {
            HStack(spacing: 3) {
                if !trailing { Image(systemName: symbol) }
                Text("Copy \(n)").themedFont(.caption).monospacedDigit()
                if trailing { Image(systemName: symbol) }
            }
            .frame(minWidth: 64)
        }
        .help("Copy the \(n) selected \(n == 1 ? "item" : "items") from \(name(from)) to \(name(to)). A copy that replaces files shows a preview first; you can undo it afterwards.")
    }

    private func copy(_ from: Pane, _ to: Pane) {
        guard let e = from.endpoint else { return }
        let items = from.selected
        Task { await store.copy(items, from: e, to: to) }
    }
}
