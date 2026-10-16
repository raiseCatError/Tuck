import SwiftUI
import AppKit

private enum SettingsPane: String, CaseIterable, Identifiable {
    case menu = "Menu"
    case compression = "Compression"
    case applications = "Applications"
    case general = "General"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .menu: "list.bullet"
        case .compression: "arrow.down.right.and.arrow.up.left"
        case .applications: "terminal"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane? = .menu
    @State private var order: [String] = TuckPreferences.order
    @State private var enabled: Set<String> = Set(TuckPreferences.defaults.filter { TuckPreferences.enabled($0) })
    @State private var sizesText = TuckPreferences.sizes.map(String.init).joined(separator: ", ")
    @State private var terminalID = TuckPreferences.terminal
    @State private var desktop = TuckPreferences.showDesktop
    @State private var previewContext: TuckContext = .image
    @State private var lastPreview = "Choose an action to test the menu. Nothing will change on disk."
    @State private var sizeError = false

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { value in
                Label(value.rawValue, systemImage: value.symbol).tag(value)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 195)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch pane ?? .menu {
                    case .menu: menuPane
                    case .compression: compressionPane
                    case .applications: applicationsPane
                    case .general: generalPane
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 820, minHeight: 565)
    }

    private var menuPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Context Menu", subtitle: "Drag to reorder your actions. Changes appear on the next right-click.")
            GroupBox("Actions") {
                List {
                    ForEach(order, id: \.self) { id in
                        if let action = TuckAction(rawValue: id) {
                            HStack(spacing: 12) {
                                Image(systemName: action.symbol).frame(width: 22).foregroundStyle(.secondary)
                                Text(action.title)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { enabled.contains(id) },
                                    set: { on in
                                        if on { enabled.insert(id) } else { enabled.remove(id) }
                                        TuckPreferences.setEnabled(id, to: on)
                                    }
                                )).labelsHidden()
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        order.move(fromOffsets: source, toOffset: destination)
                        TuckPreferences.order = order
                    }
                }
                .listStyle(.inset)
                .frame(height: 193)
            }
            .help("On macOS, drag rows using the handle. Only Tuck's entries can be reordered.")
            GroupBox("Live Menu Preview") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Right-clicking", selection: $previewContext) {
                        ForEach(TuckContext.allCases) { context in
                            Text(context.title).tag(context)
                        }
                    }
                    .pickerStyle(.segmented)
                    Menu {
                        ForEach(previewActions, id: \.id) { action in
                            previewContent(for: action)
                        }
                    } label: {
                        Label("Open Test Context Menu", systemImage: "cursorarrow.click.2")
                    }
                    Text(lastPreview).font(.caption).foregroundStyle(.secondary)
                    Text("The preview uses the saved action order and presets. It simulates operations; it never touches files.")
                        .font(.caption).foregroundStyle(.tertiary)
                }.padding(10)
            }
            Text("Finder decides where extension items appear relative to Apple's built-in commands. Desktop support also depends on Finder exposing the extension menu in that location.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var previewActions: [TuckAction] {
        order.compactMap(TuckAction.init(rawValue:)).filter {
            enabled.contains($0.id) && ($0 != .compress || previewContext.hasSelection) && (previewContext != .desktop || desktop)
        }
    }

    @ViewBuilder private func previewContent(for action: TuckAction) -> some View {
        switch action {
        case .newFile:
            Menu(action.title) {
                ForEach(TuckMenuModel.templates, id: \.1) { template in
                    Button(template.0) { lastPreview = "New File → \(template.1)" }
                }
                Button("Custom Name…") { lastPreview = "New File → Custom Name" }
            }
        case .openWith:
            Menu(action.title) {
                ForEach(TuckMenuModel.editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }, id: \.1) { app in
                    Button(app.0) { lastPreview = "Open With → \(app.0)" }
                }
            }
        case .compress:
            Menu(action.title) {
                ForEach(currentSizes, id: \.self) { size in
                    Button("Under \(size) MB") { lastPreview = "Compress → \(size) MB target" }
                }
                Button("Custom Size…") { lastPreview = "Compress → Custom Size" }
                Divider()
                Button("Create ZIP Archive") { lastPreview = "Compress → ZIP archive (no size cap)" }
            }
        case .terminal:
            Button(action.title) { lastPreview = "Open Terminal Here → \(terminalName)" }
        }
    }

    private var currentSizes: [Int] { TuckPreferences.sizes }

    private var terminalName: String {
        terminalID == "com.mitchellh.ghostty" ? "Ghostty" : "Terminal"
    }

    private var compressionPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Compression", subtitle: "Size limits are targets, never a promise. Originals are always preserved.")
            GroupBox("Right-click Presets") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Targets (MB)") {
                        TextField("1, 2, 5, 10, 25", text: $sizesText)
                            .frame(width: 245)
                            .onSubmit(saveSizes)
                    }
                    HStack {
                        Text("1–500 MB · Up to 10 presets").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") { saveSizes() }
                    }
                    if sizeError {
                        Text("Enter up to ten comma-separated whole numbers from 1 to 500.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }.padding(10)
            }
            GroupBox("How compression works") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Images: resize and re-encode until the chosen limit fits; preserve PNG transparency.", systemImage: "photo")
                    Label("PDFs: use PDFKit image optimization while keeping searchable text where possible.", systemImage: "doc.richtext")
                    Label("Other files and folders: create ZIP; lossless ZIP sizes cannot be guaranteed.", systemImage: "archivebox")
                    Label("If a target cannot be met, no compressed output is left behind.", systemImage: "checkmark.shield")
                }.font(.callout).padding(10)
            }
            Button("Choose a File to Test Compression…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let file = panel.url {
                    lastPreview = "Chosen \(file.lastPathComponent). Use Finder → Compress to run the actual operation."
                    pane = .menu
                }
            }
        }
    }

    private func saveSizes() {
        let pieces = sizesText.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = pieces.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        sizeError = numbers.count != pieces.count || numbers.count > 10 || numbers.isEmpty || numbers.contains(where: { !(1...500).contains($0) })
        guard !sizeError else { return }
        TuckPreferences.sizes = numbers
        sizesText = TuckPreferences.sizes.map(String.init).joined(separator: ", ")
    }

    private var applicationsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Applications", subtitle: "Choose which terminal is used when you right-click a folder or the Desktop.")
            GroupBox("Open Terminal Here") {
                Picker("Terminal", selection: $terminalID) {
                    Text("Ghostty").tag("com.mitchellh.ghostty")
                    Text("Terminal.app").tag("com.apple.Terminal")
                }
                .onChange(of: terminalID) { _, value in TuckPreferences.terminal = value }
                .padding(10)
            }
            Text("Open With automatically lists installed editors. Zed, VS Code, Cursor, Xcode, Sublime Text and TextEdit are currently recognized.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("General", subtitle: "A small, local-only Finder utility.")
            GroupBox("Locations") {
                Toggle("Include Desktop background", isOn: $desktop)
                    .onChange(of: desktop) { _, value in TuckPreferences.showDesktop = value }
                    .padding(10)
            }
            GroupBox("About") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Tuck 0.1 · Swift 6")
                    Text("No telemetry, uploads, accounts, or external compression service.")
                    Text("Finder extension + invisible local helper. Your original files are never overwritten.")
                }.font(.callout).foregroundStyle(.secondary).padding(10)
            }
        }
    }

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle).fontWeight(.semibold)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}
