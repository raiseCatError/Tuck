import AppKit
import SwiftUI
import CryptoKit

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    let size: UInt64
    let members: [OutputIdentity]
    var reclaimable: UInt64 { size * UInt64(max(0, members.count - 1)) }
}

/// Read-only scan: files are grouped by exact byte size and then full SHA-256.
/// Symlinks, packages and file references already pointing to the same inode
/// are deliberately excluded. No file is removed during scanning.
enum DuplicateScanner {
    static func scan(_ roots: [URL], isCancelled: @escaping @Sendable () -> Bool,
                     progress: @escaping @Sendable (Int) -> Void) throws -> [DuplicateGroup] {
        let fm = FileManager.default
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        var candidates: [UInt64: [URL]] = [:]
        var seenPaths = Set<String>()
        var seenInodes = Set<String>()
        var visited = 0
        for root in roots {
            if isCancelled() { throw CancellationError() }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            let files: [URL]
            if !isDir.boolValue {
                files = [root]
            } else {
                guard let en = fm.enumerator(at: root, includingPropertiesForKeys:
                    [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey],
                    options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
                var gathered: [URL] = []
                while let next = en.nextObject() as? URL {
                    if isCancelled() { throw CancellationError() }
                    if gathered.count >= 100_000 {
                        throw UndoError.unsafe("Scan exceeds 100,000 entries. Select a smaller folder.")
                    }
                    gathered.append(next)
                }
                files = gathered
            }
            for file in files {
                if isCancelled() { throw CancellationError() }
                let path = file.standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                      let vals = try? file.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey
                      ]),
                      vals.isRegularFile == true, vals.isSymbolicLink != true,
                      vals.isPackage != true,
                      let attrs = try? fm.attributesOfItem(atPath: path),
                      let dev = attrs[.systemNumber] as? NSNumber,
                      let inode = attrs[.systemFileNumber] as? NSNumber,
                      let size = attrs[.size] as? NSNumber else { continue }
                let identity = "\(dev.uint64Value):\(inode.uint64Value)"
                guard seenInodes.insert(identity).inserted else { continue }
                candidates[size.uint64Value, default: []].append(file)
                visited += 1
                if visited % 32 == 0 { progress(visited) }
            }
        }
        _ = rootPaths
        var groups: [DuplicateGroup] = []
        for (size, matches) in candidates where matches.count > 1 {
            if isCancelled() { throw CancellationError() }
            var byHash: [String: [OutputIdentity]] = [:]
            for url in matches {
                if isCancelled() { throw CancellationError() }
                guard let proof = try? OutputIdentity.capture(url) else { continue }
                byHash[proof.sha256, default: []].append(proof)
            }
            for (_, proofs) in byHash where proofs.count > 1 {
                // Distinct file identities were checked before grouping.
                groups.append(DuplicateGroup(id: UUID().uuidString, size: size,
                                             members: proofs.sorted { $0.path < $1.path }))
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }
}

@MainActor
private final class DuplicateModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var visited = 0
    @Published var running = true
    @Published var message = "Scanning selected folders…"
    let token = CancellationFlag()

    func begin(_ roots: [URL]) {
        let cancellation = token
        Task.detached(priority: .utility) { [weak self] in
            do {
                let groups = try DuplicateScanner.scan(roots,
                    isCancelled: { cancellation.isCancelled },
                    progress: { [weak self] count in
                        Task { await self?.recordProgress(count) }
                    })
                await self?.finished(groups)
            } catch {
                await self?.failed(error)
            }
        }
    }

    private func recordProgress(_ count: Int) { visited = count }
    private func finished(_ result: [DuplicateGroup]) {
        groups = result
        message = result.isEmpty ? "No exact duplicates found." :
            "Found \(result.count) exact-content duplicate group(s)."
        running = false
    }
    private func failed(_ error: Error) {
        message = error is CancellationError ? "Scan cancelled." : error.localizedDescription
        running = false
    }
}

@MainActor
enum DuplicateWindow {
    private static var windows: [UUID: NSWindow] = [:]
    static func show(paths: [String]) {
        guard !paths.isEmpty else { return }
        let id = UUID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Find Exact Duplicates"
        window.contentViewController = NSHostingController(rootView:
            DuplicatesView(roots: paths.map { URL(fileURLWithPath: $0) }))
        window.center()
        window.isReleasedWhenClosed = false
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = windows.removeValue(forKey: id) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct DuplicatesView: View {
    let roots: [URL]
    @StateObject private var model = DuplicateModel()
    @State private var selected = Set<String>()
    @State private var filter = ""
    @State private var errorText = ""
    @State private var showError = false
    @State private var confirmTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exact Duplicates").font(.title2.weight(.semibold))
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running {
                    ProgressView()
                    Text("\(model.visited) files").font(.caption).monospacedDigit()
                    Button("Cancel") { model.token.cancel() }
                }
            }
            if !model.running && !model.groups.isEmpty {
                HStack {
                    TextField("Filter paths", text: $filter)
                    Text("Potential savings: \(savingsLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Move Selected to Trash…") { confirmTrash = true }
                        .disabled(selected.isEmpty)
                }
                List {
                    ForEach(model.groups) { group in
                        Section("\(group.members.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)) each") {
                            ForEach(group.members.filter {
                                filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter)
                            }, id: \.path) { proof in
                                HStack {
                                    Toggle("", isOn: Binding(
                                        get: { selected.contains(proof.path) },
                                        set: { value in
                                            if value { selected.insert(proof.path) }
                                            else { selected.remove(proof.path) }
                                        }
                                    )).labelsHidden()
                                    Text(proof.path).font(.callout).lineLimit(2)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([
                                            URL(fileURLWithPath: proof.path)])
                                    }
                                }
                            }
                        }
                    }
                }
            } else if !model.running {
                ContentUnavailableView("Nothing to review", systemImage: "doc.on.doc",
                                       description: Text(model.message))
            }
            Text("Exact full-file SHA-256, not filename similarity. Skips symlinks and packages. Select only disposable copies for Trash; Tuck never chooses deletions automatically.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 680, minHeight: 430)
        .task { model.begin(roots) }
        .confirmationDialog("Move \(selected.count) verified duplicate copies to Trash?",
                            isPresented: $confirmTrash) {
            Button("Move Selected to Trash", role: .destructive) {
                Task {
                    do { try await removeSelected() }
                    catch { errorText = error.localizedDescription; showError = true }
                }
            }
        } message: {
            Text("Tuck will refuse to remove every member of a group, and will recheck identities before moving anything.")
        }
        .alert("Duplicate cleanup refused", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText) }
    }

    private var savingsLabel: String {
        let bytes = model.groups.reduce(UInt64(0)) { $0 + $1.reclaimable }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func removeSelected() async throws {
        let marked = selected
        let groups = model.groups
        // Never trash every member in any group.
        for group in groups {
            guard group.members.filter({ marked.contains($0.path) }).count < group.members.count else {
                throw UndoError.unsafe("At least one copy in every group must remain unselected.")
            }
        }
        let proofs = groups.flatMap(\.members).filter { marked.contains($0.path) }
        guard !proofs.isEmpty else { return }
        // Full-file identity hashing and Trash I/O run away from the UI actor.
        let removed = try await Task.detached(priority: .userInitiated) {
            for proof in proofs { try proof.verifyUnchanged() }
            var moved: [String] = []
            for proof in proofs {
                do {
                    try proof.verifyUnchanged()
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: proof.path), resultingItemURL: nil)
                    moved.append(proof.path)
                } catch {
                    throw UndoError.unsafe(
                        "Moved \(moved.count) item(s) to Trash before an error. Refresh results and inspect Trash: \(error.localizedDescription)")
                }
            }
            return moved
        }.value
        selected.subtract(removed)
        let removedSet = Set(removed)
        model.groups = groups.compactMap { group in
            let remaining = group.members.filter { !removedSet.contains($0.path) }
            return remaining.count > 1
                ? DuplicateGroup(id: group.id, size: group.size, members: remaining) : nil
        }
    }
}
