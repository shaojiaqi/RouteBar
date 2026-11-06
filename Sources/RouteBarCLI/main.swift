import Foundation
import Darwin
import RouteBarCore

do {
    let args = CommandLine.arguments
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if args.count == 1 || args[1] == "inspect" {
        let snapshot = try NetworkSnapshot.collect()
        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
    } else if args[1] == "plan", args.count >= 3, let kind = RequestKind(rawValue: args[2]), kind != .recover {
        let snapshot = try NetworkSnapshot.collect()
        let journal = try JournalStore.read(uid: getuid())
        var settings = AppSettings.load()
        if args.count == 5, args[3] == "--select", kind == .applyTailscale {
            settings.selectedSubnets = Set(args[4].split(separator: ",").map(String.init))
        } else if args.count != 3 { throw RouteBarError(L("只支持 plan applyTailscale --select <逗号分隔的 CIDR>，不会保存草稿或修改网络。")) }
        let plan = try RoutePlanner.make(kind: kind, settings: settings, snapshot: snapshot, session: journal.state)
        print(String(decoding: try encoder.encode(plan), as: UTF8.self))
    } else {
        print(L("routebarctl inspect | plan applyPgy | plan restorePgy | plan applyTailscale [--select CIDR,CIDR] | plan restoreTailscale\n只读工具，不提供执行网络修改的命令。"))
        exit(2)
    }
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
