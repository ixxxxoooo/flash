import SwiftUI
import AppKit
import FlashKit

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var level = "all"
    @State private var search = ""
    @State private var paused = false
    @State private var frozen: [LogEntry] = []

    private let levels = ["all", "debug", "info", "warning", "error"]
    private let order = ["debug": 0, "info": 1, "warning": 2, "error": 3]

    private var entries: [LogEntry] {
        let base = paused ? frozen : model.logs
        let q = search.lowercased()
        return base.filter { e in
            (level == "all" || (order[e.level.lowercased()] ?? 1) >= (order[level] ?? 0))
                && (q.isEmpty || e.message.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            PageHeader("日志", subtitle: "内核实时日志，最多保留 2000 条") {
                HStack(spacing: 10) {
                    Picker("级别", selection: $level) {
                        Text("全部").tag("all"); Text("调试").tag("debug"); Text("信息").tag("info")
                        Text("警告").tag("warning"); Text("错误").tag("error")
                    }
                    .frame(width: 100)
                    Button {
                        paused.toggle()
                        if paused { frozen = model.logs }
                    } label: { Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill") }
                        .buttonStyle(.glass)
                    Button { export() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.glass).disabled(model.logs.isEmpty)
                    Button { model.clearLogs(); frozen = [] } label: { Label("清空", systemImage: "trash") }
                        .buttonStyle(.glass).disabled(model.logs.isEmpty)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Fmt.clock(e.time)).foregroundStyle(.tertiary)
                                Text(e.level.uppercased()).frame(width: 52, alignment: .leading)
                                    .foregroundStyle(color(e.level)).fontWeight(.semibold)
                                Text(e.message).textSelection(.enabled)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .id(e.id)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.separator, lineWidth: 0.5) }
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView(model.isRunning ? "暂无日志" : "内核未运行", systemImage: "terminal")
                    }
                }
                .onChange(of: model.logs.count) { _, _ in
                    if !paused, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索日志")
    }

    private func color(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": .red
        case "warning", "warn": .orange
        case "debug": .secondary
        default: .flashAccent
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "flash-\(Fmt.date(Date())).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = model.logs.map { "\(Fmt.clock($0.time)) [\($0.level.uppercased())] \($0.message)" }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
