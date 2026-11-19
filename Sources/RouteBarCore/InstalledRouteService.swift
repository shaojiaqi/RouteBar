import Foundation
import Darwin

public enum InstalledRouteService {
    static let directory = JournalStore.directory.appendingPathComponent("service", isDirectory: true)
    static let helper = directory.appendingPathComponent(RouteService.helperBasename)
    static let catalog = directory.appendingPathComponent("Localizations.json")
    private static let launchDirectory = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    private static let plist = launchDirectory.appendingPathComponent("\(RouteService.name).plist")
    private static let job = "system/\(RouteService.name)"
    static var hasConfiguration: Bool { exists(plist) }

    struct Configuration {
        let appHash: String
        let uid: uid_t
        let helperHash: String
    }

    static func read() throws -> Configuration {
        try verify(launchDirectory, isDirectory: true)
        try verify(plist, isDirectory: false)
        let bytes = try Data(contentsOf: plist)
        guard bytes.count <= 16_384,
              let config = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              config["Label"] as? String == RouteService.name,
              let args = config["ProgramArguments"] as? [String], args.count == 5,
              args[0] == helper.path, args[1] == "--serve-installed",
              RouteService.validHash(args[2]), let uid = uid_t(args[3]), uid >= 500,
              RouteService.validHash(args[4]) else { throw RouteService.unavailable() }
        return Configuration(appHash: args[2], uid: uid, helperHash: args[4])
    }

    public static func install(appHash: String, uid: uid_t) throws {
        guard geteuid() == 0, uid == RouteService.consoleUID, RouteService.validHash(appHash),
              let path = Bundle.main.executableURL, let helperHash = RouteService.currentHash(identifier: RouteService.helperID) else {
            throw RouteService.unavailable()
        }
        let sourceCatalog = path.deletingLastPathComponent().appendingPathComponent("Localizations.json")
        let executable = try Data(contentsOf: path), translations = try Data(contentsOf: sourceCatalog)
        _ = try JSONDecoder().decode([String: [String: String]].self, from: translations)
        try withAdminLock {
            try stop()
            do {
                try put(executable, at: helper, mode: 0o755)
                try put(translations, at: catalog, mode: 0o644)
                let job: [String: Any] = ["Label": RouteService.name,
                    "ProgramArguments": [helper.path, "--serve-installed", appHash, String(uid), helperHash],
                    "MachServices": [RouteService.name: true]]
                let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
                try put(data, at: plist, mode: 0o644)
                _ = try CommandRunner.checked("/bin/launchctl", ["enable", Self.job])
                _ = try CommandRunner.checked("/bin/launchctl", ["bootstrap", "system", plist.path])
            } catch {
                // Do not leave an enabled but incomplete installation after a failed bootstrap.
                try? remove(plist)
                try? remove(helper)
                try? remove(catalog)
                throw error
            }
        }
    }

    public static func uninstall() throws {
        try withAdminLock {
            try stop()
            try remove(plist)
            try remove(helper)
            try remove(catalog)
        }
    }

    private static func withAdminLock(_ operation: () throws -> Void) throws {
        try RouteExecutor.withExclusiveLock {
            try verify(JournalStore.directory, isDirectory: true)
            try verify(launchDirectory, isDirectory: true)
            if !exists(directory) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            }
            try verify(directory, isDirectory: true)
            try operation()
        }
    }

    private static func stop() throws {
        if exists(plist) { try verify(plist, isDirectory: false) }
        let result = try CommandRunner.run("/bin/launchctl", ["print", job])
        if result.status == 0 { _ = try CommandRunner.checked("/bin/launchctl", ["bootout", job]) }
        else if result.status != ESRCH && result.status != 113 { throw RouteBarError(result.errorOutput) }
    }

    private static func put(_ data: Data, at file: URL, mode: Int) throws {
        if exists(file) { try verify(file, isDirectory: false) }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        try verify(file, isDirectory: false)
    }

    private static func remove(_ file: URL) throws {
        guard exists(file) else { return }
        try verify(file, isDirectory: false)
        try FileManager.default.removeItem(at: file)
    }

    private static func exists(_ file: URL) -> Bool {
        var attributes = stat()
        return lstat(file.path, &attributes) == 0
    }

    private static func verify(_ file: URL, isDirectory: Bool) throws {
        var attributes = stat()
        guard lstat(file.path, &attributes) == 0, attributes.st_uid == 0, attributes.st_mode & 0o022 == 0,
              attributes.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG) else { throw RouteService.unavailable() }
    }
}
