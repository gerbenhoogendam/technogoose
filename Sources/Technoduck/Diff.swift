import SwiftUI
import UniformTypeIdentifiers

// MARK: Line diff

/// One line of a diff. `old` numbers lines in the file that gets replaced, `new` in the file that arrives.
struct DiffLine: Identifiable {
    enum Kind { case same, removed, added }
    let id: Int
    let kind: Kind
    let old: Int?, new: Int?
    var text: AttributedString
}

/// What the compare view lists: lines, and runs of unchanged lines folded away.
enum DiffRow: Identifiable {
    case line(DiffLine)
    case gap(id: Int, lines: [DiffLine])
    var id: Int { switch self { case .line(let l): l.id; case .gap(let id, _): -1 - id } }
}

struct TextDiff {
    var lines: [DiffLine]
    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }

    /// Lines with `context` unchanged lines around each change; longer unchanged runs fold into a gap.
    func rows(context: Int = 3) -> [DiffRow] {
        var keep = [Bool](repeating: false, count: lines.count)
        for (i, l) in lines.enumerated() where l.kind != .same {
            for k in max(0, i - context)...min(lines.count - 1, i + context) { keep[k] = true }
        }
        var rows: [DiffRow] = [], run: [DiffLine] = []
        func flush() {
            if run.count <= 2 { rows += run.map(DiffRow.line) } else { rows.append(.gap(id: run[0].id, lines: run)) }
            run = []
        }
        for (i, l) in lines.enumerated() { if keep[i] { flush(); rows.append(.line(l)) } else { run.append(l) } }
        flush()
        return rows
    }
}

/// Compares two texts line by line, then marks the changed words inside lines that were edited.
func diffText(_ old: String, _ new: String) -> TextDiff {
    func split(_ s: String) -> [Substring] {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }
    let o = split(old), n = split(new)
    var removed = Set<Int>(), inserted = Set<Int>()
    // The common start and end are cheap to skip, and leave a small middle for the real diff.
    var pre = 0; while pre < o.count, pre < n.count, o[pre] == n[pre] { pre += 1 }
    var suf = 0; while suf < o.count - pre, suf < n.count - pre, o[o.count - 1 - suf] == n[n.count - 1 - suf] { suf += 1 }
    let om = o[pre..<(o.count - suf)], nm = n[pre..<(n.count - suf)]
    if om.count * nm.count > 40_000_000 {
        // Too different to diff quickly: the whole middle counts as replaced.
        removed = Set(om.indices); inserted = Set(nm.indices)
    } else {
        for c in Array(nm).difference(from: Array(om)) {
            switch c {
            case .remove(let off, _, _): removed.insert(pre + off)
            case .insert(let off, _, _): inserted.insert(pre + off)
            }
        }
    }
    var lines: [DiffLine] = [], i = 0, j = 0
    while i < o.count || j < n.count {
        if i < o.count, removed.contains(i) || j >= n.count {
            lines.append(DiffLine(id: lines.count, kind: .removed, old: i + 1, new: nil, text: plain(o[i]))); i += 1
        } else if j < n.count, inserted.contains(j) || i >= o.count {
            lines.append(DiffLine(id: lines.count, kind: .added, old: nil, new: j + 1, text: plain(n[j]))); j += 1
        } else {
            lines.append(DiffLine(id: lines.count, kind: .same, old: i + 1, new: j + 1, text: plain(o[i]))); i += 1; j += 1
        }
    }
    // A block of removed lines followed by added lines is an edit: pair them up and mark what changed inside.
    var k = 0
    while k < lines.count {
        guard lines[k].kind == .removed else { k += 1; continue }
        var r = k; while r < lines.count, lines[r].kind == .removed { r += 1 }
        var a = r; while a < lines.count, lines[a].kind == .added { a += 1 }
        for p in 0..<min(r - k, a - r) {
            let (x, y) = wordMarks(String(o[lines[k + p].old! - 1]), String(n[lines[r + p].new! - 1]))
            lines[k + p].text = x; lines[r + p].text = y
        }
        k = a
    }
    return TextDiff(lines: lines)
}

private let longLine = 2_000

/// A line as shown: very long lines (minified HTML) are cut down.
private func plain(_ s: Substring) -> AttributedString {
    guard s.count > longLine else { return AttributedString(String(s)) }
    var out = AttributedString(String(s.prefix(longLine)))
    out += faint(" … \((s.count - longLine).formatted()) more characters")
    return out
}
private func faint(_ s: String) -> AttributedString {
    var a = AttributedString(s); a.foregroundColor = .secondary; return a
}

/// Words, runs of spaces and single symbols, so a change marks whole words.
private func tokens(_ s: String) -> [Substring] {
    var out: [Substring] = [], start = s.startIndex, kind = -1
    func k(_ c: Character) -> Int { c.isLetter || c.isNumber || c == "_" ? 0 : c.isWhitespace ? 1 : 2 }
    for i in s.indices {
        let c = k(s[i])
        if i != start, c != kind || c == 2 { out.append(s[start..<i]); start = i }
        kind = c
    }
    if start < s.endIndex { out.append(s[start...]) }
    return out
}

/// The old and the new line, with the words that differ highlighted.
private func wordMarks(_ old: String, _ new: String) -> (AttributedString, AttributedString) {
    let a = tokens(old), b = tokens(new)
    var pre = 0; while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
    var suf = 0; while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
    var da = Set(pre..<(a.count - suf)), db = Set(pre..<(b.count - suf))
    let am = Array(a[pre..<(a.count - suf)]), bm = Array(b[pre..<(b.count - suf)])
    if am.count * bm.count <= 4_000_000 {
        da = []; db = []
        for c in bm.difference(from: am) {
            switch c { case .remove(let o, _, _): da.insert(pre + o); case .insert(let o, _, _): db.insert(pre + o) }
        }
    }
    return (marked(a, da, .red), marked(b, db, .green))
}

/// Joins tokens, highlighting the ones in `hot`. Long unchanged stretches are cut to the part around the changes.
private func marked(_ t: [Substring], _ hot: Set<Int>, _ color: Color) -> AttributedString {
    let long = t.reduce(0) { $0 + $1.count } > longLine
    var out = AttributedString(), i = 0
    while i < t.count {
        var j = i; let h = hot.contains(i)
        while j < t.count, hot.contains(j) == h { j += 1 }
        var s = t[i..<j].joined()
        if !h && long && s.count > 300 {   // keep 120 characters of context on each side of a change
            let head = i == 0 ? "" : String(s.prefix(120)), tail = j == t.count ? "" : String(s.suffix(120))
            out += AttributedString(head)
            out += faint(" … \((s.count - head.count - tail.count).formatted()) characters … ")
            s = tail
        }
        var piece = AttributedString(s)
        if h { piece.backgroundColor = color.opacity(0.38); piece.inlinePresentationIntent = .stronglyEmphasized }
        out += piece
        i = j
    }
    return out
}

// MARK: Loading both versions

/// What the compare view shows for one file.
enum FileComparison {
    case text(TextDiff, new: Bool)
    case identical
    /// Images, PDFs, fonts, video and audio, archives and other binaries.
    case details(FileDetails, new: Bool)
    case tooBig
    case failed(String)
}

/// Text when it has no NUL bytes and decodes as UTF-8 (or else Latin-1); UTF-16 with a byte order mark too. nil for binary files.
func decodeText(_ d: Data) -> String? {
    if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16) }
    if d.prefix(8000).contains(0) { return nil }
    return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
}

/// The file that arrives and the one it replaces (nil for a new file). `a`/`b` are the plan's ends.
func fetchVersions(_ op: SyncOp, _ a: Endpoint, _ b: Endpoint) async throws -> (new: Data, old: Data?) {
    let src = op.to == .a ? b : a, dst = op.to == .a ? a : b
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-compare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    func fetch(_ e: Endpoint, _ name: String) async throws -> Data {
        let path = joinPath(e.root, op.rel)
        if e.service is LocalService { return try Data(contentsOf: URL(fileURLWithPath: path)) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let u = tmp.appendingPathComponent(name)
        try await e.service.download(path, to: u)
        return try Data(contentsOf: u)
    }
    let new = try await fetch(src, "new")
    return (new, op.overwrite ? try await fetch(dst, "old") : nil)
}

/// Fetches the file that arrives and the one it replaces (if any) and compares them.
func compare(_ op: SyncOp, in plan: SyncPlan) async -> FileComparison {
    // Video and audio may be larger: only their facts and one frame are compared.
    let isMedia = UTType(filenameExtension: (op.rel as NSString).pathExtension)?.conforms(to: .audiovisualContent) == true
    let limit = isMedia ? 200_000_000 : 50_000_000
    if op.size > limit { return .tooBig }
    do {
        let (new, old) = try await fetchVersions(op, plan.a, plan.b)
        if old == new { return .identical }
        if old?.count ?? 0 > limit { return .tooBig }
        return await compare(op.rel, old: old, new: new)
    } catch {
        return .failed(error.localizedDescription)
    }
}

/// Compares two versions of `rel` already in memory: text line by line, everything else by its kind.
func compare(_ rel: String, old: Data?, new: Data) async -> FileComparison {
    if FileKind.of(rel, new) == .text, let nt = decodeText(new), old.map(decodeText) != .some(nil), new.count <= 20_000_000 {
        let ot = old.flatMap(decodeText) ?? ""
        return await Task.detached { .text(diffText(ot, nt), new: old == nil) }.value
    }
    return .details(await details(rel, old: old, new: new), new: old == nil)
}

extension FileComparison: @unchecked Sendable {}

// MARK: Compare view

/// Quick Look for a sync: what a file will look like after the sync, against what is there now.
struct FileCompareView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: SyncPlan
    let files: [SyncOp]
    @State var index: Int
    @State private var result: FileComparison?
    @State private var open: Set<Int> = []
    @State private var change = 0

    private var op: SyncOp { files[index] }
    private var src: Endpoint { op.to == .a ? plan.b : plan.a }
    private var dst: Endpoint { op.to == .a ? plan.a : plan.b }

    var body: some View {
        VStack(spacing: 0) {
            header.padding()
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.padding(.horizontal).padding(.vertical, 10)
        }
        .frame(width: 940, height: 680)
        .background(store.theme.label ? store.theme.bar ?? .clear : .clear)
        .task(id: index) { result = nil; open = []; change = 0; result = await compare(op, in: plan) }
        .onKeyPress(.space) { dismiss(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text((op.rel as NSString).lastPathComponent).themedFont(.title3.bold()).lineLimit(1)
                if op.rel.contains("/") { Text(op.rel).themedFont(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                Spacer()
                Text(op.reason).themedFont(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label("\(src.place) · \(src.name)", systemImage: "doc.on.doc")
                Image(systemName: "arrow.right").foregroundStyle(store.theme.accent)
                Label("\(dst.place) · \(dst.name)", systemImage: op.overwrite ? "arrow.triangle.2.circlepath" : "plus.circle")
                Text(op.reason == SyncOp.notCopied ? "would get this version, but it is left alone" : op.overwrite ? "gets this version; the current one is backed up first" : "gets this new file")
                    .foregroundStyle(.secondary)
            }
            .themedFont(.callout).lineLimit(1)
            if let w = op.warning { Label(w, systemImage: "exclamationmark.triangle.fill").themedFont(.callout).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private var content: some View {
        switch result {
        case nil: ProgressView("Fetching both versions…")
        case .identical?:
            ContentUnavailableView("Contents Are the Same", systemImage: "equal.circle",
                                   description: Text("Only the date or listing differs. Copying it changes nothing inside the file."))
        case .tooBig?: ContentUnavailableView("Too Large to Compare", systemImage: "doc.questionmark", description: Text("Files over 50 MB (200 MB for video and audio) aren't compared here."))
        case .failed(let e)?: ContentUnavailableView("Couldn't Fetch the File", systemImage: "exclamationmark.triangle", description: Text(e))
        case .details(let d, let isNew)?: details(d, isNew: isNew)
        case .text(let d, let isNew)?: diff(d, isNew: isNew)
        }
    }

    /// Facts side by side (changed ones marked), then the pictures with their pixel diff, or a text diff.
    private func details(_ d: FileDetails, isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(d.kind, systemImage: d.symbol).themedFont(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        if !isNew { Text("Now on \(dst.name)").foregroundStyle(.secondary) }
                        Text(isNew ? "New file" : "After the sync").foregroundStyle(.secondary)
                    }
                    .themedFont(.caption.weight(.semibold))
                    ForEach(d.rows) { r in
                        GridRow {
                            Text(r.name).foregroundStyle(.secondary)
                            if !isNew { Text(r.old ?? "—").strikethrough(r.changed, color: .red.opacity(0.6)) }
                            Text(r.new).fontWeight(r.changed ? .semibold : .regular).foregroundStyle(r.changed ? Color.orange : .primary)
                        }
                        .textSelection(.enabled)
                    }
                }
                .themedFont(.callout.monospacedDigit())
                if let n = d.note { Label(n, systemImage: "info.circle").themedFont(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            .padding()
            Divider()
            if let t = d.text { diff(t, isNew: isNew) }
            else if let p = d.pictures {
                HStack(spacing: 14) {
                    if !isNew { picture(p.old, "Now on \(dst.name)") }
                    picture(p.new, isNew ? "New file" : "After the sync")
                    if let x = d.pixels, x.changed > 0 { picture(x.overlay, "What differs") }
                }
                .padding()
            } else { Spacer() }
        }
    }

    private func picture(_ i: NSImage?, _ title: String) -> some View {
        VStack {
            Text(title).themedFont(.headline)
            if let i {
                Image(nsImage: i).resizable().interpolation(.high).scaledToFit()
                    .background(Color.white).border(.separator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ContentUnavailableView("Can't Show This", systemImage: "photo") }
        }
    }

    private func diff(_ d: TextDiff, isNew: Bool) -> some View {
        let rows = d.rows(context: isNew ? 0 : 3)
        // Where each change starts, for the up and down buttons.
        let starts = rows.indices.filter { i in
            guard case .line(let l) = rows[i], l.kind != .same else { return false }
            if i == 0 { return true }
            if case .line(let p) = rows[i - 1], p.kind != .same { return false }
            return true
        }.map { rows[max(0, $0 - 2)].id }   // land two lines above the change, for context
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                if isNew {
                    Label("New file: every line arrives", systemImage: "plus.square.fill").foregroundStyle(.green)
                } else {
                    Label("Now on \(dst.name), goes away", systemImage: "minus.square.fill").foregroundStyle(.red)
                    Label("From \(src.name), arrives", systemImage: "plus.square.fill").foregroundStyle(.green)
                }
                Spacer()
                Text("+\(d.added)  −\(d.removed) lines").monospacedDigit().foregroundStyle(.secondary)
                if !isNew && !starts.isEmpty {
                    Text("Change \(change + 1) of \(starts.count)").monospacedDigit()
                    ControlGroup {
                        Button { change = max(0, change - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(change == 0).keyboardShortcut(.upArrow, modifiers: .command).help("Previous change (⌘↑)")
                        Button { change = min(starts.count - 1, change + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(change >= starts.count - 1).keyboardShortcut(.downArrow, modifiers: .command).help("Next change (⌘↓)")
                    }
                    .fixedSize()
                }
            }
            .themedFont(.callout).padding(.horizontal).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .line(let l): line(l)
                            case .gap(let id, let lines):
                                if open.contains(id) { ForEach(lines) { line($0) } }
                                else {
                                    Button { open.insert(id) } label: {
                                        Label("\(lines.count) unchanged lines", systemImage: "chevron.up.chevron.down")
                                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                                            .background(.quaternary.opacity(0.5))
                                    }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .help("Show the lines that stay the same")
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
                .onChange(of: change) { if starts.indices.contains(change) { withAnimation { proxy.scrollTo(starts[change], anchor: .top) } } }
                .onAppear { if let s = starts.first, s > 10 { proxy.scrollTo(s, anchor: .top) } }
            }
        }
    }

    private func line(_ l: DiffLine) -> some View {
        let tint: Color = l.kind == .added ? .green : l.kind == .removed ? .red : .clear
        return HStack(alignment: .top, spacing: 0) {
            Text(l.old.map(String.init) ?? "").frame(width: 46, alignment: .trailing).foregroundStyle(.tertiary)
            Text(l.new.map(String.init) ?? "").frame(width: 46, alignment: .trailing).foregroundStyle(.tertiary)
            Text(l.kind == .added ? "+" : l.kind == .removed ? "−" : " ").frame(width: 22).foregroundStyle(tint)
            Text(l.text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1).padding(.trailing, 8)
        .background(tint.opacity(0.13))
        .id(l.id)
    }

    private var footer: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0).help("Previous file (←)")
            Text("File \(index + 1) of \(files.count)").monospacedDigit()
            Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(index >= files.count - 1).help("Next file (→)")
            Text("Nothing has changed yet.").foregroundStyle(.secondary).padding(.leading, 8)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                .labelButtons(store.theme.label, accent: store.theme.accent, prominent: true)
        }
        .themedFont(.callout)
        .labelButtons(store.theme.label, accent: store.theme.accent)
    }

    private func step(_ d: Int) { index = min(max(0, index + d), files.count - 1) }
}
