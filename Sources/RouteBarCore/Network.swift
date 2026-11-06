import Foundation

public struct RouteBarError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct IPv4: Hashable, Codable, Comparable, CustomStringConvertible {
    public let value: UInt32
    public init(value: UInt32) { self.value = value }
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = UInt32(part), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        self.value = value
    }
    public var description: String { (0..<4).reversed().map { String((value >> ($0 * 8)) & 255) }.joined(separator: ".") }
    public var isUnicast: Bool { value > 0 && value < 0xE0000000 && value >> 24 != 127 && value >> 24 != 0 }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

public struct CIDR: Hashable, Codable, Comparable, CustomStringConvertible {
    public let address: IPv4
    public let prefix: Int
    public init(_ address: IPv4, _ prefix: Int) {
        precondition((0...32).contains(prefix))
        self.prefix = prefix
        self.address = IPv4(value: address.value & Self.mask(prefix))
    }
    public init?(_ text: String, abbreviated: Bool = false, host: Bool = false) {
        if text == "default" { self.init(IPv4(value: 0), 0); return }
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 2, !pieces[0].isEmpty else { return nil }
        var bytes = pieces[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let count = bytes.count
        if abbreviated && (1...4).contains(count) { while bytes.count < 4 { bytes.append("0") } }
        guard let ip = IPv4(bytes.joined(separator: ".")) else { return nil }
        let prefix = pieces.count == 2 ? Int(pieces[1]) : (host ? 32 : (abbreviated ? count * 8 : 32))
        guard let prefix, (0...32).contains(prefix) else { return nil }
        self.init(ip, prefix)
    }
    public static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : UInt32.max << (32 - prefix) }
    public var description: String { "\(address)/\(prefix)" }
    public var last: IPv4 { IPv4(value: address.value | ~Self.mask(prefix)) }
    public func contains(_ ip: IPv4) -> Bool { (ip.value & Self.mask(prefix)) == address.value }
    public func contains(_ other: CIDR) -> Bool { prefix <= other.prefix && contains(other.address) }
    public func overlaps(_ other: CIDR) -> Bool { contains(other.address) || other.contains(address) }
    public var children: [CIDR] {
        guard prefix < 32 else { return [] }
        return [CIDR(address, prefix + 1), CIDR(IPv4(value: address.value | (1 << (31 - prefix))), prefix + 1)]
    }
    public static func < (a: Self, b: Self) -> Bool { a.address == b.address ? a.prefix < b.prefix : a.address < b.address }
}

public struct InterfaceAddress: Codable, Hashable {
    public let name: String
    public let address: IPv4
    public let network: CIDR
    public let pointToPoint: Bool
    public var isPhysical: Bool { !pointToPoint && (name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("bond")) }
    public static func parse(_ text: String) -> [Self] {
        var result: [Self] = [], name = "", point = false
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                name = String(line[..<colon]); point = line.contains("POINTOPOINT")
            }
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.first == "inet", words.count > 1, let ip = IPv4(words[1]),
                  let i = words.firstIndex(of: "netmask"), i + 1 < words.count else { continue }
            let maskText = words[i + 1]
            let mask = maskText.hasPrefix("0x") ? UInt32(maskText.dropFirst(2), radix: 16) : IPv4(maskText)?.value
            guard let mask else { continue }
            let prefix = mask.nonzeroBitCount
            guard mask == CIDR.mask(prefix) else { continue }
            result.append(Self(name: name, address: ip, network: CIDR(ip, prefix), pointToPoint: point))
        }
        return result
    }
}

public struct RouteEntry: Codable, Hashable, CustomStringConvertible {
    public let network: CIDR
    public let gateway: String
    public let interface: String
    public let flags: String
    public init(network: CIDR, gateway: String, interface: String, flags: String = "US") {
        self.network = network; self.gateway = gateway; self.interface = interface; self.flags = flags
    }
    public var description: String { "\(network) → \(gateway) [\(interface)]" }
    public var isScoped: Bool { flags.contains("I") }
    public var isCloned: Bool { flags.contains("W") || flags.contains("L") }
    public func samePath(as other: Self) -> Bool { network == other.network && interface == other.interface && gateway == other.gateway && isScoped == other.isScoped }
    public func matchesTarget(_ target: RouteTarget) -> Bool {
        guard interface == target.interface, !isScoped else { return false }
        switch target {
        case .interface: return !flags.contains("G")
        case .gateway(let ip, _): return gateway == ip.description && flags.contains("G")
        }
    }
    public static func parse(_ text: String) -> [Self] {
        text.components(separatedBy: .newlines).compactMap { line in
            let w = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard w.count >= 4, w[2].contains("U"), let cidr = CIDR(w[0], abbreviated: true, host: w[2].contains("H")) else { return nil }
            return Self(network: cidr, gateway: w[1], interface: w[3], flags: w[2])
        }
    }
}

public enum RouteTarget: Codable, Hashable {
    case interface(String)
    case gateway(IPv4, String)
    public var interface: String {
        switch self { case .interface(let i), .gateway(_, let i): return i }
    }
    public var label: String {
        switch self { case .interface(let i): return i; case .gateway(let ip, let i): return "\(ip) · \(i)" }
    }
    public func validate() throws {
        guard interface.range(of: "^[a-z][a-z0-9]{0,15}$", options: .regularExpression) != nil else { throw RouteBarError(L("无效网络接口")) }
        if case .gateway(let ip, _) = self, !ip.isUnicast { throw RouteBarError(L("无效网关")) }
    }
}

public struct TailscaleSubnet: Codable, Hashable, Identifiable {
    public let network: CIDR
    public var routers: [String]
    public var online: Bool
    public var id: String { network.description }
}

public struct TailscaleState: Codable {
    public var backend: String
    public var ownIPs: [IPv4]
    public var subnets: [TailscaleSubnet]
    public var acceptsRoutes: Bool?
    public var hasIPv6Subnets: Bool
    public var executable: String
    public static func parse(status: Data, prefs: Data?, executable: String) throws -> Self {
        guard let d = try JSONSerialization.jsonObject(with: status) as? [String: Any] else { throw RouteBarError(L("无法解析 Tailscale 状态")) }
        let selfNode = d["Self"] as? [String: Any] ?? [:]
        let peers = d["Peer"] as? [String: [String: Any]] ?? [:]
        var nets: [CIDR: TailscaleSubnet] = [:], ipv6 = false
        for peer in peers.values {
            let ips = Set(peer["TailscaleIPs"] as? [String] ?? [])
            let primary = Set(peer["PrimaryRoutes"] as? [String] ?? [])
            let allowed = Set((peer["AllowedIPs"] as? [String] ?? [])).union(primary)
            for text in allowed {
                if text.contains(":"), text != "::/0", !ips.contains(String(text.split(separator: "/")[0])) { ipv6 = true }
                guard let net = CIDR(text), net.prefix > 0,
                      !(net.prefix == 32 && ips.contains(net.address.description)),
                      !(net.prefix == 32 && !primary.contains(text)),
                      !CIDR("100.64.0.0/10")!.contains(net) else { continue }
                let name = peer["HostName"] as? String ?? L("未知路由器")
                let online = peer["Online"] as? Bool ?? false
                if var existing = nets[net] { existing.routers.append(name); existing.online = existing.online || online; nets[net] = existing }
                else { nets[net] = TailscaleSubnet(network: net, routers: [name], online: online) }
            }
        }
        var accepts: Bool?
        if let prefs, let p = try? JSONSerialization.jsonObject(with: prefs) as? [String: Any] { accepts = p["RouteAll"] as? Bool }
        return Self(backend: d["BackendState"] as? String ?? "Unknown", ownIPs: (selfNode["TailscaleIPs"] as? [String] ?? []).compactMap(IPv4.init), subnets: nets.values.sorted { $0.network < $1.network }, acceptsRoutes: accepts, hasIPv6Subnets: ipv6, executable: executable)
    }
}
