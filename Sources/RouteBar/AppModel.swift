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
    let settings: AppSettings
}

enum SelectionCheck {
    case ready(Int, recordingSelection: Bool)
    case blocked(String)
    case waiting(String)

    var message: String {
        switch self {
        case .ready(0, false): return L("当前路由已符合选择，无需授权或修改。")
        case .ready(0, true): return L("无需修改系统路由；仍可记录此选择。")
        case .ready(1, _): return L("待应用选择可用：1 项变更")
        case .ready(let count, _): return L("待应用选择可用：{0} 项变更", count)
        case .blocked(let reason): return L("待应用选择有冲突：{0}", reason)
        case .waiting(let reason): return L("等待网络就绪：{0}", reason)
        }
    }
    var canReview: Bool {
        if case .ready(let count, let recordingSelection) = self { return count > 0 || recordingSelection }
        return false
    }
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
            if settings.maintainPgy != oldValue.maintainPgy { maintenanceAttempts[.applyPgy] = nil }
            if settings.maintainTailscale != oldValue.maintainTailscale { maintenanceAttempts[.applyTailscale] = nil }
            do { try settings.save() } catch { errorMessage = L("保存配置失败：{0}", error.localizedDescription) }
            checkDraftSelections()
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

    let supportsRouteService = RouteService.canAuthorize
    @Published private(set) var routeServiceStatus = RouteService.Status.notInstalled
    @Published private(set) var routeServiceFailed = false
    @Published private(set) var changingApproval = false
    var routeServiceEnabled: Bool { supportsRouteService && routeServiceStatus == .approved }

    func refreshRouteServiceStatus() {
        guard supportsRouteService else { return }
        let status = RouteService.status
        if status != routeServiceStatus {
            routeServiceFailed = false
            routeServiceStatus = status
        }
    }

    func setRouteService(_ enabled: Bool) {
        guard supportsRouteService, !applying, !changingApproval else { return }
        changingApproval = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try RouteService.changeApproval(enabled) } }.value
            changingApproval = false
            refreshRouteServiceStatus()
            switch result {
            case .success: routeServiceFailed = false
            case .failure(let error):
                routeServiceFailed = enabled && routeServiceEnabled
                errorMessage = L("无法更改后台路由授权：{0}", error.localizedDescription)
            }
            refresh()
        }
    }

    @Published var refreshing = false
    @Published var applying = false
    @Published var preview: Preview?
    @Published var errorMessage: String?
    @Published var activities: [Activity] = []
    @Published var lastResult = L("只读检查 · 尚未修改网络")
    @Published var healthWarnings: [String] = []
    @Published private(set) var pgySelectionCheck: SelectionCheck?
    @Published private(set) var tailscaleSelectionCheck: SelectionCheck?
    var showWindow: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    var onLanguageChanged: (() -> Void)?
    private var timer: Timer?
    private var refreshInvalidated = false
    private var maintenanceAttempts: [RequestKind: [Date]] = [:]

    init() {
        if let data = try? Data(contentsOf: AppSettings.directory.appendingPathComponent("activity.json")),
           let logs = try? JSONDecoder().decode([Activity].self, from: data) { activities = logs }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(allowingMaintenance: true) }
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
    @Published private var checkedIPv4Routes: IPv4RouteCoverage?
    @Published private var checkedTailscaleRoutes: [String: RouteCoverage] = [:]
    @Published private var lastTailscaleSubnets: [TailscaleSubnet] = []

    func pgyPath(for address: String) -> RouteCoverage {
        guard !applying, journal.pending == nil, let tunnel = pgyInterface?.name,
              let ip = IPv4(address) else { return .unverified }
        return checkedIPv4Routes?.check(CIDR(ip, 32), through: tunnel) ?? .unverified
    }
    func tailscalePath(for subnet: String) -> RouteCoverage {
        guard !applying, journal.pending == nil else { return .unverified }
        return checkedTailscaleRoutes[subnet] ?? .unverified
    }
    var appliedPgySelection: Set<String> {
        guard journal.pending == nil, let virtualIP = journal.state.pgyVirtualIP,
              virtualIP == (detectedPgyIP ?? settings.pgyVirtualIP) else { return [] }
        return Set(journal.state.pgySelection)
    }
    var canLoadPgySelection: Bool {
        let applied = appliedPgySelection
        return !applied.isEmpty && applied != Set(settings.pgyNodes.filter(\.selected).map(\.address))
    }
    func loadAppliedPgySelection() {
        guard !applying, canLoadPgySelection else { return }
        let applied = appliedPgySelection
        var updated = settings
        for index in updated.pgyNodes.indices {
            updated.pgyNodes[index].selected = applied.contains(updated.pgyNodes[index].address)
        }
        let missing = applied.subtracting(updated.pgyNodes.map(\.address))
        updated.pgyNodes += missing.sorted().map { PgyNode(name: $0, address: $0) }
        settings = updated
    }
    var pgyUnavailable: Bool { snapshot?.pgyProcessRunning == false }
    var pgyUnavailableTitle: String {
        snapshot?.pgyClientInstalled == false ? L("未检测到蒲公英") : L("蒲公英未运行")
    }
    var tsOnline: Bool { snapshot?.tailscale?.backend == "Running" && snapshot?.tailscaleInterface != nil }
    var tailscaleSubnets: [TailscaleSubnet] {
        let live = snapshot?.tailscale?.subnets ?? []
        let current = tsOnline && !live.isEmpty ? live : lastTailscaleSubnets.map {
            TailscaleSubnet(network: $0.network, routers: $0.routers, online: false)
        }
        let remembered = settings.selectedSubnets.union(journal.state.tailscaleSelection).subtracting(current.map(\.id))
        return (current + remembered.compactMap { id in
            CIDR(id).map { TailscaleSubnet(network: $0, routers: [], online: false) }
        }).sorted { $0.network < $1.network }
    }
    var canLoadTailscaleSelection: Bool {
        let state = journal.state
        return journal.pending == nil && (state.hasTailscale || !state.tailscaleSelection.isEmpty)
            && state.tailscaleSelection != settings.selectedSubnets
    }
    var hasManagedRoutes: Bool { journal.state.hasPgy || journal.state.hasTailscale }
    var maintenanceRequested: Bool {
        (settings.maintainPgy && journal.state.hasPgy) || (settings.maintainTailscale && journal.state.hasTailscale)
    }
    var maintenanceStatus: String {
        if maintenanceRequested {
            return routeServiceEnabled && !routeServiceFailed && journal.pending == nil ? L("路由维护中") : L("自动维护已暂停")
        }
        return hasManagedRoutes ? L("路由已应用") : L("只读观察")
    }
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

    func refresh(allowingMaintenance: Bool = false) {
        refreshLoginItemStatus()
        refreshRouteServiceStatus()
        guard !refreshing, !applying else { return }
        refreshing = true
        refreshInvalidated = false
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<(NetworkSnapshot, SessionJournal, IPv4RouteCoverage, [String: RouteCoverage]), Error> in
                Result {
                    let snapshot = try NetworkSnapshot.collect(), journal = try JournalStore.read(uid: getuid())
                    let routes = IPv4RouteCoverage(snapshot.routes)
                    return (snapshot, journal, routes, snapshot.tailscaleRouteCoverage(using: routes))
                }
            }.value
            refreshing = false
            if refreshInvalidated { refresh(); return }
            switch result {
            case .success(let (snapshot, journal, routes, tailscaleRoutes)):
                self.snapshot = snapshot; self.journal = journal
                checkedIPv4Routes = routes; checkedTailscaleRoutes = tailscaleRoutes
                if tsOnline, let subnets = snapshot.tailscale?.subnets, !subnets.isEmpty { lastTailscaleSubnets = subnets }
                if preview == nil, let discovery = snapshot.pgyDiscovery {
                    var updated = settings
                    if let ip = detectedPgyIP { updated.pgyVirtualIP = ip }
                    updated.pgyNodes = discovery.merging(settings.pgyNodes, virtualIP: updated.pgyVirtualIP, applied: appliedPgySelection)
                    if updated.pgyVirtualIP != settings.pgyVirtualIP || updated.pgyNodes != settings.pgyNodes { settings = updated }
                }
                checkDraftSelections()
                assessHealth()
                onStatusChanged?()
                if allowingMaintenance { checkMaintenance() }
            case .failure(let error):
                checkedIPv4Routes = nil; checkedTailscaleRoutes = [:]
                pgySelectionCheck = nil; tailscaleSelectionCheck = nil
                errorMessage = error.localizedDescription; onStatusChanged?()
            }
        }
    }

    private func checkDraftSelections() {
        guard let snapshot, preview == nil, !applying, journal.pending == nil else {
            pgySelectionCheck = nil; tailscaleSelectionCheck = nil
            return
        }
        func check(_ kind: RequestKind) -> SelectionCheck {
            do {
                let plan = try RoutePlanner.make(kind: kind, settings: settings, snapshot: snapshot, session: journal.state)
                return .ready(plan.actions.count, recordingSelection: plan.after != journal.state)
            } catch let error as RouteNotReady {
                return .waiting(error.localizedDescription)
            } catch {
                return .blocked(error.localizedDescription)
            }
        }
        pgySelectionCheck = check(.applyPgy)
        tailscaleSelectionCheck = check(.applyTailscale)
    }

    func updateDraftChecks() { checkDraftSelections() }

    func prepare(_ kind: RequestKind) {
        guard let snapshot else { return }
        do {
            if kind == .recover {
                guard let pending = journal.pending else { throw RouteBarError(L("没有未完成的操作")) }
                let recovery = ChangePlan(actions: Array(pending.plan.actions.prefix(pending.attempted).reversed().map(\.inverse)), after: pending.before, warnings: [L("仅回滚执行记录中的操作；发生外部路由冲突时会停止。")], fingerprint: snapshot.fingerprint, summary: L("回滚中断操作"))
                preview = Preview(kind: kind, plan: recovery, settings: settings)
            } else {
                guard journal.pending == nil else { throw RouteBarError(L("请先回滚上次中断的操作")) }
                let plan = try RoutePlanner.make(kind: kind, settings: settings, snapshot: snapshot, session: journal.state)
                if !plan.hasChanges && plan.after == journal.state { lastResult = L("当前路由已符合选择，无需授权或修改。"); return }
                preview = Preview(kind: kind, plan: plan, settings: settings)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func apply(_ preview: Preview, automatic: Bool = false, forceManual: Bool = false) {
        guard !applying, !changingApproval else { return }
        refreshRouteServiceStatus()
        let useService = routeServiceEnabled && !forceManual
        guard !automatic || useService else { return }
        self.preview = nil
        applying = true
        refreshInvalidated = true
        checkedIPv4Routes = nil; checkedTailscaleRoutes = [:]
        let request = ChangeRequest(kind: preview.kind, settings: automatic ? AppSettings() : preview.settings, uid: getuid(), expectedFingerprint: preview.plan.fingerprint, language: RouteBarLocalization.language, maintenance: automatic)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<HelperResponse, Error> in
                Result {
                    if useService { return try RouteService.apply(request) }
                    return try RouteService.applyManually(request)
                }
            }.value
            applying = false
            switch result {
            case .success(let response):
                if useService { routeServiceFailed = false }
                lastResult = response.message
                record(response.message)
                if let state = response.state { journal.state = state }
                if response.success {
                    if preview.kind == .restorePgy { settings.maintainPgy = false }
                    if preview.kind == .restoreTailscale { settings.maintainTailscale = false }
                    if !automatic { maintenanceAttempts[preview.kind] = nil }
                } else if automatic && (response.networkChanged == true || response.waitingForNetwork == true) {
                    // No writes were attempted. Wait for the next snapshot without counting this as route churn.
                    _ = maintenanceAttempts[preview.kind]?.popLast()
                    onStatusChanged?()
                    return
                } else if automatic {
                    pauseMaintenance(preview.kind, reason: response.message)
                } else { errorMessage = response.message }
            case .failure(let error):
                lastResult = error.localizedDescription
                record(L("{0}未完成：{1}", automatic ? L("自动维护") : L("手动切换"), error.localizedDescription))
                if useService { routeServiceFailed = true }
                if !automatic { errorMessage = error.localizedDescription }
            }
            refresh()
        }
    }

    private func pauseMaintenance(_ kind: RequestKind, reason: String) {
        if kind == .applyPgy { settings.maintainPgy = false }
        if kind == .applyTailscale { settings.maintainTailscale = false }
        lastResult = L("自动维护已暂停：{0}", reason)
        record(lastResult)
    }

    private func assessHealth() {
        healthWarnings = []
        guard let snapshot else { return }
        if maintenanceRequested && (!routeServiceEnabled || routeServiceFailed) {
            healthWarnings.append(L("自动维护已暂停，后台路由授权不可用。"))
        }
        let active: [(Bool, Bool, RequestKind, String)] = [
            (journal.state.hasPgy, pgyOnline, .applyPgy, L("蒲公英")),
            (journal.state.hasTailscale, tsOnline, .applyTailscale, "Tailscale")
        ]
        for (managed, online, kind, label) in active where managed {
            guard online else { healthWarnings.append(L("{0} 未连接，已应用模式暂不可用。", label)); continue }
            guard let config = journal.state.maintenanceSettings(for: kind) else { continue }
            do {
                let plan = try RoutePlanner.make(kind: kind, settings: config, snapshot: snapshot, session: journal.state)
                if plan.hasChanges { healthWarnings.append(L("{0} 路由与已应用选择不同：{1} 项待修复。", label, plan.actions.count)) }
            } catch { healthWarnings.append("\(label)：\(error.localizedDescription)") }
        }
    }

    private func checkMaintenance() {
        guard routeServiceEnabled, !routeServiceFailed, !applying, !changingApproval, preview == nil, journal.pending == nil, let snapshot else { return }
        let kinds: [RequestKind] = (settings.maintainPgy && journal.state.hasPgy && pgyOnline ? [.applyPgy] : [])
            + (settings.maintainTailscale && journal.state.hasTailscale && tsOnline ? [.applyTailscale] : [])
        for kind in kinds {
            do {
                guard let config = journal.state.maintenanceSettings(for: kind) else { continue }
                let plan = try RoutePlanner.make(kind: kind, settings: config, snapshot: snapshot, session: journal.state)
                if plan.hasChanges {
                    let now = Date(), attempts = maintenanceAttempts[kind, default: []].filter { now.timeIntervalSince($0) <= 60 }
                    guard attempts.count < 3 else { throw RouteBarError(L("一分钟内路由被反复改写，已停止自动维护。请检查 VPN 或代理配置。")) }
                    maintenanceAttempts[kind] = attempts + [now]
                    record(L("检测到路由变化，重新应用：{0}", plan.summary))
                    apply(Preview(kind: kind, plan: plan, settings: config), automatic: true)
                    return
                }
            } catch is RouteNotReady {
                continue
            } catch {
                pauseMaintenance(kind, reason: error.localizedDescription)
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
}
