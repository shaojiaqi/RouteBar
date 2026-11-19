public enum RouteCoverage: Equatable {
    case vpn, other, partial, unverified
}

public struct IPv4RouteCoverage {
    private let routes: [RouteEntry]

    public init(_ routes: [RouteEntry]) {
        self.routes = routes.filter { $0.flags.contains("U") && !$0.isScoped && !$0.isCloned }
    }

    public func check(_ network: CIDR, through tunnel: String, minimumTunnelPrefix: Int = 1) -> RouteCoverage {
        let overlaps = routes.filter { $0.network.overlaps(network) }
        let covering = overlaps.filter { $0.network.contains(network) }
        let prefix = covering.map(\.network.prefix).max()
        let effective = covering.filter { $0.network.prefix == prefix }
        let narrower = overlaps.filter { $0.network.prefix > network.prefix }

        func inspect(_ net: CIDR, inherited: [RouteEntry], specifics: [RouteEntry]) -> RouteCoverage {
            guard !specifics.isEmpty else {
                guard let first = inherited.first,
                      inherited.allSatisfy({ $0.interface == first.interface && !$0.flags.contains("R") && !$0.flags.contains("B") }) else { return .unverified }
                if first.interface != tunnel { return .other }
                return first.network.prefix >= minimumTunnelPrefix ? .vpn : .unverified
            }
            // Split only at routes that can override the enclosing path; never enumerate hosts.
            let halves = net.children.map { child in
                let relevant = specifics.filter { child.contains($0.network) }
                let exact = relevant.filter { $0.network == child }
                return inspect(child, inherited: exact.isEmpty ? inherited : exact,
                               specifics: relevant.filter { $0.network.prefix > child.prefix })
            }
            if halves.contains(.partial) || (halves.contains(.vpn) && halves.contains(.other)) { return .partial }
            if halves.contains(.unverified) { return .unverified }
            return halves[0]
        }
        return inspect(network, inherited: effective, specifics: narrower)
    }
}

public extension NetworkSnapshot {
    func tailscaleRouteCoverage(using routes: IPv4RouteCoverage) -> [String: RouteCoverage] {
        guard let tailscale, tailscale.backend == "Running", let tunnel = tailscaleInterface else { return [:] }
        return Dictionary(uniqueKeysWithValues: tailscale.subnets.map { subnet in
            // A broader exit-node route alone does not establish that a subnet route is active.
            let prefix = tailscale.subnets.lazy.filter { $0.network.contains(subnet.network) }.map(\.network.prefix).min() ?? subnet.network.prefix
            let status = routes.check(subnet.network, through: tunnel, minimumTunnelPrefix: prefix)
            return (subnet.id, status == .other || (tailscale.acceptsRoutes == true && subnet.online) ? status : .unverified)
        })
    }
}
