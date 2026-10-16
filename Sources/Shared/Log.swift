import Foundation
import OSLog

// Structured diagnostics for both processes. Stages are logged as
// "<process>.<stage>" so one stream shows the whole action lifecycle:
//
//   log stream --level info --predicate 'subsystem == "dev.raisecaterror.tuck"'
//   log show --last 10m --info --predicate 'subsystem == "dev.raisecaterror.tuck"'
//
// Signing keys, signatures, authenticated URLs and file paths are never logged.
enum TuckLog {
    static let subsystem = "dev.raisecaterror.tuck"
    static let extensionLogger = Logger(subsystem: subsystem, category: "extension")
    static let ipcLogger = Logger(subsystem: subsystem, category: "ipc")
    static let helperLogger = Logger(subsystem: subsystem, category: "helper")
    static let compressionLogger = Logger(subsystem: subsystem, category: "compression")
}