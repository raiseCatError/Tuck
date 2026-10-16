import Foundation

enum CustomActionRunner {
    enum ActionFailure: LocalizedError {
        case missing
        case incompatible
        case cancelled
        case invalidExecutable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: "The action was removed or disabled."
            case .incompatible: "The selection is not compatible with this action."
            case .cancelled: "The custom action was cancelled."
            case .invalidExecutable: "The executable is unavailable, not a regular file, or lacks execute permission."
            case .failed(let message): message
            }
        }
    }

    static func supports(_ action: CustomFinderAction, paths: [String]) -> Bool {
        guard action.enabled, action.valid, !paths.isEmpty, paths.count <= 256 else { return false }
        let fm = FileManager.default
        for path in paths {
            guard path.hasPrefix("/"),
                  let values = try? URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
            if action.selection == .files && values.isRegularFile != true { return false }
            if action.selection == .folders && values.isDirectory != true { return false }
            if values.isRegularFile != true && values.isDirectory != true { return false }
        }
        _ = fm
        return true
    }

    static func execute(_ action: CustomFinderAction, paths: [String],
                        shouldCancel: @escaping @Sendable () -> Bool) throws {
        guard supports(action, paths: paths) else { throw ActionFailure.incompatible }
        if shouldCancel() { throw CancellationError() }

        let tool: Tool
        let args: [String]
        switch action.kind {
        case .executable:
            let url = URL(fileURLWithPath: action.target).standardizedFileURL
            guard url.path == action.target,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ActionFailure.invalidExecutable
            }
            tool = Tool(name: action.title, url: url)
            args = paths // Each path is exactly one argv element, not shell-interpolated.
        case .shortcut:
            guard paths.count == 1 else {
                throw ActionFailure.failed("macOS Shortcuts accepts a single input file per invocation. Select one item.")
            }
            tool = Tool(name: "shortcuts", url: URL(fileURLWithPath: "/usr/bin/shortcuts"))
            args = ["run", action.target, "--input-path", paths[0]]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8"
        ]
        do {
            _ = try Toolchain.run(tool, args, timeout: 300,
                shouldCancel: shouldCancel,
                workingDirectory: URL(fileURLWithPath: home),
                environment: environment)
        } catch ToolError.cancelled {
            throw CancellationError()
        } catch ToolError.timedOut {
            throw ActionFailure.failed("The action exceeded its five-minute time limit.")
        } catch ToolError.failed(let status, _) {
            // Never store arbitrary script output in durable history: it can
            // contain tokens, paths, cookies, or user credentials.
            throw ActionFailure.failed("The action exited with status \(status).")
        }
    }
}
