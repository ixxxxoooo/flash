import SwiftUI
import Charts
import FlashKit

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 7
    @State private var kind: StatKind = .process
    @State private var rows: [StatRow] = []
    @State private var daily: [DailyTotal] = []

    private struct LoadKey: Hashable { var days: Int; var kind: StatKind; var revision: Int }

    private struct Segment: Identifiable {
        var id: String { key + series }
        var key: String; var series: String; var bytes: Int
    }

    private var segments: [Segment] {
        rows.flatMap { [Segment(key: $0.key, series: "下载", bytes: $0.down), Segment(key: $0.key, series: "上传", bytes: $0.up)] }
    }

    private var dailySegments: [Segment] {
        daily.flatMap { [Segment(key: $0.day, series: "下载", bytes: $0.down), Segment(key: $0.day, series: "上传", bytes: $0.up)] }
    }

    private var totalDown: Int { daily.reduce(0) { $0 + $1.down } }
    private var totalUp: Int { daily.reduce(0) { $0 + $1.up } }

    private func kindTitle(_ k: StatKind) -> String {
        switch k {
        case .process: "进程"
        case .host: "域名"
        case .policy: "策略"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader("统计", subtitle: "按天聚合的流量用量，数据保存在本机") {
                    HStack(spacing: 10) {
                        Picker("范围", selection: $days) {
                            Text("今天").tag(1); Text("7 天").tag(7); Text("30 天").tag(30)
                        }
                        .pickerStyle(.segmented).frame(width: 190)
                        Picker("维度", selection: $kind) {
                            ForEach(StatKind.allCases, id: \.self) { Text(kindTitle($0)).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 190)
                    }
                    .labelsHidden()
                }
                .padding(.top, 8)

                GlassEffectContainer(spacing: 16) {
                    HStack(spacing: 16) {
                        MetricTile(title: "下载合计", value: Fmt.bytes(totalDown), systemImage: "arrow.down.circle.fill", tint: .downColor)
                        MetricTile(title: "上传合计", value: Fmt.bytes(totalUp), systemImage: "arrow.up.circle.fill", tint: .upColor)
                        MetricTile(title: "连接数", value: "\(rows.reduce(0) { $0 + $1.connections })", systemImage: "link",
                                   subtitle: "当前维度合计")
                    }
                }

                GlassCard("每日流量", systemImage: "calendar") {
                    if daily.isEmpty {
                        empty
                    } else {
                        Chart(dailySegments) { item in
                            BarMark(x: .value("日期", String(item.key.suffix(5))), y: .value("流量", item.bytes))
                                .foregroundStyle(by: .value("方向", item.series))
                        }
                        .chartForegroundStyleScale(["下载": Color.downColor, "上传": Color.upColor])
                        .chartYAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.bytes(n)) } }
                            }
                        }
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
                        .frame(height: 200)
                    }
                }

                GlassCard("\(kindTitle(kind))排行 Top 10", systemImage: "list.number") {
                    if rows.isEmpty {
                        empty
                    } else {
                        Chart(segments) { seg in
                            BarMark(x: .value("流量", seg.bytes), y: .value("名称", seg.key))
                                .foregroundStyle(by: .value("方向", seg.series))
                        }
                        .chartForegroundStyleScale(["下载": Color.downColor, "上传": Color.upColor])
                        .chartYAxis { AxisMarks { AxisValueLabel().font(.callout) } }
                        .chartXAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.bytes(n)) } }
                            }
                        }
                        .frame(height: CGFloat(max(rows.count, 3)) * 34 + 30)
                    }
                }

                HStack {
                    Spacer()
                    Button("清除统计数据", role: .destructive) { Task { await model.stats.clear() } }
                        .buttonStyle(.glass)
                }
            }
            .padding(24)
        }
        .task(id: LoadKey(days: days, kind: kind, revision: model.stats.revision)) {
            rows = await model.stats.top(kind: kind, days: days, limit: 10)
            daily = await model.stats.dailyTotals(days: days)
        }
    }

    private var empty: some View {
        Text("暂无数据，开始使用代理后会在这里累积")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
    }
}
