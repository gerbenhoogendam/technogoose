import SwiftUI

/// Techno Goose › Settings… (⌘,).
struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var backupSize: Int64?
    @State private var confirmClear = false
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Form {
                Picker("Theme", selection: $store.theme) {
                    ForEach(Theme.allCases) { t in
                        HStack { Swatch(theme: t); Text(t.title) }.tag(t)
                    }
                }
                .pickerStyle(.radioGroup)
                Section {
                    Toggle("Show hidden files", isOn: $store.showHidden)
                    Toggle("Calculate folder sizes", isOn: $store.folderSizes)
                } footer: {
                    Text("Folder sizes are worked out in the background. Turn this off for very large or slow servers.").foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }.tag("general")

            IconPicker()
                .tabItem { Label("Icon", systemImage: "app.badge") }.tag("icon")

            Form {
                Toggle("Show Activity when a transfer starts", isOn: $store.autoShowActivity)
                Toggle("Play a sound when a sync finishes", isOn: $store.doneSound)
                Section {
                    Picker("Undo history", selection: $store.undoLimit) {
                        ForEach([10, 30, 100], id: \.self) { Text("Last \($0) syncs").tag($0) }
                    }
                    LabeledContent("Backups for undo") {
                        Text(backupSize.map(fmtBytes) ?? "…").monospacedDigit()
                        Button("Clear…") { confirmClear = true }.disabled(store.records.isEmpty && backupSize == 0)
                    }
                } footer: {
                    Text("Before a sync replaces a file, the old version is kept so the sync can be undone.").foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }.tag("transfers")
            .confirmationDialog("Clear the undo history?", isPresented: $confirmClear) {
                Button("Clear Undo History", role: .destructive) { store.clearUndoHistory(); backupSize = 0 }
            } message: {
                Text("Past syncs can no longer be undone. Your files are not changed.")
            }

            Form {
                Toggle("Sync bookmarks with iCloud Drive", isOn: Binding(get: { store.iCloud }, set: { store.setICloud($0) }))
                LabeledContent("Daily backups") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: store.libraryBackups, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.libraryBackups)
                    }
                    Button("Restore…") { store.restoreLibrary() }
                }
                Text("Passwords are not synced; they stay in each Mac's Keychain.").foregroundStyle(.secondary)
            }
            .tabItem { Label("Bookmarks", systemImage: "bookmark") }.tag("bookmarks")
        }
        .formStyle(.grouped)
        .scrollContentBackground(store.theme.canvas == nil ? .automatic : .hidden)
        .background(store.theme.canvas ?? .clear)
        .frame(width: 480, height: 400)
        .tint(store.theme.accent)
        .themed(store.theme)
        // shortcut: measured on the main thread; fine for the 30-ish backups kept, move off-main if it ever stalls.
        .task { backupSize = store.undoBackupSize() }
    }
}

/// The theme's two accent colours on its canvas, as a small preview.
private struct Swatch: View {
    let theme: Theme
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.canvas ?? Color(nsColor: .windowBackgroundColor))
            .overlay(Capsule().fill(theme.gradient).frame(width: 18, height: 5))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .frame(width: 30, height: 18)
    }
}

/// The Dock icons to choose from. The .app's own icon (Resources/AppIcon.png) is `goggles`.
enum AppIcon: String, CaseIterable, Identifiable {
    case goggles, deepSync = "deep-sync", pixel, redAlert = "red-alert", lime, copper, chrome, wavelength, ledVisor = "led-visor", frost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .goggles: "Goggles"
        case .deepSync: "Deep Sync"
        case .pixel: "Pixel"
        case .redAlert: "Red Alert"
        case .lime: "Label Lime"
        case .copper: "Copper"
        case .chrome: "Chrome"
        case .wavelength: "Wavelength"
        case .ledVisor: "LED Visor"
        case .frost: "Frost"
        }
    }
    private static let images = Dictionary(uniqueKeysWithValues: allCases.compactMap { i in
        NSImage(contentsOf: resourceURL(i.rawValue, "png", in: "Icons")).map { (i, $0) }
    })
    var image: NSImage? { Self.images[self] }
    /// Shows this icon in the Dock and the app switcher while Techno Goose runs; nil brings back the .app's own icon.
    @MainActor func apply() { NSApp.applicationIconImage = self == .goggles ? nil : image }
}

/// Settings › Icon: a grid of ducks.
private struct IconPicker: View {
    @Environment(Store.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 12) {
                    ForEach(AppIcon.allCases) { icon in
                        let on = store.appIcon == icon
                        Button { store.appIcon = icon } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: icon.image ?? NSImage()).resizable().interpolation(.high).frame(width: 64, height: 64)
                                    .padding(5)
                                    .background(RoundedRectangle(cornerRadius: store.theme.corner(14)).fill(on ? store.theme.accent.opacity(0.18) : .clear))
                                    .overlay(RoundedRectangle(cornerRadius: store.theme.corner(14)).strokeBorder(on ? store.theme.accent : .clear, lineWidth: 2))
                                Text(icon.title).themedFont(.caption).fontWeight(on ? .semibold : .regular).lineLimit(1)
                                    .foregroundStyle(on ? .primary : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(icon.title)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Text("The icon in the Dock and the app switcher while Techno Goose runs. Finder and a closed Dock icon keep Goggles.")
                    .themedFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }
}
