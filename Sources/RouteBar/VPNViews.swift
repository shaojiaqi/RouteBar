import SwiftUI
import RouteBarCore

enum VPNPage {
    case pgy, tailscale
}

struct VPNPane: View {
    @ObservedObject var model: AppModel
    let vpn: VPNPage
    let editNodes: (NodeEditorMode) -> Void

    private var isPgy: Bool { vpn == .pgy }
    private var check: SelectionCheck? { isPgy ? model.pgySelectionCheck : model.tailscaleSelectionCheck }
    private var busy: Bool { model.applying || model.changingApproval }
    private var canRestore: Bool { isPgy ? model.journal.state.hasPgy : model.journal.state.hasTailscale }
    private var selectedCount: Int {
        isPgy ? model.settings.pgyNodes.filter(\.selected).count : model.settings.selectedSubnets.count
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionHeader
            tableHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isPgy { pgyRows } else { tailscaleRows }
                }
            }
            Divider()
            reviewBar
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 9) {
            StatusDot(online: isPgy ? model.pgyOnline : model.tsOnline)
            Text(isPgy ? model.pgyLabel : model.tsLabel).font(.callout.weight(.medium))
            if isPgy, let ip = model.detectedPgyIP {
                Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .help(L("本机虚拟 IP"))
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var actions: some View {
        Menu {
            if isPgy {
                Button(L("添加节点")) { editNodes(.add) }
                Button(L("批量导入节点")) { editNodes(.importList) }
                Divider()
            }
            Button(L("载入上次选择")) {
                if isPgy { model.loadAppliedPgySelection() }
                else { model.settings.selectedSubnets = model.journal.state.tailscaleSelection }
            }.disabled(isPgy ? !model.canLoadPgySelection : !model.canLoadTailscaleSelection)
            Button(L("全不选")) {
                if isPgy {
                    var draft = model.settings
                    for index in draft.pgyNodes.indices { draft.pgyNodes[index].selected = false }
                    model.settings = draft
                } else { model.settings.selectedSubnets = [] }
            }.disabled(selectedCount == 0)
            Divider()
            Button(isPgy ? L("恢复原始路由") : L("恢复原始设置")) {
                model.prepare(isPgy ? .restorePgy : .restoreTailscale)
            }.disabled(!canRestore || model.snapshot == nil || model.journal.pending != nil || model.refreshing)
            if isPgy, model.settings.pgyNodes.contains(where: { $0.discoveryID == nil }) {
                Menu(L("移除手动节点")) {
                    ForEach(model.settings.pgyNodes.filter { $0.discoveryID == nil }) { node in
                        Button("\(node.name) · \(node.address)") { model.settings.pgyNodes.removeAll { $0.id == node.id } }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 16))
                .frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("更多操作"))
        .accessibilityLabel(L("更多操作"))
        .disabled(busy)
    }

    private var tableHeader: some View {
        HStack(spacing: 14) {
            Text(isPgy ? L("节点") : L("子网")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("当前路径")).frame(width: 150, alignment: .leading)
            Text(L("待应用")).frame(width: 96)
                .help(L("更改待应用的选择"))
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder private var pgyRows: some View {
        if model.settings.pgyNodes.isEmpty {
            emptyState(model.pgyUnavailable ? model.pgyUnavailableTitle : L("等待蒲公英节点列表"),
                       detail: model.pgyUnavailable ? nil : model.snapshot?.pgyDiscoveryNote.map { model.message($0) })
        }
        ForEach($model.settings.pgyNodes) { $node in
            let conflict = IPv4(node.address).flatMap { model.conflict(CIDR($0, 32)) }
            let member = model.snapshot?.pgyDiscovery?.members.first { $0.address == node.address }
            row(name: node.name, detail: node.address, monospaceName: false,
                presence: member.map { $0.online ? .online : .offline } ?? .unknown,
                reason: conflict, path: model.pgyPath(for: node.address),
                draft: $node.selected, blocked: conflict != nil && !node.selected)
        }
    }

    @ViewBuilder private var tailscaleRows: some View {
        let subnets = model.tailscaleSubnets
        if subnets.isEmpty { emptyState(L("未发现已批准的 IPv4 子网路由")) }
        ForEach(subnets) { subnet in
            let selected = model.settings.selectedSubnets.contains(subnet.id)
            let conflict = model.conflict(subnet.network)
            let reason = conflict ?? (!subnet.online ? L("子网路由器离线或不可用") : nil)
            row(name: subnet.id, detail: subnet.routers.sorted().joined(separator: " / "), monospaceName: true,
                reason: reason, path: model.tailscalePath(for: subnet.id),
                draft: Binding(get: { model.settings.selectedSubnets.contains(subnet.id) }, set: { enabled in
                    if enabled { model.settings.selectedSubnets.insert(subnet.id) }
                    else { model.settings.selectedSubnets.remove(subnet.id) }
                }), blocked: !selected && reason != nil)
        }
    }

    private func row(name: String, detail: String, monospaceName: Bool, presence: NodePresence? = nil, reason: String?,
                     path: RouteCoverage, draft: Binding<Bool>, blocked: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name).font(.system(size: 13, weight: .semibold, design: monospaceName ? .monospaced : .default))
                            .fixedSize(horizontal: false, vertical: true)
                        if let presence { NodePresenceBadge(presence: presence).fixedSize() }
                    }
                    .accessibilityElement(children: .combine)
                    if !detail.isEmpty {
                        Text(detail).font(monospaceName ? .caption : .caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let reason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RoutePathLabel(status: path).frame(width: 150, alignment: .leading)
                Toggle(isOn: draft) { Text(L("待应用：{0}", name)) }
                    .toggleStyle(.checkbox).labelsHidden().frame(width: 96)
                    .disabled(busy || blocked)
            }
            .padding(.vertical, 10)
            Divider()
        }
        .padding(.horizontal, 22)
    }

    private func emptyState(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash").font(.title2).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(32)
    }

    private var reviewBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("待应用 · 已选 {0} 项", selectedCount)).font(.callout.weight(.semibold))
                if !isPgy && model.snapshot?.tailscale?.hasIPv6Subnets == true {
                    StatusLine(message: L("检测到 IPv6 子网。本版无法安全开启混合选择；仍可关闭全部子网接收。"), symbol: "info.circle", color: .orange)
                }
                if model.applying {
                    StatusLine(message: L("等待管理员授权 / 应用并验证路由…"), symbol: "arrow.triangle.2.circlepath")
                } else if let check {
                    switch check {
                    case .ready:
                        StatusLine(message: check.message, symbol: "checkmark.circle")
                        if !isPgy && selectedCount == 0 && model.snapshot?.tailscale?.acceptsRoutes == true {
                            Text(L("不选任何子网将关闭子网接收。")).font(.caption).foregroundStyle(.secondary)
                        }
                    case .blocked: StatusLine(message: check.message, symbol: "exclamationmark.triangle", color: .orange)
                    case .waiting: StatusLine(message: check.message, symbol: "clock")
                    }
                }
            }
            Spacer(minLength: 6)
            Button(L("预览更改")) { model.prepare(isPgy ? .applyPgy : .applyTailscale) }
                .buttonStyle(.borderedProminent)
                .disabled(busy || model.refreshing || model.journal.pending != nil || check?.canReview != true)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Color.primary.opacity(0.035))
    }
}

private enum NodePresence {
    case online, offline, unknown
}

private struct NodePresenceBadge: View {
    let presence: NodePresence
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: (title: String, symbol: String, color: Color) {
        switch presence {
        case .online:
            return (L("在线"), "circle.fill", colorScheme == .dark
                    ? Color(red: 0.53, green: 0.90, blue: 0.64) : Color(red: 0.08, green: 0.38, blue: 0.22))
        case .offline:
            return (L("离线"), "minus.circle.fill", colorScheme == .dark
                    ? Color(red: 1.00, green: 0.69, blue: 0.64) : Color(red: 0.62, green: 0.18, blue: 0.13))
        case .unknown:
            return (L("状态未知"), "questionmark.circle", .secondary)
        }
    }

    var body: some View {
        let (title, symbol, color) = appearance
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: presence == .online ? 6 : 10))
                .frame(width: 10).accessibilityHidden(true)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct RoutePathLabel: View {
    let status: RouteCoverage
    private var presentation: (String, String, Color) {
        switch status {
        case .vpn: return (L("走此 VPN"), "checkmark.circle.fill", .green)
        case .other: return (L("不走此 VPN"), "minus.circle", .secondary)
        case .partial: return (L("部分走此 VPN"), "circle.lefthalf.filled", .orange)
        case .unverified: return (L("路由未确认"), "questionmark.circle", .secondary)
        }
    }
    var body: some View {
        let (title, image, color) = presentation
        Label(title, systemImage: image)
            .font(.caption).foregroundStyle(color)
    }
}

enum NodeEditorMode: String, Identifiable {
    case add, importList
    var id: Self { self }
}

struct NodeEditor: View {
    @ObservedObject var model: AppModel
    let mode: NodeEditorMode
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var importText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .add ? L("添加节点") : L("批量导入节点")).font(.headline)
            if mode == .add {
                TextField(L("节点名称（可选）"), text: $name)
                TextField(L("节点 IPv4"), text: $address)
            } else {
                Text(L("每行一个：名称,IPv4 或单独 IPv4。导入只保存列表，不会修改网络。"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $importText).font(.body.monospaced())
                    .frame(height: 170).border(Color.secondary.opacity(0.25))
            }
            HStack(spacing: 10) {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .add ? L("添加") : L("导入")) {
                    let saved = mode == .add ? model.addNode(name: name, ip: address) : model.importNodes(importText)
                    if saved { dismiss() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.applying || (mode == .add ? address : importText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: mode == .add ? 390 : 530)
        .routeBarError(model)
    }
}
