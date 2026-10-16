import Foundation
import CryptoKit

// Guards the authenticated IPC contract: a signed request is accepted, and
// anything unsigned, tampered with, stale or out of policy is refused with a
// reason the helper can log.
@main
struct IPCTests {
    static func main() {
        let savedKey = TuckPreferences.store.object(forKey: "ipcKey")
        defer {
            if let savedKey { TuckPreferences.store.set(savedKey, forKey: "ipcKey") }
            else { TuckPreferences.store.removeObject(forKey: "ipcKey") }
        }
        TuckPreferences.store.set(Data(repeating: 0x2a, count: 32).base64EncodedString(), forKey: "ipcKey")

        let request = TuckRequest(operation: "zip", paths: ["/tmp/one", "/tmp/two"], argument: "5")
        guard let url = request.signedURL() else { fatalError("a key is present, so signing must succeed") }
        assert(TuckRequest.verified(url) != nil, "a freshly signed request verifies")

        // Wrong shape.
        assert(failure(of: URL(string: "tuck://perform")!) == .shape)
        assert(failure(of: URL(string: "https://example.com")!) == .shape)
        assert(failure(of: URL(string: "tuck://other?payload=AA&signature=AA")!) == .shape)
        assert(TuckRequest.verified(URL(fileURLWithPath: "/tmp")) == nil)

        // Missing or unusable query items.
        assert(failure(of: URL(string: "tuck://perform?payload=AAAA")!) == .malformedQuery)
        assert(failure(of: URL(string: "tuck://perform?payload=not*base64&signature=AAAA")!) == .malformedQuery)

        // A tampered payload keeps a well formed but wrong signature.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let payload = Data(base64Encoded: items.first { $0.name == "payload" }!.value!)!
        var forged = payload
        forged[forged.count - 2] ^= 0xff
        assert(failure(of: substitute(url, query: "payload", value: forged.base64EncodedString())) == .badSignature,
               "a flipped payload byte fails the MAC")

        // A payload signed with a different key.
        var otherKey = Data(repeating: 0x2a, count: 32)
        otherKey[0] ^= 0x01
        let foreign = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: otherKey))
        assert(failure(of: substitute(url, query: "signature", value: Data(foreign).base64EncodedString())) == .badSignature)

        // No shared key at all.
        TuckPreferences.store.removeObject(forKey: "ipcKey")
        assert(failure(of: url) == .noKey)
        TuckPreferences.store.set(Data(repeating: 0x2a, count: 32).base64EncodedString(), forKey: "ipcKey")

        // Timestamp window: fresh requests pass, stale and far future ones do not.
        assert(failure(of: signed(staleBy: 30, paths: ["/tmp"])) == nil, "a 30 second old request is still fresh")
        assert(failure(of: signed(staleBy: 600, paths: ["/tmp"])) == .staleTimestamp)
        assert(failure(of: signed(staleBy: -30, paths: ["/tmp"])) == .staleTimestamp, "a far future timestamp is refused")

        // Path and argument policy.
        assert(failure(of: signed(staleBy: 1, paths: ["relative/path"])) == .badPaths)
        assert(failure(of: signed(staleBy: 1, paths: ["/tmp/\0evil"])) == .badPaths)
        assert(failure(of: signed(staleBy: 1, paths: ["/" + String(repeating: "a", count: 5000)])) == .badPaths)
        assert(failure(of: signed(staleBy: 1, paths: ["/tmp"], forcePaths: Array(repeating: "/tmp", count: 20))) == .badPaths,
               "the helper refuses more than sixteen paths even in a correctly signed payload")
        assert(failure(of: signed(staleBy: 1, paths: ["/tmp"], argument: String(repeating: "x", count: 600))) == .badArgument)

        // The signer caps what it will send.
        assert(TuckRequest(operation: "zip", paths: Array(repeating: "/tmp", count: 40)).paths.count == 16)

        print("IPCTests passed")
    }

    /// Signs a request with an explicit age so the timestamp window is testable.
    /// `forcePaths` bypasses the signer's own cap, so helper-side policy can be tested.
    static func signed(staleBy seconds: TimeInterval, paths: [String], argument: String? = nil, forcePaths: [String]? = nil) -> URL {
        let request = TuckRequest(operation: "zip", paths: paths, argument: argument)
        var object = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(request)) as! [String: Any]
        object["timestamp"] = Int64(Date().timeIntervalSince1970) - Int64(seconds)
        if let forcePaths { object["paths"] = forcePaths }
        let body = try! JSONSerialization.data(withJSONObject: object)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: TuckPreferences.sharedKey!))
        var components = URLComponents()
        components.scheme = "tuck"
        components.host = "perform"
        components.queryItems = [
            URLQueryItem(name: "payload", value: body.base64EncodedString()),
            URLQueryItem(name: "signature", value: Data(mac).base64EncodedString())
        ]
        return components.url!
    }

    static func substitute(_ url: URL, query: String, value: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = components.queryItems?.map {
            $0.name == query ? URLQueryItem(name: query, value: value) : $0
        }
        return components.url!
    }

    static func failure(of url: URL) -> TuckVerificationFailure? {
        guard case .failure(let reason) = TuckRequest.verify(url) else { return nil }
        return reason
    }
}