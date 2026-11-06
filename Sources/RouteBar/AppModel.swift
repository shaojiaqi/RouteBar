import AppKit
import SwiftUI
import RouteBarCore
import Darwin
import ServiceManagement

struct Activity: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var message: String
}
struct Preview: Identifiable {
    let id = UUID()
    let kind: RequestKind
    let plan: ChangePlan
}

@MainActor final class AppModel: ObservableObject {
    @Published var language = RouteBarLocalization.selection {
        didSet {
            RouteBarLocalization.selection = language
            lastResult = message(lastResult)
            errorMessage = errorMessage.map { message($0) }
            healthWarnings = healthWarnings.map { message($0) }
            onLanguageChanged?()
            onStatusChanged?()
        }
    }
    func message(_ text: String) -> String { RouteBarLocalization.relocalize(text) }
    @Published var snapshot: NetworkSnapshot?
    @Published var journal = SessionJournal()
    @Published var settings = AppSettings.load() {
        didSet {
            if settings.pgyVirtualIP != oldValue.pgyVirtualIP || settings.pgyNodes != oldValue.pgyNodes { settings.maintainPgy = false }
            if settings.selectedSubnets != oldValue.selectedSubnets { settings.maintainTailscale = false }
            do { try settings.save() } catch { errorMessage = L("保存配置失败：{0}", error.localizedDescription) }
        }
    }
    @Published private(set) var loginItemStatus = SMAppService.mainApp.status
    var launchAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }
    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    func refreshLoginItemStatus() { loginItemStatus = SMAppService.mainApp.status }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = L("无法更改登录启动设置：{0}", error.localizedDescription)
        }
        refreshLoginItemStatus()
    }

    func openLoginItemSettings() { SMAppService.openSystemSettingsLoginItems() }

    @Published var refreshing = false
    @Published var applying = false
    @Published var preview: Preview?
    @Published var errorMessage: String?
    @Published var activities: [Activity] = []
    @Published var lastResult = L("只读检查 · 尚未修改网络")
    @Published var healthWarnings: [String] = []
    var showWindow: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    var onLanguageChanged: (() -> Void)?
    private var timer: Timer?
    private var maintenanceAttempts: [Date] = []

    init() {
        if let data = try? Data(contentsOf: AppSettings.directory.appendingPathComponent("activity.json")),
           let logs = try? JSONDecoder().decode([Activity].self, from: data) { activities = logs }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    var detectedPgyIP: String? {
        guard let snapshot, snapshot.pgyProcessRunning else { return nil }
        if let ip = snapshot.pgyDiscovery?.ownIP, snapshot.pgyInterface(virtualIP: ip) != nil { return ip }
        // Retain a previously verified identity only while its tunnel still exists.
        return snapshot.pgyInterface(virtualIP: settings.pgyVirtualIP)?.address.description
    }
    var pgyInterface: InterfaceAddress? { detectedPgyIP.flatMap { snapshot?.pgyInterface(virtualIP: $0) } }
    var pgyOnline: Bool { pgyInterface != nil }
    var pgyUnavailable: Bool { snapshot?.pgyProcessRunning == false }
    var pgyUnavailableTitle: String {
        snapshot?.pgyClientInstalled == false ? L("未检测到蒲公英") : L("蒲公英未运行")
    }
    var tsOnline: Bool { snapshot?.tailscale?.backend == "Running" && snapshot?.tailscaleInterface != nil }
    var hasManagedRoutes: Bool { journal.state.hasPgy || journal.state.hasTailscale }
    var needsAttention: Bool { journal.pending != nil || errorMessage != nil || !healthWarnings.isEmpty }
    var pgyLabel: String {
        guard snapshot != nil else { return L("检查中…") }
        if pgyUnavailable { return L("不适用 · {0}", pgyUnavailableTitle) }
        if let iface = pgyInterface { return L("已连接 · {0}", iface.name) }
        return L("未识别本机虚拟 IP")
    }
    var tsLabel: String {
        guard let ts = snapshot?.tailscale else { return L("未检测到") }
        return tsOnline ? L("{0} · 子网接收{1}", snapshot?.tailscaleInterface ?? "", ts.acceptsRoutes == true ? L("开启") : L("关闭")) : L(ts.backend)
    }
    var lanLabel: String { snapshot?.physicalNetworks.map { "\($0.name) · \($0.network)" }.joined(separator: "  ") ?? L("检查中…") }

    func refresh() {
        refreshLoginItemStatus()
        guard !refreshing, !applying else { return }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<(NetworkSnapshot, SessionJournal), Error> in
                Result { (try NetworkSnapshot.collect(), try JournalStore.read(uid: getuid())) }
            }.value
            refreshing = false
            switch result {
            case .success(let (snapshot, journal)):
                self.snapshot = snapshot; self.journal = journal
                if preview == nil, let discovery = snapshot.pgyDiscovery {
                    var updated = settings
                    if let ownIP = discovery.ownIP { updated.pgyVirtualIP = ownIP }
                    updated.pgyNodes = discovery.merging(settings.pgyNodes, virtualIP: updated.pgyVirtualIP)
                    if updated.pgyVirtualIP != settings.pgyVirtualIP || updated.pgyNodes != settings.pgyNodes { settings = updated }
                }
                assessHealth()
                onStatusChanged?()
                checkMaintenance()
            case .failure(let error):
                errorMessage = error.localizedDescription; onStatusChanged?()
            }
        }
    }

    func prepare(_ kind: RequestKind) {
        guard let snapshot else { return }
        do {
            if kind == .recover {
                guard let pending = journal.pending else { throw RouteBarError(L("没有未完成的操作")) }
                let recovery = ChangePlan(actions: Array(pending.plan.actions.prefix(pending.attempted).reversed().map(\.inverse)), after: pending.before, warnings: [L("仅回滚执行记录中的操作；发生外部路由冲突时会停止。")], fingerprint: snapshot.fingerprint, summary: L("回滚中断操作"))
                preview = Preview(kind: kind, plan: recovery)
            } else {
                guard journal.pending == nil else { throw RouteBarError(L("请先回滚上次中断的操作")) }
                let plan = try RoutePlanner.make(kind: kind, settings: settings, snapshot: snapshot, session: journal.state)
                if !plan.hasChanges && plan.after == journal.state { lastResult = L("当前路由已符合选择，无需授权或修改。"); return }
                preview = Preview(kind: kind, plan: plan)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func apply(_ preview: Preview, automatic: Bool = false, settingsOverride: AppSettings? = nil) {
        guard !applying else { return }
        self.preview = nil
        applying = true
        let request = ChangeRequest(kind: preview.kind, settings: settingsOverride ?? settings, uid: getuid(), expectedFingerprint: preview.plan.fingerprint, language: RouteBarLocalization.language)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RouteBarHelper").path
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<HelperResponse, Error> in
                Result {
                    guard FileManager.default.isExecutableFile(atPath: helper) else { throw RouteBarError(L("找不到执行助手。请运行打包后的 RouteBar.app。")) }
                    let encoded = try JSONEncoder().encode(request).base64EncodedString()
                    let command = Self.shellQuote(helper) + " --apply " + Self.shellQuote(encoded)
                    let script = "do shell script " + Self.appleScriptQuote(command) + " with administrator privileges with prompt " + Self.appleScriptQuote(L("RouteBar 需要按预览修改本机路由；不会启动或连接 VPN。"))
                    let result = try CommandRunner.checked("/usr/bin/osascript", ["-e", script], timeout: 180)
                    guard let data = result.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { throw RouteBarError(L("无法读取执行结果")) }
                    return try JSONDecoder().decode(HelperResponse.self, from: data)
                }
            }.value
            applying = false
            switch result {
            case .success(let response):
                lastResult = response.message
                record(response.message)
                if let state = response.state { journal.state = state }
                if !response.success { errorMessage = response.message; pauseMaintenance() }
            case .failure(let error):
                lastResult = error.localizedDescription
                record(L("{0}未完成：{1}", automatic ? L("自动维护") : L("手动切换"), error.localizedDescription))
                errorMessage = error.localizedDescription; pauseMaintenance()
            }
            refresh()
        }
    }

    private func pauseMaintenance() {
        settings.maintainPgy = false; settings.maintainTailscale = false
    }

    private var appliedSettings: AppSettings {
        var config = settings
        config.pgyVirtualIP = journal.state.pgyVirtualIP ?? settings.pgyVirtualIP
        config.pgyNodes = journal.state.pgySelection.map { PgyNode(name: $0, address: $0) }
        config.selectedSubnets = journal.state.tailscaleSelection
        return config
    }

    private func assessHealth() {
        healthWarnings = []
        guard let snapshot else { return }
        let active: [(Bool, Bool, RequestKind, String)] = [
            (journal.state.hasPgy, pgyOnline, .applyPgy, L("蒲公英")),
            (journal.state.hasTailscale, tsOnline, .applyTailscale, "Tailscale")
        ]
        for (managed, online, kind, label) in active where managed {
            guard online else { healthWarnings.append(L("{0} 未连接，已应用模式暂不可用。", label)); continue }
            do {
                let plan = try RoutePlanner.make(kind: kind, settings: appliedSettings, snapshot: snapshot, session: journal.state)
                if plan.hasChanges { healthWarnings.append(L("{0} 路由与已应用选择不同：{1} 项待修复。", label, plan.actions.count)) }
            } catch { healthWarnings.append("\(label)：\(error.localizedDescription)") }
        }
    }

    private func checkMaintenance() {
        guard !applying, preview == nil, journal.pending == nil, let snapshot else { return }
        let kinds: [RequestKind] = (settings.maintainPgy && journal.state.hasPgy && pgyOnline ? [.applyPgy] : [])
            + (settings.maintainTailscale && journal.state.hasTailscale && tsOnline ? [.applyTailscale] : [])
        for kind in kinds {
            do {
                // Draft checkbox edits must never be applied by a background check.
                let config = appliedSettings
                let plan = try RoutePlanner.make(kind: kind, settings: config, snapshot: snapshot, session: journal.state)
                if plan.hasChanges {
                    maintenanceAttempts.removeAll { Date().timeIntervalSince($0) > 60 }
                    guard maintenanceAttempts.count < 3 else { throw RouteBarError(L("一分钟内路由被反复改写，已停止自动维护。请检查 VPN 或代理配置。")) }
                    maintenanceAttempts.append(Date())
                    record(L("检测到路由变化，重新应用：{0}", plan.summary))
                    apply(Preview(kind: kind, plan: plan), automatic: true, settingsOverride: config)
                    return
                }
            } catch {
                errorMessage = L("自动维护已暂停：{0}", error.localizedDescription)
                record(errorMessage!); pauseMaintenance(); return
            }
        }
    }

    func addNode(name: String, ip: String) -> Bool {
        let text = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = IPv4(text), address.isUnicast else { errorMessage = L("请输入有效的 IPv4 节点地址"); return false }
        guard !settings.pgyNodes.contains(where: { $0.address == address.description }) else { errorMessage = L("该节点地址已存在"); return false }
        settings.pgyNodes.append(PgyNode(name: name.isEmpty ? address.description : name, address: address.description)); return true
    }

    func importNodes(_ text: String) -> Bool {
        var nodes: [PgyNode] = [], seen = Set(settings.pgyNodes.map(\.address))
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\t" || $0 == " " }).map(String.init)
            guard let last = parts.last, let ip = IPv4(last), ip.isUnicast else { errorMessage = L("第 {0} 行无有效 IPv4 地址，未导入任何节点。", index + 1); return false }
            if seen.insert(ip.description).inserted { nodes.append(PgyNode(name: parts.count > 1 ? parts.dropLast().joined(separator: " ") : ip.description, address: ip.description)) }
        }
        settings.pgyNodes += nodes; return true
    }

    func conflict(_ net: CIDR) -> String? {
        snapshot?.physicalNetworks.first { $0.network.overlaps(net) }.map { L("与 {0} 的 {1} 重叠", $0.name, $0.network) }
    }
    func record(_ message: String) {
        activities.insert(Activity(message: message), at: 0)
        activities = Array(activities.prefix(100))
        if let data = try? JSONEncoder().encode(activities) {
            try? FileManager.default.createDirectory(at: AppSettings.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: AppSettings.directory.appendingPathComponent("activity.json"), options: .atomic)
        }
    }
    func copyDiagnostics() {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        lastResult = L("诊断已复制到剪贴板（包含本机 IP 与节点名称，无登录凭据）")
    }
    nonisolated static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    nonisolated static func appleScriptQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" }
}
