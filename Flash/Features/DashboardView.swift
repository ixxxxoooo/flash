import SwiftUI
import Charts
import FlashKit

/// 选中项使用带 ID 的玻璃，切换时在选项之间形变流动
private struct SelectedGlass: ViewModifier {
    var selected: Bool
    var ns: Namespace.ID

    func body(content: Content) -> some View {
        if selected {
            content
                .glassEffect(.regular.tint(Color.flashAccent.opacity(0.9)).interactive(), in: .capsule)
                .glassEffectID("selected-mode", in: ns)
        } else {
            content
        }
    }
}

struct ModeSwitcher: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(OutboundMode.allCases) { mode in
                    let selected = model.outboundMode == mode
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { model.outboundMode = mode }
                        Task { await model.setMode(mode) }
                    } label: {
                        Label(mode.title, systemImage: mode.icon)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
                            .modifier(SelectedGlass(selected: selected, ns: ns))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var topProcesses: [StatRow] = []
    @State private var todayTotal: DailyTotal?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader("概览", subtitle: subtitle) {
                    ModeSwitcher().glassEffect(.regular, in: .capsule)
                }
                .padding(.top, 8)

                HStack(alignment: .top, spacing: 16) {
                    powerCard.frame(maxWidth: 360)
                    speedCard
                }

                GlassEffectContainer(spacing: 16) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                        MetricTile(title: "下载", value: Fmt.rate(model.speed.down), systemImage: "arrow.down.circle.fill",
                                   tint: .downColor, subtitle: "本次 " + Fmt.bytes(model.sessionDown))
                        MetricTile(title: "上传", value: Fmt.rate(model.speed.up), systemImage: "arrow.up.circle.fill",
                                   tint: .upColor, subtitle: "本次 " + Fmt.bytes(model.sessionUp))
                        MetricTile(title: "活动连接", value: "\(model.active.count)", systemImage: "link",
                                   subtitle: "已关闭 \(model.closed.count)")
                        MetricTile(title: "内核内存", value: Fmt.bytes(model.memoryBytes), systemImage: "memorychip",
                                   tint: .purple, subtitle: "mihomo \(model.coreVersion)")
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    topProcessCard
                    subscriptionCard
                }
            }
            .padding(24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task(id: model.stats.revision) { await loadStats() }
    }

    private var subtitle: String {
        guard model.isRunning else { return "内核未运行" }
        return "混合代理端口 \(model.activePort) · \(model.outboundMode.title)模式"
    }

    // MARK: 电源 / 系统代理

    private var powerCard: some View {
        GlassCard {
            HStack(spacing: 18) {
                Button {
                    Task { await model.toggleCore() }
                } label: {
                    ZStack {
                        if model.busy || model.core.status.isBusy {
                            ProgressView().controlSize(.large)
                        } else {
                            Image(systemName: "power").font(.system(size: 30, weight: .semibold))
                        }
                    }
                    .frame(width: 72, height: 72)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(model.isRunning ? .green : .gray)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusText).font(.title2.weight(.semibold))
                    Text(model.isRunning ? "mihomo \(model.coreVersion)" : "点击电源按钮启动")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Divider()

            Toggle(isOn: Binding(get: { model.systemProxyOn }, set: { v in Task { await model.setSystemProxy(v) } })) {
                Label("设为系统代理", systemImage: "network")
            }
            .toggleStyle(.switch)
            .disabled(!model.isRunning)

            HStack(spacing: 6) {
                Pill(text: "HTTP/SOCKS 127.0.0.1:\(model.activePort == 0 ? model.settings.mixedPort : model.activePort)",
                     color: .flashAccent, systemImage: "arrow.left.arrow.right")
            }
        }
    }

    // MARK: 速率图

    private var speedCard: some View {
        GlassCard("实时速率", systemImage: "waveform.path.ecg") {
            Chart {
                ForEach(model.speedHistory, id: \.time) { s in
                    AreaMark(x: .value("时间", s.time), y: .value("速率", s.down), series: .value("方向", "下载"))
                        .foregroundStyle(by: .value("方向", "下载"))
                        .interpolationMethod(.monotone)
                        .opacity(0.22)
                    LineMark(x: .value("时间", s.time), y: .value("速率", s.down), series: .value("方向", "下载"))
                        .foregroundStyle(by: .value("方向", "下载"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("时间", s.time), y: .value("速率", s.up), series: .value("方向", "上传"))
                        .foregroundStyle(by: .value("方向", "上传"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["下载": Color.downColor, "上传": Color.upColor])
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine()
                    AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.compactRate(n)) } }
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 150)
        }
    }

    // MARK: 今日排行

    private var topProcessCard: some View {
        GlassCard("今日进程流量", systemImage: "app.badge") {
            if topProcesses.isEmpty {
                Text("暂无数据").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let maxValue = Double(topProcesses.map(\.total).max() ?? 1)
                VStack(spacing: 10) {
                    ForEach(topProcesses) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.key).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(row.total)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ProgressView(value: Double(row.total), total: maxValue).tint(.flashAccent)
                        }
                    }
                }
            }
            if let t = todayTotal {
                Divider()
                HStack {
                    Label(Fmt.bytes(t.down), systemImage: "arrow.down").foregroundStyle(Color.downColor)
                    Label(Fmt.bytes(t.up), systemImage: "arrow.up").foregroundStyle(Color.upColor)
                    Spacer()
                    Text("今日合计").font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: 订阅概览

    private var subscriptionCard: some View {
        GlassCard("订阅", systemImage: "antenna.radiowaves.left.and.right") {
            if model.subscriptions.items.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有订阅").foregroundStyle(.secondary)
                    Text("在「订阅」页添加链接，节点会自动并入策略组").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 14) {
                    ForEach(model.subscriptions.items.prefix(3)) { sub in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(sub.name).lineLimit(1)
                                Spacer()
                                Text("\(sub.nodeCount) 节点").font(.caption).foregroundStyle(.secondary)
                            }
                            if let u = sub.usage, u.total > 0 {
                                ProgressView(value: u.fraction).tint(u.fraction > 0.9 ? .red : .flashAccent)
                                Text("已用 \(Fmt.bytes64(u.used)) / \(Fmt.bytes64(u.total))" + (u.expire.map { " · \(Fmt.date($0)) 到期" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadStats() async {
        topProcesses = await model.stats.top(kind: .process, days: 1, limit: 5)
        todayTotal = await model.stats.dailyTotals(days: 1).last
    }
}
