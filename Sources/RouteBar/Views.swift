import SwiftUI
import RouteBarCore

private let accent = Color(red: 0.13, green: 0.45, blue: 0.67)
private let muted = Color.secondary

struct LanguagePicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Picker(L("语言"), selection: $model.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }.labelsHidden().frame(width: 145).help(L("语言切换立即生效"))
            .accessibilityLabel(L("语言"))
    }
}

struct LoginItemControl: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(L("登录时启动"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.caption)
                .help(L("登录后仅显示菜单栏图标，不打开管理窗口。"))
            if model.loginItemNeedsApproval {
                HStack {
                    Text(L("需要在系统设置中允许登录时启动")).font(.caption2).foregroundStyle(.orange)
                    Button(L("打开系统设置")) { model.openLoginItemSettings() }.font(.caption2).buttonStyle(.borderless)
                }
            }
        }.onAppear { model.refreshLoginItemStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshLoginItemStatus()
            }
    }
}

struct StatusDot: View {
    var online: Bool
    var body: some View { Circle().fill(online ? Color.green : Color.secondary.opacity(0.45)).frame(width: 7, height: 7) }
}
struct Metric: View {
    var title: String; var value: String; var symbol: String; var online: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: symbol).foregroundStyle(accent); Text(title).font(.system(size: 12, weight: .medium)); Spacer(); StatusDot(online: online) }
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(2).frame(minHeight: 30, alignment: .topLeading)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) { Text("RouteBar").font(.headline); Text(model.hasManagedRoutes ? L("路由维护中") : L("只读观察")).font(.caption).foregroundStyle(muted) }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(model.refreshing || model.applying).help(L("立即检查"))
            }
            Divider()
            status(L("蒲公英"), model.pgyLabel, online: model.pgyOnline)
            status("Tailscale", model.tsLabel, online: model.tsOnline)
            Label(model.lanLabel, systemImage: "building.2").font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if let snapshot = model.snapshot {
                Text(L("检查于 {0}", snapshot.timestamp.formatted(.dateTime.hour().minute().second().locale(RouteBarLocalization.locale)))).font(.caption2).foregroundStyle(muted)
            }
            if model.journal.pending != nil { Label(L("上次操作未完成，请打开管理窗口回滚"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if let warning = model.healthWarnings.first { Label(model.message(warning), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Text(model.message(model.lastResult)).font(.caption).foregroundStyle(muted).lineLimit(3)
            LoginItemControl(model: model)
            HStack { Text(L("语言")).font(.caption); Spacer(); LanguagePicker(model: model) }
            Button { model.showWindow?() } label: { HStack { Text(L("管理节点与子网")); Spacer(); Image(systemName: "arrow.up.right") }.padding(.vertical, 4) }.buttonStyle(.borderedProminent).tint(accent)
            HStack { Text(L("右键图标可打开管理窗口")).font(.caption2).foregroundStyle(muted); Spacer(); Button(L("退出")) { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).font(.caption) }
        }.padding(20).frame(width: 390).environment(\.locale, RouteBarLocalization.locale)
    }
    private func status(_ title: String, _ value: String, online: Bool) -> some View {
        HStack { StatusDot(online: online); Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text(value).font(.caption).foregroundStyle(muted) }
    }
}

struct MainContent: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("让每条连接，走对的路")).font(.system(size: 23, weight: .semibold))
                    Text(L("RouteBar  /  本机路由管理")).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) { LanguagePicker(model: model); LoginItemControl(model: model) }
                if model.refreshing || model.applying { ProgressView().controlSize(.small) }
                Button(L("检查状态"), systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.refreshing || model.applying)
            }
            HStack(spacing: 12) {
                Metric(title: L("蒲公英"), value: model.pgyLabel, symbol: "point.3.connected.trianglepath.dotted", online: model.pgyOnline)
                Metric(title: "Tailscale", value: model.tsLabel, symbol: "circle.grid.3x3.fill", online: model.tsOnline)
                Metric(title: L("直连内网"), value: model.lanLabel, symbol: "building.2", online: !(model.snapshot?.physicalNetworks.isEmpty ?? true))
            }
            TabView(selection: $tab) {
                PgyPane(model: model).tabItem { Text(L("蒲公英节点")) }.tag(0)
                TailscalePane(model: model).tabItem { Text(L("Tailscale 子网")) }.tag(1)
                DiagnosticsPane(model: model).tabItem { Text(L("检查与记录")) }.tag(2)
            }
            HStack(spacing: 8) {
                Image(systemName: model.applying ? "arrow.triangle.2.circlepath" : "checkmark.shield").foregroundStyle(accent)
                Text(model.applying ? L("等待管理员授权 / 应用并验证路由…") : model.message(model.healthWarnings.first ?? model.lastResult)).font(.caption).lineLimit(2)
                Spacer()
                Text(L("IPv4 · 每 10 秒检查")).font(.caption2).foregroundStyle(muted)
            }
        }.padding(24).frame(minWidth: 900, minHeight: 660).environment(\.locale, RouteBarLocalization.locale).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $model.preview) { PreviewPane(model: model, preview: $0) }
            .alert("RouteBar", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button(L("知道了"), role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.message(model.errorMessage ?? "")) }
    }
}

struct PgyPane: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var ip = ""
    @State private var importing = false
    @State private var importText = ""
    var body: some View {
        if model.pgyUnavailable {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "network.slash").font(.system(size: 34)).foregroundStyle(muted)
                Text(model.pgyUnavailableTitle).font(.headline)
                Text(L("蒲公英功能暂不适用。启动官方客户端后会自动重新检测。"))
                    .font(.callout).foregroundStyle(muted).multilineTextAlignment(.center)
                Text(L("已保存的节点和选择会保留，不会自动启动或连接蒲公英。"))
                    .font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
                Button(L("检查状态")) { model.refresh() }.disabled(model.refreshing || model.applying)
                if model.journal.state.hasPgy {
                    Text(L("仍有已应用的蒲公英路由记录，可在客户端可用后恢复。"))
                        .font(.caption).foregroundStyle(.orange)
                    Button(L("恢复原始路由")) { model.prepare(.restorePgy) }.disabled(model.applying)
                }
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            editor
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("本机虚拟 IP")).font(.caption).foregroundStyle(muted)
                Text(model.detectedPgyIP ?? L("未识别"))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(width: 230, alignment: .leading)
                    .help(L("由蒲公英客户端自动识别，仅供查看和复制。"))
                Spacer()
                Text(model.pgyOnline ? L("接口自动识别，无需填写 utun 编号") : L("未连接 · 不会自动启动蒲公英")).font(.caption).foregroundStyle(muted)
            }
            HStack {
                Text(L("仅以下勾选的 IP 走蒲公英")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("刷新节点")) { model.refresh() }.font(.caption).disabled(model.refreshing || model.applying)
                Button(L("批量导入")) { importing = true }.font(.caption)
            }
            List {
                if model.settings.pgyNodes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { Text(L("等待蒲公英节点列表")).font(.headline); Text(L("连接官方客户端后点击刷新节点。也可手动添加节点或节点后的内网 IP。")).font(.caption).foregroundStyle(muted) }.padding(.vertical, 18).listRowSeparator(.hidden)
                }
                ForEach($model.settings.pgyNodes) { $node in
                    HStack {
                        Toggle(isOn: $node.selected) { Text(node.name) }.toggleStyle(.checkbox)
                        Spacer()
                        if let member = model.snapshot?.pgyDiscovery?.members.first(where: { $0.address == node.address }) {
                            HStack(spacing: 5) { StatusDot(online: member.online); Text(member.online ? L("在线") : L("离线")).font(.caption2).foregroundStyle(muted) }
                        }
                        Text(node.address).font(.system(.caption, design: .monospaced)).foregroundStyle(muted)
                        if node.discoveryID == nil { Button { model.settings.pgyNodes.removeAll { $0.id == node.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help(L("从选择列表移除；点击应用后才更改路由")) }
                    }.padding(.vertical, 3)
                }
            }.listStyle(.inset).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                TextField(L("节点名称（可选）"), text: $name).textFieldStyle(.roundedBorder)
                TextField(L("节点 IPv4"), text: $ip).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(L("添加")) { if model.addNode(name: name, ip: ip) { name = ""; ip = "" } }.disabled(model.applying)
            }
            HStack {
                Toggle(L("重连后维护已应用模式"), isOn: $model.settings.maintainPgy).toggleStyle(.checkbox).disabled(!model.journal.state.hasPgy || model.applying)
                Spacer()
                Button(L("恢复原始路由")) { model.prepare(.restorePgy) }.disabled(!model.journal.state.hasPgy || model.applying)
                Button(L("应用")) { model.prepare(.applyPgy) }.buttonStyle(.borderedProminent).tint(accent).disabled(!model.pgyOnline || model.applying)
            }
            Text(model.snapshot?.pgyDiscoveryNote.map { model.message($0) } ?? L("已从蒲公英本机接口读取节点（排除本机）；新节点默认不勾选，预览并确认后才修改路由。")).font(.caption2).foregroundStyle(muted)
        }.padding(16)
            .sheet(isPresented: $importing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("批量导入节点")).font(.headline)
                    Text(L("每行一个：名称,IPv4 或单独 IPv4。导入只保存列表，不会修改网络。")).font(.caption).foregroundStyle(muted)
                    TextEditor(text: $importText).font(.system(.body, design: .monospaced)).frame(height: 200).border(Color.secondary.opacity(0.3))
                    HStack { Spacer(); Button(L("取消")) { importing = false }; Button(L("导入")) { if model.importNodes(importText) { importing = false; importText = "" } }.buttonStyle(.borderedProminent) }
                }.padding(20).frame(width: 540)
            }
    }
}

struct TailscalePane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("选择由 Tailscale 接管的子网")).font(.system(size: 13, weight: .semibold))
                    Text(L("部分选择时，未选子网走本地物理网关；全不选只关闭子网接收。保留 DNS 与出口节点。")).font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L("全不选")) { model.settings.selectedSubnets = [] }.font(.caption)
            }
            List {
                if (model.snapshot?.tailscale?.subnets ?? []).isEmpty { Text(L("未发现已批准的 IPv4 子网路由")).foregroundStyle(muted).padding(.vertical, 24) }
                ForEach(model.snapshot?.tailscale?.subnets ?? []) { subnet in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { model.settings.selectedSubnets.contains(subnet.id) }, set: { selected in
                            if selected { model.settings.selectedSubnets.insert(subnet.id) } else { model.settings.selectedSubnets.remove(subnet.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(subnet.id).font(.system(size: 13, weight: .medium, design: .monospaced))
                                Text(subnet.routers.sorted().joined(separator: " / ")).font(.caption).foregroundStyle(muted)
                            }
                        }.toggleStyle(.checkbox).disabled(model.conflict(subnet.network) != nil || !subnet.online || model.applying)
                        Spacer()
                        if let conflict = model.conflict(subnet.network) {
                            Label(L("直连内网优先"), systemImage: "building.2.crop.circle").font(.caption).foregroundStyle(.orange).help(conflict)
                        } else {
                            HStack(spacing: 5) { StatusDot(online: subnet.online); Text(subnet.online ? L("在线") : L("离线")).font(.caption).foregroundStyle(muted) }
                        }
                    }.padding(.vertical, 7)
                }
            }.listStyle(.inset)
            Label(L("选择保存在本机，点击「预览」并确认后才生效。原生接收总开关与本机路由一起管理。"), systemImage: "info.circle").font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if model.snapshot?.tailscale?.hasIPv6Subnets == true { Text(L("检测到 IPv6 子网。本版无法安全开启混合选择；仍可关闭全部子网接收。")).font(.caption).foregroundStyle(.orange) }
            HStack {
                Toggle(L("网络变化后维护已应用选择"), isOn: $model.settings.maintainTailscale).toggleStyle(.checkbox).disabled(!model.journal.state.hasTailscale || model.applying)
                Spacer()
                Button(L("恢复原始设置")) { model.prepare(.restoreTailscale) }.disabled(!model.journal.state.hasTailscale || model.applying)
                Button(L("应用")) { model.prepare(.applyTailscale) }.buttonStyle(.borderedProminent).tint(accent).disabled(!model.tsOnline || model.applying)
            }
        }.padding(16)
    }
}

struct DiagnosticsPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("执行记录与连接检查")).font(.headline)
                Spacer()
                Button(L("复制只读诊断")) { model.copyDiagnostics() }
                if model.journal.pending != nil { Button(L("回滚中断操作")) { model.prepare(.recover) }.tint(.orange) }
            }
            ForEach(model.snapshot?.notes ?? [], id: \.self) { Text(model.message($0)).font(.caption).foregroundStyle(.orange) }
            ForEach(model.healthWarnings, id: \.self) { Text(model.message($0)).font(.caption).foregroundStyle(.orange) }
            if let snapshot = model.snapshot {
                Text(L("已识别接口：") + snapshot.interfaces.filter { $0.name != "lo0" }.map { "\($0.name) (\($0.address))" }.joined(separator: " · ")).font(.system(.caption, design: .monospaced)).foregroundStyle(muted)
            }
            List {
                if model.activities.isEmpty { Text(L("尚未执行路由修改。检查状态不会改变网络。")).font(.caption).foregroundStyle(muted).padding(.vertical, 24) }
                ForEach(model.activities) { entry in
                    VStack(alignment: .leading, spacing: 4) { Text(model.message(entry.message)).font(.caption); Text(entry.date.formatted(.dateTime.year().month().day().hour().minute().second().locale(RouteBarLocalization.locale))).font(.caption2).foregroundStyle(muted) }.padding(.vertical, 4)
                }
            }.listStyle(.inset)
            Text(L("恢复记录由执行助手保存在 /var/db/io.routebar。退出工具不会自动撤销已应用的模式；请先使用对应恢复按钮。")).font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }.padding(16)
    }
}

struct PreviewPane: View {
    @ObservedObject var model: AppModel
    let preview: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("预览路由更改"), systemImage: "arrow.triangle.branch").font(.title3.weight(.semibold))
            Text(model.message(preview.plan.summary)).font(.subheadline)
            Text(L("请检查以下本机变更。执行时由 macOS 请求管理员授权；网络状态变化时会停止并要求重新预览。")).font(.caption).foregroundStyle(muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if preview.plan.actions.isEmpty { Text(L("无需修改路由，当前状态已符合选择。")) }
                    ForEach(Array(preview.plan.actions.enumerated()), id: \.offset) { _, action in Text(action.description).frame(maxWidth: .infinity, alignment: .leading) }
                }.font(.system(.caption, design: .monospaced)).padding(12).textSelection(.enabled)
            }.frame(height: 230).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            ForEach(preview.plan.warnings, id: \.self) { warning in Label(model.message(warning), systemImage: "info.circle").font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
            HStack { Text(L("共 {0} 项变更", preview.plan.actions.count)).font(.caption).foregroundStyle(muted); Spacer(); Button(L("取消")) { model.preview = nil }.keyboardShortcut(.cancelAction); Button(L("确认并应用")) { model.apply(preview) }.buttonStyle(.borderedProminent).tint(accent) }
        }.padding(22).frame(width: 650)
    }
}
