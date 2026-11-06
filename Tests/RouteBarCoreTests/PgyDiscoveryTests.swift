import XCTest
@testable import RouteBarCore

final class PgyDiscoveryTests: XCTestCase {
    func testInstallationDetectionUsesBundleIdentityInsteadOfFilename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(PgyClientPresence.isInstalled(applicationDirectories: [directory]))
        func app(_ name: String, identifier: String) throws {
            let contents = directory.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("PgyVisitor", identifier: "com.example.unrelated")
        XCTAssertFalse(PgyClientPresence.isInstalled(applicationDirectories: [directory]))
        try app("Renamed Client", identifier: "com.oray.pgy.visitorent")
        XCTAssertTrue(PgyClientPresence.isInstalled(applicationDirectories: [directory]))
    }

    func testOlderSnapshotWithoutInstallationFieldRemainsDecodable() throws {
        let snapshot = NetworkSnapshot(interfaces: [], routes: [], pgyProcessRunning: false, notes: [], timestamp: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "pgyClientInstalled")
        let decoded = try JSONDecoder().decode(NetworkSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.pgyClientInstalled)
        XCTAssertFalse(decoded.pgyProcessRunning)
    }

    private func state(_ rows: String, local: Set<String> = ["172.16.0.167"]) throws -> PgyDiscoveryState {
        try PgyDiscoveryState.parse(Data(("{\"return\":true,\"result_code\":0,\"info\":" + rows + "}").utf8), localAddresses: local)
    }
    private let rows = #"[{"id":1,"name":"Self","ip_address":"172.16.0.167","is_online":true},{"id":2,"name":"NAS","ip_address":"172.16.0.26","is_online":true},{"id":3,"name":"Laptop","ip_address":"172.16.0.78","is_online":false}]"#

    func testOwnIPExcludedAndOfflinePeersRetained() throws {
        let discovery = try state(rows)
        XCTAssertEqual(discovery.ownIP, "172.16.0.167")
        let nodes = discovery.merging([], virtualIP: "")
        XCTAssertEqual(nodes.map(\.name), ["NAS", "Laptop"])
        XCTAssertTrue(nodes.allSatisfy { !$0.selected && $0.discoveryID != nil })
        XCTAssertEqual(discovery.members.first(where: { $0.name == "Laptop" })?.online, false)
    }
    func testRefreshPreservesCheckboxUUIDAndManualNodes() throws {
        let discovery = try state(rows)
        var nodes = discovery.merging([], virtualIP: "")
        nodes[0].selected = true
        nodes.append(PgyNode(name: "Manual server", address: "192.168.99.8"))
        let again = discovery.merging(nodes, virtualIP: "")
        XCTAssertEqual(again, nodes)
        XCTAssertTrue(again[0].selected)
    }
    func testChangedMemberIPUnselectsAndRemovedMemberDisappears() throws {
        let discovery = try state(rows)
        var nodes = discovery.merging([], virtualIP: "")
        nodes[0].selected = true
        let changed = try state(#"[{"id":2,"name":"Renamed NAS","ip_address":"172.16.0.27","is_online":true}]"#)
        let merged = changed.merging(nodes, virtualIP: "172.16.0.167")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, nodes[0].id)
        XCTAssertEqual(merged[0].address, "172.16.0.27")
        XCTAssertEqual(merged[0].name, "Renamed NAS")
        XCTAssertFalse(merged[0].selected)
    }
    func testManualAliasAndSelectionPreservedWhenDiscovered() throws {
        let manual = PgyNode(name: "My NAS", address: "172.16.0.26")
        let merged = try state(rows).merging([manual], virtualIP: "172.16.0.167")
        XCTAssertEqual(merged[0], manual)
        XCTAssertNil(merged[0].discoveryID)
    }
    func testRejectsMalformedFailedOrPartialResponse() {
        for json in ["{}", #"{"return":false,"result_code":0,"info":[]}"#, #"{"return":true,"result_code":5,"info":[]}"#, #"{"return":true,"result_code":0}"#, "broken"] {
            XCTAssertThrowsError(try PgyDiscoveryState.parse(Data(json.utf8), localAddresses: []))
        }
    }
    func testFiltersHiddenInvalidAndDuplicateNodes() throws {
        let discovery = try state(#"[{"id":1,"ip_address":"127.0.0.1"},{"id":2,"ip_address":"172.16.0.1","hide":true},{"id":3,"ip_address":"172.16.0.2"},{"id":4,"ip_address":"172.16.0.2"},{"id":5,"ip_address":"1.2.3.4;id"},{"ip_address":"172.16.0.4"}]"#)
        XCTAssertEqual(discovery.members.count, 1)
        XCTAssertEqual(discovery.members[0].name, "172.16.0.2")
    }
    func testMissingTunnelUsesSavedSelfIPAndNeverGuessesAmongMultipleMatches() throws {
        let offline = try state(rows, local: [])
        XCTAssertNil(offline.ownIP)
        XCTAssertEqual(offline.merging([], virtualIP: "172.16.0.167").count, 2)
        XCTAssertNil(try state(rows, local: ["172.16.0.167", "172.16.0.26"]).ownIP)
    }
    func testOldSettingsDecodeWithoutDiscoveryID() throws {
        let node = try JSONDecoder().decode(PgyNode.self, from: Data(#"{"id":"CE7E0130-BE15-4CBD-A21F-BC4EE409B186","name":"Legacy","address":"172.16.0.26","selected":true}"#.utf8))
        XCTAssertNil(node.discoveryID)
        XCTAssertTrue(node.selected)
    }
}
