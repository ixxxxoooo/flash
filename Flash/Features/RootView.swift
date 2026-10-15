import SwiftUI
import FlashKit

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, traffic, stats, policies, subscriptions, profile, rules, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "概览"
        case .traffic: "请求"
        case .stats: "统计"
        case .policies: "策略"
        case .subscriptions: "订阅"
        case .profile: "配置"
        case .rules: "规则"
        case .logs: "日志"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .traffic: "list.bullet.rectangle.portrait"
        case .stats: "chart.bar.xaxis"
        case .policies: "point.3.connected.trianglepath.dotted"
        case .subscriptions: "antenna.radiowaves.left.and.right"
        case .profile: "doc.text"
        case .rules: "arrow.triangle.branch"
        case .logs: "terminal"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppSection? = {
        // 便于截图验收：--section=traffic 直接打开指定页面
        for a in ProcessInfo.processInfo.arguments where a.hasPrefix("--section=") {
            if let s = AppSection(rawValue: String(a.dropFirst("--section=".count))) { return s }
        }
        return .dashboard
    }()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("监控") {
                    row(.dashboard); row(.traffic); row(.stats)
                }
                Section("配置") {
                    row(.policies); row(.subscriptions); row(.profile); row(.rules)
                }
                Section("诊断") {
                    row(.logs)
                }
                Section {
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(10) }
        } detail: {
            detail
                .toolbar(removing: .title)
                // 工具栏不再绘制自己的白色底，直接透出下方统一的氛围背景
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background { AmbientBackground(active: model.isRunning).ignoresSafeArea() }
                .overlay(alignment: .bottom) {
                    // 提示横幅放在底部，避免遮挡页面顶部的标题与筛选控件
                    VStack(spacing: 8) {
                        if let msg = model.errorMessage {
                            Banner(message: msg) { model.errorMessage = nil }
                        }
                        if !model.conflictVPNs.isEmpty {
                            Banner(message: model.tunFailed
                                   ? "「\(model.conflictVPNs.map(\.name).joined(separator: "、"))」VPN 占用了路由，Flash 增强模式无法创建虚拟网卡，流量仍走它"
                                   : "「\(model.conflictVPNs.map(\.name).joined(separator: "、"))」VPN 接管了系统网络，Flash 的系统代理不会被应用读取，流量仍走它",
                                   tint: .red, actionTitle: "断开它", action: { Task { await model.disconnectConflictingVPNs() } }) {
                                model.dismissVPNConflict()
                            }
                        } else if let msg = model.noticeMessage {
                            Banner(message: msg, systemImage: "info.circle.fill", tint: .flashAccent) { model.noticeMessage = nil }
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(.smooth, value: model.errorMessage)
                    .animation(.smooth, value: model.noticeMessage)
                    .animation(.smooth, value: model.conflictVPNs)
                }
        }
    }

    private func row(_ s: AppSection) -> some View {
        NavigationLink(value: s) { Label(s.title, systemImage: s.icon) }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .traffic: TrafficView()
        case .stats: StatsView()
        case .policies: PoliciesView()
        case .subscriptions: SubscriptionsView()
        case .profile: ProfileView()
        case .rules: RulesView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}

/// 侧边栏底部的状态胶囊
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.isRunning ? Color.green : Color.secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusText).font(.caption.weight(.medium))
                if model.isRunning {
                    Text("↓\(Fmt.compactRate(model.speed.down))  ↑\(Fmt.compactRate(model.speed.up))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}
