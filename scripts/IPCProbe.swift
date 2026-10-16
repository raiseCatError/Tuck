import AppKit
import Foundation

// Sends a single authenticated request to the installed helper exactly the way
// the Finder extension does, so the IPC hop can be exercised without Finder.
// Compiled and run by scripts/verify-ipc.sh; never part of the app build.

@main
struct IPCProbe {
    static func main() {
        let arguments = CommandLine.arguments
        let folder = arguments.count > 1 ? arguments[1] : NSTemporaryDirectory()
        let operation = arguments.count > 2 ? arguments[2] : "newFile"
        let argument = arguments.count > 3 ? arguments[3] : "Untitled.txt"

        guard let url = TuckRequest(operation: operation, paths: [folder], argument: argument).signedURL() else {
            print("probe: could not sign a request (is the shared key present?)")
            exit(2)
        }
        print("probe: op=\(operation) urlBytes=\(url.absoluteString.utf8.count) scheme=\(url.scheme ?? "nil")")
        print("probe: NSWorkspace.open accepted=\(NSWorkspace.shared.open(url))")
    }
}