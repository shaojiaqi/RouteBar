import Foundation
import Security
import SystemConfiguration
import XPC
import Darwin

public enum RouteService {
    public static let name = "io.routebar.app.route-service"
    static let appID = "io.routebar.app"
    static let helperID = "io.routebar.app.helper"
    static let maxRequestBytes = 75_000
    static let version: Int64 = 1
    static let helperBasename = "RouteBarHelper"
    private static let ownAppHash = currentHash(identifier: appID)

    public enum Status: Equatable { case notInstalled, needsApproval, approved, unavailable }

    public static var canAuthorize: Bool { ownAppHash != nil && sealedPayloadHashes != nil }
    public static var status: Status {
        guard InstalledRouteService.hasConfiguration else { return .notInstalled }
        guard let config = try? InstalledRouteService.read() else { return .unavailable }
        return config.appHash == ownAppHash && config.uid == getuid() ? .approved : .needsApproval
    }

    static func validHash(_ hash: String) -> Bool { hash.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    private static let sealedPayloadHashes: (helper: String, catalog: String)? = {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess, hash(of: code, identifier: appID) == ownAppHash, ownAppHash != nil,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let plist = values[kSecCodeInfoPList as String] as? [String: Any],
              let helper = plist["RouteBarHelperSHA256"] as? String, let catalog = plist["RouteBarCatalogSHA256"] as? String,
              [helper, catalog].allSatisfy({ $0.count == 64 && validHash(String($0.prefix(40))) && validHash(String($0.suffix(40))) }) else { return nil }
        return (helper, catalog)
    }()
    static func requirement(_ identifier: String, hash: String) -> String {
        "identifier \"\(identifier)\" and cdhash H\"\(hash)\" and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }

    static func currentHash(identifier: String) -> String? {
        var dynamic: SecCode?, code: SecStaticCode?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCheckValidity(dynamic, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code else { return nil }
        return hash(of: code, identifier: identifier)
    }

    private static func hash(of code: SecStaticCode, identifier: String) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == identifier,
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber, flags.uint32Value & 0x10000 != 0, // CS_RUNTIME
              (values[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?.isEmpty != false,
              let data = values[kSecCodeInfoUnique as String] as? Data, data.count == 20 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    public static func changeApproval(_ approve: Bool) throws {
        guard let appHash = ownAppHash else { throw RouteBarError(L("此构建仅支持手动授权")) }
        let command = approve ? ["--install", appHash, String(getuid())] : ["--uninstall"]
        let result = try runWithApproval(command, prompt: approve
            ? L("RouteBar 请求启用后台路由授权，允许此版本在重连时维护已应用路由。")
            : L("RouteBar 请求撤销后台路由授权。"))
        guard result.success else { throw RouteBarError(result.message) }
        if approve { try probe() }
    }

    public static func applyManually(_ request: ChangeRequest) throws -> HelperResponse {
        let encoded = try JSONEncoder().encode(request).base64EncodedString()
        guard encoded.utf8.count < 100_000 else { throw RouteBarError(L("路由请求过大。")) }
        return try runWithApproval(["--apply", encoded], prompt: L("RouteBar 需要按预览修改本机路由；不会启动或连接 VPN。"))
    }

    private static func runWithApproval(_ args: [String], prompt: String) throws -> HelperResponse {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let helper = helpers.appendingPathComponent(helperBasename)
        let catalog = helpers.appendingPathComponent("RouteBar_RouteBarCore.bundle/Contents/Resources/Localizations.json")
        guard let hashes = sealedPayloadHashes, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw RouteBarError(L("找不到执行助手。请运行打包后的 RouteBar.app。"))
        }
        let functionArgs = args.map(shellQuote).joined(separator: " ")
        // The administrator command copies bytes to a root-only directory and checks the copies before running code.
        let command = """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        stage=$(/usr/bin/mktemp -d /private/var/db/.routebar-stage.XXXXXXXX)
        trap '/bin/rm -f "$stage/RouteBarHelper" "$stage/Localizations.json"; /bin/rmdir "$stage"' EXIT
        /bin/cp -X \(shellQuote(helper.path)) "$stage/RouteBarHelper"
        /bin/cp -X \(shellQuote(catalog.path)) "$stage/Localizations.json"
        verify() {
            result=$(/usr/bin/shasum -a 256 "$1")
            test "${result%% *}" = "$2"
        }
        verify "$stage/RouteBarHelper" \(hashes.helper)
        verify "$stage/Localizations.json" \(hashes.catalog)
        /bin/chmod 700 "$stage/RouteBarHelper"
        "$stage/RouteBarHelper" \(functionArgs)
        """
        let script = "do shell script " + appleScriptQuote(command) + " with administrator privileges with prompt " + appleScriptQuote(prompt)
        let result = try CommandRunner.checked("/usr/bin/osascript", ["-e", script], timeout: 180)
        return try JSONDecoder().decode(HelperResponse.self, from: Data(result.utf8))
    }

    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    public static func probe() throws {
        let reply = try send(nil, timeout: 8)
        guard reply.success else { throw RouteBarError(reply.message) }
    }

    public static func apply(_ request: ChangeRequest) throws -> HelperResponse { try send(request, timeout: 180) }

    private static func send(_ request: ChangeRequest?, timeout: TimeInterval) throws -> HelperResponse {
        let config = try InstalledRouteService.read()
        guard config.appHash == ownAppHash, config.uid == getuid() else { throw unavailable() }
        let connection = xpc_connection_create_mach_service(name, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        defer { xpc_connection_cancel(connection) }
        guard xpc_connection_set_peer_code_signing_requirement(connection, requirement(helperID, hash: config.helperHash)) == 0 else { throw unavailable() }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, "version", version)
        if let request {
            let data = try JSONEncoder().encode(request)
            guard data.count <= maxRequestBytes else { throw RouteBarError(L("路由请求过大。")) }
            data.withUnsafeBytes { xpc_dictionary_set_data(message, "request", $0.baseAddress!, $0.count) }
        } else {
            xpc_dictionary_set_bool(message, "probe", true)
        }
        let done = DispatchSemaphore(value: 0)
        let result = ServiceReply()
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        xpc_connection_send_message_with_reply(connection, message, .global(qos: .utility)) { reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                var count = 0
                if let bytes = xpc_dictionary_get_data(reply, "response", &count), count <= 1_000_000 {
                    result.data = Data(bytes: bytes, count: count)
                }
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let data = result.data else { throw unavailable() }
        return try JSONDecoder().decode(HelperResponse.self, from: data)
    }

    public static func serveInstalled() -> Never {
        guard geteuid() == 0, let config = try? InstalledRouteService.read(), currentHash(identifier: helperID) == config.helperHash,
              CommandLine.arguments.first == InstalledRouteService.helper.path else { exit(EX_NOPERM) }
        let queue = DispatchQueue(label: name)
        let listener = xpc_connection_create_mach_service(name, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        let clientRequirement = requirement(appID, hash: config.appHash)
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            guard xpc_connection_set_peer_code_signing_requirement(peer, clientRequirement) == 0 else {
                xpc_connection_cancel(peer)
                return
            }
            xpc_connection_set_target_queue(peer, queue)
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, let peer = xpc_dictionary_get_remote_connection(message),
                      let reply = xpc_dictionary_create_reply(message) else { return }
                let response = handle(message, uid: xpc_connection_get_euid(peer), approvedUID: config.uid)
                if let data = try? JSONEncoder().encode(response) {
                    data.withUnsafeBytes { xpc_dictionary_set_data(reply, "response", $0.baseAddress!, $0.count) }
                }
                xpc_connection_send_message(peer, reply)
            }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
        withExtendedLifetime(listener) { dispatchMain() }
    }

    static var consoleUID: uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil, uid >= 500 else { return nil }
        return uid
    }

    private static func handle(_ message: xpc_object_t, uid: uid_t, approvedUID: uid_t) -> HelperResponse {
        do {
            guard uid == approvedUID, uid == consoleUID else { throw RouteBarError(L("只有当前登录的用户可以修改路由。")) }
            guard xpc_dictionary_get_int64(message, "version") == version else { throw unavailable() }
            if xpc_dictionary_get_bool(message, "probe") { return HelperResponse(success: true, message: L("已启用")) }
            var count = 0
            guard let bytes = xpc_dictionary_get_data(message, "request", &count), count <= maxRequestBytes else {
                throw RouteBarError(L("后台路由服务与请求不兼容。"))
            }
            var request = try JSONDecoder().decode(ChangeRequest.self, from: Data(bytes: bytes, count: count))
            request.uid = uid
            RouteBarLocalization.useInCurrentProcess(request.language)
            defer { RouteBarLocalization.useInCurrentProcess(nil) }
            do { return try RouteExecutor.apply(request) }
            catch { return HelperResponse(success: false, message: error.localizedDescription) }
        } catch { return HelperResponse(success: false, message: error.localizedDescription) }
    }

    static func unavailable() -> RouteBarError { RouteBarError(L("未收到后台路由服务的结果，请检查授权和当前路由状态。")) }
}

private final class ServiceReply: @unchecked Sendable {
    var data: Data? // Published by the semaphore before the caller reads it.
}
