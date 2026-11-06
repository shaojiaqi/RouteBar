import Foundation
import RouteBarCore

/// Small local lifecycle log; no commands, credentials, or node lists are recorded.
enum AppDiagnostics {
    private static let lock = NSLock()
    static func write(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        let directory = AppSettings.directory
        let url = directory.appendingPathComponent("lifecycle.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let line = "\(Date().ISO8601Format()) pid=\(ProcessInfo.processInfo.processIdentifier) \(event)\n"
            let data = Data(line.utf8)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if !FileManager.default.fileExists(atPath: url.path) || size > 131_072 {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            }
        } catch { /* Diagnostics must never prevent the menu bar utility from running. */ }
    }
}
