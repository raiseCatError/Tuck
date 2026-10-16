import Foundation
import CryptoKit

// Requests can originate only from a user-triggered Finder extension action. We
// authenticate the payload before allowing the invisible helper to touch files.
// This isn't a security boundary against malicious same-user processes with
// access to the user's preferences; it prevents arbitrary unsigned URL requests.
struct TuckRequest: Codable, Sendable {
    let operation: String
    let paths: [String]
    let argument: String?
    let timestamp: Int64
    let nonce: String

    init(operation: String, paths: [String], argument: String? = nil) {
        self.operation = operation
        self.paths = Array(paths.prefix(16))
        self.argument = argument
        self.timestamp = Int64(Date().timeIntervalSince1970)
        self.nonce = UUID().uuidString
    }

    func signedURL() -> URL? {
        guard let key = TuckPreferences.sharedKey,
              let payload = try? JSONEncoder().encode(self), payload.count < 12000 else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        var components = URLComponents()
        components.scheme = "tuck"
        components.host = "perform"
        components.queryItems = [
            URLQueryItem(name: "payload", value: payload.base64EncodedString()),
            URLQueryItem(name: "signature", value: Data(mac).base64EncodedString())
        ]
        return components.url
    }

    static func verified(_ url: URL) -> TuckRequest? {
        guard url.scheme == "tuck", url.host == "perform",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let p = items.first(where: { $0.name == "payload" })?.value,
              let s = items.first(where: { $0.name == "signature" })?.value,
              let payload = Data(base64Encoded: p), payload.count < 12000,
              let signature = Data(base64Encoded: s),
              let key = TuckPreferences.sharedKey,
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: SymmetricKey(data: key)),
              let request = try? JSONDecoder().decode(TuckRequest.self, from: payload) else { return nil }
        let age = Int64(Date().timeIntervalSince1970) - request.timestamp
        guard (-5...45).contains(age), request.paths.count <= 16,
              request.paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.count < 4096 }),
              request.argument.map({ $0.count < 500 }) ?? true else { return nil }
        return request
    }
}
