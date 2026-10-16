import Foundation
import CryptoKit

// Requests can originate only from a user-triggered Finder extension action. We
// authenticate the payload before allowing the invisible helper to touch files.
// This isn't a security boundary against malicious same-user processes with
// access to the user's preferences; it prevents arbitrary unsigned URL requests.

// Why a request was refused. The reason is safe to log; it never contains the
// signature, the key or any path.
enum TuckVerificationFailure: String, Sendable, Error {
    case shape
    case malformedQuery
    case malformedPayload
    case noKey
    case badSignature
    case staleTimestamp
    case badPaths
    case badArgument
}

struct TuckRequest: Codable, Sendable {
    let operation: String
    let paths: [String]
    let argument: String?
    let timestamp: Int64
    let nonce: String

    init(operation: String, paths: [String], argument: String? = nil) {
        self.operation = operation
        self.paths = Array(paths.prefix(256))
        self.argument = argument
        self.timestamp = Int64(Date().timeIntervalSince1970)
        self.nonce = UUID().uuidString
    }

    func signedURL() -> URL? {
        guard let key = TuckPreferences.sharedKey else {
            TuckLog.ipcLogger.error("ipc.prepare-failed op=\(self.operation, privacy: .public) reason=missing-shared-key")
            return nil
        }
        guard let payload = try? JSONEncoder().encode(self) else {
            TuckLog.ipcLogger.error("ipc.prepare-failed op=\(self.operation, privacy: .public) reason=encode-failed")
            return nil
        }
        guard payload.count < 65536 else {
            TuckLog.ipcLogger.error("ipc.prepare-failed op=\(self.operation, privacy: .public) reason=payload-too-large")
            return nil
        }
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        var components = URLComponents()
        components.scheme = "tuck"
        components.host = "perform"
        components.queryItems = [
            URLQueryItem(name: "payload", value: payload.base64EncodedString()),
            URLQueryItem(name: "signature", value: Data(mac).base64EncodedString())
        ]
        guard let url = components.url else {
            TuckLog.ipcLogger.error("ipc.prepare-failed op=\(self.operation, privacy: .public) reason=url-build-failed")
            return nil
        }
        // Never log the URL itself: it carries the signature.
        TuckLog.ipcLogger.info("ipc.prepared op=\(self.operation, privacy: .public) paths=\(self.paths.count) payloadBytes=\(payload.count) urlBytes=\(url.absoluteString.utf8.count)")
        return url
    }

    static func verified(_ url: URL) -> TuckRequest? {
        guard case .success(let request) = verify(url) else { return nil }
        return request
    }

    static func verify(_ url: URL) -> Result<TuckRequest, TuckVerificationFailure> {
        guard url.scheme == "tuck", url.host == "perform",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return .failure(.shape)
        }
        guard let p = items.first(where: { $0.name == "payload" })?.value,
              let s = items.first(where: { $0.name == "signature" })?.value,
              let payload = Data(base64Encoded: p), payload.count < 65536,
              let signature = Data(base64Encoded: s) else {
            return .failure(.malformedQuery)
        }
        guard let key = TuckPreferences.sharedKey else { return .failure(.noKey) }
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: SymmetricKey(data: key)) else {
            return .failure(.badSignature)
        }
        guard let request = try? JSONDecoder().decode(TuckRequest.self, from: payload) else {
            return .failure(.malformedPayload)
        }
        let age = Int64(Date().timeIntervalSince1970) - request.timestamp
        guard (-5...45).contains(age) else { return .failure(.staleTimestamp) }
        guard request.paths.count <= 256,
              request.paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.count < 4096 }) else {
            return .failure(.badPaths)
        }
        guard request.argument.map({ $0.count < 500 }) ?? true else { return .failure(.badArgument) }
        return .success(request)
    }
}