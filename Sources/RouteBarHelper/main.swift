import Foundation
import Darwin
import RouteBarCore

let args = CommandLine.arguments
if args.count == 5, args[1] == "--serve-installed" { RouteService.serveInstalled() }

let response: HelperResponse
do {
    if args.count == 4, args[1] == "--install", let uid = uid_t(args[3]) {
        try InstalledRouteService.install(appHash: args[2], uid: uid)
        response = HelperResponse(success: true, message: L("已启用"))
    } else if args.count == 2, args[1] == "--uninstall" {
        try InstalledRouteService.uninstall()
        response = HelperResponse(success: true, message: L("撤销授权"))
    } else {
        guard args.count == 3, args[1] == "--apply", args[2].utf8.count < 100_000,
              let data = Data(base64Encoded: args[2]) else { throw RouteBarError(L("用法：RouteBarHelper --apply <base64-request>（需要管理员授权）")) }
        let request = try JSONDecoder().decode(ChangeRequest.self, from: data)
        RouteBarLocalization.useInCurrentProcess(request.language)
        response = try RouteExecutor.apply(request)
    }
} catch { response = HelperResponse(success: false, message: error.localizedDescription) }
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
if let data = try? encoder.encode(response), let output = String(data: data, encoding: .utf8) { print(output) }
else {
    let fallback: [String: Any] = ["success": false, "message": L("无法编码执行结果"), "warnings": []]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: fallback), as: UTF8.self))
}
// Structured errors must reach the UI intact through `do shell script`.
exit(0)
