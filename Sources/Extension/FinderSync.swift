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

        // PDF Toolkit tags
        static let pdfMerge = 400
        static let pdfSplitRange = 401
        static let pdfSplitPages = 402
        static let pdfRotate90 = 403
        static let pdfRotate180 = 404
        static let pdfRotate270 = 405
        static let pdfOCR = 406
        static let pdfExtractImages = 407
        static let pdfToImages = 408
        static let pdfReorder = 409

        // Image Toolkit tags
        static let imgToJPEG = 500
        static let imgToPNG = 501
        static let imgToHEIC = 502
        static let imgToTIFF = 503
        static let imgToWebP = 504
        static let imgToPDF = 505
        static let imgResize50 = 510
        static let imgResize25 = 511
        static let imgResizeCustom = 512

        // Metadata tags
        static let metaInspect = 600
        static let metaStrip = 601

        // Copy As tags
        static let copyAbsPath = 700
        static let copyRelPath = 701
        static let copyFileName = 702
        static let copyFileNameNoExt = 703
        static let copyFileURL = 704
        static let copyShellQuoted = 705
        static let copySHA256 = 706

        // Rename tags
        static let renameBatch = 800
        static let copyFavorite = 900
        static let moveFavorite = 950
        static let chooseCopy = 990
        static let chooseMove = 991
    }

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
        let imageExts = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "webp", "gif"]
        if kind == .contextualMenuForContainer {
            context = target?.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path ? .desktop : .folder
        } else if !selection.isEmpty && selection.allSatisfy({ $0.pathExtension.lowercased() == "zip" }) {
            context = .archive
        } else if !selection.isEmpty && selection.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) {
            context = .pdf
        } else if !selection.isEmpty && selection.allSatisfy({ imageExts.contains($0.pathExtension.lowercased()) }) {
            context = .image
        } else if !selection.isEmpty && selection.allSatisfy({ $0.pathExtension.lowercased() == "pdf" || imageExts.contains($0.pathExtension.lowercased()) }) {
            context = .mixed
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
            case .pdfToolkit:
                item.submenu = makePDFToolkitMenu(context: context)
            case .imageToolkit:
                item.submenu = makeImageToolkitMenu()
            case .metadata:
                item.submenu = makeMetadataMenu()
            case .copyAs:
                item.submenu = makeCopyAsMenu()
            case .rename:
                item.action = #selector(advancedRename(_:))
            case .destinations:
                item.submenu = makeDestinationMenu()
            case .duplicates:
                item.action = #selector(findDuplicates(_:))
            case .zipInspector:
                item.action = #selector(inspectZIP(_:))
            }
            root.addItem(item)
        }
        TuckLog.extensionLogger.info("extension.menu kind=\(kind.rawValue) context=\(context.rawValue, privacy: .public) selection=\(selection.count) target=\(target != nil, privacy: .public) actions=\(entries.count)")
        return root.items.isEmpty ? nil : root
    }

    private func makeDestinationMenu() -> NSMenu {
        let root = NSMenu(title: "Copy / Move To")
        let copy = NSMenu(title: "Copy To")
        let move = NSMenu(title: "Move To")
        for favorite in FavoritePreferences.all {
            let a = copy.addItem(withTitle: favorite.title, action: #selector(destinationAction(_:)), keyEquivalent: "")
            a.tag = Tag.copyFavorite
            a.representedObject = favorite.id.uuidString
            let b = move.addItem(withTitle: favorite.title, action: #selector(destinationAction(_:)), keyEquivalent: "")
            b.tag = Tag.moveFavorite
            b.representedObject = favorite.id.uuidString
        }
        if !FavoritePreferences.all.isEmpty {
            copy.addItem(.separator())
            move.addItem(.separator())
        }
        let chooseCopy = copy.addItem(withTitle: "Choose Folder…", action: #selector(destinationAction(_:)), keyEquivalent: "")
        chooseCopy.tag = Tag.chooseCopy
        let chooseMove = move.addItem(withTitle: "Choose Folder…", action: #selector(destinationAction(_:)), keyEquivalent: "")
        chooseMove.tag = Tag.chooseMove
        let ci = root.addItem(withTitle: "Copy To", action: nil, keyEquivalent: "")
        ci.submenu = copy
        let mi = root.addItem(withTitle: "Move To", action: nil, keyEquivalent: "")
        mi.submenu = move
        return root
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

    private func makePDFToolkitMenu(context: TuckContext) -> NSMenu {
        let menu = NSMenu(title: "PDF Toolkit")
        let merge = menu.addItem(withTitle: "Merge into PDF…", action: #selector(pdfAction(_:)), keyEquivalent: "")
        merge.tag = Tag.pdfMerge

        if context == .pdf {
            menu.addItem(.separator())
            let splitRange = menu.addItem(withTitle: "Split by Page Range…", action: #selector(pdfAction(_:)), keyEquivalent: "")
            splitRange.tag = Tag.pdfSplitRange

            let splitPages = menu.addItem(withTitle: "Split Every Page", action: #selector(pdfAction(_:)), keyEquivalent: "")
            splitPages.tag = Tag.pdfSplitPages

            let rotateSubmenu = NSMenu(title: "Rotate Pages")
            let r90 = rotateSubmenu.addItem(withTitle: "Rotate 90° Clockwise", action: #selector(pdfAction(_:)), keyEquivalent: "")
            r90.tag = Tag.pdfRotate90
            let r180 = rotateSubmenu.addItem(withTitle: "Rotate 180°", action: #selector(pdfAction(_:)), keyEquivalent: "")
            r180.tag = Tag.pdfRotate180
            let r270 = rotateSubmenu.addItem(withTitle: "Rotate 90° Counterclockwise", action: #selector(pdfAction(_:)), keyEquivalent: "")
            r270.tag = Tag.pdfRotate270

            let rotateItem = menu.addItem(withTitle: "Rotate Pages", action: nil, keyEquivalent: "")
            rotateItem.submenu = rotateSubmenu

            let reorder = menu.addItem(withTitle: "Reorder Pages…", action: #selector(pdfAction(_:)), keyEquivalent: "")
            reorder.tag = Tag.pdfReorder

            menu.addItem(.separator())
            let ocr = menu.addItem(withTitle: "OCR (Recognize Text)…", action: #selector(pdfAction(_:)), keyEquivalent: "")
            ocr.tag = Tag.pdfOCR

            let extractImages = menu.addItem(withTitle: "Extract Embedded Images", action: #selector(pdfAction(_:)), keyEquivalent: "")
            extractImages.tag = Tag.pdfExtractImages

            let toImages = menu.addItem(withTitle: "Convert Pages to Images", action: #selector(pdfAction(_:)), keyEquivalent: "")
            toImages.tag = Tag.pdfToImages
        }
        return menu
    }

    private func makeImageToolkitMenu() -> NSMenu {
        let menu = NSMenu(title: "Image Toolkit")
        let convertSubmenu = NSMenu(title: "Convert Format")
        let toJPEG = convertSubmenu.addItem(withTitle: "Convert to JPEG", action: #selector(imageAction(_:)), keyEquivalent: "")
        toJPEG.tag = Tag.imgToJPEG
        let toPNG = convertSubmenu.addItem(withTitle: "Convert to PNG", action: #selector(imageAction(_:)), keyEquivalent: "")
        toPNG.tag = Tag.imgToPNG
        let toHEIC = convertSubmenu.addItem(withTitle: "Convert to HEIC", action: #selector(imageAction(_:)), keyEquivalent: "")
        toHEIC.tag = Tag.imgToHEIC
        let toTIFF = convertSubmenu.addItem(withTitle: "Convert to TIFF", action: #selector(imageAction(_:)), keyEquivalent: "")
        toTIFF.tag = Tag.imgToTIFF
        let toWebP = convertSubmenu.addItem(withTitle: "Convert to WebP", action: #selector(imageAction(_:)), keyEquivalent: "")
        toWebP.tag = Tag.imgToWebP
        let toPDF = convertSubmenu.addItem(withTitle: "Convert to PDF", action: #selector(imageAction(_:)), keyEquivalent: "")
        toPDF.tag = Tag.imgToPDF

        let convertItem = menu.addItem(withTitle: "Convert Format", action: nil, keyEquivalent: "")
        convertItem.submenu = convertSubmenu

        let resizeSubmenu = NSMenu(title: "Resize")
        let r50 = resizeSubmenu.addItem(withTitle: "Scale 50%", action: #selector(imageAction(_:)), keyEquivalent: "")
        r50.tag = Tag.imgResize50
        let r25 = resizeSubmenu.addItem(withTitle: "Scale 25%", action: #selector(imageAction(_:)), keyEquivalent: "")
        r25.tag = Tag.imgResize25
        let rCustom = resizeSubmenu.addItem(withTitle: "Custom Dimensions…", action: #selector(imageAction(_:)), keyEquivalent: "")
        rCustom.tag = Tag.imgResizeCustom

        let resizeItem = menu.addItem(withTitle: "Resize", action: nil, keyEquivalent: "")
        resizeItem.submenu = resizeSubmenu

        return menu
    }

    private func makeMetadataMenu() -> NSMenu {
        let menu = NSMenu(title: "Metadata")
        let inspect = menu.addItem(withTitle: "Inspect Metadata…", action: #selector(metadataAction(_:)), keyEquivalent: "")
        inspect.tag = Tag.metaInspect
        let strip = menu.addItem(withTitle: "Strip Metadata", action: #selector(metadataAction(_:)), keyEquivalent: "")
        strip.tag = Tag.metaStrip
        return menu
    }

    private func makeCopyAsMenu() -> NSMenu {
        let menu = NSMenu(title: "Copy As")
        let p1 = menu.addItem(withTitle: "Absolute Path", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p1.tag = Tag.copyAbsPath
        let p2 = menu.addItem(withTitle: "Relative Path", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p2.tag = Tag.copyRelPath
        let p3 = menu.addItem(withTitle: "Filename", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p3.tag = Tag.copyFileName
        let p4 = menu.addItem(withTitle: "Filename Without Extension", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p4.tag = Tag.copyFileNameNoExt
        let p5 = menu.addItem(withTitle: "File URL", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p5.tag = Tag.copyFileURL
        let p6 = menu.addItem(withTitle: "Shell-Quoted Path", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p6.tag = Tag.copyShellQuoted
        let p7 = menu.addItem(withTitle: "SHA-256 Checksum", action: #selector(copyAsAction(_:)), keyEquivalent: "")
        p7.tag = Tag.copySHA256
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

    @objc func pdfAction(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let paths = selection.map(\.path)
        guard !paths.isEmpty else { return }

        switch sender.tag {
        case Tag.pdfMerge:
            dispatch("pdfMerge", paths: paths)
        case Tag.pdfSplitRange:
            dispatch("pdfSplitRange", paths: paths)
        case Tag.pdfSplitPages:
            dispatch("pdfSplitPages", paths: paths)
        case Tag.pdfRotate90:
            dispatch("pdfRotate", paths: paths, argument: "90")
        case Tag.pdfRotate180:
            dispatch("pdfRotate", paths: paths, argument: "180")
        case Tag.pdfRotate270:
            dispatch("pdfRotate", paths: paths, argument: "270")
        case Tag.pdfOCR:
            dispatch("pdfOCR", paths: paths)
        case Tag.pdfExtractImages:
            dispatch("pdfExtractImages", paths: paths)
        case Tag.pdfToImages:
            dispatch("pdfToImages", paths: paths)
        case Tag.pdfReorder:
            dispatch("pdfReorder", paths: paths)
        default:
            break
        }
    }

    @objc func imageAction(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let paths = selection.map(\.path)
        guard !paths.isEmpty else { return }

        switch sender.tag {
        case Tag.imgToJPEG:
            dispatch("imageConvert", paths: paths, argument: "jpeg")
        case Tag.imgToPNG:
            dispatch("imageConvert", paths: paths, argument: "png")
        case Tag.imgToHEIC:
            dispatch("imageConvert", paths: paths, argument: "heic")
        case Tag.imgToTIFF:
            dispatch("imageConvert", paths: paths, argument: "tiff")
        case Tag.imgToWebP:
            dispatch("imageConvert", paths: paths, argument: "webp")
        case Tag.imgToPDF:
            dispatch("pdfMerge", paths: paths)
        case Tag.imgResize50:
            dispatch("imageResize", paths: paths, argument: "pct:50")
        case Tag.imgResize25:
            dispatch("imageResize", paths: paths, argument: "pct:25")
        case Tag.imgResizeCustom:
            dispatch("imageResizeCustom", paths: paths)
        default:
            break
        }
    }

    @objc func metadataAction(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let paths = selection.map(\.path)
        guard !paths.isEmpty else { return }

        switch sender.tag {
        case Tag.metaInspect:
            dispatch("metaInspect", paths: paths)
        case Tag.metaStrip:
            dispatch("metaStrip", paths: paths)
        default:
            break
        }
    }

    @objc func copyAsAction(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let paths = selection.map(\.path)
        guard !paths.isEmpty else { return }

        let formatStr: String
        switch sender.tag {
        case Tag.copyAbsPath: formatStr = CopyAsFormat.absolutePath.rawValue
        case Tag.copyRelPath: formatStr = CopyAsFormat.relativePath.rawValue
        case Tag.copyFileName: formatStr = CopyAsFormat.fileNameWithExt.rawValue
        case Tag.copyFileNameNoExt: formatStr = CopyAsFormat.fileNameWithoutExt.rawValue
        case Tag.copyFileURL: formatStr = CopyAsFormat.fileURL.rawValue
        case Tag.copyShellQuoted: formatStr = CopyAsFormat.shellQuoted.rawValue
        case Tag.copySHA256: formatStr = CopyAsFormat.sha256.rawValue
        default: formatStr = CopyAsFormat.absolutePath.rawValue
        }
        dispatch("copyAs", paths: paths, argument: formatStr)
    }

    @objc func advancedRename(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let paths = selection.map(\.path)
        guard !paths.isEmpty else { return }
        dispatch("advancedRename", paths: paths)
    }

    @objc func destinationAction(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        guard !selection.isEmpty else { return }
        let copy = sender.tag == Tag.copyFavorite || sender.tag == Tag.chooseCopy
        let move = sender.tag == Tag.moveFavorite || sender.tag == Tag.chooseMove
        guard copy || move else { return }
        let favorite = (sender.tag == Tag.chooseCopy || sender.tag == Tag.chooseMove)
            ? "choose" : (sender.representedObject as? String)
        guard let favorite else { return }
        dispatch(copy ? "copyTo" : "moveTo", paths: selection.map(\.path), argument: favorite)
    }

    @objc func findDuplicates(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let folders = selection.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if !folders.isEmpty { dispatch("findDuplicates", paths: folders.map(\.path)) }
    }

    @objc func inspectZIP(_ sender: NSMenuItem) {
        let (selection, _) = resolveContext()
        let archives = selection.filter { $0.pathExtension.lowercased() == "zip" }
        if !archives.isEmpty { dispatch("inspectZIP", paths: archives.map(\.path)) }
    }

    private func dispatch(_ operation: String, paths: [String], argument: String? = nil) {
        if paths.count > 256 {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Selection Exceeds Limit"
                alert.informativeText = "Tuck supports batch operations on up to 256 files at once. You have selected \(paths.count) items. Please reduce your selection to 256 files or fewer."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            TuckLog.extensionLogger.error("ipc.dispatch-aborted op=\(operation, privacy: .public) reason=exceeds-max-paths count=\(paths.count)")
            return
        }

        guard let url = TuckRequest(operation: operation, paths: paths, argument: argument).signedURL() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Request Too Large"
                alert.informativeText = "The total file path payload exceeded the maximum buffer size. Try selecting fewer files or files with shorter paths."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
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