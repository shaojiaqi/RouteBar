import XCTest
@testable import RouteBarCore

final class NetworkTests: XCTestCase {
    func testIPv4RejectsMalformedAndShellContent() {
        for text in ["", "1.2.3", "256.1.1.1", "1..2.3", "1.2.3.4;id", "$(id)", "１２.1.1.1", "-1.2.3.4"] { XCTAssertNil(IPv4(text), text) }
        XCTAssertEqual(IPv4("192.168.1.255")?.description, "192.168.1.255")
        XCTAssertFalse(IPv4("127.0.0.1")!.isUnicast)
        XCTAssertFalse(IPv4("224.0.0.1")!.isUnicast)
    }
    func testCIDRParsingAndCoverage() {
        XCTAssertNil(CIDR("")); XCTAssertNil(CIDR("1.2.3.4/33")); XCTAssertNil(CIDR("1.2.3.4/-1"))
        XCTAssertEqual(CIDR("172.16/13", abbreviated: true)?.description, "172.16.0.0/13")
        XCTAssertEqual(CIDR("10.20.5.20/23")?.description, "10.20.4.0/23")
        XCTAssertEqual(CIDR("192.168.1.0/24")!.children.map(\.description), ["192.168.1.0/25", "192.168.1.128/25"])
        XCTAssertEqual(CIDR("10.1.1.0/32")!.children, [])
        XCTAssertTrue(CIDR("172.16.0.0/13")!.contains(IPv4("172.23.255.255")!))
        XCTAssertFalse(CIDR("172.16.0.0/13")!.contains(IPv4("172.24.0.0")!))
    }
    func testNetstatAbbreviatedHostAndScopedRoutes() {
        let routes = RouteEntry.parse("""
        Routing tables
        Destination Gateway Flags Netif Expire
        default 10.20.0.1 UGScg en0
        172.16/13 172.16.0.167 UGSc utun17
        172.16.0.167 172.16.0.167 UH utun17
        100.64/10 link#18 UCS utun3
        default link#18 UCSIg utun3
        10.20.0.7 aa:bb:cc:dd:ee:ff UHLWI en0 123
        """)
        XCTAssertEqual(routes.count, 6)
        XCTAssertEqual(routes[1].network.description, "172.16.0.0/13")
        XCTAssertEqual(routes[2].network.prefix, 32)
        XCTAssertTrue(routes[4].isScoped)
        XCTAssertTrue(routes[5].isCloned)
    }
    func testInterfaceDetectionUsesIPInsteadOfNumber() throws {
        var s = fixture()
        XCTAssertEqual(s.pgyInterface(virtualIP: "172.16.0.167")?.name, "utun17")
        s.interfaces[2] = InterfaceAddress(name: "utun29", address: IPv4("172.16.0.167")!, network: CIDR("172.16.0.0/13")!, pointToPoint: true)
        XCTAssertEqual(s.pgyInterface(virtualIP: "172.16.0.167")?.name, "utun29")
        XCTAssertNil(s.pgyInterface(virtualIP: "172.16.0.168"))
        s.pgyProcessRunning = false
        XCTAssertNil(s.pgyInterface(virtualIP: "172.16.0.167"))
    }
    func testTailscaleFiltersNodeAliasesExitRoutesAndDeduplicatesHA() throws {
        let json = #"{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.2"]},"Peer":{"a":{"HostName":"router-a","Online":true,"TailscaleIPs":["192.200.0.3","fd7a::1"],"AllowedIPs":["192.200.0.3/32","fd7a::1/128","0.0.0.0/0","::/0","192.168.30.0/24"]},"b":{"HostName":"router-b","Online":false,"AllowedIPs":["192.168.30.0/24","10.40.0.0/16"]}}}"#
        let ts = try TailscaleState.parse(status: Data(json.utf8), prefs: Data(#"{"RouteAll":false,"CorpDNS":false}"#.utf8), executable: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertEqual(ts.subnets.count, 2)
        XCTAssertEqual(ts.subnets.first { $0.id == "192.168.30.0/24" }?.routers.count, 2)
        XCTAssertTrue(ts.subnets.first { $0.id == "192.168.30.0/24" }!.online)
        XCTAssertFalse(ts.hasIPv6Subnets)
        XCTAssertEqual(ts.acceptsRoutes, false)
    }
    func testIPv6AdvertisementsDetectedSeparatelyFromNodeAddresses() throws {
        let json = #"{"Peer":{"a":{"TailscaleIPs":["fd7a::1"],"AllowedIPs":["fd7a::1/128","fd00:1234::/64"]}}}"#
        XCTAssertTrue(try TailscaleState.parse(status: Data(json.utf8), prefs: nil, executable: "").hasIPv6Subnets)
    }
    func testCustomIPv4NodeAliasIsNotSubnetEvenWhenOnlyIPv6InTailscaleIPs() throws {
        let json = #"{"Peer":{"a":{"TailscaleIPs":["fd7a::1"],"AllowedIPs":["192.200.0.3/32","fd7a::1/128"]},"b":{"TailscaleIPs":["100.64.0.3"],"AllowedIPs":["100.64.0.3/32","10.50.0.7/32"],"PrimaryRoutes":["10.50.0.7/32"]}}}"#
        let ts = try TailscaleState.parse(status: Data(json.utf8), prefs: nil, executable: "")
        XCTAssertEqual(ts.subnets.map(\.id), ["10.50.0.7/32"])
    }
    func testFingerprintIgnoresARPCache() {
        let a = fixture(); var b = a
        b.routes.append(RouteEntry(network: CIDR("10.20.0.7")!, gateway: "aa:bb:cc:dd:ee:ff", interface: "en0", flags: "UHLWI"))
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        b.routes.append(RouteEntry(network: CIDR("192.168.9.0/24")!, gateway: "link#11", interface: "utun17"))
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }
    func testInterfaceNamesRejectCommandInjection() {
        XCTAssertThrowsError(try RouteTarget.interface("utun7;id").validate())
        XCTAssertThrowsError(try RouteTarget.interface("../route").validate())
        XCTAssertNoThrow(try RouteTarget.interface("utun1024").validate())
    }
    func testCommandTimeoutTerminatesOnlyItsOwnChild() {
        let started = Date()
        XCTAssertThrowsError(try CommandRunner.run("/bin/sleep", ["3"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

final class PlannerTests: XCTestCase {
    func testPgyPinsNodesBeforeRemovingBroadRoute() throws {
        let s = fixture(), config = pgySettings()
        let p = try RoutePlanner.make(kind: .applyPgy, settings: config, snapshot: s, session: SessionState())
        XCTAssertEqual(p.actions.count, 2)
        guard case .add(let r) = p.actions[0] else { return XCTFail("nodes must be pinned first") }
        XCTAssertEqual(r.network.description, "172.16.0.3/32")
        XCTAssertEqual(r.target.interface, "utun17")
        XCTAssertEqual(r.interfaceIdentity, IPv4("172.16.0.167"))
        guard case .removeOriginal(let broad) = p.actions[1] else { return XCTFail() }
        XCTAssertEqual(broad.network.prefix, 13)
    }
    func testPgyDoesNotConnectWhenOffline() {
        var s = fixture(); s.interfaces.removeAll { $0.name == "utun17" }
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyPgy, settings: pgySettings(), snapshot: s, session: SessionState()))
    }
    func testPgyRefusesOfficeIPAndEmptySelection() {
        var config = pgySettings(); config.pgyNodes[0].address = "10.20.0.55"
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyPgy, settings: config, snapshot: fixture(), session: SessionState()))
        config.pgyNodes = []
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyPgy, settings: config, snapshot: fixture(), session: SessionState()))
    }
    func testPgyNeverClaimsAnExistingMatchingRoute() throws {
        var s = fixture()
        s.routes.append(RouteEntry(network: CIDR("172.16.0.3")!, gateway: "link#22", interface: "utun17", flags: "UHS"))
        let p = try RoutePlanner.make(kind: .applyPgy, settings: pgySettings(), snapshot: s, session: SessionState())
        XCTAssertTrue(p.after.pgyManaged.isEmpty)
        XCTAssertEqual(p.actions.count, 1)
    }
    func testPgyDoesNotOverwriteConflictingHostRoute() {
        var s = fixture(); s.routes.append(RouteEntry(network: CIDR("172.16.0.3")!, gateway: "198.18.0.1", interface: "utun1024", flags: "UGHS"))
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyPgy, settings: pgySettings(), snapshot: s, session: SessionState()))
    }
    func testPgyReapplicationIsIdempotent() throws {
        let config = pgySettings(); var s = fixture()
        let p = try RoutePlanner.make(kind: .applyPgy, settings: config, snapshot: s, session: SessionState())
        s.routes.removeAll { $0.interface == "utun17" && $0.network.prefix == 13 }
        for m in p.after.pgyManaged { s.routes.append(route(for: m)) }
        let again = try RoutePlanner.make(kind: .applyPgy, settings: config, snapshot: s, session: p.after)
        XCTAssertTrue(again.actions.isEmpty)
        XCTAssertEqual(again.after.pgyOriginals.count, 1)
    }
    func testRestoreNeverTouchesReusedUtunInterface() throws {
        var s = fixture(), state = SessionState()
        state.pgyManaged = [ManagedRoute(network: CIDR("172.16.0.3")!, target: .interface("utun17"), interfaceIdentity: IPv4("172.16.0.167"))]
        state.pgyVirtualIP = "172.16.0.167"
        s.interfaces[2] = InterfaceAddress(name: "utun17", address: IPv4("10.9.0.2")!, network: CIDR("10.9.0.2")!, pointToPoint: true)
        s.routes.append(route(for: state.pgyManaged[0]))
        let p = try RoutePlanner.make(kind: .restorePgy, settings: pgySettings(), snapshot: s, session: state)
        XCTAssertTrue(p.actions.isEmpty)
    }
    func testRestoreAddsBroadRouteBeforeRemovingPins() throws {
        var s = fixture(); let cfg = pgySettings()
        let p = try RoutePlanner.make(kind: .applyPgy, settings: cfg, snapshot: s, session: SessionState())
        s.routes.removeAll { $0.network.prefix == 13 }
        p.after.pgyManaged.forEach { s.routes.append(route(for: $0)) }
        let restore = try RoutePlanner.make(kind: .restorePgy, settings: cfg, snapshot: s, session: p.after)
        guard case .addOriginal = restore.actions.first else { return XCTFail() }
        guard case .remove = restore.actions.last else { return XCTFail() }
    }
    func testTailscaleProtectsExcludedLANBeforeEnabling() throws {
        let s = fixture(); var cfg = AppSettings(); cfg.selectedSubnets = ["192.168.30.0/24"]
        let p = try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState())
        let toggle = try XCTUnwrap(p.actions.firstIndex(of: .acceptRoutes(from: false, to: true)))
        XCTAssertGreaterThan(toggle, 0)
        let routes = p.after.tailscaleManaged
        XCTAssertTrue(routes.contains { $0.network.description == "192.168.30.0/25" && $0.target.interface == "utun3" })
        XCTAssertTrue(routes.contains { $0.network.description == "10.20.0.0/25" && $0.target == .interface("en0") })
        XCTAssertFalse(p.actions.contains { if case .removeOriginal = $0 { return true }; return false })
    }
    func testTailscaleDisabledAllDisablesBeforeRemovingOverlays() throws {
        var s = fixture(), state = SessionState(); s.tailscale?.acceptsRoutes = true
        let m = ManagedRoute(network: CIDR("192.168.30.0/25")!, target: .interface("utun3"), interfaceIdentity: IPv4("100.64.0.2"))
        state.tailscaleManaged = [m]; state.tailscaleOriginalAccepts = false; s.routes.append(route(for: m))
        let p = try RoutePlanner.make(kind: .applyTailscale, settings: AppSettings(), snapshot: s, session: state)
        XCTAssertEqual(p.actions.first, .acceptRoutes(from: true, to: false))
        XCTAssertEqual(p.actions.last, .remove(m))
    }
    func testTailscaleRejectsSelectedOfficeSubnet() {
        var cfg = AppSettings(); cfg.selectedSubnets = ["10.20.0.0/24"]
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: fixture(), session: SessionState()))
    }
    func testTailscaleRejectsRevokedOfflineAndIPv6() {
        var cfg = AppSettings(), s = fixture(); cfg.selectedSubnets = ["192.168.99.0/24"]
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState()))
        cfg.selectedSubnets = ["192.168.30.0/24"]; s.tailscale?.subnets[0].online = false
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState()))
        s.tailscale?.subnets[0].online = true; s.tailscale?.hasIPv6Subnets = true
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState()))
    }
    func testOverlappingDifferentSelectionsRefused() {
        var s = fixture(), cfg = AppSettings(); cfg.selectedSubnets = ["192.168.30.0/24"]
        s.tailscale?.subnets.append(TailscaleSubnet(network: CIDR("192.168.30.0/25")!, routers: ["nested"], online: true))
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState()))
    }
    func testOverlaySplitsAroundProxyWithoutDeletingIt() throws {
        var s = fixture(), cfg = AppSettings(); cfg.selectedSubnets = ["192.168.30.0/24"]
        let proxy = RouteEntry(network: CIDR("192.168.30.0/25")!, gateway: "198.18.0.1", interface: "utun1024", flags: "UGS")
        s.routes.append(proxy)
        let p = try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState())
        XCTAssertTrue(p.after.tailscaleManaged.contains { $0.network.description == "192.168.30.0/26" })
        XCTAssertFalse(p.actions.contains { if case .removeOriginal(let r) = $0 { return r == proxy }; return false })
    }
    func testNoOpDoesNotClaimTailscalePreferenceOwnership() throws {
        let p = try RoutePlanner.make(kind: .applyTailscale, settings: AppSettings(), snapshot: fixture(), session: SessionState())
        XCTAssertTrue(p.actions.isEmpty)
        XCTAssertNil(p.after.tailscaleOriginalAccepts)
    }
    func testEveryAddressInSelectedAndOfficeSubnetsHasCorrectLongestPrefix() throws {
        var s = fixture(), cfg = AppSettings(); cfg.selectedSubnets = ["192.168.30.0/24"]
        s.routes.append(RouteEntry(network: CIDR("192.168.30.64/26")!, gateway: "198.18.0.1", interface: "utun1024", flags: "UGS"))
        let p = try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: SessionState())
        var routes = s.routes + p.after.tailscaleManaged.map { route(for: $0) }
        // Model the native route injection after all protective overlays are installed.
        routes += s.tailscale!.subnets.map { RouteEntry(network: $0.network, gateway: "link#18", interface: "utun3", flags: "US") }
        for byte in 0...255 {
            for (prefix, expected) in [("192.168.30", "utun3"), ("10.20.0", "en0")] {
                let ip = IPv4("\(prefix).\(byte)")!
                let best = routes.filter { !$0.isScoped && $0.network.contains(ip) }.max { $0.network.prefix < $1.network.prefix }
                XCTAssertEqual(best?.interface, expected, ip.description)
            }
        }
    }
    func testTailscalePreviewRefusesConflictWithManagedPgyHost() {
        var s = fixture(), state = SessionState(), cfg = AppSettings(); cfg.selectedSubnets = ["192.168.30.0/24"]
        let pgy = ManagedRoute(network: CIDR("192.168.30.8")!, target: .interface("utun17"), interfaceIdentity: IPv4("172.16.0.167"))
        state.pgyManaged = [pgy]; s.routes.append(route(for: pgy))
        XCTAssertThrowsError(try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: s, session: state))
    }
    func testAppliedSelectionStoredForMaintenanceInsteadOfDrafts() throws {
        let p = try RoutePlanner.make(kind: .applyPgy, settings: pgySettings(), snapshot: fixture(), session: SessionState())
        XCTAssertEqual(p.after.pgySelection, ["172.16.0.3"])
        var cfg = AppSettings(); cfg.selectedSubnets = ["192.168.30.0/24"]
        let ts = try RoutePlanner.make(kind: .applyTailscale, settings: cfg, snapshot: fixture(), session: SessionState())
        XCTAssertEqual(ts.after.tailscaleSelection, cfg.selectedSubnets)
    }
}

final class TransactionTests: XCTestCase {
    let a = Mutation.add(ManagedRoute(network: CIDR("192.168.30.1")!, target: .interface("utun3")))
    let b = Mutation.acceptRoutes(from: false, to: true)
    func plan() -> ChangePlan { ChangePlan(actions: [a, b], after: SessionState(), warnings: [], fingerprint: "fixture", summary: "test") }
    func testWriteAheadBeforeEveryMutation() throws {
        var journal = SessionJournal(), persisted: [Int] = [], executed: [Mutation] = []
        try TransactionEngine.commit(plan: plan(), journal: &journal, persist: { persisted.append($0.pending?.attempted ?? -1) }, execute: { action, recovering in
            XCTAssertFalse(recovering); XCTAssertEqual(persisted.last, executed.count + 1); executed.append(action)
        }, verify: {})
        XCTAssertEqual(executed, [a, b]); XCTAssertEqual(persisted, [0, 1, 2, -1]); XCTAssertNil(journal.pending)
    }
    func testFailureRollsBackInReverseOrder() {
        var journal = SessionJournal(), executed: [Mutation] = []
        XCTAssertThrowsError(try TransactionEngine.commit(plan: plan(), journal: &journal, persist: { _ in }, execute: { action, recovering in
            executed.append(action)
            if !recovering && action == self.b { throw RouteBarError("simulated failure") }
        }, verify: {}))
        XCTAssertEqual(executed, [a, b, b.inverse, a.inverse]); XCTAssertNil(journal.pending)
    }
    func testVerificationFailureRollsBack() {
        var journal = SessionJournal(), rolledBack: [Mutation] = []
        XCTAssertThrowsError(try TransactionEngine.commit(plan: plan(), journal: &journal, persist: { _ in }, execute: { action, recovering in if recovering { rolledBack.append(action) } }, verify: { throw RouteBarError("unexpected route") }))
        XCTAssertEqual(rolledBack, [b.inverse, a.inverse]); XCTAssertNil(journal.pending)
    }
    func testFailedRollbackRetainsRecoverableJournal() throws {
        var journal = SessionJournal()
        XCTAssertThrowsError(try TransactionEngine.commit(plan: plan(), journal: &journal, persist: { _ in }, execute: { _, recovering in if recovering { throw RouteBarError("route taken over") } }, verify: { throw RouteBarError("verify") }))
        XCTAssertEqual(journal.pending?.attempted, 2)
        var inverses: [Mutation] = []
        try TransactionEngine.recover(journal: &journal, persist: { _ in }, execute: { action, _ in inverses.append(action) })
        XCTAssertEqual(inverses, [b.inverse, a.inverse]); XCTAssertNil(journal.pending)
    }
    func testFinalJournalWriteFailureStillRollsBack() {
        var journal = SessionJournal(), rolledBack: [Mutation] = [], failedOnce = false
        XCTAssertThrowsError(try TransactionEngine.commit(plan: plan(), journal: &journal, persist: { state in
            if state.pending == nil && !failedOnce { failedOnce = true; throw RouteBarError("disk write failed") }
        }, execute: { action, recovering in if recovering { rolledBack.append(action) } }, verify: {}))
        XCTAssertEqual(rolledBack, [b.inverse, a.inverse]); XCTAssertNil(journal.pending)
    }
    func testInitialPersistenceFailureDoesNotExecuteCommands() {
        var journal = SessionJournal(), executed = false
        XCTAssertThrowsError(try TransactionEngine.commit(plan: plan(), journal: &journal, persist: { _ in throw RouteBarError("disk full") }, execute: { _, _ in executed = true }, verify: {}))
        XCTAssertFalse(executed)
    }
    func testMutationRoundTripAndInverse() throws {
        for action in [a, b, a.inverse, b.inverse, .removeOriginal(fixture().routes[1])] {
            XCTAssertEqual(action.inverse.inverse, action)
            XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(action)), action)
        }
    }
}

private func route(for managed: ManagedRoute) -> RouteEntry {
    switch managed.target {
    case .interface(let iface): return RouteEntry(network: managed.network, gateway: "link#22", interface: iface, flags: "US")
    case .gateway(let ip, let iface): return RouteEntry(network: managed.network, gateway: ip.description, interface: iface, flags: "UGS")
    }
}
private func pgySettings() -> AppSettings {
    var settings = AppSettings(); settings.pgyVirtualIP = "172.16.0.167"
    settings.pgyNodes = [PgyNode(name: "Test node", address: "172.16.0.3")]
    return settings
}
private func fixture() -> NetworkSnapshot {
    NetworkSnapshot(
        interfaces: [
            InterfaceAddress(name: "en0", address: IPv4("10.20.0.2")!, network: CIDR("10.20.0.0/24")!, pointToPoint: false),
            InterfaceAddress(name: "utun3", address: IPv4("100.64.0.2")!, network: CIDR("100.64.0.2")!, pointToPoint: true),
            InterfaceAddress(name: "utun17", address: IPv4("172.16.0.167")!, network: CIDR("172.16.0.0/13")!, pointToPoint: true)
        ],
        routes: [
            RouteEntry(network: CIDR("default")!, gateway: "10.20.0.1", interface: "en0", flags: "UGScg"),
            RouteEntry(network: CIDR("172.16.0.0/13")!, gateway: "172.16.0.167", interface: "utun17", flags: "UGSc"),
            RouteEntry(network: CIDR("10.20.0.0/24")!, gateway: "link#12", interface: "en0", flags: "UCS")
        ],
        tailscale: TailscaleState(backend: "Running", ownIPs: [IPv4("100.64.0.2")!], subnets: [
            TailscaleSubnet(network: CIDR("192.168.30.0/24")!, routers: ["remote-router"], online: true),
            TailscaleSubnet(network: CIDR("10.20.0.0/24")!, routers: ["office-router"], online: true)
        ], acceptsRoutes: false, hasIPv6Subnets: false, executable: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        pgyProcessRunning: true, notes: [], timestamp: Date(timeIntervalSince1970: 0))
}
