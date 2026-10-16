import Foundation

enum TuckAction: String, CaseIterable, Identifiable {
    case newFile, openWith, compress, terminal
    case pdfToolkit, imageToolkit, metadata, copyAs, rename, duplicates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newFile: "New File"
        case .openWith: "Open With"
        case .compress: "Compress"
        case .terminal: "Open Terminal Here"
        case .pdfToolkit: "PDF Toolkit"
        case .imageToolkit: "Image Toolkit"
        case .metadata: "Inspect Metadata"
        case .copyAs: "Copy As"
        case .rename: "Advanced Rename"
        case .duplicates: "Find Duplicates"
        }
    }

    var symbol: String {
        switch self {
        case .newFile: "doc.badge.plus"
        case .openWith: "arrow.up.forward.app"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .terminal: "terminal"
        case .pdfToolkit: "doc.text.fill"
        case .imageToolkit: "photo.on.rectangle"
        case .metadata: "info.circle"
        case .copyAs: "doc.on.clipboard"
        case .rename: "textformat"
        case .duplicates: "square.on.square"
        }
    }
}

enum TuckContext: String, CaseIterable, Identifiable {
    case desktop, folder, image, pdf, mixed, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hasSelection: Bool { self == .image || self == .pdf || self == .mixed || self == .other }
}

enum TuckMenuModel {
    static func visible(in context: TuckContext) -> [TuckAction] {
        TuckPreferences.order.compactMap(TuckAction.init(rawValue:)).filter { action in
            guard TuckPreferences.enabled(action.id) else { return false }
            if context == .desktop && !TuckPreferences.showDesktop { return false }
            switch action {
            case .newFile:
                return context == .desktop || context == .folder
            case .openWith:
                return context.hasSelection
            case .compress:
                return context.hasSelection
            case .terminal:
                return true
            case .pdfToolkit:
                return context == .pdf || context == .mixed
            case .imageToolkit:
                return context == .image
            case .metadata:
                return context.hasSelection
            case .copyAs:
                return context.hasSelection
            case .rename:
                return context.hasSelection
            case .duplicates:
                return context == .other
            }
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

public enum CopyAsFormat: String, CaseIterable, Identifiable, Sendable {
    case absolutePath = "Absolute Path"
    case relativePath = "Relative Path"
    case fileNameWithExt = "Filename"
    case fileNameWithoutExt = "Filename Without Extension"
    case fileURL = "File URL"
    case shellQuoted = "Shell-Quoted Path"
    case sha256 = "SHA-256 Checksum"

    public var id: String { rawValue }
}
