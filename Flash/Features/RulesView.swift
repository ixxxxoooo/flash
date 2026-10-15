import SwiftUI
import FlashKit

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var host = ""
    @State private var port = ""
    @State private var process = ""
    @State private var result: RuleSimulator.Result?
    @State private var tested = false

    private var rules: [DisplayRule] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.displayRules
        guard !q.isEmpty else { return all }
        return all.filter { $0.type.lowercased().contains(q) || $0.payload.lowercased().contains(q) || $0.policy.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 14) {
            PageHeader("规则", subtitle: "共 \(model.displayRules.count) 条，自上而下匹配，首条命中即生效")
                .padding(.horizontal, 24).padding(.top, 8)

            GlassCard("规则测试", systemImage: "scope", padding: 14) {
                HStack(spacing: 10) {
                    TextField("域名或 IP，例如 github.com", text: $host).textFieldStyle(.roundedBorder).onSubmit(run)
                    TextField("端口", text: $port).textFieldStyle(.roundedBorder).frame(width: 80).onSubmit(run)
                    TextField("进程（可选）", text: $process).textFieldStyle(.roundedBorder).frame(width: 150).onSubmit(run)
                    Button("测试", action: run).buttonStyle(.glassProminent).disabled(host.isEmpty)
                }
                if tested {
                    if let r = result {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("命中第 \(r.index + 1) 条：").foregroundStyle(.secondary)
                            Text(r.rule.body).font(.callout.monospaced())
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            PolicyBadge(policy: r.rule.policy, text: r.rule.policy)
                            Spacer()
                        }
                        if !r.skipped.isEmpty {
                            Text("有 \(r.skipped.count) 条规则（GEOIP / 规则集）缺少本地数据而被跳过，实际结果以内核为准")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Label("没有规则命中", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)

            Table(rules) {
                TableColumn("#") { r in Text("\(r.id + 1)").monospacedDigit().foregroundStyle(.secondary) }.width(50)
                TableColumn("类型") { r in Text(r.type).font(.callout.monospaced()) }.width(min: 120, ideal: 160)
                TableColumn("内容") { r in Text(r.payload).lineLimit(1).truncationMode(.middle) }
                TableColumn("策略") { r in PolicyBadge(policy: r.policy, text: r.policy) }.width(min: 90, ideal: 130)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if rules.isEmpty {
                    ContentUnavailableView("没有规则", systemImage: "arrow.triangle.branch",
                                           description: Text("在「配置」页的 [Rule] 段添加规则"))
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索类型、内容、策略")
    }

    private func run() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        let isIP = h.split(separator: ".").count == 4 && h.allSatisfy { $0.isNumber || $0 == "." }
        let q = RuleSimulator.Query(host: isIP ? "" : h, ip: isIP ? h : nil, port: Int(port),
                                    process: process.isEmpty ? nil : process, network: "tcp")
        result = RuleSimulator.match(rules: model.composed.rules, query: q)
        tested = true
    }
}
