import SwiftUI
import RouteBarCore

let routeBarSymbol = "point.3.connected.trianglepath.dotted"

struct StatusDot: View {
    var online: Bool

    var body: some View {
        Circle().fill(online ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

struct StatusLine: View {
    let message: String
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: routeBarSymbol).font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("RouteBar").font(.headline)
                    Text(model.maintenanceStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.refreshing || model.applying { ProgressView().controlSize(.small) }
            }
            Divider()
            status(L("蒲公英"), model.pgyLabel, online: model.pgyOnline)
            status("Tailscale", model.tsLabel, online: model.tsOnline)
            StatusLine(message: model.lanLabel, symbol: "building.2").lineLimit(2)
            if model.journal.pending != nil {
                StatusLine(message: L("上次操作未完成，请打开管理窗口回滚"), symbol: "exclamationmark.triangle", color: .orange)
            } else if let warning = model.healthWarnings.first {
                StatusLine(message: model.message(warning), symbol: "exclamationmark.triangle", color: .orange)
            }
            Divider()
            HStack {
                Button(L("退出")) { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
                Spacer()
                Button(L("打开管理窗口"), systemImage: "arrow.up.right") { model.showWindow?() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 370)
        .environment(\.locale, RouteBarLocalization.locale)
    }

    private func status(_ title: String, _ value: String, online: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(online: online)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text(value).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PreviewPane: View {
    @ObservedObject var model: AppModel
    let preview: Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("预览路由更改"), systemImage: "arrow.triangle.branch").font(.title2.weight(.semibold))
                Text(model.message(preview.plan.summary)).font(.callout)
                Text(model.routeServiceEnabled
                     ? L("使用已批准的后台服务。网络状态变化时需重新预览。")
                     : L("请检查以下本机变更。执行时由 macOS 请求管理员授权；网络状态变化时会停止并要求重新预览。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.plan.warnings, id: \.self) { warning in
                        StatusLine(message: model.message(warning), symbol: "info.circle")
                    }
                    if !preview.plan.warnings.isEmpty && !preview.plan.actions.isEmpty { Divider() }
                    if preview.plan.actions.isEmpty {
                        Text(preview.plan.after == model.journal.state
                             ? L("无需修改路由，当前状态已符合选择。")
                             : L("无需修改系统路由；仍可记录此选择。"))
                            .font(.callout)
                    } else {
                        ForEach(Array(preview.plan.actions.enumerated()), id: \.offset) { index, action in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                Text(action.description).monospaced().textSelection(.enabled)
                            }.font(.caption)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Divider()
            HStack(spacing: 10) {
                Text(L("共 {0} 项变更", preview.plan.actions.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("取消")) { model.preview = nil }.keyboardShortcut(.cancelAction)
                if model.routeServiceEnabled {
                    Button(L("手动授权并应用")) { model.apply(preview, forceManual: true) }
                }
                Button(L("确认并应用")) { model.apply(preview) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
