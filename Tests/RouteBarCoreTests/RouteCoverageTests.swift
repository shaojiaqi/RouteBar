import XCTest
@testable import RouteBarCore

final class RouteCoverageTests: XCTestCase {
    private func route(_ cidr: String, _ interface: String, flags: String = "US") -> RouteEntry {
        RouteEntry(network: CIDR(cidr)!, gateway: "link#12", interface: interface, flags: flags)
    }

    func testNodePathsUseCurrentTunnelAndMoreSpecificOfficeRoute() {
        let old = route("172.16.1.2/32", "utun7")
        let office = route("172.16.1.3/32", "en0")
        let reconnected = route("172.16.1.2/32", "utun12")
        let a = CIDR("172.16.1.2/32")!, b = CIDR("172.16.1.3/32")!
        XCTAssertEqual(IPv4RouteCoverage([old, office]).check(a, through: "utun12"), .other)
        let coverage = IPv4RouteCoverage([route("172.16.0.0/16", "utun12"), reconnected, office])
        XCTAssertEqual(coverage.check(a, through: "utun12"), .vpn)
        XCTAssertEqual(coverage.check(b, through: "utun12"), .other)
    }

    func testSubnetRequiresFullCoverageAndDetectsASingleDifferentHost() {
        let subnet = CIDR("192.168.120.0/24")!
        let defaultRoute = route("default", "en0")
        let left = route("192.168.120.0/25", "utun12"), right = route("192.168.120.128/25", "utun12")
        XCTAssertEqual(IPv4RouteCoverage([defaultRoute, left]).check(subnet, through: "utun12"), .partial)
        XCTAssertEqual(IPv4RouteCoverage([defaultRoute, left, right]).check(subnet, through: "utun12"), .vpn)
        let outside = route("192.168.120.99/32", "en0")
        XCTAssertEqual(IPv4RouteCoverage([defaultRoute, left, right, outside]).check(subnet, through: "utun12"), .partial)
        XCTAssertEqual(IPv4RouteCoverage([defaultRoute, left, right, route("192.168.120.99/32", "en0", flags: "UHLWI")]).check(subnet, through: "utun12"), .vpn)
        XCTAssertEqual(IPv4RouteCoverage([defaultRoute, left, right, route("192.168.120.99/32", "utun12", flags: "UHR")]).check(subnet, through: "utun12"), .unverified)
    }

    func testTailscaleDisconnectAndExitNodeDoNotLookLikeActiveSubnet() {
        let own = IPv4("100.64.0.2")!, advertised = CIDR("192.168.120.0/24")!
        let subnet = TailscaleSubnet(network: advertised, routers: ["router"], online: true)
        let tunnel = InterfaceAddress(name: "utun12", address: own, network: CIDR(own, 32), pointToPoint: true)
        let ts = TailscaleState(backend: "Running", ownIPs: [own], subnets: [subnet], acceptsRoutes: true,
                                hasIPv6Subnets: false, executable: "")
        var snapshot = NetworkSnapshot(interfaces: [tunnel], routes: [route("128.0.0.0/1", "utun12")],
                                       tailscale: ts, pgyProcessRunning: false, notes: [], timestamp: Date())
        func status() -> RouteCoverage? {
            snapshot.tailscaleRouteCoverage(using: IPv4RouteCoverage(snapshot.routes))[subnet.id]
        }
        XCTAssertEqual(status(), .unverified)
        snapshot.routes.append(route(subnet.id, "utun12"))
        XCTAssertEqual(status(), .vpn)
        snapshot.routes.append(route("192.168.120.0/25", "en0"))
        XCTAssertEqual(status(), .partial)
        snapshot.tailscale?.backend = "Stopped"
        XCTAssertNil(status())
        snapshot.tailscale?.backend = "Running"
        snapshot.tailscale?.acceptsRoutes = false
        XCTAssertEqual(status(), .unverified)
        snapshot.routes = [route(subnet.id, "en0")]
        XCTAssertEqual(status(), .other)
    }
}
