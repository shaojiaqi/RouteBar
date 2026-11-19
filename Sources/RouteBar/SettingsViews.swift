import SwiftUI
import RouteBarCore

struct SettingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section(L("通用")) {
                Picker(L("语言"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                }
                Toggle(L("登录时启动"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .help(L("登录后仅显示菜单栏图标，不打开管理窗口。"))
                if model.loginItemNeedsApproval {
                    LabeledContent(L("需要在系统设置中允许登录时启动")) {
                        Button(L("打开系统设置")) { model.openLoginItemSettings() }
                    }
                }
            }
            Section(L("后台路由授权")) { routeService }
            Section(L("自动维护")) {
                Toggle(L("重连后维护蒲公英路由"), isOn: $model.settings.maintainPgy)
                    .disabled(!model.journal.state.hasPgy || model.applying)
                Toggle(L("网络变化后维护 Tailscale 路由"), isOn: $model.settings.maintainTailscale)
                    .disabled(!model.journal.state.hasTailscale || model.applying)
                if !model.hasManagedRoutes {
                    StatusLine(message: L("没有可自动维护的已应用选择。"), symbol: "info.circle")
                } else if !model.routeServiceEnabled || model.routeServiceFailed {
                    StatusLine(message: model.maintenanceRequested ? L("自动维护已暂停，后台路由授权不可用。") : L("自动维护需要后台路由授权。"),
                               symbol: "lock.shield")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var routeService: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.changingApproval { ProgressView().controlSize(.small) }
                if model.supportsRouteService && !model.changingApproval {
                    if model.routeServiceStatus == .needsApproval || model.routeServiceFailed {
                        Button(L("重新授权")) { model.setRouteService(true) }
                    } else if !model.routeServiceEnabled {
                        Button(L("启用后台授权")) { model.setRouteService(true) }
                    }
                    if model.routeServiceEnabled || model.routeServiceStatus == .needsApproval {
                        Button(L("撤销授权")) { model.setRouteService(false) }
                    }
                }
            }.disabled(model.applying)
        } label: {
            Label(serviceStatus, systemImage: "lock.shield")
        }
    }

    private var serviceStatus: String {
        if !model.supportsRouteService { return L("此构建仅支持手动授权") }
        if model.changingApproval { return L("等待系统批准") }
        if model.routeServiceFailed { return L("服务不可用") }
        if model.routeServiceStatus == .needsApproval { return L("需要重新授权") }
        return model.routeServiceEnabled ? L("已启用") : L("未启用")
    }
}

struct DiagnosticsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("执行记录与连接检查")).font(.headline)
                Spacer()
                Button(L("复制只读诊断"), systemImage: "doc.on.doc") { model.copyDiagnostics() }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.journal.pending != nil {
                        HStack(spacing: 10) {
                            StatusLine(message: L("请先回滚上次中断的操作"), symbol: "exclamationmark.triangle", color: .orange)
                            Spacer()
                            Button(L("回滚中断操作")) { model.prepare(.recover) }
                                .disabled(model.applying || model.refreshing || model.snapshot == nil || model.changingApproval)
                        }
                        Divider()
                    }
                    ForEach(model.snapshot?.notes ?? [], id: \.self) { note in
                        StatusLine(message: model.message(note), symbol: "info.circle")
                    }
                    if let note = model.snapshot?.pgyDiscoveryNote {
                        StatusLine(message: model.message(note), symbol: routeBarSymbol)
                    }
                    ForEach(model.healthWarnings, id: \.self) { warning in
                        StatusLine(message: model.message(warning), symbol: "exclamationmark.triangle", color: .orange)
                    }
                    if let snapshot = model.snapshot {
                        Text(L("已识别接口：") + snapshot.interfaces.filter { $0.name != "lo0" }
                            .map { "\($0.name) (\($0.address))" }.joined(separator: " · "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                    Text(L("活动记录")).font(.headline)
                    if model.activities.isEmpty {
                        Text(L("尚未执行路由修改。检查状态不会改变网络。")).font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.activities) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.message(entry.message)).font(.callout).textSelection(.enabled)
                                Text(entry.date.formatted(.dateTime.year().month().day().hour().minute().second().locale(RouteBarLocalization.locale)))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
