import Foundation

// A shared-preferences read exception is granted only to the Finder extension.
// The settings app owns all writes. No App Group or paid developer account needed.
enum TuckPreferences {
    static let domain = "dev.raisecaterror.tuck"

    // Foundation refuses a suite name that equals the running bundle identifier
    // ("Using your own bundle identifier as an NSUserDefaults suite name does not
    // make sense and will not work") and returns nil for it. The helper therefore
    // resolves the store instead of force unwrapping, and falls back to the standard
    // domain, which for the helper is the very same preference file.
    static var store: UserDefaults { resolveStore() }

    static func resolveStore(domain: String = TuckPreferences.domain,
                             bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> UserDefaults {
        if bundleIdentifier == domain { return .standard }
        guard let suite = UserDefaults(suiteName: domain) else {
            TuckLog.extensionLogger.error("preferences.suite-unavailable domain=\(domain, privacy: .public) bundle=\(bundleIdentifier ?? "none", privacy: .public)")
            return .standard
        }
        return suite
    }

    static let defaults: [String] = [
        "newFile", "openWith", "compress", "terminal",
        "pdfToolkit", "imageToolkit", "metadata", "copyAs", "rename", "duplicates"
    ]

    static var order: [String] {
        get {
            let stored = store.stringArray(forKey: "menuOrder") ?? defaults
            var seen = Set<String>()
            return (stored + defaults).filter { defaults.contains($0) && seen.insert($0).inserted }
        }
        set { store.set(newValue.filter { defaults.contains($0) }, forKey: "menuOrder") }
    }

    static func enabled(_ id: String) -> Bool {
        store.object(forKey: "enabled.\(id)") as? Bool ?? true
    }

    static func setEnabled(_ id: String, to value: Bool) {
        store.set(value, forKey: "enabled.\(id)")
    }

    static var sizes: [Int] {
        get {
            let v = store.array(forKey: "targetSizesMB") as? [Int] ?? [1, 2, 5, 10, 25]
            return Array(Set(v.filter { (1...500).contains($0) })).sorted().prefix(10).map { $0 }
        }
        set { store.set(Array(Set(newValue.filter { (1...500).contains($0) })).sorted(), forKey: "targetSizesMB") }
    }

    static var terminal: String {
        get { store.string(forKey: "terminalID") ?? "com.mitchellh.ghostty" }
        set { store.set(newValue, forKey: "terminalID") }
    }

    static var showDesktop: Bool {
        get { store.object(forKey: "desktop") as? Bool ?? true }
        set { store.set(newValue, forKey: "desktop") }
    }

    static var sharedKey: Data? {
        guard let encoded = store.string(forKey: "ipcKey") else { return nil }
        return Data(base64Encoded: encoded)
    }

    static func prepareKey() -> Bool {
        guard sharedKey == nil else { return false }
        var data = Data(count: 32)
        data.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            arc4random_buf(ptr, buffer.count)
        }
        store.set(data.base64EncodedString(), forKey: "ipcKey")
        TuckLog.ipcLogger.info("preferences.key-created bytes=\(data.count)")
        return true
    }
}
