import SwiftUI
import RouteBarCore

private enum ManagerPage: String, CaseIterable, Identifiable {
    case overview, pgy, tailscale, diagnostics, settings

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: L("总览")
        case .pgy: L("蒲公英节点")
        case .tailscale: L("Tailscale 子网")
        case .diagnostics: L("诊断")
        case .settings: L("设置")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .pgy: routeBarSymbol
        case .tailscale: "circle.grid.3x3.fill"
        case .diagnostics: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

struct MainContent: View {
    @ObservedObject var model: AppModel
    @State private var page: ManagerPage = .overview
    @State private var nodeEditor: NodeEditorMode?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if model.journal.pending != nil && page != .diagnostics {
                    HStack(spacing: 12) {
                        StatusLine(message: L("请先回滚上次中断的操作"), symbol: "exclamationmark.triangle", color: .orange)
                        Spacer(minLength: 0)
                        Button(L("查看诊断")) { page = .diagnostics }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    Divider()
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .environment(\.locale, RouteBarLocalization.locale)
        .sheet(item: $model.preview, onDismiss: model.updateDraftChecks) { PreviewPane(model: model, preview: $0) }
        .sheet(item: $nodeEditor) { NodeEditor(model: model, mode: $0) }
        .routeBarError(model, active: nodeEditor == nil)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("RouteBar", systemImage: routeBarSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 15)
            ForEach(ManagerPage.allCases) { item in
                if item == .settings { Divider().padding(.vertical, 8).padding(.horizontal, 10) }
                Button { page = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.callout.weight(page == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background {
                            if page == item { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 12)
            Label(model.maintenanceStatus, systemImage: model.maintenanceRequested ? "arrow.triangle.2.circlepath" : "shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(14)
        }
        .frame(width: 170)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(page.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if model.refreshing || model.applying {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.applying ? L("正在应用…") : L("检查中…"))
            }
            if let snapshot = model.snapshot {
                Text(L("检查于 {0}", snapshot.timestamp.formatted(.dateTime.hour().minute().second().locale(RouteBarLocalization.locale))))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button(L("检查状态"), systemImage: "arrow.clockwise") { model.refresh() }
                .help(L("只读检查连接、当前路由和待应用选择"))
                .disabled(model.refreshing || model.applying)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .overview:
            OverviewPane(model: model, showPgy: { page = .pgy }, showTailscale: { page = .tailscale }, showDiagnostics: { page = .diagnostics })
        case .pgy:
            VPNPane(model: model, vpn: .pgy) { nodeEditor = $0 }
        case .tailscale:
            VPNPane(model: model, vpn: .tailscale) { nodeEditor = $0 }
        case .diagnostics: DiagnosticsPane(model: model)
        case .settings: SettingsPane(model: model)
        }
    }
}

extension View {
    func routeBarError(_ model: AppModel, active: Bool = true) -> some View {
        alert("RouteBar", isPresented: Binding(get: { active && model.errorMessage != nil }, set: {
            if active && !$0 { model.errorMessage = nil }
        })) {
            Button(L("知道了"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.message(model.errorMessage ?? "")) }
    }
}

struct OverviewPane: View {
    @ObservedObject var model: AppModel
    let showPgy: () -> Void
    let showTailscale: () -> Void
    let showDiagnostics: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle(L("连接"))
                    Button(action: showPgy) {
                        connection(L("蒲公英节点"), model.pgyLabel, symbol: routeBarSymbol, online: model.pgyOnline, link: true)
                    }.buttonStyle(.plain)
                    Divider()
                    Button(action: showTailscale) {
                        connection(L("Tailscale 子网"), model.tsLabel, symbol: "circle.grid.3x3.fill", online: model.tsOnline, link: true)
                    }.buttonStyle(.plain)
                    Divider()
                    connection(L("直连内网"), model.lanLabel.isEmpty ? L("未检测到") : model.lanLabel, symbol: "building.2",
                               online: !(model.snapshot?.physicalNetworks.isEmpty ?? true))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sectionTitle(L("路由状态"))
                        Spacer()
                        Button(L("查看诊断"), action: showDiagnostics).buttonStyle(.link)
                    }
                    Divider()
                    if let warning = model.healthWarnings.first {
                        StatusLine(message: model.message(warning), symbol: "exclamationmark.triangle", color: .orange)
                    }
                    StatusLine(message: model.message(model.lastResult), symbol: "clock.arrow.circlepath")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func connection(_ title: String, _ value: String, symbol: String, online: Bool, link: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            Text(title).font(.callout.weight(.semibold))
            Spacer(minLength: 14)
            StatusDot(online: online)
            Text(value).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .opacity(link ? 1 : 0).accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
