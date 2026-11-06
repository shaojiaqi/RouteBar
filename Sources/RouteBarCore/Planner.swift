import Foundation

public enum Provider: String, Codable { case pgy, tailscale }
public enum RequestKind: String, Codable { case applyPgy, restorePgy, applyTailscale, restoreTailscale, recover }

public struct ManagedRoute: Codable, Hashable, CustomStringConvertible {
    public var network: CIDR
    public var target: RouteTarget
    public var interfaceIdentity: IPv4? = nil
    public var description: String { "\(network) → \(target.label)" }
    public func matches(_ route: RouteEntry) -> Bool { network == route.network && route.matchesTarget(target) }
    public func identityMatches(_ interfaces: [InterfaceAddress]) -> Bool {
        guard let identity = interfaceIdentity else { return true }
        return interfaces.contains { $0.name == target.interface && $0.address == identity }
    }
}

public struct SessionState: Codable, Equatable {
    public var pgyManaged: [ManagedRoute] = []
    public var pgyOriginals: [RouteEntry] = []
    public var pgyVirtualIP: String? = nil
    public var pgySelection: [String] = []
    public var tailscaleManaged: [ManagedRoute] = []
    public var tailscaleOriginalAccepts: Bool? = nil
    public var tailscaleSelection: Set<String> = []
    public init() {}
    public var hasPgy: Bool { !pgyManaged.isEmpty || !pgyOriginals.isEmpty }
    public var hasTailscale: Bool { tailscaleOriginalAccepts != nil || !tailscaleManaged.isEmpty }
}

public enum Mutation: Codable, Equatable {
    case add(ManagedRoute)
    case remove(ManagedRoute)
    case addOriginal(RouteEntry)
    case removeOriginal(RouteEntry)
    case acceptRoutes(from: Bool, to: Bool)
    public var inverse: Self {
        switch self {
        case .add(let r): return .remove(r)
        case .remove(let r): return .add(r)
        case .addOriginal(let r): return .removeOriginal(r)
        case .removeOriginal(let r): return .addOriginal(r)
        case .acceptRoutes(let from, let to): return .acceptRoutes(from: to, to: from)
        }
    }
    public var description: String {
        switch self {
        case .add(let r): return "+ \(r)"
        case .remove(let r): return "− \(r)"
        case .addOriginal(let r): return L("恢复 {0}", r)
        case .removeOriginal(let r): return L("移除蒲公英网段 {0}", r)
        case .acceptRoutes(_, let to): return L("Tailscale 接收子网：{0}（不改 DNS / 出口节点）", to ? L("开") : L("关"))
        }
    }
}

public struct ChangePlan: Codable {
    public var actions: [Mutation]
    public var after: SessionState
    public var warnings: [String]
    public var fingerprint: String
    public var summary: String
    public init(actions: [Mutation], after: SessionState, warnings: [String], fingerprint: String, summary: String) {
        self.actions = actions; self.after = after; self.warnings = warnings; self.fingerprint = fingerprint; self.summary = summary
    }
    public var hasChanges: Bool { !actions.isEmpty }
}

public struct ChangeRequest: Codable {
    public var kind: RequestKind
    public var settings: AppSettings
    public var uid: UInt32
    public var expectedFingerprint: String
    public var language: AppLanguage? = nil
    public init(kind: RequestKind, settings: AppSettings, uid: UInt32, expectedFingerprint: String, language: AppLanguage? = nil) {
        self.kind = kind; self.settings = settings; self.uid = uid; self.expectedFingerprint = expectedFingerprint; self.language = language
    }
}

public enum RoutePlanner {
    public static func make(kind: RequestKind, settings: AppSettings, snapshot s: NetworkSnapshot, session: SessionState) throws -> ChangePlan {
        var actions: [Mutation] = [], after = session, warnings: [String] = []
        switch kind {
        case .applyPgy:
            guard let tunnel = s.pgyInterface(virtualIP: settings.pgyVirtualIP) else { throw RouteBarError(L("蒲公英未连接，或虚拟 IP 未匹配。工具不会替你启动它。")) }
            let ips = try settings.pgyNodes.filter(\.selected).map { node -> IPv4 in
                guard let ip = IPv4(node.address), ip.isUnicast else { throw RouteBarError(L("节点 IP 无效：{0}", node.address)) }
                guard ip != tunnel.address else { throw RouteBarError(L("节点列表不能包含本机蒲公英 IP")) }
                guard !s.physicalNetworks.contains(where: { $0.network.contains(ip) }) else { throw RouteBarError(L("{0} 属于当前直连内网，已阻止切换以保护办公室连接。", ip)) }
                if let ti = s.tailscaleInterface, s.routes.contains(where: { $0.network.prefix == 32 && $0.network.contains(ip) && $0.interface == ti }) {
                    throw RouteBarError(L("{0} 已由 Tailscale 使用，请先解决地址冲突。", ip))
                }
                return ip
            }
            guard !ips.isEmpty else { throw RouteBarError(L("请至少添加并选择一个蒲公英节点。")) }
            let originalRoutes = s.routes.filter { $0.interface == tunnel.name && !$0.isScoped && !$0.isCloned && $0.network.prefix < 32 && $0.network.address.value < 0xE0000000 }
            guard !originalRoutes.contains(where: { $0.network.prefix == 0 }) else { throw RouteBarError(L("检测到蒲公英默认路由，请先在官方客户端关闭全局代理模式。")) }
            let desired = Set(ips).sorted().map { ManagedRoute(network: CIDR($0, 32), target: .interface(tunnel.name), interfaceIdentity: tunnel.address) }
            let diff = try routeDiff(desired: desired, previous: session.pgyManaged, snapshot: s)
            actions += diff.add
            actions += originalRoutes.map(Mutation.removeOriginal)
            actions += diff.remove
            after.pgyManaged = diff.owned
            // A re-created interface is a new generation; never restore routes to an old utun number.
            after.pgyOriginals = Array(Set(session.pgyOriginals.filter { $0.interface == tunnel.name && session.pgyVirtualIP == settings.pgyVirtualIP } + originalRoutes)).sorted { $0.network < $1.network }
            after.pgyVirtualIP = settings.pgyVirtualIP
            after.pgySelection = ips.map(\.description).sorted()
            warnings.append(L("仅管理 IPv4。节点选择需确认应用后才生效。"))
        case .restorePgy:
            let current = session.pgyVirtualIP.flatMap { s.pgyInterface(virtualIP: $0) }
            for original in session.pgyOriginals {
                if current?.name == original.interface {
                    let exact = s.routes.filter { $0.network == original.network && !$0.isScoped }
                    if !exact.contains(where: { $0.samePath(as: original) }) {
                        guard exact.isEmpty else { throw RouteBarError(L("原始蒲公英路由位置已有其他路由，拒绝覆盖：{0}", original.network)) }
                        actions.append(.addOriginal(original))
                    }
                } else { warnings.append(L("旧接口已消失，不恢复旧路由：{0}", original.network)) }
            }
            actions += session.pgyManaged.filter { m in m.identityMatches(s.interfaces) && s.routes.contains(where: m.matches) }.map(Mutation.remove)
            after.pgyManaged = []; after.pgyOriginals = []; after.pgyVirtualIP = nil; after.pgySelection = []
        case .applyTailscale:
            guard let ts = s.tailscale, ts.backend == "Running", let ti = s.tailscaleInterface,
                  let accepts = ts.acceptsRoutes else { throw RouteBarError(L("Tailscale 未就绪，或无法读取接收子网设置。")) }
            let available = Set(ts.subnets.map(\.id)), selected = settings.selectedSubnets
            guard selected.isSubset(of: available) else { throw RouteBarError(L("部分选择的子网已撤销，请刷新并重新选择。")) }
            if !selected.isEmpty && ts.hasIPv6Subnets { throw RouteBarError(L("发现 IPv6 子网；本版只支持 IPv4，不能安全开启混合子网选择。")) }
            for subnet in ts.subnets where selected.contains(subnet.id) {
                guard subnet.online else { throw RouteBarError(L("子网路由器离线：{0}", subnet.id)) }
                guard !s.physicalNetworks.contains(where: { $0.network.overlaps(subnet.network) }) else {
                    throw RouteBarError(L("{0} 与当前直连内网重叠，已阻止通过 Tailscale 接管。", subnet.id))
                }
            }
            let effective = ts.subnets.sorted { $0.network < $1.network }
            for (i, a) in effective.enumerated() {
                for b in effective.dropFirst(i + 1) where a.network.overlaps(b.network) && selected.contains(a.id) != selected.contains(b.id) {
                    throw RouteBarError(L("重叠子网 {0} 与 {1} 必须同时选择或同时停用。", a.id, b.id))
                }
            }
            var desired: [ManagedRoute] = []
            if !selected.isEmpty {
                guard let fallback = s.physicalDefault else { throw RouteBarError(L("未找到本地物理默认网关，无法保护未选子网。")) }
                let baseRoutes = s.routes.filter { r in !session.tailscaleManaged.contains(where: { $0.matches(r) }) }
                var covered: [CIDR] = []
                for subnet in effective {
                    if covered.contains(where: { $0.contains(subnet.network) }) { continue }
                    guard subnet.network.prefix >= 8 else { throw RouteBarError(L("子网范围过大：{0}，本版拒绝自动接管小于 /8 的网段。", subnet.id)) }
                    let useTS = selected.contains(subnet.id)
                    let seed = subnet.network.prefix == 32 ? [subnet.network] : subnet.network.children
                    for leaf in seed {
                        try overlay(leaf, selected: useTS, tunnel: ti, fallback: fallback, physical: s.physicalNetworks, routes: baseRoutes, result: &desired)
                    }
                    covered.append(subnet.network)
                }
                warnings.append(L("选中的子网走 Tailscale；未选子网固定走本地物理网络，绕过其他代理。"))
                warnings.append(L("Tailscale 原生接收开关会打开；本工具以更具体的本机路由实现选择。"))
            }
            if let ownIP = s.interfaces.first(where: { $0.name == ti })?.address {
                desired = desired.map { route in
                    var r = route
                    if r.target.interface == ti { r.interfaceIdentity = ownIP }
                    return r
                }
            }
            let diff = try routeDiff(desired: desired, previous: session.tailscaleManaged, snapshot: s)
            let nextAccepts = !selected.isEmpty
            // Protect excluded LANs before enabling native subnet routes; disable native routes before removing protection.
            if nextAccepts {
                actions += diff.add
                if accepts != nextAccepts { actions.append(.acceptRoutes(from: accepts, to: nextAccepts)) }
                actions += diff.remove
            } else {
                if accepts != nextAccepts { actions.append(.acceptRoutes(from: accepts, to: nextAccepts)) }
                actions += diff.remove
            }
            after.tailscaleManaged = diff.owned
            after.tailscaleOriginalAccepts = session.tailscaleOriginalAccepts ?? (actions.isEmpty ? nil : accepts)
            after.tailscaleSelection = selected
        case .restoreTailscale:
            if let original = session.tailscaleOriginalAccepts {
                guard let current = s.tailscale?.acceptsRoutes else { throw RouteBarError(L("无法读取 Tailscale 设置，暂不能恢复。")) }
                if current != original { actions.append(.acceptRoutes(from: current, to: original)) }
            }
            actions += session.tailscaleManaged.filter { m in m.identityMatches(s.interfaces) && s.routes.contains(where: m.matches) }.map(Mutation.remove)
            after.tailscaleManaged = []; after.tailscaleOriginalAccepts = nil; after.tailscaleSelection = []
        case .recover: throw RouteBarError(L("恢复未完成事务应由执行器处理"))
        }
        guard actions.count <= 1024 else { throw RouteBarError(L("路由变更超过 1024 条，拒绝自动执行。")) }
        return ChangePlan(actions: actions, after: after, warnings: warnings, fingerprint: s.fingerprint, summary: title(kind))
    }

    public static func title(_ kind: RequestKind) -> String {
        switch kind {
        case .applyPgy: return L("蒲公英 · 仅选定节点")
        case .restorePgy: return L("恢复蒲公英原始路由")
        case .applyTailscale: return L("应用 Tailscale 子网选择")
        case .restoreTailscale: return L("恢复 Tailscale 原始设置")
        case .recover: return L("回滚未完成的操作")
        }
    }

    private static func routeDiff(desired: [ManagedRoute], previous: [ManagedRoute], snapshot: NetworkSnapshot) throws -> (add: [Mutation], remove: [Mutation], owned: [ManagedRoute]) {
        let desired = Array(Set(desired)).sorted { $0.network < $1.network }
        var additions: [Mutation] = [], owned: [ManagedRoute] = []
        for route in desired {
            try route.target.validate()
            let exact = snapshot.routes.filter { $0.network == route.network && !$0.isScoped && !$0.isCloned }
            if exact.contains(where: route.matches) {
                if previous.contains(route) { owned.append(route) }
                continue // Existing routes never become ours just because they match.
            }
            guard exact.isEmpty else { throw RouteBarError(L("已有路由占用 {0}，拒绝覆盖：{1}", route.network, exact[0])) }
            additions.append(.add(route)); owned.append(route)
        }
        let removals = previous.filter { !desired.contains($0) && $0.identityMatches(snapshot.interfaces) && snapshot.routes.contains(where: $0.matches) }.map(Mutation.remove)
        return (additions, removals, owned)
    }

    private static func overlay(_ net: CIDR, selected: Bool, tunnel: String, fallback: RouteTarget,
                                physical: [InterfaceAddress], routes: [RouteEntry], result: inout [ManagedRoute]) throws {
        guard result.count < 1024 else { throw RouteBarError(L("路由分片过多，拒绝继续。")) }
        var target: RouteTarget = selected ? .interface(tunnel) : fallback
        if !selected {
            if let local = physical.first(where: { $0.network.contains(net) }) { target = .interface(local.name) }
            else if physical.contains(where: { $0.network.overlaps(net) }) {
                guard net.prefix < 32 else { throw RouteBarError(L("无法确定直连内网路径")) }
                for child in net.children { try overlay(child, selected: selected, tunnel: tunnel, fallback: fallback, physical: physical, routes: routes, result: &result) }
                return
            }
        }
        let conflicts = routes.filter { !$0.isScoped && !$0.isCloned && $0.network.overlaps(net) && $0.network.prefix >= net.prefix && !$0.matchesTarget(target) }
        if !conflicts.isEmpty {
            guard net.prefix < 32 else { throw RouteBarError(L("单 IP 路由冲突，拒绝覆盖：{0}", net)) }
            for child in net.children { try overlay(child, selected: selected, tunnel: tunnel, fallback: fallback, physical: physical, routes: routes, result: &result) }
        } else {
            result.append(ManagedRoute(network: net, target: target))
        }
    }
}
