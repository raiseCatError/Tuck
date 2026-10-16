import AppKit
import FinderSync

@objc(TuckFinderSync)
final class TuckFinderSync: FIFinderSync {
    private enum Tag {
        static let newTemplate = 100
        static let customFile = 150
        static let openWith = 200
        static let compressMB = 300
        static let customSize = 350
        static let zip = 360
    }

    override init() {
        super.init()
        watchVolumes()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func volumesChanged(_ notification: Notification) { watchVolumes() }

    private func watchVolumes() {
        var watched: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        watched.formUnion(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? [])
        FIFinderSyncController.default().directoryURLs = watched
    }

    private var selected: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    private var targetDirectory: URL? {
        let controller = FIFinderSyncController.default()
        if let target = controller.targetedURL() { return target }
        if TuckPreferences.showDesktop {
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        return nil
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForContainer || kind == .contextualMenuForItems else { return nil }
        TuckPreferences.store.synchronize()
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL
        let clickedPaths = selected.isEmpty ? [targetDirectory].compactMap { $0 } : selected
        if !TuckPreferences.showDesktop,
           let desktop,
           clickedPaths.contains(where: { $0.standardizedFileURL == desktop || $0.deletingLastPathComponent().standardizedFileURL == desktop }) {
            return nil
        }
        let context: TuckContext
        if kind == .contextualMenuForContainer {
            context = targetDirectory?.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path ? .desktop : .folder
        } else if !selected.isEmpty && selected.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
            context = .pdf
        } else if !selected.isEmpty && selected.allSatisfy({ ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp"].contains($0.pathExtension.lowercased()) }) {
            context = .image
        } else {
            context = .other
        }
        let entries = TuckMenuModel.visible(in: context)
        let root = NSMenu(title: "Tuck")
        for action in entries {
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            switch action {
            case .newFile:
                item.submenu = makeFileMenu()
            case .openWith:
                item.submenu = makeOpenWithMenu()
            case .compress:
                item.submenu = makeCompressMenu()
            case .terminal:
                item.action = #selector(openTerminal(_:))
                item.target = self
            }
            root.addItem(item)
        }
        return root.items.isEmpty ? nil : root
    }

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "New File")
        for (index, template) in TuckMenuModel.templates.enumerated() {
            let item = menu.addItem(withTitle: template.0, action: #selector(createFile(_:)), keyEquivalent: "")
            item.tag = Tag.newTemplate + index
            item.target = self
        }
        menu.addItem(.separator())
        let custom = menu.addItem(withTitle: "Custom Name…", action: #selector(createFile(_:)), keyEquivalent: "")
        custom.tag = Tag.customFile
        custom.target = self
        return menu
    }

    private func makeOpenWithMenu() -> NSMenu {
        let menu = NSMenu(title: "Open With")
        for (index, editor) in TuckMenuModel.editors.enumerated() {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.1) != nil else { continue }
            let item = menu.addItem(withTitle: editor.0, action: #selector(openInApp(_:)), keyEquivalent: "")
            item.tag = Tag.openWith + index
            item.target = self
        }
        return menu
    }

    private func makeCompressMenu() -> NSMenu {
        let menu = NSMenu(title: "Compress")
        for (index, size) in TuckPreferences.sizes.enumerated() {
            let item = menu.addItem(withTitle: "Under \(size) MB", action: #selector(compress(_:)), keyEquivalent: "")
            item.tag = Tag.compressMB + index
            item.target = self
        }
        let custom = menu.addItem(withTitle: "Custom Size…", action: #selector(compress(_:)), keyEquivalent: "")
        custom.tag = Tag.customSize
        custom.target = self
        menu.addItem(.separator())
        let zip = menu.addItem(withTitle: "Create ZIP Archive", action: #selector(compress(_:)), keyEquivalent: "")
        zip.tag = Tag.zip
        zip.target = self
        return menu
    }

    @objc private func createFile(_ sender: NSMenuItem) {
        guard let folder = selected.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? targetDirectory else { return }
        if sender.tag == Tag.customFile {
            dispatch("newFileCustom", paths: [folder.path]); return
        }
        let index = sender.tag - Tag.newTemplate
        guard TuckMenuModel.templates.indices.contains(index) else { return }
        dispatch("newFile", paths: [folder.path], argument: TuckMenuModel.templates[index].1)
    }

    @objc private func openInApp(_ sender: NSMenuItem) {
        let index = sender.tag - Tag.openWith
        guard TuckMenuModel.editors.indices.contains(index) else { return }
        let paths = selected.isEmpty ? (targetDirectory.map { [$0.path] } ?? []) : selected.map(\.path)
        dispatch("openWith", paths: paths, argument: TuckMenuModel.editors[index].1)
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        let source = selected.first ?? targetDirectory
        guard let source else { return }
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let folder = isFolder ? source : source.deletingLastPathComponent()
        dispatch("terminal", paths: [folder.path])
    }

    @objc private func compress(_ sender: NSMenuItem) {
        let paths = selected.map(\.path)
        guard !paths.isEmpty else { return }
        if sender.tag == Tag.zip { dispatch("zip", paths: paths); return }
        if sender.tag == Tag.customSize { dispatch("compressCustom", paths: paths); return }
        let index = sender.tag - Tag.compressMB
        guard TuckPreferences.sizes.indices.contains(index) else { return }
        dispatch("compress", paths: paths, argument: String(TuckPreferences.sizes[index]))
    }

    private func dispatch(_ operation: String, paths: [String], argument: String? = nil) {
        guard let url = TuckRequest(operation: operation, paths: paths, argument: argument).signedURL() else { return }
        NSWorkspace.shared.open(url)
    }
}
