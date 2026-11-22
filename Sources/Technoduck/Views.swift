import SwiftUI
import UniformTypeIdentifiers

extension Activity {
    var color: Color {
        switch self {
        case .upload: .orange
        case .download: .blue
        case .sync: .purple
        case .delete: .red
        case .mkdir: .green
        case .rollback: .gray
        }
    }
}

/// What a sync or a copy is going to do. Nothing changes until you click Sync (or Copy) here.
struct SyncPlanSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("syncMode") private var mode = SyncMode.upload
    let plan: SyncPlan
    @State private var selection = Set<SyncOp.ID>()
    @State private var quick: QuickItem?
    @State private var showRules = false

    struct QuickItem: Identifiable { let index: Int; var id: Int { index } }

    private var isCopy: Bool { plan.title != nil }
    private var verb: String { isCopy ? "Copy" : "Sync" }
    private var files: [SyncOp] { plan.ops.filter { !$0.isDir } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if store.theme.label {
                    Eyebrow("Preview · nothing has changed yet")
                    (Text("\(verb.uppercased()): ").font(bebas(36)) + Text(heading.uppercased()).font(bebas(36)).foregroundColor(store.theme.accent))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Preview · nothing has changed yet").themedFont(.caption).foregroundStyle(.secondary)
                    Text("\(verb): \(heading)").themedFont(.title3.bold()).lineLimit(1).truncationMode(.middle)
                }
                sides
                if !isCopy { options }
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)  // the list below gives way, not the header
            .padding()
            .opacity(store.planning ? 0.5 : 1)
            Divider()
            if store.planning {
                ProgressView("Comparing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plan.ops.isEmpty {
                ContentUnavailableView("Already in Sync", systemImage: "checkmark.circle",
                                       description: Text(plan.skipped.isEmpty ? "Nothing would be copied this way." : "Nothing would be copied this way. The files left alone are listed below, each with the reason."))
            } else {
                table
            }
            if !plan.skipped.isEmpty && !store.planning { skipped }
            Divider()
            footer.padding()
        }
        .frame(width: 800, height: 660)
        .background(store.theme.label ? store.theme.bar ?? .clear : .clear)
        .onAppear { if !isCopy { mode = plan.mode } }
        .onChange(of: store.rules) { if !isCopy { Task { await store.sync(mode, plan.a, plan.b, dryRun: true) } } }
        .sheet(item: $quick) { q in FileCompareView(plan: plan, files: files, index: q.index).themed(store.theme) }
    }

    private var heading: String {
        isCopy ? { let n = plan.ops.filter(\.overwrite).count; return "replaces \(n) existing \(n == 1 ? "file" : "files")" }() : plan.mode.phrase(plan.a, plan.b)
    }

    /// Both folders, the arrow between them, and for each whether it changes.
    private var sides: some View {
        HStack(spacing: 12) {
            side(plan.a, .a)
            Image(systemName: plan.mode == .both ? "arrow.left.arrow.right" : plan.mode == .upload ? "arrow.right" : "arrow.left")
                .font(.title.weight(.bold)).foregroundStyle(store.theme.accent)
            side(plan.b, .b)
        }
    }

    private func side(_ e: Endpoint, _ s: Side) -> some View {
        let writes = plan.mode == .both || (plan.mode == .upload) == (s == .b)
        let n = plan.files(to: s).count, dirs = plan.ops.filter { $0.isDir && $0.to == s }.count
        let changes = n + dirs > 0
        let tint: Color = store.theme.label ? store.theme.accent : .orange
        return VStack(alignment: .leading, spacing: 3) {
            Text(e.place).themedFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(e.name).themedFont(.headline).lineLimit(1).truncationMode(.middle)
            Text(e.root).themedFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Group {
                if !writes { Label("Read only: stays as it is", systemImage: "lock") }
                else if changes {
                    Label("Gets \(n) \(n == 1 ? "file" : "files") · \(fmtBytes(plan.bytes(to: s)))" + (dirs > 0 ? " · \(dirs) new \(dirs == 1 ? "folder" : "folders")" : ""),
                          systemImage: "square.and.arrow.down.fill").foregroundStyle(tint)
                } else { Label("No changes", systemImage: "checkmark") }
            }
            .themedFont(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: store.theme.corner(8)).fill(changes ? tint.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: store.theme.corner(8)).strokeBorder(changes ? tint.opacity(0.7) : Color.secondary.opacity(0.3), lineWidth: changes ? 1.5 : 1))
    }

    /// Direction, rules, auto-upload and what gets skipped. Changing the direction or a rule compares again.
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Direction", selection: $mode) {
                    ForEach(SyncMode.allCases) { m in Label(title(m), systemImage: m.symbol(stacked: false)).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: mode) { if mode != plan.mode { Task { await store.sync(mode, plan.a, plan.b, dryRun: true) } } }
                Button { showRules.toggle() } label: { Label("Rules", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $showRules, arrowEdge: .bottom) { SyncRulesForm(stacked: store.stacked) }
                    .labelButtons(store.theme.label, accent: store.theme.accent)
                    .help("What wins when a file differs on both sides")
            }
            Text(store.rules.summary(mode)).themedFont(.caption).foregroundStyle(.secondary)
            if let pp = store.planPanes, let b = store.pairable(pp.0, pp.1) {
                Toggle("Keep uploading changes from this Mac to \(b.title) while Techno Goose is open",
                       isOn: Binding(get: { store.autoSyncOn(pp.0, pp.1) }, set: { store.setAutoSync($0, pp.0, pp.1) }))
                    .themedFont(.callout)
            }
        }
    }

    /// "To public_html": the folder that changes, cut short so the three choices fit.
    private func title(_ m: SyncMode) -> String {
        guard m != .both else { return "Both ways" }
        let n = (m == .upload ? plan.b : plan.a).name
        return "To " + (n.count > 26 ? n.prefix(24) + "…" : n)
    }

    /// Replaced files, warnings and what's skipped, in one line.
    private var notes: some View {
        let replaced = plan.ops.filter(\.overwrite).count, warned = plan.ops.filter { $0.warning != nil }.count
        let ex = store.excludes(plan.a) + store.excludes(plan.b)
        return VStack(alignment: .leading, spacing: 4) {
            if replaced > 0 {
                Label("\(replaced) existing \(replaced == 1 ? "file is" : "files are") replaced. Each is backed up first, so Undo puts it back.", systemImage: "arrow.triangle.2.circlepath")
            }
            if warned > 0 {
                Label("\(warned) of them \(warned == 1 ? "replaces a file that is" : "replace files that are") newer. Check the rows marked ⚠ or change the rules.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text((ex.isEmpty ? "" : "Skipping \(ex.joined(separator: ", ")). ") + (store.showHidden ? "Hidden files included." : "Hidden files skipped (View › Show Hidden Files).") + " Nothing is ever deleted.")
                .foregroundStyle(.secondary)
        }
        .themedFont(.caption).lineLimit(2)
    }

    private var table: some View {
        Table(plan.ops, selection: $selection) {
            TableColumn("") { op in
                Image(systemName: op.isDir ? "folder.badge.plus" : arrow(op))
                    .foregroundStyle(store.theme.label ? store.theme.accent : op.isDir ? Color.green : op.to == .b ? Color.orange : Color.blue)
                    .help(op.isDir ? "New folder" : "Copied to \((op.to == .a ? plan.a : plan.b).name)")
            }
            .width(22)
            TableColumn("Path") { op in
                HStack(spacing: 4) {
                    if let w = op.warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(w) }
                    Text(op.rel).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("To") { op in Text((op.to == .a ? plan.a : plan.b).name).lineLimit(1).foregroundStyle(.secondary) }.width(110)
            TableColumn("Why") { op in Text(op.warning.map { _ in op.reason + " ⚠" } ?? op.reason).foregroundStyle(op.warning == nil ? .secondary : Color.orange) }.width(100)
            TableColumn("Size") { op in Text(op.isDir ? "" : fmtBytes(op.size)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("") { op in
                if !op.isDir {
                    Button { show(op.id) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help(op.overwrite ? "Show what changes in this file (Space)" : "Show this new file (Space)")
                }
            }
            .width(26)
        }
        .contextMenu(forSelectionType: SyncOp.ID.self) { ids in
            if let id = ids.first, files.contains(where: { $0.id == id }) { Button("Show Changes") { show(id) } }
        } primaryAction: { ids in if let id = ids.first { show(id) } }
        .onKeyPress(.space) { if let id = selection.first { show(id) }; return .handled }
        .alternatingRowBackgrounds(store.theme.label ? .disabled : .automatic)
    }

    private func arrow(_ op: SyncOp) -> String {
        let s = store.stacked && !isCopy
        return op.to == .b ? (s ? "arrow.down" : "arrow.right") : (s ? "arrow.up" : "arrow.left")
    }

    private func show(_ id: SyncOp.ID) {
        if let i = files.firstIndex(where: { $0.id == id }) { quick = QuickItem(index: i) }
    }

    private var skipped: some View {
        DisclosureGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.skipped) { f in
                        HStack { Text(f.rel).lineLimit(1).truncationMode(.middle); Spacer(); Text(f.why).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(maxHeight: 90)
        } label: {
            Label("\(plan.skipped.count) \(plan.skipped.count == 1 ? "file looks different but is" : "files look different but are") left alone, with the reason for each", systemImage: "hand.raised")
        }
        .themedFont(.callout).padding(.horizontal).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Space or double-click shows what changes in a file.", systemImage: "eye")
                Label("You can undo this afterwards: status bar, ⌘Z or Activity.", systemImage: "arrow.uturn.backward")
            }
            .themedFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                .labelButtons(store.theme.label, accent: store.theme.accent)
            Button("\(verb) \(plan.ops.count) \(plan.ops.count == 1 ? "Item" : "Items")") {
                let p = plan; dismiss()
                Task { await store.run(p, title: p.title ?? "Sync " + p.mode.phrase(p.a, p.b), kind: p.kind) }
            }
            .keyboardShortcut(.defaultAction).disabled(plan.ops.isEmpty || store.planning)
            .labelButtons(store.theme.label, accent: store.theme.accent, prominent: true)
        }
    }
}

extension SyncRules {
    /// One line for the preview: the rule that applies to this direction.
    func summary(_ mode: SyncMode) -> String {
        let what = compare == .sizeOnly ? "Changed means a different size." : "Changed means a different size or a newer date."
        switch mode {
        case .both:
            let w = switch conflict { case .newest: "the newest version wins"; case .a: "the left (or top) side wins"; case .b: "the right (or bottom) side wins"; case .skip: "both are left alone" }
            return "Rules: \(what) Changed on both sides: \(w)."
        default:
            let r = switch replace { case .whenDifferent: "it is replaced"; case .onlyNewer: "it is replaced only if the incoming file is newer"; case .never: "it is left alone, only new files are added" }
            return "Rules: \(what) When a file changed, \(r)."
        }
    }
}

/// The Rules panel: what counts as changed and which version wins. Used for every sync.
struct SyncRulesForm: View {
    @Environment(Store.self) private var store
    var stacked = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync Rules").themedFont(.headline)
                Text("For files that exist on both sides but differ. New files are always copied, and nothing is ever deleted.")
                    .themedFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            group("A file has changed when") {
                Picker("", selection: $store.rules.compare) {
                    Text("Its size or its date differs").tag(SyncRules.Compare.dateAndSize)
                    Text("Its size differs").tag(SyncRules.Compare.sizeOnly)
                }
                note("A file that only has a newer date is first checked byte for byte; if the contents are the same, it is left alone.")
            }
            group("One way: the file is different on the other side") {
                Picker("", selection: $store.rules.replace) {
                    Text("Replace it").tag(SyncRules.Replace.whenDifferent)
                    Text("Replace it only if the incoming file is newer").tag(SyncRules.Replace.onlyNewer)
                    Text("Never replace, only add new files").tag(SyncRules.Replace.never)
                }
            }
            group("Both ways: changed on both sides") {
                Picker("", selection: $store.rules.conflict) {
                    Text("Newest version wins").tag(SyncRules.Conflict.newest)
                    Text(stacked ? "Top side wins" : "Left side wins").tag(SyncRules.Conflict.a)
                    Text(stacked ? "Bottom side wins" : "Right side wins").tag(SyncRules.Conflict.b)
                    Text("Leave both alone").tag(SyncRules.Conflict.skip)
                }
                note("Files with the same size count as unchanged here, so they don't bounce back and forth.")
            }
            HStack {
                Text("Replaced files are backed up first, so a sync can be undone.").themedFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Defaults") { store.rules = SyncRules() }.disabled(store.rules == SyncRules())
                    .labelButtons(store.theme.label, accent: store.theme.accent)
            }
        }
        .pickerStyle(.radioGroup).labelsHidden()
        .themedFont(.callout)
        .padding(16).frame(width: 360)
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).themedFont(.callout.weight(.semibold))
            content()
        }
    }
    private func note(_ s: String) -> some View {
        Text(s).themedFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct StatusBar: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(spacing: 8) {
            if store.planning || store.panes.contains(where: \.busy) { ProgressView().controlSize(.small) }
            Text(store.message.isEmpty ? " " : store.message).lineLimit(1).truncationMode(.tail)
            if let id = store.lastUndo, store.canUndo(id), let r = store.records.first(where: { $0.id == id }) {
                Label(r.title, systemImage: "checkmark.circle").lineLimit(1).truncationMode(.middle)
                Button("Undo") { Task { await store.rollback(id) } }
                    .controlSize(.small).help("Puts back what \(r.title) changed (⌘Z)")
                    .labelButtons(store.theme.label, accent: store.theme.accent)
            }
            Spacer()
            if store.showHidden { Label("Hidden files shown", systemImage: "eye").labelStyle(.titleAndIcon) }
            if let c = store.active?.bookmark { Image(systemName: "lock.fill").opacity(c.proto == .ftp || c.proto == .webdav ? 0 : 1); Text(c.proto.rawValue) }
            if store.theme.label {   // the status diamond
                Rectangle().fill(store.theme.accent).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                    .shadow(color: store.theme.accent.opacity(0.7), radius: 5).padding(.leading, 4).accessibilityHidden(true)
            }
        }
        .themedFont(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .themeBackground(store.theme.bar, .bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct InspectorView: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("View", selection: $store.inspectorTab) {
                Text("Transfers").tag(Store.Tab.transfers)
                Text("Timeline").tag(Store.Tab.timeline)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            if store.inspectorTab == .transfers { TransfersView() } else { TimelineView() }
        }
    }
}

struct TransfersView: View {
    @Environment(Store.self) private var store
    var body: some View {
        if store.transfers.isEmpty {
            ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down", description: Text("Copies and syncs appear here."))
        } else {
            List(store.transfers) { t in TransferRow(t: t) }
                .safeAreaInset(edge: .bottom) {
                    Button("Clean Up") { store.transfers.removeAll { $0.state != .running } }.padding(8)
                }
        }
    }
}

struct TransferRow: View {
    @Environment(Store.self) private var store
    let t: Transfer
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: t.kind.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(t.kind.color, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).lineLimit(1)
                switch t.state {
                case .running: ProgressView(value: t.progress)
                case .done: Text("Complete · \(t.started.formatted(date: .omitted, time: .shortened))").themedFont(.caption).foregroundStyle(.green)
                case .failed(let m): Text(m).themedFont(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Text(t.detail).themedFont(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                if t.state != .running, let r = t.recordID, store.canUndo(r) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.rollback(r) } }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything that changed on one connection, newest first, grouped per day.
struct TimelineView: View {
    @Environment(Store.self) private var store
    @State private var pick: UUID?

    var body: some View {
        let id = pick ?? store.active?.bookmark?.id ?? store.panes.compactMap(\.bookmark?.id).first ?? store.bookmarks.first?.id
        let events = store.log.filter { $0.bookmarkID == id }.sorted { $0.date > $1.date }
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        VStack(spacing: 0) {
            Picker("Connection", selection: Binding(get: { id }, set: { pick = $0 })) {
                ForEach(store.bookmarks) { b in Label("\(b.title) · \(b.proto.rawValue)", systemImage: b.proto.symbol).tag(Optional(b.id)) }
            }
            .labelsHidden().padding(.horizontal, 10).padding(.bottom, 10)
            Divider()
            if events.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock", description: Text("Uploads, downloads, syncs and deletes on this connection appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(days, id: \.key) { day in
                            Section {
                                ForEach(day.value) { e in TimelineRow(e: e) }
                            } header: {
                                Text(dayTitle(day.key)).themedFont(.caption.bold()).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }
    private func dayTitle(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

struct TimelineRow: View {
    @Environment(Store.self) private var store
    let e: LogEvent
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: e.kind.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(e.kind.color, in: Circle())
                Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(e.title).themedFont(.callout.weight(.medium)).lineLimit(2)
                    Spacer()
                    Text(e.date.formatted(date: .omitted, time: .shortened)).themedFont(.caption).foregroundStyle(.tertiary)
                }
                if !e.detail.isEmpty { Text(e.detail).themedFont(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle) }
                if e.bytes > 0 { Text(fmtBytes(e.bytes)).themedFont(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if !e.items.isEmpty {
                    DisclosureGroup("\(e.items.count) item\(e.items.count == 1 ? "" : "s")", isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(e.items.prefix(300).enumerated()), id: \.offset) { Text($0.element).lineLimit(1).truncationMode(.middle) }
                            if e.items.count > 300 { Text("… and \(e.items.count - 300) more") }
                        }
                        .themedFont(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .themedFont(.caption)
                }
                if let r = e.recordID {
                    if store.canUndo(r) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.rollback(r) } }.controlSize(.small).padding(.top, 2)
                    } else if store.records.contains(where: { $0.id == r }) {
                        Label("Undone", systemImage: "checkmark").themedFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.top, 8)
    }
}

struct BookmarkMenu: View {
    @Environment(Store.self) private var store
    let b: Bookmark
    @Binding var editing: Bookmark?
    var body: some View {
        Button("Connect") { Task { await store.connect(b) } }
        Button("Edit Bookmark…") { editing = b }
        Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") { Task { await store.backUp(b) } }
        Button(b.backupFolder == nil ? "Choose Backup Folder…" : "Change Backup Folder…") { store.chooseBackupFolder(for: b) }
        Divider()
        Button("Duplicate") { var c = b; c.id = UUID(); c.nickname = b.title + " copy"; store.bookmarks.append(c) }
        Divider()
        Button("Delete Bookmark", role: .destructive) { Keychain.set(b, ""); store.bookmarks.removeAll { $0.id == b.id } }
    }
}

struct ConnectionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var bookmark: Bookmark
    @State private var password = ""
    @State private var saveBookmark = true
    private var isExisting: Bool { store.bookmarks.contains { $0.id == bookmark.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Protocol", selection: $bookmark.proto) {
                    ForEach(Proto.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .onChange(of: bookmark.proto) { _, p in bookmark.port = p.defaultPort }
                TextField("Nickname", text: $bookmark.nickname, prompt: Text("Optional"))
                if bookmark.proto != .local {
                    TextField("Server", text: $bookmark.host, prompt: Text("example.com"))
                    TextField("Port", value: $bookmark.port, format: .number.grouping(.never))
                    TextField("Username", text: $bookmark.user, prompt: Text("Optional"))
                    SecureField("Password", text: $password, prompt: Text(bookmark.proto == .sftp ? "Leave empty to use your SSH key" : "Optional"))
                }
                TextField("Start folder", text: $bookmark.path, prompt: Text(bookmark.proto == .local ? homeDir : "Home folder"))
                if !isExisting { Toggle("Add to Bookmarks", isOn: $saveBookmark) }
                Section("Sync") {
                    TextField("Exclude", text: Binding(get: { bookmark.excludes ?? "" }, set: { bookmark.excludes = $0.isEmpty ? nil : $0 }),
                              prompt: Text("node_modules, .git, *.log"))
                    LabeledContent("Local folder") {
                        HStack {
                            Text(bookmark.syncLocal ?? "Not paired yet").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { bookmark.syncLocal = u.path }
                            }
                        }
                    }
                    TextField("Server folder", text: Binding(get: { bookmark.syncRemote ?? "" }, set: { bookmark.syncRemote = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Set by your first sync"))
                    Toggle("Auto-upload changes from the local folder", isOn: Binding(get: { bookmark.autoSync ?? false }, set: { bookmark.autoSync = $0 }))
                        .disabled(bookmark.syncLocal == nil || bookmark.syncRemote == nil)
                }
                Section("Backup") {
                    LabeledContent("Backup folder") {
                        HStack {
                            Text(bookmark.backupFolder ?? "Asked on first backup").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                                if p.runModal() == .OK, let u = p.url { bookmark.backupFolder = u.path }
                            }
                        }
                    }
                }
                LabeledContent("URL") { Text(bookmark.url).textSelection(.enabled).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if isExisting { Button("Save") { persist(); dismiss() } }
                Button("Connect") {
                    persist()
                    let b = bookmark, pw = password
                    dismiss()
                    Task { await store.connect(b, password: pw) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bookmark.proto != .local && bookmark.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear { if isExisting { password = Keychain.get(bookmark) } }
    }

    private func persist() {
        if let i = store.bookmarks.firstIndex(where: { $0.id == bookmark.id }) { store.bookmarks[i] = bookmark }
        else if saveBookmark { store.bookmarks.append(bookmark) }
        else { return }
        Keychain.set(bookmark, password)
    }
}
