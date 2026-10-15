import SwiftUI
import AppKit
import FlashKit

struct TrafficView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case active = "活动", closed = "已关闭", all = "全部"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var scope: Scope = .active
    @State private var search = ""
    @State private var policyFilter: String?
    @State private var processFilter: String?
    @State private var selection: Set<String> = []
    @State private var showInspector = false
    @State private var sortOrder = [KeyPathComparator(\ConnectionRecord.startedAt, order: .reverse)]

    private var source: [ConnectionRecord] {
        switch scope {
        case .active: model.active
        case .closed: model.closed
        case .all: model.active + model.closed
        }
    }

    private var rows: [ConnectionRecord] {
        var list = source
        if let p = policyFilter { list = list.filter { $0.policy == p } }
        if let p = processFilter { list = list.filter { $0.displayProcess == p } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.host.lowercased().contains(q) || $0.process.lowercased().contains(q)
                    || $0.destinationIP.contains(q) || $0.ruleText.lowercased().contains(q) || $0.chainText.lowercased().contains(q)
            }
        }
        if list.count > 3000 { list = Array(list.prefix(3000)) }
        return list.sorted(using: sortOrder)
    }

    private var selectedRecord: ConnectionRecord? {
        guard let id = selection.first else { return nil }
        return (model.active + model.closed).first { $0.id == id }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            PageHeader("请求", subtitle: "\(model.active.count) 个活动连接 · 历史 \(model.closed.count) 条") {
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("时间", value: \.startedAt) { r in
                    Text(Fmt.clock(r.startedAt)).monospacedDigit().foregroundStyle(r.isActive ? .primary : .secondary)
                }
                .width(min: 64, ideal: 70, max: 80)

                TableColumn("进程", value: \.displayProcess) { r in
                    HStack(spacing: 6) {
                        Image(nsImage: ProcessIcon.image(path: r.processPath, name: r.process)).resizable().frame(width: 16, height: 16)
                        Text(r.displayProcess).lineLimit(1)
                    }
                }
                .width(min: 100, ideal: 130)

                TableColumn("目标", value: \.endpoint) { r in
                    Text(r.endpoint).lineLimit(1).truncationMode(.middle)
                }
                .width(min: 160, ideal: 240)

                TableColumn("协议", value: \.network) { r in
                    Text(r.network.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .width(44)

                TableColumn("规则", value: \.ruleText) { r in
                    Text(r.ruleText).lineLimit(1).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 170)

                TableColumn("策略", value: \.chainText) { r in
                    PolicyBadge(policy: r.policy, text: r.chainText)
                }
                .width(min: 100, ideal: 170)

                TableColumn("↓", value: \.download) { r in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Fmt.bytes(r.download)).monospacedDigit()
                        if r.isActive, r.downSpeed > 0 {
                            Text(Fmt.rate(r.downSpeed)).font(.caption2).foregroundStyle(Color.downColor).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)

                TableColumn("↑", value: \.upload) { r in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Fmt.bytes(r.upload)).monospacedDigit()
                        if r.isActive, r.upSpeed > 0 {
                            Text(Fmt.rate(r.upSpeed)).font(.caption2).foregroundStyle(Color.upColor).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                contextMenu(for: ids)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(model.isRunning ? "没有匹配的连接" : "内核未运行",
                                           systemImage: "network.slash",
                                           description: Text(model.isRunning ? "调整筛选条件，或让应用发起一些网络请求" : "启动内核后，经过代理的连接会实时显示在这里"))
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索主机、进程、规则")
        .toolbar {
            ToolbarItemGroup {
                filterMenu
                Button { Task { await model.closeAllConnections() } } label: {
                    Label("断开全部", systemImage: "scissors")
                }
                .help("断开所有活动连接")
                .disabled(model.active.isEmpty)
                Button { model.clearHistory() } label: { Label("清空历史", systemImage: "trash") }
                    .help("清空已关闭连接历史")
                    .disabled(model.closed.isEmpty)
                Button { showInspector.toggle() } label: { Label("详情", systemImage: "sidebar.trailing") }
                    .help("显示 / 隐藏详情")
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let r = selectedRecord {
                    ConnectionDetail(record: r)
                } else {
                    ContentUnavailableView("未选择连接", systemImage: "cursorarrow.click", description: Text("在表格中选择一条连接查看详情"))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
        .onChange(of: selection) { _, new in if !new.isEmpty { showInspector = true } }
    }

    // MARK: 筛选菜单

    private var filterMenu: some View {
        Menu {
            Menu("按策略") {
                Button("全部") { policyFilter = nil }
                Divider()
                ForEach(Array(Set(source.map(\.policy))).sorted(), id: \.self) { p in
                    Button { policyFilter = p } label: { Label(p, systemImage: policyFilter == p ? "checkmark" : "") }
                }
            }
            Menu("按进程") {
                Button("全部") { processFilter = nil }
                Divider()
                ForEach(Array(Set(source.map(\.displayProcess))).sorted(), id: \.self) { p in
                    Button { processFilter = p } label: { Label(p, systemImage: processFilter == p ? "checkmark" : "") }
                }
            }
            if policyFilter != nil || processFilter != nil {
                Divider()
                Button("清除筛选") { policyFilter = nil; processFilter = nil }
            }
        } label: {
            Label("筛选", systemImage: policyFilter != nil || processFilter != nil
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let all = model.active + model.closed
        let records = all.filter { ids.contains($0.id) }
        if let r = records.first {
            Button("复制主机") { copy(r.host.isEmpty ? r.destinationIP : r.host) }
            Button("复制连接信息") { copy("\(r.process) → \(r.endpoint) [\(r.ruleText)] \(r.chainText)") }
            Divider()
            let domain = r.host.isEmpty ? nil : registrableDomain(r.host)
            if let domain {
                Menu("为 \(domain) 添加规则") {
                    Button("直连") { model.addOverlayRule(type: "DOMAIN-SUFFIX", value: domain, policy: "DIRECT") }
                    Button("走代理") { model.addOverlayRule(type: "DOMAIN-SUFFIX", value: domain, policy: model.orderedGroups.first?.name ?? "Proxy") }
                    Button("拒绝") { model.addOverlayRule(type: "DOMAIN-SUFFIX", value: domain, policy: "REJECT") }
                }
            }
            if r.isActive {
                Divider()
                Button("断开连接", role: .destructive) {
                    for rec in records where rec.isActive { Task { await model.closeConnection(rec.id) } }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// 策略徽标：DIRECT 绿色，REJECT 红色，其余强调色
struct PolicyBadge: View {
    var policy: String
    var text: String

    private var color: Color {
        switch policy {
        case "DIRECT": .green
        case "REJECT", "REJECT-DROP": .red
        default: .flashAccent
        }
    }

    var body: some View {
        Text(text).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 连接详情检查器
struct ConnectionDetail: View {
    var record: ConnectionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(nsImage: ProcessIcon.image(path: record.processPath, name: record.process))
                        .resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayProcess).font(.headline)
                        Text(record.isActive ? "活动中" : "已关闭").font(.caption)
                            .foregroundStyle(record.isActive ? .green : .secondary)
                    }
                }

                GlassCard(padding: 12) {
                    detail("目标", record.endpoint)
                    if !record.destinationIP.isEmpty { detail("目标 IP", record.destinationIP) }
                    detail("来源", "\(record.sourceIP):\(record.sourcePort)")
                    detail("协议", "\(record.network.uppercased()) · \(record.inboundType)")
                    detail("匹配规则", record.ruleText)
                }

                GlassCard("出站链路", systemImage: "arrow.triangle.turn.up.right.diamond", padding: 12) {
                    let steps = ["本机"] + record.chains.reversed() + [record.host.isEmpty ? record.destinationIP : record.host]
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 8) {
                                Image(systemName: i == 0 ? "laptopcomputer" : (i == steps.count - 1 ? "globe" : "arrow.down"))
                                    .frame(width: 16).foregroundStyle(.secondary)
                                Text(s).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.callout)
                        }
                    }
                }

                GlassCard("流量", systemImage: "arrow.up.arrow.down", padding: 12) {
                    detail("下载", Fmt.bytes(record.download))
                    detail("上传", Fmt.bytes(record.upload))
                    if record.isActive {
                        detail("下载速率", Fmt.rate(record.downSpeed))
                        detail("上传速率", Fmt.rate(record.upSpeed))
                    }
                    detail("开始", Fmt.clock(record.startedAt))
                    detail("持续", Fmt.duration(record.duration))
                }

                if !record.processPath.isEmpty {
                    Text(record.processPath).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}
