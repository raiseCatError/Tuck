import Foundation

enum TuckAction: String, CaseIterable, Identifiable {
    case newFile, openWith, compress, terminal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newFile: "New File"
        case .openWith: "Open With"
        case .compress: "Compress"
        case .terminal: "Open Terminal Here"
        }
    }

    var symbol: String {
        switch self {
        case .newFile: "doc.badge.plus"
        case .openWith: "arrow.up.forward.app"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .terminal: "terminal"
        }
    }
}

enum TuckContext: String, CaseIterable, Identifiable {
    case desktop, folder, image, pdf, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hasSelection: Bool { self == .image || self == .pdf || self == .other }
}

enum TuckMenuModel {
    static func visible(in context: TuckContext) -> [TuckAction] {
        TuckPreferences.order.compactMap(TuckAction.init(rawValue:)).filter { action in
            guard TuckPreferences.enabled(action.id) else { return false }
            if action == .compress { return context.hasSelection }
            if context == .desktop && !TuckPreferences.showDesktop { return false }
            return true
        }
    }

    static let templates: [(String, String)] = [
        ("Text File", "Untitled.txt"),
        ("Markdown", "Untitled.md"),
        ("Swift File", "Untitled.swift"),
        ("JSON File", "Untitled.json"),
        ("Environment File", ".env")
    ]

    static let editors: [(String, String)] = [
        ("Zed", "dev.zed.Zed"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("TextEdit", "com.apple.TextEdit")
    ]
}
