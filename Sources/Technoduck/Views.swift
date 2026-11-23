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

/// What a sync or a copy is going to do: every file that differs, with what happens to it. Each one can be
/// sent the other way or left alone; nothing changes until you click Sync (or Copy) here.
struct SyncPlanSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("syncMode") private var mode = SyncMode.upload
    let plan: SyncPlan
    @State private var selection = Set<CompareRow.ID>()
    @State private var quick: QuickItem?
    @State private var showRules = false
    /// Your own choices, by path; everything else follows the rules.
    @State private var picks: [String: Pick] = [:]
    @State private var filters: Set<Filter> = [.differs, .onlyA, .onlyB]

    struct QuickItem: Identifiable { let ops: [SyncOp]; let index: Int; var id: Int { index } }
    enum Pick: Hashable { case toA, toB, skip }
    enum Filter: Hashable { case differs, onlyA, onlyB, same }

    private var isCopy: Bool { plan.title != nil }
    private var verb: String { isCopy ? "Copy" : "Sync" }

    var body: some View {
        let ops = finalOps
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
                sides(ops)
                if !isCopy { options }
                notes(ops)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)  // the list below gives way, not the header
            .padding()
            .opacity(store.planning ? 0.5 : 1)
            Divider()
            if store.planning {
                ProgressView("Comparing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !isCopy { filterBar.padding(.horizontal).padding(.vertical, 8) }
                if shown.isEmpty {
                    ContentUnavailableView(plan.rows.contains { $0.status != .same } ? "Nothing to Show" : "Already in Sync", systemImage: "checkmark.circle",
                                           description: Text(emptyText))
                } else {
                    table(ops)
                }
            }
            Divider()
            footer(ops).padding()
        }
        .frame(width: 960, height: 700)
        .background(store.theme.label ? store.theme.bar ?? .clear : .clear)
        .onAppear { if !isCopy { mode = plan.mode } }
        .onChange(of: store.rules) { if !isCopy { Task { await store.sync(mode, plan.a, plan.b, dryRun: true) } } }
        .onChange(of: plan.ops) { picks = [:] }  // a new direction or rule starts from the rules again
        .sheet(item: $quick) { q in FileCompareView(plan: plan, files: q.ops, index: q.index).themed(store.theme) }
    }

    private var heading: String {
        isCopy ? { let n = plan.ops.filter(\.overwrite).count; return "replaces \(n) existing \(n == 1 ? "file" : "files")" }() : plan.mode.phrase(plan.a, plan.b)
    }

    // MARK: What happens to each file

    private var defaults: [String: Side] { Dictionary(plan.ops.map { ($0.rel, $0.to) }, uniquingKeysWith: { x, _ in x }) }
    private func pick(_ r: CompareRow, _ d: [String: Side]) -> Pick {
        picks[r.rel] ?? d[r.rel].map { $0 == .a ? .toA : .toB } ?? .skip
    }
    /// A copy only goes one way; a sync can send a file either way, as long as it exists on that side.
    private func can(_ p: Pick, _ r: CompareRow) -> Bool {
        switch p {
        case .skip: true
        case .toB: r.a != nil && (r.b == nil || r.a!.isDir == r.b!.isDir)
        case .toA: !isCopy && r.b != nil && (r.a == nil || r.a!.isDir == r.b!.isDir)
        }
    }

    private var finalOps: [SyncOp] {
        let d = defaults
        return applyChoices(plan.rows, plan.ops) { r in
            switch pick(r, d) { case .toA: .a; case .toB: .b; case .skip: nil }
        }
    }

    private func filter(_ r: CompareRow) -> Filter {
        switch r.status { case .same: .same; case .onlyA: .onlyA; case .onlyB: .onlyB; default: .differs }
    }
    private var shown: [CompareRow] { plan.rows.filter { filters.contains(filter($0)) } }
    private var emptyText: String {
        let same = plan.rows.filter { $0.status == .same }.count
        if plan.rows.contains(where: { $0.status != .same }) { return "Nothing matches the filters above." }
        return same == 0 ? "Both folders are empty." : "All \(same) \(same == 1 ? "file is" : "files are") the same on both sides."
    }

    // MARK: Header

    /// Both folders, the arrow between them, and for each whether it changes.
    private func sides(_ ops: [SyncOp]) -> some View {
        let toA = ops.contains { $0.to == .a }, toB = ops.contains { $0.to == .b }
        return HStack(spacing: 12) {
            side(plan.a, .a, ops)
            Image(systemName: toA && toB ? "arrow.left.arrow.right" : toA ? "arrow.left" : toB ? "arrow.right"
                  : plan.mode == .both ? "arrow.left.arrow.right" : plan.mode == .upload ? "arrow.right" : "arrow.left")
                .font(.title.weight(.bold)).foregroundStyle(store.theme.accent)
            side(plan.b, .b, ops)
        }
    }

    private func side(_ e: Endpoint, _ s: Side, _ ops: [SyncOp]) -> some View {
        let files = ops.filter { $0.to == s && !$0.isDir }, dirs = ops.filter { $0.isDir && $0.to == s }.count
        let n = files.count, bytes = files.reduce(Int64(0)) { $0 + $1.size }
        let changes = n + dirs > 0
        let writes = changes || plan.mode == .both || (plan.mode == .upload) == (s == .b)
        let tint: Color = store.theme.label ? store.theme.accent : .orange
        return VStack(alignment: .leading, spacing: 3) {
            Text(e.place).themedFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(e.name).themedFont(.headline).lineLimit(1).truncationMode(.middle)
            Text(e.root).themedFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Group {
                if !writes { Label("Read only: stays as it is", systemImage: "lock") }
                else if changes {
                    Label("Gets \(n) \(n == 1 ? "file" : "files") · \(fmtBytes(bytes))" + (dirs > 0 ? " · \(dirs) new \(dirs == 1 ? "folder" : "folders")" : ""),
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

    /// Direction, rules and auto-upload. Changing the direction or a rule compares again.
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
    private func notes(_ ops: [SyncOp]) -> some View {
        let replaced = ops.filter(\.overwrite).count, warned = ops.filter { $0.warning != nil }.count
        let ex = store.excludes(plan.a) + store.excludes(plan.b)
        return VStack(alignment: .leading, spacing: 4) {
            if replaced > 0 {
                Label("\(replaced) existing \(replaced == 1 ? "file is" : "files are") replaced. Each is backed up first, so Undo puts it back.", systemImage: "arrow.triangle.2.circlepath")
            }
            if warned > 0 {
                Label("\(warned) of them \(warned == 1 ? "replaces a file that is" : "replace files that are") newer. Check the rows marked ⚠.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text((ex.isEmpty ? "" : "Skipping \(ex.joined(separator: ", ")). ") + (store.showHidden ? "Hidden files included." : "Hidden files skipped (View › Show Hidden Files).") + " Nothing is ever deleted.")
                .foregroundStyle(.secondary)
        }
        .themedFont(.caption).lineLimit(2)
    }

    /// Which differences the list shows, with how many of each.
    private var filterBar: some View {
        let count = { (f: Filter) in plan.rows.filter { filter($0) == f }.count }
        return HStack(spacing: 6) {
            Text("Show").themedFont(.caption).foregroundStyle(.secondary)
            chip(.differs, "≠ Different", count(.differs))
            chip(.onlyA, "Only in \(short(plan.a.name))", count(.onlyA))
            chip(.onlyB, "Only in \(short(plan.b.name))", count(.onlyB))
            chip(.same, "= Same", count(.same))
            Spacer()
        }
    }
    private func chip(_ f: Filter, _ title: String, _ n: Int) -> some View {
        let on = filters.contains(f)
        return Button { if on { filters.remove(f) } else { filters.insert(f) } } label: {
            Text("\(title)  \(n)").monospacedDigit().lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? store.theme.accent.opacity(0.2) : Color.secondary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(on ? store.theme.accent : Color.secondary.opacity(0.3)))
                .foregroundStyle(on ? Color.primary : .secondary)
        }
        .buttonStyle(.plain).themedFont(.caption.weight(.semibold))
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Hide these" : "Show these")
    }
    private func short(_ s: String) -> String { s.count > 22 ? s.prefix(20) + "…" : s }

    // MARK: The list

    private func table(_ ops: [SyncOp]) -> some View {
        let d = defaults, warn = Dictionary(ops.compactMap { o in o.warning.map { (o.rel, $0) } }, uniquingKeysWith: { x, _ in x })
        return Table(shown, selection: $selection) {
            TableColumn("Path") { r in
                HStack(spacing: 4) {
                    if r.isDir { Image(systemName: "folder").foregroundStyle(.secondary) }
                    if let w = warn[r.rel] { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(w) }
                    Text(r.rel).lineLimit(1).truncationMode(.middle)
                }
                .opacity(pick(r, d) == .skip && r.status != .same ? 0.75 : 1)
            }
            .width(min: 160, ideal: 300)
            TableColumn(short(plan.a.name)) { r in facts(r.a, newer: r.status == .newerA) }.width(min: 100, ideal: 140)
            TableColumn("") { r in status(r) }.width(30)
            TableColumn(short(plan.b.name)) { r in facts(r.b, newer: r.status == .newerB) }.width(min: 100, ideal: 140)
            TableColumn("What happens") { r in action(r, d) }.width(min: 140, ideal: 170)
            TableColumn("") { r in
                if !r.isDir {
                    Button { look(r.rel, ops) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("Show what differs in this file (Space)")
                }
            }
            .width(26)
        }
        .contextMenu(forSelectionType: CompareRow.ID.self) { ids in
            let rows = plan.rows.filter { ids.contains($0.rel) }
            if let r = rows.first, rows.count == 1, !r.isDir { Button("Show What Differs") { look(r.rel, ops) }; Divider() }
            if !isCopy { Button("Copy to \(plan.b.name)") { set(.toB, rows) }.disabled(!rows.contains { can(.toB, $0) }) }
            if !isCopy { Button("Copy to \(plan.a.name)") { set(.toA, rows) }.disabled(!rows.contains { can(.toA, $0) }) }
            if isCopy { Button("Copy") { set(.toB, rows) } }
            Button("Leave Alone") { set(.skip, rows) }
            Divider()
            Button("Back to the Rules") { for r in rows { picks[r.rel] = nil } }.disabled(!rows.contains { picks[$0.rel] != nil })
        } primaryAction: { ids in if let id = ids.first { look(id, ops) } }
        .onKeyPress(.space) { if let id = selection.first { look(id, ops) }; return .handled }
        .alternatingRowBackgrounds(store.theme.label ? .disabled : .automatic)
    }

    private func set(_ p: Pick, _ rows: [CompareRow]) { for r in rows where can(p, r) { picks[r.rel] = p } }

    /// Size and date on one side; the newer side's date stands out.
    @ViewBuilder private func facts(_ f: RemoteFile?, newer: Bool) -> some View {
        if let f {
            HStack(spacing: 6) {
                Text(f.isDir ? "Folder" : fmtBytes(f.size)).monospacedDigit()
                Text(f.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "").fontWeight(newer ? .semibold : .regular)
                    .foregroundStyle(newer ? Color.primary : .secondary)
            }
            .themedFont(.caption).lineLimit(1)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func status(_ r: CompareRow) -> some View {
        let (sym, help): (String, String) = switch r.status {
        case .same: ("=", r.why ?? "The same on both sides")
        case .onlyA: ("◀", "Only in \(plan.a.name)")
        case .onlyB: ("▶", "Only in \(plan.b.name)")
        case .newerA: ("≠", "Newer in \(plan.a.name)")
        case .newerB: ("≠", "Newer in \(plan.b.name)")
        case .differs: ("≠", r.a?.isDir != r.b?.isDir ? "A file on one side, a folder on the other" : "Different size, same date")
        }
        return Text(sym).fontWeight(.bold).foregroundStyle(r.status == .same ? Color.secondary : store.theme.accent)
            .frame(maxWidth: .infinity).help(help)
    }

    /// What happens to this file, as a menu: the rules' choice, or yours.
    private func action(_ r: CompareRow, _ d: [String: Side]) -> some View {
        let p = pick(r, d), mine = picks[r.rel] != nil
        let label: String = switch p {
        case .toB: "Copy to \(short(plan.b.name))"
        case .toA: "Copy to \(short(plan.a.name))"
        case .skip: r.status == .same ? "Nothing" : "Left alone"
        }
        let icon = switch p { case .toB: arrowTo(.b); case .toA: arrowTo(.a); case .skip: "minus" }
        return Menu {
            Picker("", selection: Binding(get: { p }, set: { picks[r.rel] = $0 == (d[r.rel].map { $0 == .a ? Pick.toA : .toB } ?? .skip) ? nil : $0 })) {
                if can(.toB, r) { Label("Copy to \(plan.b.name)", systemImage: arrowTo(.b)).tag(Pick.toB) }
                if can(.toA, r) { Label("Copy to \(plan.a.name)", systemImage: arrowTo(.a)).tag(Pick.toA) }
                Label("Leave alone", systemImage: "minus").tag(Pick.skip)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(label + (mine ? " ·" : ""), systemImage: icon)
        }
        .menuStyle(.borderlessButton).menuIndicator(r.status == .same && p == .skip ? .hidden : .visible)
        .foregroundStyle(p == .skip ? Color.secondary : store.theme.label ? store.theme.accent : p == .toB ? .orange : .blue)
        .help(mine ? "Your choice; right-click › Back to the Rules undoes it" : p == .skip ? (r.why ?? why(r)) : "Chosen by the rules")
    }

    private func arrowTo(_ s: Side) -> String {
        let st = store.stacked && !isCopy
        return s == .b ? (st ? "arrow.down" : "arrow.right") : (st ? "arrow.up" : "arrow.left")
    }

    /// Why a different file is left alone when the rules gave no reason of their own.
    private func why(_ r: CompareRow) -> String {
        switch (r.status, plan.mode) {
        case (.same, _): "The same on both sides"
        case (.onlyB, .upload): "Only in \(plan.b.name); this direction doesn't copy it"
        case (.onlyA, .download): "Only in \(plan.a.name); this direction doesn't copy it"
        case (.newerB, .upload), (.newerA, .download): "The copy there is newer; this direction doesn't copy it back"
        case (_, .both): "Same size on both sides: counts as unchanged"
        default: "Left alone by the rules"
        }
    }

    /// Opens the comparison for a file, with the files around it in the list for ← and →.
    /// A file that's left alone is shown as if it were copied the usual way, marked as not copied.
    private func look(_ rel: String, _ ops: [SyncOp]) {
        let byRel = Dictionary(ops.map { ($0.rel, $0) }, uniquingKeysWith: { x, _ in x })
        let list: [SyncOp] = shown.filter { !$0.isDir }.compactMap { r in
            if let op = byRel[r.rel] { return op }
            let to: Side = r.a != nil && (r.status != .newerB || r.b == nil) ? .b : .a
            guard let src = to == .b ? r.a : r.b else { return nil }
            return SyncOp(to: to, rel: r.rel, size: src.size, modified: src.modified, overwrite: (to == .b ? r.b : r.a) != nil, reason: SyncOp.notCopied)
        }
        if let i = list.firstIndex(where: { $0.rel == rel }) { quick = QuickItem(ops: list, index: i) }
    }

    private func footer(_ ops: [SyncOp]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Space shows what differs in a file. Click What happens, or right-click, to choose per file.", systemImage: "eye")
                Label("You can undo this afterwards: status bar, ⌘Z or Activity.", systemImage: "arrow.uturn.backward")
            }
            .themedFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !picks.isEmpty {
                Button("Back to the Rules") { picks = [:] }.labelButtons(store.theme.label, accent: store.theme.accent)
                    .help("Undo your own choices: \(picks.count)")
            }
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                .labelButtons(store.theme.label, accent: store.theme.accent)
            Button("\(verb) \(ops.count) \(ops.count == 1 ? "Item" : "Items")") {
                var p = plan; p.ops = ops; dismiss()
                Task { await store.run(p, title: p.title ?? "Sync " + p.mode.phrase(p.a, p.b), kind: p.kind) }
            }
            .keyboardShortcut(.defaultAction).disabled(ops.isEmpty || store.planning)
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
