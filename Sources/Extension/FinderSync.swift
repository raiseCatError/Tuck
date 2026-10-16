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

    // Finder can clear the selection context between building a menu and the click
    // that activates it, so the URLs resolved while building the menu are reused by
    // the action instead of being queried again after the menu closes.
    private var menuSelection: [URL]?
    private var menuTarget: URL?

    override init() {
        super.init()
        let watched = watchVolumes()
        TuckLog.extensionLogger.info("extension.started pid=\(ProcessInfo.processInfo.processIdentifier) watchedVolumes=\(watched) hasKey=\(TuckPreferences.sharedKey != nil)")
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func volumesChanged(_ notification: Notification) {
        let watched = watchVolumes()
        TuckLog.extensionLogger.info("extension.volumes-changed watchedVolumes=\(watched)")
    }

    private func watchVolumes() -> Int {
        var watched: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        watched.formUnion(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? [])
        FIFinderSyncController.default().directoryURLs = watched
        return watched.count
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

    private func resolveContext() -> (selected: [URL], target: URL?) {
        let liveSelected = selected
        let liveTarget = targetDirectory
        guard let menuSelection else { return (liveSelected, liveTarget) }
        return (menuSelection.isEmpty ? liveSelected : menuSelection, menuTarget ?? liveTarget)
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForContainer || kind == .contextualMenuForItems else { return nil }
        TuckPreferences.store.synchronize()
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL
        let selection = selected
        let target = targetDirectory
        menuSelection = selection
        menuTarget = target
        let clickedPaths = selection.isEmpty ? [target].compactMap { $0 } : selection
        if !TuckPreferences.showDesktop,
           let desktop,
           clickedPaths.contains(where: { $0.standardizedFileURL == desktop || $0.deletingLastPathComponent().standardizedFileURL == desktop }) {
            TuckLog.extensionLogger.info("extension.menu kind=\(kind.rawValue) skipped=desktop-hidden")
            return nil
        }
        let context: TuckContext
        if kind == .contextualMenuForContainer {
            context = target?.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path ? .desktop : .folder
        } else if !selection.isEmpty && selection.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
            context = .pdf
        } else if !selection.isEmpty && selection.allSatisfy({ ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp"].contains($0.pathExtension.lowercased()) }) {
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
            }
            root.addItem(item)
        }
        TuckLog.extensionLogger.info("extension.menu kind=\(kind.rawValue) context=\(context.rawValue, privacy: .public) selection=\(selection.count) target=\(target != nil, privacy: .public) actions=\(entries.count)")
        return root.items.isEmpty ? nil : root
    }

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "New File")
        for (index, template) in TuckMenuModel.templates.enumerated() {
            let item = menu.addItem(withTitle: template.0, action: #selector(createFile(_:)), keyEquivalent: "")
            item.tag = Tag.newTemplate + index
        }
        menu.addItem(.separator())
        let custom = menu.addItem(withTitle: "Custom Name…", action: #selector(createFile(_:)), keyEquivalent: "")
        custom.tag = Tag.customFile
        return menu
    }

    private func makeOpenWithMenu() -> NSMenu {
        let menu = NSMenu(title: "Open With")
        for (index, editor) in TuckMenuModel.editors.enumerated() {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.1) != nil else { continue }
            let item = menu.addItem(withTitle: editor.0, action: #selector(openInApp(_:)), keyEquivalent: "")
            item.tag = Tag.openWith + index
        }
        return menu
    }

    private func makeCompressMenu() -> NSMenu {
        let menu = NSMenu(title: "Compress")
        for (index, size) in TuckPreferences.sizes.enumerated() {
            let item = menu.addItem(withTitle: "Under \(size) MB", action: #selector(compress(_:)), keyEquivalent: "")
            item.tag = Tag.compressMB + index
        }
        let custom = menu.addItem(withTitle: "Custom Size…", action: #selector(compress(_:)), keyEquivalent: "")
        custom.tag = Tag.customSize
        menu.addItem(.separator())
        let zip = menu.addItem(withTitle: "Create ZIP Archive", action: #selector(compress(_:)), keyEquivalent: "")
        zip.tag = Tag.zip
        return menu
    }

    @objc func createFile(_ sender: NSMenuItem) {
        let (selection, target) = resolveContext()
        TuckLog.extensionLogger.info("menu.action=createFile tag=\(sender.tag) selection=\(selection.count) target=\(target != nil, privacy: .public)")
        guard let folder = selection.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? target else {
            TuckLog.extensionLogger.error("menu.createFile-aborted reason=no-destination")
            return
        }
        if sender.tag == Tag.customFile {
            dispatch("newFileCustom", paths: [folder.path]); return
        }
        let index = sender.tag - Tag.newTemplate
        guard TuckMenuModel.templates.indices.contains(index) else {
            TuckLog.extensionLogger.error("menu.createFile-aborted reason=unknown-template-tag")
            return
        }
        dispatch("newFile", paths: [folder.path], argument: TuckMenuModel.templates[index].1)
    }

    @objc func openInApp(_ sender: NSMenuItem) {
        let (selection, target) = resolveContext()
        TuckLog.extensionLogger.info("menu.action=openInApp tag=\(sender.tag) selection=\(selection.count)")
        let index = sender.tag - Tag.openWith
        guard TuckMenuModel.editors.indices.contains(index) else {
            TuckLog.extensionLogger.error("menu.openInApp-aborted reason=unknown-editor-tag")
            return
        }
        let paths = selection.isEmpty ? (target.map { [$0.path] } ?? []) : selection.map(\.path)
        guard !paths.isEmpty else {
            TuckLog.extensionLogger.error("menu.openInApp-aborted reason=no-target")
            return
        }
        dispatch("openWith", paths: paths, argument: TuckMenuModel.editors[index].1)
    }

    @objc func openTerminal(_ sender: NSMenuItem) {
        let (selection, target) = resolveContext()
        TuckLog.extensionLogger.info("menu.action=openTerminal tag=\(sender.tag) selection=\(selection.count)")
        let source = selection.first ?? target
        guard let source else {
            TuckLog.extensionLogger.error("menu.openTerminal-aborted reason=no-target")
            return
        }
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let folder = isFolder ? source : source.deletingLastPathComponent()
        dispatch("terminal", paths: [folder.path])
    }

    @objc func compress(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        TuckLog.extensionLogger.info("menu.action=compress tag=\(sender.tag) selection=\(selection.count)")
        let paths = selection.map(\.path)
        guard !paths.isEmpty else {
            TuckLog.extensionLogger.error("menu.compress-aborted reason=no-selection")
            return
        }
        if sender.tag == Tag.zip { dispatch("zip", paths: paths); return }
        if sender.tag == Tag.customSize { dispatch("compressCustom", paths: paths); return }
        let index = sender.tag - Tag.compressMB
        guard TuckPreferences.sizes.indices.contains(index) else {
            TuckLog.extensionLogger.error("menu.compress-aborted reason=unknown-size-tag")
            return
        }
        dispatch("compress", paths: paths, argument: String(TuckPreferences.sizes[index]))
    }

    private func dispatch(_ operation: String, paths: [String], argument: String? = nil) {
        guard let url = TuckRequest(operation: operation, paths: paths, argument: argument).signedURL() else {
            TuckLog.extensionLogger.error("ipc.dispatch-failed op=\(operation, privacy: .public) paths=\(paths.count)")
            return
        }
        let accepted = NSWorkspace.shared.open(url)
        if accepted {
            TuckLog.extensionLogger.info("ipc.dispatched op=\(operation, privacy: .public) paths=\(paths.count)")
        } else {
            TuckLog.extensionLogger.error("ipc.dispatch-refused op=\(operation, privacy: .public) paths=\(paths.count) reason=no-handler-for-scheme")
        }
    }
}