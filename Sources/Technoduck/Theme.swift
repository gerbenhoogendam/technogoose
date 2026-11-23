import AppKit
import CoreImage
import SwiftUI

/// The home folder. `TECHNODUCK_HOME` moves it, and all of the app's data with it, for demos and screenshots.
let homeDir = ProcessInfo.processInfo.environment["TECHNODUCK_HOME"] ?? NSHomeDirectory()
let isDemo = ProcessInfo.processInfo.environment["TECHNODUCK_HOME"] != nil

/// Colour themes after Panic's Nova: deep slate canvases, a tinted sidebar and a two-colour accent gradient.
/// `system` leaves every colour to macOS. Label Lime is near-black with square corners, hairlines and one chartreuse accent.
enum Theme: String, CaseIterable, Identifiable {
    case system, midnight, daylight, pond, mac512, lime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .midnight: "Nova Midnight"
        case .daylight: "Nova Daylight"
        case .pond: "Neon Pond"
        case .mac512: "Macintosh 512K"
        case .lime: "Label Lime"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .daylight, .mac512: NSAppearance(named: .aqua)
        case .midnight, .pond, .lime: NSAppearance(named: .darkAqua)
        }
    }
    var accent: Color {
        switch self {
        case .system: .accentColor
        case .midnight: Color(hex: 0xFF4F9A)
        case .daylight: Color(hex: 0x6C5CE7)
        case .pond: Color(hex: 0x2EF2C8)
        case .mac512: .black
        case .lime: Color(hex: 0xD4FF00)
        }
    }
    /// The far end of the accent gradient.
    var accent2: Color {
        switch self {
        case .system: .accentColor
        case .midnight: Color(hex: 0xFF9F43)
        case .daylight: Color(hex: 0x00B5D8)
        case .pond: Color(hex: 0xB6FF3B)
        case .mac512: .black
        case .lime: Color(hex: 0xD4FF00)   // one loud colour, no gradient
        }
    }
    /// Text and symbols drawn on the accent colour.
    var onAccent: Color { [.pond: Color(hex: 0x06211C), .lime: Color(hex: 0x0B0B0C)][self] ?? .white }
    /// 1984: everything in Chicago 12, in shades of grey.
    var font: Font? { self == .mac512 ? chicago : nil }
    var grayscale: Double { self == .mac512 ? 1 : 0 }
    /// Label Lime's look: square corners, hairline frames, condensed capitals for paths and numbers.
    var label: Bool { self == .lime }
    /// A corner radius, or none for Label Lime.
    func corner(_ r: CGFloat) -> CGFloat { label ? 0 : r }
    var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }

    // nil keeps the system colour.
    var canvas: Color? { [.midnight: Color(hex: 0x161925), .daylight: Color(hex: 0xFCFBF9), .pond: Color(hex: 0x0A1315), .mac512: .white, .lime: Color(hex: 0x0B0B0C)][self] }
    var bar: Color? { [.midnight: Color(hex: 0x1F2335), .daylight: Color(hex: 0xF1EEF6), .pond: Color(hex: 0x0F1F21), .mac512: .white, .lime: Color(hex: 0x141415)][self] }
    var sidebar: Color? { [.midnight: Color(hex: 0x11131D), .daylight: Color(hex: 0xEAE5F3), .pond: Color(hex: 0x071012), .mac512: .white, .lime: Color(hex: 0x111112)][self] }
    var strip: Color? { [.midnight: Color(hex: 0x1A1D2C), .daylight: Color(hex: 0xF5F2F8), .pond: Color(hex: 0x0C191B), .mac512: .white, .lime: Color(hex: 0x0B0B0C)][self] }
}

/// A file from Resources. The .app carries a copy; a plain `swift build` reads it from the source tree.
func resourceURL(_ name: String, _ ext: String, in dir: String? = nil) -> URL {
    Bundle.main.url(forResource: name, withExtension: ext, subdirectory: dir)
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/\(dir.map { $0 + "/" } ?? "")\(name).\(ext)").standardized
}
private func register(_ name: String) {
    CTFontManagerRegisterFontsForURL(resourceURL(name, "ttf") as CFURL, .process, nil)
}
/// ChicagoFLF, a public-domain revival of the 1984 Mac system font (Resources/README.ChicagoFLF).
private let chicago: Font = { register("ChicagoFLF"); return .custom("ChicagoFLF", size: 12) }()
private let bebasNeue: Void = register("BebasNeue-Regular")
/// Bebas Neue (SIL Open Font License, Resources/OFL.BebasNeue.txt): Label Lime's condensed capitals.
func bebas(_ size: CGFloat) -> Font { _ = bebasNeue; return .custom("BebasNeue-Regular", size: size) }

extension EnvironmentValues { @Entry var classic = false }

private struct ThemedFont: ViewModifier {
    @Environment(\.classic) private var classic
    let font: Font?
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.font(chicago) } else if let font { content.font(font) } else { content }
    }
}

extension NSView {
    func setGreyscale(_ on: Bool) {
        guard on || !contentFilters.isEmpty else { return } // leave other themes' windows untouched
        wantsLayer = true
        layerUsesCoreImageFilters = true
        contentFilters = on ? [CIFilter(name: "CIColorControls", parameters: ["inputSaturation": 0])!] : []
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// The theme's font, for each column and sheet.
    func themed(_ theme: Theme) -> some View { font(theme.font).environment(\.classic, theme == .mac512) }
    /// `font`, except that the Macintosh 512K theme (like 1984) has one font in one size: Chicago 12. nil keeps the inherited font.
    func themedFont(_ font: Font?) -> some View { modifier(ThemedFont(font: font)) }

    /// A themed background, or the system one when the theme has none.
    @ViewBuilder func themeBackground(_ color: Color?, _ fallback: some ShapeStyle) -> some View {
        if let color { background(color) } else { background(fallback) }
    }
}

// MARK: Label Lime pieces

/// "—— FAVORITES": a short accent line before small, widely spaced capitals.
struct Eyebrow: View {
    @Environment(Store.self) private var store
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(store.theme.accent).frame(width: 18, height: 1)
            Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The active pane: a hairline accent frame with a solid bar along the top.
struct ActiveFrame: View {
    let color: Color
    var body: some View {
        // A solid bar on top, like a selected tab; corner squares looked like resize handles.
        ZStack(alignment: .top) {
            Rectangle().strokeBorder(color.opacity(0.55), lineWidth: 1)
            Rectangle().fill(color).frame(height: 3)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Text set around a circle, like a rubber stamp, starting at the top.
struct RingText: View {
    let text: String, radius: CGFloat, color: Color
    var body: some View {
        let chars = Array(text)
        ZStack {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i])).font(.system(size: 7, weight: .bold)).foregroundStyle(color)
                    .offset(y: -radius).rotationEffect(.degrees(Double(i) / Double(chars.count) * 360))
            }
        }
        .frame(width: radius * 2 + 10, height: radius * 2 + 10).accessibilityHidden(true)
    }
}

/// Square buttons in tracked capitals: filled with the accent, or outlined in a hairline.
struct LabelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold)).tracking(1.6).textCase(.uppercase)
            .foregroundStyle(prominent ? Color(hex: 0x0B0B0C) : Color(hex: 0xF2F2F2))
            .padding(.horizontal, 12).frame(minHeight: 26)
            .background(prominent ? accent : .clear)
            .overlay(Rectangle().strokeBorder(prominent ? .clear : Color(hex: 0x3A3A3A)))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Label Lime's square buttons when `on`; otherwise the button style set further out.
    @ViewBuilder func labelButtons(_ on: Bool, accent: Color, prominent: Bool = false) -> some View {
        if on { buttonStyle(LabelButtonStyle(prominent: prominent, accent: accent)) } else { self }
    }
}
