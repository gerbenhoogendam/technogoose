import AppKit
import AVFoundation
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// Comparisons for files that aren't plain text: images, PDFs, fonts, video and audio, archives and other binaries.
/// Each fills in `FileDetails`: facts side by side, and either pictures (with a pixel diff) or a text diff.

/// One fact about the file, before and after the sync. `old` nil: there is no file yet.
struct DetailRow: Identifiable {
    let name: String
    let old: String?
    let new: String
    var id: String { name }
    var changed: Bool { old != nil && old != new }
}

/// Where two pictures differ: the new picture faded, with changed pixels in magenta.
struct PixelDiff {
    let overlay: NSImage
    /// Share of pixels that changed, 0…1.
    let changed: Double
}

struct FileDetails {
    var kind: String
    var symbol: String
    var rows: [DetailRow] = []
    var pictures: (old: NSImage?, new: NSImage?)?
    var pixels: PixelDiff?
    var text: TextDiff?
    /// One sentence on what differs, shown above the details.
    var note: String?
}

/// The kind of comparison a file gets, from its extension and, failing that, its first bytes.
enum FileKind {
    case image, pdf, font, media, archive, text, binary

    static func of(_ rel: String, _ data: Data) -> FileKind {
        let ext = (rel as NSString).pathExtension.lowercased()
        let t = UTType(filenameExtension: ext)
        if ["ttf", "otf", "ttc", "woff", "woff2"].contains(ext) { return .font }
        if ["zip", "tar", "tgz", "gz", "bz2", "xz", "7z", "jar"].contains(ext) || rel.lowercased().hasSuffix(".tar.gz") { return .archive }
        if ext == "pdf" || data.starts(with: Array("%PDF".utf8)) { return .pdf }
        if ext == "svg" { return .text }   // SVG is text: its markup diffs better than its picture
        if let t, t.conforms(to: .image) { return .image }
        if let t, t.conforms(to: .audiovisualContent) { return .media }
        return decodeText(data) == nil ? .binary : .text
    }
}

/// Compares a binary-ish file. `old` nil: a new file.
func details(_ rel: String, old: Data?, new: Data) async -> FileDetails {
    switch FileKind.of(rel, new) {
    case .image: return imageDetails(old: old, new: new)
    case .pdf: return pdfDetails(old: old, new: new)
    case .font: return fontDetails(old: old, new: new) ?? binaryDetails(old: old, new: new)
    case .media: return await mediaDetails(rel, old: old, new: new)
    case .archive: return await archiveDetails(rel, old: old, new: new)
    case .text, .binary: return binaryDetails(old: old, new: new)
    }
}

// MARK: Images

func imageDetails(old: Data?, new: Data) -> FileDetails {
    var d = FileDetails(kind: "Image", symbol: "photo")
    let a = old.flatMap(NSImage.init(data:)), b = NSImage(data: new)
    d.pictures = (a, b)
    func dims(_ i: NSImage?) -> String { i.flatMap(cg).map { "\($0.width) × \($0.height) px" } ?? "Can't read" }
    d.rows = [DetailRow(name: "Dimensions", old: old.map { _ in dims(a) }, new: dims(b)),
              DetailRow(name: "File size", old: old.map { fmtBytes(Int64($0.count)) }, new: fmtBytes(Int64(new.count)))]
    guard old != nil else { return d }
    if let a, let b, let p = pixelDiff(a, b) {
        d.pixels = p
        d.note = p.changed == 0 ? "Looks the same: not one pixel differs. Only the file's encoding or metadata changed."
                                : "\(percent(p.changed)) of the pixels differ, marked in magenta."
    } else {
        d.note = "The dimensions differ, so the pictures are shown side by side without a pixel comparison."
    }
    return d
}

private func cg(_ i: NSImage) -> CGImage? { i.cgImage(forProposedRect: nil, context: nil, hints: nil) }

private func percent(_ f: Double) -> String {
    f > 0 && f < 0.001 ? "Less than 0.1%" : f.formatted(.percent.precision(.fractionLength(f < 0.1 ? 1 : 0)))
}

/// Pixel by pixel, for two pictures of the same size (up to 25 megapixels).
func pixelDiff(_ a: NSImage, _ b: NSImage) -> PixelDiff? {
    guard let ca = cg(a), let cb = cg(b), ca.width == cb.width, ca.height == cb.height, ca.width * ca.height <= 25_000_000 else { return nil }
    let w = ca.width, h = ca.height, n = w * h * 4
    func pixels(_ c: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))   // transparency compares as white
            ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }
    let pa = pixels(ca), pb = pixels(cb)
    var out = [UInt8](repeating: 255, count: n), changed = 0
    for i in stride(from: 0, to: n, by: 4) {
        let diff = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i + 1]) - Int(pb[i + 1])), abs(Int(pa[i + 2]) - Int(pb[i + 2])))
        if diff > 16 {   // small differences are JPEG noise
            changed += 1
            out[i] = 255; out[i + 1] = 0; out[i + 2] = 200
        } else {
            let lum = (Int(pb[i]) * 3 + Int(pb[i + 1]) * 6 + Int(pb[i + 2])) / 10
            let faded = UInt8(190 + lum / 4)
            out[i] = faded; out[i + 1] = faded; out[i + 2] = faded
        }
    }
    let provider = CGDataProvider(data: Data(out) as CFData)!
    guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
    return PixelDiff(overlay: NSImage(cgImage: img, size: NSSize(width: w, height: h)), changed: Double(changed) / Double(w * h))
}

// MARK: PDF

/// The text of every page; when that's the same, the pages themselves are compared as pictures.
func pdfDetails(old: Data?, new: Data) -> FileDetails {
    var d = FileDetails(kind: "PDF", symbol: "doc.richtext")
    let a = old.flatMap(PDFDocument.init(data:)), b = PDFDocument(data: new)
    guard let b else { return binaryDetails(old: old, new: new) }
    func attr(_ doc: PDFDocument?, _ k: PDFDocumentAttribute) -> String { (doc?.documentAttributes?[k] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
    func size(_ doc: PDFDocument?) -> String {
        guard let r = doc?.page(at: 0)?.bounds(for: .mediaBox) else { return "—" }
        return "\(Int(r.width)) × \(Int(r.height)) pt"
    }
    let has = old != nil
    d.rows = [DetailRow(name: "Pages", old: has ? "\(a?.pageCount ?? 0)" : nil, new: "\(b.pageCount)"),
              DetailRow(name: "Page size", old: has ? size(a) : nil, new: size(b)),
              DetailRow(name: "Title", old: has ? attr(a, .titleAttribute) : nil, new: attr(b, .titleAttribute)),
              DetailRow(name: "Author", old: has ? attr(a, .authorAttribute) : nil, new: attr(b, .authorAttribute)),
              DetailRow(name: "Made with", old: has ? attr(a, .producerAttribute) : nil, new: attr(b, .producerAttribute)),
              DetailRow(name: "File size", old: old.map { fmtBytes(Int64($0.count)) }, new: fmtBytes(Int64(new.count)))]
    func text(_ doc: PDFDocument?) -> String {
        guard let doc else { return "" }
        return (0..<doc.pageCount).map { i in "──── Page \(i + 1) ────\n" + (doc.page(at: i)?.string ?? "") }.joined(separator: "\n")
    }
    let ta = text(a), tb = text(b)
    let hasText = tb.count > 40 * b.pageCount + 20
    if !has || ta != tb, hasText {
        d.text = diffText(ta, tb)
        if has { d.note = "The text of the pages differs. Page breaks are marked ──── Page n ────." }
        return d
    }
    // Same text (or no text, like a scan): find the first page that looks different.
    if !has { d.pictures = (nil, render(b.page(at: 0))); return d }
    for i in 0..<min(max(a?.pageCount ?? 0, b.pageCount), 60) {
        let pa = render(a?.page(at: i)), pb = render(b.page(at: i))
        if let pa, let pb, let p = pixelDiff(pa, pb), p.changed == 0 { continue }
        d.pictures = (pa, pb)
        d.pixels = pa.flatMap { x in pb.flatMap { pixelDiff(x, $0) } }
        d.note = (hasText ? "The text is the same, but page \(i + 1) looks different" : "Page \(i + 1) looks different") + (d.pixels == nil ? "." : ", marked in magenta.")
        return d
    }
    d.pictures = (render(a?.page(at: 0)), render(b.page(at: 0)))
    d.note = "Text and pages look the same. Only the file's internal data changed (for example its metadata or how it was saved)."
    return d
}

/// A page as a picture, 900 points wide, on white.
private func render(_ page: PDFPage?) -> NSImage? {
    guard let page else { return nil }
    let r = page.bounds(for: .mediaBox), scale = 900 / max(r.width, 1)
    return page.thumbnail(of: NSSize(width: r.width * scale, height: r.height * scale), for: .mediaBox)
}

// MARK: Fonts

/// Names, version and glyph count, plus a sample line in each version with a pixel diff.
func fontDetails(old: Data?, new: Data) -> FileDetails? {
    func font(_ data: Data?) -> CTFont? {
        guard let data, let descs = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let f = descs.first else { return nil }
        return CTFontCreateWithFontDescriptor(f, 44, nil)
    }
    guard let b = font(new) else { return nil }
    let a = font(old), has = old != nil
    func name(_ f: CTFont?, _ key: CFString) -> String { f.flatMap { CTFontCopyName($0, key) as String? } ?? "—" }
    func glyphs(_ f: CTFont?) -> String { f.map { "\(CTFontGetGlyphCount($0))" } ?? "—" }
    var d = FileDetails(kind: "Font", symbol: "textformat")
    d.rows = [DetailRow(name: "Family", old: has ? name(a, kCTFontFamilyNameKey) : nil, new: name(b, kCTFontFamilyNameKey)),
              DetailRow(name: "Style", old: has ? name(a, kCTFontStyleNameKey) : nil, new: name(b, kCTFontStyleNameKey)),
              DetailRow(name: "Version", old: has ? name(a, kCTFontVersionNameKey) : nil, new: name(b, kCTFontVersionNameKey)),
              DetailRow(name: "Glyphs", old: has ? glyphs(a) : nil, new: glyphs(b)),
              DetailRow(name: "File size", old: old.map { fmtBytes(Int64($0.count)) }, new: fmtBytes(Int64(new.count)))]
    let sa = a.map(sample), sb = sample(b)
    d.pictures = (sa, sb)
    if let sa { d.pixels = pixelDiff(sa, sb) }
    if let p = d.pixels { d.note = p.changed == 0 ? "The sample text looks the same in both versions." : "The sample text renders differently, marked in magenta." }
    if has && a == nil { d.note = "macOS can't read the font that is there now, so only the new one is shown." }
    return d
}

private func sample(_ f: CTFont) -> NSImage {
    let s = NSAttributedString(string: "Aa Bb Gg Qq 0123 €&@\nThe quick brown fox jumps", attributes: [.font: f as NSFont, .foregroundColor: NSColor.black])
    let size = NSSize(width: 820, height: 150)
    return NSImage(size: size, flipped: true) { r in
        NSColor.white.setFill(); r.fill()
        s.draw(in: r.insetBy(dx: 12, dy: 10))
        return true
    }.bitmapped(size)
}

private extension NSImage {
    /// Draws a lazily drawn image once, so its pixels can be compared.
    func bitmapped(_ size: NSSize) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size); out.addRepresentation(rep); return out
    }
}

// MARK: Video and audio

/// Length, picture size and frame rate, and a frame from each version (video) or their waveforms (audio).
func mediaDetails(_ rel: String, old: Data?, new: Data) async -> FileDetails {
    var d = FileDetails(kind: "Video", symbol: "play.rectangle")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-media-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let ext = (rel as NSString).pathExtension
    struct Info { var duration = "—", dims = "—", fps = "—", audio = "—"; var frame: NSImage?; var seconds = 0.0; var levels: [Float] = [] }
    func info(_ data: Data?, _ name: String) async -> Info? {
        guard let data else { return nil }
        let u = tmp.appendingPathComponent(name).appendingPathExtension(ext)
        guard (try? data.write(to: u)) != nil else { return nil }
        let asset = AVURLAsset(url: u)
        var i = Info()
        if let t = try? await asset.load(.duration), t.isNumeric {
            i.seconds = t.seconds
            i.duration = Duration.seconds(t.seconds).formatted(.time(pattern: t.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1)))
        }
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            if let s = try? await v.load(.naturalSize) { i.dims = "\(Int(s.width)) × \(Int(s.height))" }
            if let f = try? await v.load(.nominalFrameRate), f > 0 { i.fps = "\(f.formatted(.number.precision(.fractionLength(0...2)))) fps" }
            let g = AVAssetImageGenerator(asset: asset); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 900, height: 900)
            if let (img, _) = try? await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)) { i.frame = NSImage(cgImage: img, size: .zero) }
        }
        if let a = try? await asset.loadTracks(withMediaType: .audio), !a.isEmpty {
            i.audio = a.count == 1 ? "1 track" : "\(a.count) tracks"
            if i.frame == nil { i.levels = levels(asset, a) }
        } else { i.audio = "None" }
        return i
    }
    let a = await info(old, "old"), b = await info(new, "new") ?? Info()
    let has = old != nil
    d.rows = [DetailRow(name: "Length", old: has ? a?.duration ?? "—" : nil, new: b.duration),
              DetailRow(name: "Picture", old: has ? a?.dims ?? "—" : nil, new: b.dims),
              DetailRow(name: "Frame rate", old: has ? a?.fps ?? "—" : nil, new: b.fps),
              DetailRow(name: "Audio", old: has ? a?.audio ?? "—" : nil, new: b.audio),
              DetailRow(name: "File size", old: old.map { fmtBytes(Int64($0.count)) }, new: fmtBytes(Int64(new.count)))]
    if b.frame == nil && a?.frame == nil && !b.levels.isEmpty {
        // Audio: both waveforms on one time scale, so a pixel diff shows where the sound differs.
        d.kind = "Audio"; d.symbol = "waveform"
        let span = max(a?.seconds ?? 0, b.seconds, 0.01)
        let wa = a.map { waveform($0.levels, $0.seconds / span) }, wb = waveform(b.levels, b.seconds / span)
        d.pictures = (wa, wb)
        if let wa { d.pixels = pixelDiff(wa, wb) }
        d.note = "Waveforms on the same time scale." + (d.pixels.map { $0.changed == 0 ? " They look the same." : " Differences are marked in magenta." } ?? "")
    } else if b.frame != nil || a?.frame != nil {
        d.pictures = (a?.frame, b.frame)
        if let fa = a?.frame, let fb = b.frame { d.pixels = pixelDiff(fa, fb) }
        d.note = "Frames at one second in." + (d.pixels.map { $0.changed == 0 ? " They look the same." : " Differences are marked in magenta." }
                                                ?? (old == nil ? "" : " The picture sizes differ, so they are shown side by side."))
    }
    if b.duration == "—" && b.dims == "—" { d.note = "macOS can't read this format (for example WebM or Ogg), so only the size is compared." }
    return d
}

/// Loudness in 900 steps (0…1), read as 8 kHz mono.
private func levels(_ asset: AVAsset, _ tracks: [AVAssetTrack]) -> [Float] {
    guard let reader = try? AVAssetReader(asset: asset) else { return [] }
    let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000])
    guard reader.canAdd(out) else { return [] }
    reader.add(out)
    guard reader.startReading() else { return [] }
    var samples: [Int16] = []
    while samples.count < 8000 * 1800, let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
        let n = CMBlockBufferGetDataLength(block)
        var chunk = [Int16](repeating: 0, count: n / 2)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
        samples += chunk
    }
    guard !samples.isEmpty else { return [] }
    let step = max(1, samples.count / 900)
    return stride(from: 0, to: samples.count, by: step).map { i in
        Float(samples[i..<min(i + step, samples.count)].map { abs(Int32($0)) }.max() ?? 0) / 32768
    }
}

/// A waveform 900 × 160 on white; `share` is how much of the width this file's length takes.
private func waveform(_ levels: [Float], _ share: Double) -> NSImage {
    let size = NSSize(width: 900, height: 160)
    return NSImage(size: size, flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        NSColor.black.setFill()
        let width = r.width * share, n = max(levels.count, 1)
        for (i, l) in levels.enumerated() {
            let h = max(1, CGFloat(l) * (r.height - 10))
            NSRect(x: CGFloat(i) * width / CGFloat(n), y: (r.height - h) / 2, width: max(1, width / CGFloat(n)), height: h).fill()
        }
        return true
    }.bitmapped(size)
}

// MARK: Archives

/// What's inside: every entry with its size, as a list that diffs like text.
func archiveDetails(_ rel: String, old: Data?, new: Data) async -> FileDetails {
    var d = FileDetails(kind: "Archive", symbol: "archivebox")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-archive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    func list(_ data: Data?, _ name: String) async -> [String]? {
        guard let data else { return nil }
        let u = tmp.appendingPathComponent(name + "-" + (rel as NSString).lastPathComponent)
        guard (try? data.write(to: u)) != nil, let r = try? await run("/usr/bin/tar", ["-tvf", u.path]), r.status == 0 else { return nil }
        // "-rw-r--r--  0 user staff  1234 Jan  1 12:00 name": keep name and size, drop owner and date.
        return r.out.split(separator: "\n").map { line in
            let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            return f.count == 9 ? "\(f[8])  (\(fmtBytes(Int64(f[4]) ?? 0)))" : String(line)
        }.sorted()
    }
    let a = await list(old, "old"), b = await list(new, "new")
    guard let b else { return binaryDetails(old: old, new: new) }
    d.rows = [DetailRow(name: "Entries", old: old == nil ? nil : a.map { "\($0.count)" } ?? "—", new: "\(b.count)"),
              DetailRow(name: "File size", old: old.map { fmtBytes(Int64($0.count)) }, new: fmtBytes(Int64(new.count)))]
    d.text = diffText((a ?? []).joined(separator: "\n"), b.joined(separator: "\n"))
    d.note = old == nil ? "What's inside, with sizes." : a == b ? "Same entries with the same sizes; something inside changed without changing its size." : "Entries that were added, removed or changed size."
    return d
}

// MARK: Anything else

/// Size, a fingerprint and where the bytes start to differ.
func binaryDetails(old: Data?, new: Data) -> FileDetails {
    var d = FileDetails(kind: "Binary file", symbol: "doc.zipper")
    func hash(_ x: Data) -> String { SHA256.hash(data: x).prefix(8).map { String(format: "%02x", $0) }.joined() }
    d.rows = [DetailRow(name: "File size", old: old.map { fmtBytes(Int64($0.count)) }, new: fmtBytes(Int64(new.count))),
              DetailRow(name: "Fingerprint (SHA-256)", old: old.map(hash), new: hash(new))]
    if let old {
        let first = zip(old, new).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(old.count, new.count)
        d.note = "Not text or a format Techno Goose can show, so it compares the bytes: they start to differ at byte \(first.formatted())."
    } else {
        d.note = "Not text or a format Techno Goose can show. A new file of \(fmtBytes(Int64(new.count)))."
    }
    return d
}
