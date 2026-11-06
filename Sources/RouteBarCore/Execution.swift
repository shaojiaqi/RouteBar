import Foundation
import Darwin

public struct PendingTransaction: Codable {
    public var before: SessionState
    public var plan: ChangePlan
    public var attempted: Int
}
public struct SessionJournal: Codable {
    public var state = SessionState()
    public var pending: PendingTransaction? = nil
    public init() {}
}

/// Storage and command boundaries are injected so rollback can be tested without network privileges.
public enum TransactionEngine {
    public static func commit(plan: ChangePlan, journal: inout SessionJournal,
                              persist: (SessionJournal) throws -> Void,
                              execute: (Mutation, Bool) throws -> Void,
                              verify: () throws -> Void) throws {
        let before = journal.state
        var pending = PendingTransaction(before: before, plan: plan, attempted: 0)
        journal.pending = pending
        try persist(journal)
        do {
            for (index, action) in plan.actions.enumerated() {
                pending.attempted = index + 1; journal.pending = pending
                try persist(journal)
                try execute(action, false)
            }
            try verify()
            journal.state = plan.after; journal.pending = nil
            try persist(journal)
        } catch {
            let failure = error.localizedDescription
            journal.state = before; journal.pending = pending
            do {
                try recover(journal: &journal, persist: persist, execute: execute)
                throw TransactionError(message: L("操作失败，已回滚：{0}", failure), recovered: true)
            } catch let e as TransactionError { throw e }
            catch { throw TransactionError(message: L("操作失败：{0}；回滚未完成：{1}。请使用「回滚中断操作」。", failure, error.localizedDescription), recovered: false) }
        }
    }
    public static func recover(journal: inout SessionJournal, persist: (SessionJournal) throws -> Void,
                               execute: (Mutation, Bool) throws -> Void) throws {
        guard var pending = journal.pending else { return }
        while pending.attempted > 0 {
            try execute(pending.plan.actions[pending.attempted - 1].inverse, true)
            pending.attempted -= 1; journal.pending = pending
            try persist(journal)
        }
        journal.state = pending.before; journal.pending = nil
        try persist(journal)
    }
}
public struct TransactionError: LocalizedError {
    public var message: String
    public var recovered: Bool
    public var errorDescription: String? { message }
}
public enum JournalStore {
    public static let directory = URL(fileURLWithPath: "/var/db/io.routebar", isDirectory: true)
    public static func url(uid: UInt32) -> URL { directory.appendingPathComponent("session-\(uid).json") }
    public static func read(uid: UInt32) throws -> SessionJournal {
        let path = url(uid: uid)
        guard FileManager.default.fileExists(atPath: path.path) else { return SessionJournal() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw RouteBarError(L("管理记录的所有者或权限异常，拒绝使用。")) }
        return try JSONDecoder().decode(SessionJournal.self, from: Data(contentsOf: path))
    }
    public static func prepareDirectory() throws {
        guard geteuid() == 0 else { throw RouteBarError(L("保存执行记录需要管理员授权")) }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw RouteBarError(L("执行记录目录不安全")) }
    }
    public static func write(_ journal: SessionJournal, uid: UInt32) throws {
        try prepareDirectory()
        let path = url(uid: uid)
        if FileManager.default.fileExists(atPath: path.path) { _ = try read(uid: uid) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    }
}

public struct HelperResponse: Codable {
    public var success: Bool
    public var message: String
    public var warnings: [String]
    public var state: SessionState?
    public init(success: Bool, message: String, warnings: [String] = [], state: SessionState? = nil) {
        self.success = success; self.message = message; self.warnings = warnings; self.state = state
    }
}

public enum RouteExecutor {
    public static func apply(_ request: ChangeRequest) throws -> HelperResponse {
        guard geteuid() == 0 else { throw RouteBarError(L("执行切换必须由系统管理员授权")) }
        guard request.uid >= 500, getpwuid(request.uid) != nil else { throw RouteBarError(L("无效用户")) }
        try JournalStore.prepareDirectory()
        let lockPath = JournalStore.directory.appendingPathComponent("executor.lock").path
        let lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw RouteBarError(L("无法创建执行锁")) }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw RouteBarError(L("另一个路由操作正在执行，请稍后再试。")) }
        defer { flock(lockFD, LOCK_UN) }
        var journal = try JournalStore.read(uid: request.uid)
        if request.kind == .recover {
            try recover(&journal, uid: request.uid)
            return HelperResponse(success: true, message: L("已回滚中断的操作"), state: journal.state)
        }
        guard journal.pending == nil else { throw RouteBarError(L("上次操作中断，请先回滚未完成操作。")) }
        let snapshot = try NetworkSnapshot.collect(clientUID: request.uid)
        guard snapshot.fingerprint == request.expectedFingerprint else { throw RouteBarError(L("网络状态已变化，未执行修改。请刷新并重新预览。")) }
        let plan = try RoutePlanner.make(kind: request.kind, settings: request.settings, snapshot: snapshot, session: journal.state)
        if !plan.hasChanges {
            journal.state = plan.after
            try JournalStore.write(journal, uid: request.uid)
            return HelperResponse(success: true, message: L("路由已符合所选模式"), warnings: plan.warnings, state: journal.state)
        }
        do {
            try TransactionEngine.commit(plan: plan, journal: &journal,
                persist: { try JournalStore.write($0, uid: request.uid) },
                execute: { try execute($0, recovering: $1, clientUID: request.uid) },
                verify: { try verify(plan.after, kind: request.kind, settings: request.settings, clientUID: request.uid) })
            return HelperResponse(success: true, message: L("{0} · 已验证", plan.summary), warnings: plan.warnings, state: journal.state)
        } catch let error as TransactionError {
            return HelperResponse(success: false, message: error.localizedDescription, state: journal.state)
        }
    }

    private static func recover(_ journal: inout SessionJournal, uid: UInt32) throws {
        try TransactionEngine.recover(journal: &journal,
            persist: { try JournalStore.write($0, uid: uid) },
            execute: { try execute($0, recovering: $1, clientUID: uid) })
    }

    private static func table() throws -> [RouteEntry] { RouteEntry.parse(try CommandRunner.checked("/usr/sbin/netstat", ["-rn", "-f", "inet"])) }

    private static func execute(_ action: Mutation, recovering: Bool = false, clientUID: UInt32) throws {
        switch action {
        case .acceptRoutes(let from, let to):
            let s = try NetworkSnapshot.collect(clientUID: clientUID)
            guard let ts = s.tailscale, let current = ts.acceptsRoutes else { throw RouteBarError(L("无法读取 Tailscale 子网设置")) }
            if current == to { return }
            guard current == from else { throw RouteBarError(L("Tailscale 接收设置已被外部修改")) }
            let attrs = try FileManager.default.attributesOfItem(atPath: ts.executable)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
                throw RouteBarError(L("管理员模式只允许运行 root 所有且不可由普通用户写入的官方 Tailscale 程序。"))
            }
            _ = try CommandRunner.tailscale(ts.executable, ["set", "--accept-routes=\(to ? "true" : "false")"], clientUID: clientUID, timeout: 20)
            guard try NetworkSnapshot.collect(clientUID: clientUID).tailscale?.acceptsRoutes == to else { throw RouteBarError(L("Tailscale 接收设置未生效")) }
        case .add(let r): try mutateRoute(r, add: true, recovering: recovering)
        case .remove(let r): try mutateRoute(r, add: false, recovering: recovering)
        case .addOriginal(let r), .removeOriginal(let r):
            guard r.network.prefix > 0, r.network.prefix < 32, r.interface.hasPrefix("utun"), r.network.address.value < 0xE0000000 else { throw RouteBarError(L("拒绝修改非蒲公英原始网段")) }
            let target: RouteTarget
            if r.flags.contains("G"), let ip = IPv4(r.gateway) { target = .gateway(ip, r.interface) }
            else { target = .interface(r.interface) }
            if case .addOriginal = action {
                let interfaces = InterfaceAddress.parse(try CommandRunner.checked("/sbin/ifconfig", ["-a"]))
                guard interfaces.contains(where: { $0.name == r.interface && ($0.address.description == r.gateway || !r.flags.contains("G")) }) else {
                    if recovering { return }
                    throw RouteBarError(L("蒲公英接口已变化，拒绝恢复旧接口路由"))
                }
                try mutateRoute(ManagedRoute(network: r.network, target: target), add: true, recovering: recovering)
            } else { try mutateRoute(ManagedRoute(network: r.network, target: target), add: false, recovering: recovering) }
        }
    }

    private static func mutateRoute(_ route: ManagedRoute, add: Bool, recovering: Bool) throws {
        try route.target.validate()
        guard route.network.prefix > 0, route.network.address.isUnicast else { throw RouteBarError(L("拒绝修改默认、回环或组播路由")) }
        let interfaces = InterfaceAddress.parse(try CommandRunner.checked("/sbin/ifconfig", ["-a"]))
        guard route.identityMatches(interfaces) else {
            if !add || recovering { return }
            throw RouteBarError(L("隧道接口身份已变化，拒绝操作：{0}", route.target.interface))
        }
        let routes = try table()
        let exact = routes.filter { $0.network == route.network && !$0.isScoped && !$0.isCloned }
        if add {
            if exact.contains(where: route.matches) { return }
            guard exact.isEmpty else { throw RouteBarError(L("路由被其他程序占用，未覆盖：{0}", route.network)) }
            let ifaces = InterfaceAddress.parse(try CommandRunner.checked("/sbin/ifconfig", ["-a"]))
            guard ifaces.contains(where: { $0.name == route.target.interface }) else {
                if recovering { return }
                throw RouteBarError(L("目标接口已消失：{0}", route.target.interface))
            }
        } else {
            guard exact.contains(where: route.matches) else {
                if exact.isEmpty || recovering { return }
                throw RouteBarError(L("路由归属已变化，未删除：{0}", route.network))
            }
        }
        var args = ["-n", add ? "add" : "delete", route.network.prefix == 32 ? "-host" : "-net", route.network.prefix == 32 ? route.network.address.description : route.network.description]
        switch route.target {
        case .interface(let iface): args += ["-interface", iface]
        case .gateway(let ip, let iface): args += [ip.description, "-ifp", iface]
        }
        _ = try CommandRunner.checked("/sbin/route", args)
        let now = try table()
        guard add ? now.contains(where: route.matches) : !now.contains(where: route.matches) else { throw RouteBarError(L("路由写入后验证失败：{0}", route.network)) }
    }

    private static func verify(_ state: SessionState, kind: RequestKind, settings: AppSettings, clientUID: UInt32) throws {
        let s = try NetworkSnapshot.collect(clientUID: clientUID)
        let managed = kind == .applyPgy ? state.pgyManaged : (kind == .applyTailscale ? state.tailscaleManaged : [])
        for route in managed {
            guard s.routes.contains(where: route.matches) else { throw RouteBarError(L("路由缺失：{0}", route.network)) }
            let conflicts = s.routes.filter { !$0.isScoped && !$0.isCloned && $0.network.overlaps(route.network) && $0.network.prefix >= route.network.prefix && !$0.matchesTarget(route.target) }
            guard conflicts.isEmpty else { throw RouteBarError(L("其他程序添加了更具体路由：{0}", conflicts[0])) }
            let probes = Set([route.network.address, route.network.last, IPv4(value: route.network.address.value + (route.network.last.value - route.network.address.value) / 2)])
            for ip in probes {
                let output = try CommandRunner.checked("/sbin/route", ["-n", "get", ip.description])
                let iface = output.components(separatedBy: .newlines).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
                guard iface == route.target.interface else { throw RouteBarError(L("实际查路由未走预期接口：{0}", ip)) }
            }
        }
        if kind == .applyPgy, let ti = s.pgyInterface(virtualIP: settings.pgyVirtualIP)?.name {
            guard !s.routes.contains(where: { $0.interface == ti && !$0.isScoped && !$0.isCloned && $0.network.prefix < 32 && $0.network.address.value < 0xE0000000 }) else { throw RouteBarError(L("蒲公英重新添加了大网段路由")) }
        }
    }
}
