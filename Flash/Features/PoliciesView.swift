import SwiftUI
import FlashKit

struct PoliciesView: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<String> = []

    private var groups: [PolicyInfo] {
        var list = model.orderedGroups
        // 全局模式下，实际生效的是 GLOBAL 组，放到最前面
        if model.outboundMode == .global, let g = model.policies["GLOBAL"] { list.insert(g, at: 0) }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader("策略", subtitle: "点击节点切换手动选择组；右上角可对整组测速") {
                    HStack(spacing: 10) {
                        ModeSwitcher().glassEffect(.regular, in: .capsule)
                        Button {
                            Task { await model.testAll() }
                        } label: {
                            Label("全部测速", systemImage: "speedometer")
                        }
                        .buttonStyle(.glass)
                        .disabled(!model.isRunning || !model.testingGroups.isEmpty)
                    }
                }
                .padding(.top, 8)

                if !model.isRunning {
                    ContentUnavailableView {
                        Label("内核未运行", systemImage: "power")
                    } description: {
                        Text("启动内核后即可查看并切换策略组")
                    } actions: {
                        Button("启动内核") { Task { await model.startCore() } }.buttonStyle(.glassProminent)
                    }
                    .frame(minHeight: 320)
                } else if groups.isEmpty {
                    ContentUnavailableView("没有策略组", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("请在「配置」页的 [Proxy Group] 中定义策略组"))
                        .frame(minHeight: 320)
                } else {
                    if model.outboundMode == .global {
                        Banner(message: "当前为全局代理模式：所有流量使用 GLOBAL 组的选择，规则不生效",
                               systemImage: "globe", tint: .flashAccent) { model.outboundMode = .rule; Task { await model.setMode(.rule) } }
                            .padding(.horizontal, -24)
                    }
                    ForEach(groups) { group in
                        GroupCard(group: group, collapsed: collapsed.contains(group.name)) {
                            withAnimation(.smooth) {
                                if collapsed.contains(group.name) { collapsed.remove(group.name) } else { collapsed.insert(group.name) }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct GroupCard: View {
    @Environment(AppModel.self) private var model
    var group: PolicyInfo
    var collapsed: Bool
    var toggle: () -> Void

    private var typeTitle: String {
        switch group.type {
        case "Selector": "手动选择"
        case "URLTest": "自动测速"
        case "Fallback": "故障转移"
        case "LoadBalance": "负载均衡"
        case "Relay": "链式代理"
        default: group.type
        }
    }

    private var typeColor: Color {
        switch group.type {
        case "Selector": .flashAccent
        case "URLTest": .green
        case "Fallback": .orange
        default: .purple
        }
    }

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 14)
                }
                .buttonStyle(.plain)
                Text(group.name).font(.headline)
                Pill(text: typeTitle, color: typeColor)
                Text("→ \(group.now)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(group.all.count) 项").font(.caption).foregroundStyle(.tertiary)
                Button {
                    Task { await model.testGroup(group.name) }
                } label: {
                    if model.testingGroups.contains(group.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "speedometer")
                    }
                }
                .buttonStyle(.glass)
                .help("测速")
                .disabled(model.testingGroups.contains(group.name))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if !collapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)], spacing: 8) {
                    ForEach(group.all, id: \.self) { name in
                        MemberChip(name: name, selected: name == group.now, selectable: group.isSelectable) {
                            Task { await model.select(group: group.name, policy: name) }
                        }
                    }
                }
            }
        }
    }
}

struct MemberChip: View {
    @Environment(AppModel.self) private var model
    var name: String
    var selected: Bool
    var selectable: Bool
    var action: () -> Void

    private var info: PolicyInfo? { model.policies[name] }

    private var subtitle: String {
        guard let t = info?.type else { return "" }
        switch t {
        case "Shadowsocks": return "SS"
        case "ShadowsocksR": return "SSR"
        case "Selector", "URLTest", "Fallback", "LoadBalance": return "策略组"
        case "Direct": return "直连"
        case "Reject": return "拒绝"
        default: return t
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let d = model.delay(of: name) {
                    Text(d > 0 ? "\(d) ms" : "超时")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.delayColor(d))
                }
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.flashAccent) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.flashAccent.opacity(0.16) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.flashAccent.opacity(0.7) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }
}
