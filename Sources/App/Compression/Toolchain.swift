import Foundation

// Locates optional command line encoders and runs them with argument arrays
// only, never a shell string. Everything degrades cleanly when a tool is absent:
// the engines fall back to ImageIO or report the operation as unsupported.

enum ToolError: Error { case notFound, failed(status: Int32, output: String), timedOut, cancelled }

struct ToolResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

struct Tool: Sendable {
    let name: String
    let url: URL

    var displayPath: String { url.path }
}

/// Absolute paths are preferred so a keg-only Homebrew tool is still found, and
/// so the helper never depends on the PATH it happened to inherit.
enum Toolchain {
    static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/opt/homebrew/opt/mozjpeg/bin",
        "/opt/homebrew/opt/sevenzip/bin",
        "/opt/homebrew/opt/libjxl/bin",
        "/opt/homebrew/opt/jpeg-turbo/bin"
    ]

    private static let cache: [String: Tool?] = {
        var result: [String: Tool?] = [:]
        var seen = Set<String>()
        for name in ["7zz", "7z", "7za", "qpdf", "gs", "oxipng", "pngquant", "cjpegli", "cjpeg", "jpegtran", "pdfimages", "cwebp"] {
            seen.insert(name)
            result[name] = resolve(name)
        }
        // MozJPEG and jpeg-turbo are keg-only, so they are addressed by path.
        result["mozjpeg-cjpeg"] = resolve("/opt/homebrew/opt/mozjpeg/bin/cjpeg")
        result["turbo-cjpeg"] = resolve("/opt/homebrew/opt/jpeg-turbo/bin/cjpeg")
        result["mozjpeg-jpegtran"] = resolve("/opt/homebrew/opt/mozjpeg/bin/jpegtran")
        result["turbo-jpegtran"] = resolve("/opt/homebrew/opt/jpeg-turbo/bin/jpegtran")
        return result
    }()

    static func tool(_ name: String) -> Tool? { cache[name] ?? nil }
    static func available(_ name: String) -> Bool { tool(name) != nil }

    static var sevenZip: Tool? { tool("7zz") ?? tool("7z") }
    static var legacySevenZip: Tool? { tool("7z") }
    static var qpdf: Tool? { tool("qpdf") }
    static var ghostscript: Tool? { tool("gs") }
    static var oxipng: Tool? { tool("oxipng") }
    static var pngquant: Tool? { tool("pngquant") }
    static var jpegli: Tool? { tool("cjpegli") }
    static var mozjpeg: Tool? { tool("mozjpeg-cjpeg") }
    static var turboJPEG: Tool? { tool("turbo-cjpeg") }
    static var mozjpegTran: Tool? { tool("mozjpeg-jpegtran") }
    static var turboTran: Tool? { tool("turbo-jpegtran") }

    /// Which engines this install can use, for the read-only Settings status.
    static func status() -> [(String, Bool, String)] {
        [
            ("JPEG: MozJPEG", mozjpeg != nil, mozjpeg?.displayPath ?? "not installed (brew install mozjpeg)"),
            ("JPEG: libjpeg-turbo", turboJPEG != nil, turboJPEG?.displayPath ?? "not installed"),
            ("JPEG: Jpegli (optional)", jpegli != nil, jpegli?.displayPath ?? "not installed"),
            ("PNG: Oxipng lossless", oxipng != nil, oxipng?.displayPath ?? "not installed (brew install oxipng)"),
            ("PNG: pngquant palette", pngquant != nil, pngquant?.displayPath ?? "not installed (brew install pngquant)"),
            ("ZIP: 7-Zip Deflate", sevenZip != nil, sevenZip?.displayPath ?? "not installed (brew install sevenzip)"),
            ("PDF: qpdf", qpdf != nil, qpdf?.displayPath ?? "not installed (brew install qpdf)"),
            ("PDF: Ghostscript", ghostscript != nil, ghostscript?.displayPath ?? "not installed (brew install ghostscript)")
        ]
    }

    private static func resolve(_ nameOrPath: String) -> Tool? {
        let fm = FileManager.default
        if nameOrPath.contains("/") {
            let url = URL(fileURLWithPath: nameOrPath)
            return fm.isExecutableFile(atPath: url.path) ? Tool(name: nameOrPath, url: url) : nil
        }
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(nameOrPath)
            if fm.isExecutableFile(atPath: candidate.path) { return Tool(name: nameOrPath, url: candidate) }
        }
        let environment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in environment.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(nameOrPath)
            if fm.isExecutableFile(atPath: candidate.path) { return Tool(name: nameOrPath, url: candidate) }
        }
        return nil
    }

    /// Runs a tool with an argument array. Honours a deadline and a cancellation
    /// check so a stalled encoder can never wedge the helper. Output is captured
    /// through temporary files rather than pipes, which avoids both pipe
    /// deadlocks and concurrent buffer mutation.
    @discardableResult
    static func run(_ tool: Tool, _ arguments: [String],
                    timeout: TimeInterval = 300,
                    shouldCancel: (() -> Bool)? = nil,
                    workingDirectory: URL? = nil,
                    environment: [String: String]? = nil) throws -> ToolResult {
        guard (shouldCancel?() ?? false) == false else { throw ToolError.cancelled }
        let capture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuck-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: capture) }
        let outURL = capture.appendingPathComponent("stdout")
        let errURL = capture.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              FileManager.default.createFile(atPath: errURL.path, contents: nil) else {
            throw ToolError.failed(status: -1, output: "Cannot create temporary tool logs.")
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = tool.url
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle
        do { try process.run() } catch {
            throw ToolError.failed(status: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if shouldCancel?() == true {
                stop(process)
                throw ToolError.cancelled
            }
            if Date() >= deadline {
                stop(process)
                throw ToolError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let result = ToolResult(status: process.terminationStatus,
                                standardOutput: prefix(of: outURL),
                                standardError: prefix(of: errURL))
        if result.status != 0 { throw ToolError.failed(status: result.status, output: result.standardError) }
        return result
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private static func prefix(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}