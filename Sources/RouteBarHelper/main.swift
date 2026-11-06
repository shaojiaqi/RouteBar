import Foundation
import Darwin
import RouteBarCore

let response: HelperResponse
do {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply",
          CommandLine.arguments[2].utf8.count < 100_000,
          let data = Data(base64Encoded: CommandLine.arguments[2]) else { throw RouteBarError(L("用法：RouteBarHelper --apply <base64-request>（需要管理员授权）")) }
    let request = try JSONDecoder().decode(ChangeRequest.self, from: data)
    RouteBarLocalization.useInCurrentProcess(request.language)
    response = try RouteExecutor.apply(request)
} catch { response = HelperResponse(success: false, message: error.localizedDescription) }
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
if let data = try? encoder.encode(response), let output = String(data: data, encoding: .utf8) { print(output) }
else {
    let fallback: [String: Any] = ["success": false, "message": L("无法编码执行结果"), "warnings": []]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: fallback), as: UTF8.self))
}
// Structured errors must reach the UI intact through `do shell script`.
exit(0)
