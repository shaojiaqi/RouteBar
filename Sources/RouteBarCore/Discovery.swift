import Foundation
import CryptoKit
import Darwin

public struct CommandResult { public let status: Int32; public let output: String; public let errorOutput: String }
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

public enum CommandRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> CommandResult {
        let p = Process(), pipe = Pipe(), errors = Pipe(), done = DispatchSemaphore(value: 0), reader = DispatchGroup(), box = OutputBox(), errorBox = OutputBox()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = pipe; p.standardError = errors
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "C", "TMPDIR": NSTemporaryDirectory()]
        if let account = getpwuid(geteuid()) {
            environment["HOME"] = String(cString: account.pointee.pw_dir)
            environment["USER"] = String(cString: account.pointee.pw_name)
            environment["LOGNAME"] = environment["USER"]
        }
        if executable == "/Applications/Tailscale.app/Contents/MacOS/Tailscale" { environment["TAILSCALE_BE_CLI"] = "1" }
        p.environment = environment
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        reader.enter()
        DispatchQueue.global(qos: .utility).async { box.set(pipe.fileHandleForReading.readDataToEndOfFile()); reader.leave() }
        reader.enter()
        DispatchQueue.global(qos: .utility).async { errorBox.set(errors.fileHandleForReading.readDataToEndOfFile()); reader.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
            throw RouteBarError(L("命令超时：{0}", URL(fileURLWithPath: executable).lastPathComponent))
        }
        _ = reader.wait(timeout: .now() + 2)
        return CommandResult(status: p.terminationStatus, output: String(data: box.get(), encoding: .utf8) ?? "", errorOutput: String(data: errorBox.get(), encoding: .utf8) ?? "")
    }
    public static func checked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> String {
        let r = try run(executable, arguments, timeout: timeout)
        guard r.status == 0 else { throw RouteBarError("\(URL(fileURLWithPath: executable).lastPathComponent)：\((r.output + r.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))") }
        return r.output
    }
    public static func tailscale(_ executable: String, _ arguments: [String], clientUID: UInt32? = nil, timeout: TimeInterval = 10) throws -> String {
        // The macOS CLI talks to the logged-in user's app. Never start a separate root GUI context.
        if geteuid() == 0, let uid = clientUID, uid >= 500 {
            return try checked("/usr/bin/sudo", ["-H", "-u", "#\(uid)", "/usr/bin/env", "TAILSCALE_BE_CLI=1", executable] + arguments, timeout: timeout)
        }
        return try checked(executable, arguments, timeout: timeout)
    }
}

public struct NetworkSnapshot: Codable {
    public var interfaces: [InterfaceAddress]
    public var routes: [RouteEntry]
    public var tailscale: TailscaleState?
    public var pgyDiscovery: PgyDiscoveryState? = nil
    public var pgyDiscoveryNote: String? = nil
    public var pgyProcessRunning: Bool
    public var pgyClientInstalled: Bool? = nil
    public var notes: [String]
    public var timestamp: Date
    public var physicalNetworks: [InterfaceAddress] { interfaces.filter(\.isPhysical) }
    public var tailscaleInterface: String? {
        guard let ts = tailscale else { return nil }
        let matches = Set(interfaces.filter { ts.ownIPs.contains($0.address) && $0.name.hasPrefix("utun") }.map(\.name))
        return matches.count == 1 ? matches.first : nil
    }
    public func pgyInterface(virtualIP: String) -> InterfaceAddress? {
        guard pgyProcessRunning, let ip = IPv4(virtualIP) else { return nil }
        let matches = interfaces.filter { $0.address == ip && $0.name.hasPrefix("utun") && $0.pointToPoint && $0.name != tailscaleInterface }
        return matches.count == 1 ? matches.first : nil
    }
    public var physicalDefault: RouteTarget? {
        guard let route = routes.first(where: { $0.network.prefix == 0 && !$0.isScoped && $0.flags.contains("G") && physicalNetworks.map(\.name).contains($0.interface) }),
              let ip = IPv4(route.gateway) else { return nil }
        return .gateway(ip, route.interface)
    }
    public var fingerprint: String {
        let relevant = routes.filter { !$0.isCloned && !$0.network.address.description.hasPrefix("224.") && $0.network.address.value < 0xE0000000 }
        let material = relevant.map { "\($0.network)|\($0.gateway)|\($0.interface)|\($0.isScoped)" }.sorted().joined(separator: "\n")
            + interfaces.map { "\($0.name):\($0.address):\($0.network)" }.sorted().joined()
            + (tailscale?.acceptsRoutes.map(String.init) ?? "unknown")
            + (tailscale?.subnets.map { "\($0.id):\($0.online)" }.sorted().joined() ?? "")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func collect(clientUID: UInt32? = nil) throws -> Self {
        let interfaces = InterfaceAddress.parse(try CommandRunner.checked("/sbin/ifconfig", ["-a"]))
        let routes = RouteEntry.parse(try CommandRunner.checked("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        let processes = (try? CommandRunner.checked("/bin/ps", ["-axo", "comm="])) ?? ""
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        var ts: TailscaleState?, notes: [String] = []
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            do {
                let status = try CommandRunner.tailscale(path, ["status", "--json"], clientUID: clientUID, timeout: 8)
                guard status.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { throw RouteBarError(L("CLI 未返回 JSON：{0}", status.prefix(180))) }
                let prefs = try? CommandRunner.tailscale(path, ["debug", "prefs"], clientUID: clientUID, timeout: 8)
                ts = try TailscaleState.parse(status: Data(status.utf8), prefs: prefs.map { Data($0.utf8) }, executable: path)
            } catch { notes.append("Tailscale：\(error.localizedDescription)") }
        } else { notes.append(L("未找到 Tailscale CLI；请先安装官方客户端。")) }
        var snapshot = Self(interfaces: interfaces, routes: routes, tailscale: ts, pgyProcessRunning: processes.contains("pgyvpn"), notes: notes, timestamp: Date())
        snapshot.pgyClientInstalled = snapshot.pgyProcessRunning || PgyClientPresence.isInstalled()
        if snapshot.pgyProcessRunning {
            do { snapshot.pgyDiscovery = try PgyDiscoveryState.collect(interfaces: interfaces) }
            catch { snapshot.pgyDiscoveryNote = error.localizedDescription }
        } else { snapshot.pgyDiscoveryNote = L("蒲公英未运行，保留上次节点列表") }
        return snapshot
    }
}

public struct PgyNode: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    public var address: String
    public var selected: Bool = true
    public var discoveryID: String? = nil
    public init(name: String, address: String, selected: Bool = true) { self.name = name; self.address = address; self.selected = selected }
}

public struct AppSettings: Codable {
    public var pgyVirtualIP = ""
    public var pgyNodes: [PgyNode] = []
    public var selectedSubnets: Set<String> = []
    public var maintainPgy = false
    public var maintainTailscale = false
    public init() {}
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RouteBar", isDirectory: true) }
    public static func load() -> Self {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent("settings.json")), let s = try? JSONDecoder().decode(Self.self, from: d) else { return Self() }
        // Maintenance always needs an explicit opt-in after launching the app.
        var settings = s; settings.maintainPgy = false; settings.maintainTailscale = false; return settings
    }
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.directory.appendingPathComponent("settings.json"), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.directory.appendingPathComponent("settings.json").path)
    }
}
