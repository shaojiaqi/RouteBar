import Foundation
import Darwin

public enum PgyClientPresence {
    public static func isInstalled(applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]) -> Bool {
        applicationDirectories.contains { directory in
            let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return apps.filter { $0.pathExtension == "app" }.contains { app in
                guard let identifier = Bundle(url: app)?.bundleIdentifier?.lowercased() else { return false }
                return identifier.hasPrefix("com.oray.pgy.")
            }
        }
    }
}

public struct PgyMember: Codable, Equatable {
    public let memberID: String
    public let name: String
    public let address: String
    public let online: Bool
}

public struct PgyDiscoveryState: Codable {
    public let members: [PgyMember]
    public let ownIP: String?

    public static func parse(_ data: Data, localAddresses: Set<String>) throws -> Self {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["return"] as? Bool == true, (body["result_code"] as? Int) == 0,
              let rows = body["info"] as? [[String: Any]] else {
            throw RouteBarError(L("蒲公英节点接口未就绪或返回格式不兼容"))
        }
        var seen = Set<String>(), members: [PgyMember] = []
        for row in rows {
            guard row["hide"] as? Bool != true,
                  let text = row["ip_address"] as? String, let ip = IPv4(text), ip.isUnicast,
                  let id = row["id"] as? NSNumber, id.int64Value > 0,
                  seen.insert(ip.description).inserted else { continue }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            members.append(PgyMember(memberID: id.stringValue, name: name.isEmpty ? ip.description : name,
                                     address: ip.description, online: row["is_online"] as? Bool ?? false))
        }
        let own = members.filter { localAddresses.contains($0.address) }
        return Self(members: members.sorted { $0.address < $1.address }, ownIP: own.count == 1 ? own.first?.address : nil)
    }

    public func merging(_ existing: [PgyNode], virtualIP: String) -> [PgyNode] {
        let peers = members.filter { $0.address != ownIP && $0.address != virtualIP }
        let ids = Set(peers.map(\.memberID)), addresses = Set(peers.map(\.address))
        var result = existing.filter { node in
            guard let id = node.discoveryID else { return node.address != ownIP && node.address != virtualIP }
            return ids.contains(id) || addresses.contains(node.address)
        }
        for member in peers {
            if let index = result.firstIndex(where: { $0.discoveryID == member.memberID || $0.address == member.address }) {
                if result[index].discoveryID != nil {
                    if result[index].address != member.address { result[index].selected = false }
                    result[index].address = member.address
                    result[index].name = member.name
                    result[index].discoveryID = member.memberID
                }
            } else {
                var node = PgyNode(name: member.name, address: member.address, selected: false)
                node.discoveryID = member.memberID
                result.append(node)
            }
        }
        return result
    }

    public static func collect(interfaces: [InterfaceAddress]) throws -> Self {
        let rpc = try PgyReadOnlyRPC()
        let response = try rpc.members()
        let addresses = Set(interfaces.filter { $0.name.hasPrefix("utun") && $0.pointToPoint }.map { $0.address.description })
        return try parse(response, localAddresses: addresses)
    }
}

/// Local, connection-scoped service discovery and GetGrpMbrs only. Never subscribes
/// to events or sends credentials, configuration, login, or connection commands.
private final class PgyReadOnlyRPC {
    private let fd: Int32
    private let deadline = Date().addingTimeInterval(3)
    private var buffered = Data()
    private let limit = 2 * 1024 * 1024

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RouteBarError(L("无法创建蒲公英本机读取连接")) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(16604).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status != 0 && errno != EINPROGRESS { close(fd); throw RouteBarError(L("蒲公英本机服务未运行；请打开官方客户端")) }
        // Remaining connect errors are reported by send after poll.
    }
    deinit { close(fd) }

    func members() throws -> Data {
        let hello = try exchange(channel: -1, body: NSNull())
        guard let services = hello["services"] as? [[String: Any]],
              let service = services.first(where: { $0["name"] as? String == "VPNClientRpcService" }),
              let channel = service["id"] as? Int,
              let methods = service["funcs"] as? [[String: Any]],
              let method = methods.first(where: { $0["name"] as? String == "GetGrpMbrs" }),
              let action = method["id"] as? Int else { throw RouteBarError(L("蒲公英节点读取接口不兼容")) }
        let body = try exchange(channel: channel, body: ["action": action, "parameters": [:]])
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func ready(_ event: Int16) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw RouteBarError(L("蒲公英节点读取超时")) }
        var descriptor = pollfd(fd: fd, events: event, revents: 0)
        guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0,
              descriptor.revents & event != 0 else { throw RouteBarError(L("蒲公英本机接口无响应；请稍后检查状态")) }
    }
    private func receive() throws {
        try ready(Int16(POLLIN))
        var chunk = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &chunk, chunk.count, 0)
        guard count > 0, buffered.count + count <= limit else { throw RouteBarError(L("蒲公英节点响应中断或超出大小限制")) }
        buffered.append(contentsOf: chunk.prefix(count))
    }
    private func exchange(channel: Int, body: Any) throws -> [String: Any] {
        let json = try JSONSerialization.data(withJSONObject: ["type": 0, "channel": channel, "body": body])
        let encoded = String(decoding: json, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let data = Data(("POST /rpccall HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/x-www-form-urlencoded\r\nUser-Agent: rpcclient/1.0 (web)\r\nContent-Length: \(encoded.utf8.count)\r\n\r\n" + encoded).utf8)
        var offset = 0
        while offset < data.count {
            try ready(Int16(POLLOUT))
            let count = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { throw RouteBarError(L("蒲公英本机服务连接失败")) }
            offset += count
        }
        let separator = Data("\r\n\r\n".utf8)
        while buffered.range(of: separator) == nil {
            guard buffered.count < 16384 else { throw RouteBarError(L("蒲公英接口响应头无效")) }
            try receive()
        }
        let headerEnd = buffered.range(of: separator)!
        let header = String(decoding: buffered[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("HTTP/1.1 200 ") == true,
              let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
              length > 0, length <= limit else { throw RouteBarError(L("蒲公英接口响应头不兼容")) }
        buffered.removeSubrange(..<headerEnd.upperBound)
        while buffered.count < length { try receive() }
        let raw = buffered.prefix(length)
        guard let decoded = String(data: raw, encoding: .utf8)?.removingPercentEncoding,
              let envelope = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any],
              envelope["type"] as? Int == 1, envelope["channel"] as? Int == channel,
              let result = envelope["body"] as? [String: Any] else { throw RouteBarError(L("蒲公英节点响应格式不兼容")) }
        buffered.removeFirst(length)
        return result
    }
}
