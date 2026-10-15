import SwiftUI
import AppKit
import FlashKit

/// 请求详情中的「报文」标签：展示某个连接期间被 MitM 解密记录的 HTTP 报文
/// @author ygw
struct HTTPInspectorView: View {
    @Environment(AppModel.self) private var model
    var record: ConnectionRecord

    @State private var selectedID: UUID?

    /// 与该连接时间窗口、主机匹配的报文（依赖 recordRevision 触发刷新）
    private var exchanges: [HTTPExchange] {
        _ = model.mitm.recordRevision
        let from = record.startedAt.addingTimeInterval(-1)
        let to = (record.closedAt ?? Date()).addingTimeInterval(1)
        return model.mitm.recorder.exchanges(host: record.host, from: from, to: to).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        let list = exchanges
        VStack(alignment: .leading, spacing: 12) {
            if list.isEmpty {
                ContentUnavailableView("没有报文记录", systemImage: "doc.text.magnifyingglass",
                                       description: Text(model.settings.mitmEnabled
                                                         ? "该连接没有被解密（主机不在 [MITM] hostname 中，或客户端拒绝了证书）"
                                                         : "在设置中启用 MitM 并信任根证书后，命中 hostname 的 HTTPS 连接会在这里显示报文"))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                GlassCard("共 \(list.count) 条 HTTP 交换", systemImage: "arrow.left.arrow.right", padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(list) { e in
                            Button { selectedID = e.id } label: { row(e, selected: e.id == (selectedID ?? list.first?.id)) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if let e = list.first(where: { $0.id == selectedID }) ?? list.first {
                    ExchangeDetail(exchange: e)
                        .id(e.id)
                }
            }
        }
    }

    private func row(_ e: HTTPExchange, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(e.method).font(.caption.monospaced().weight(.semibold)).frame(width: 46, alignment: .leading)
            Text(path(of: e.url)).lineLimit(1).truncationMode(.middle).font(.caption)
            Spacer(minLength: 4)
            Text(e.statusCode == 0 ? "…" : "\(e.statusCode)").font(.caption.monospacedDigit())
                .foregroundStyle(statusColor(e.statusCode))
            Text(e.finished ? "\(Int(e.duration * 1000))ms" : "进行中").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(selected ? Color.flashAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private func path(of url: String) -> String {
        guard let u = URL(string: url) else { return url }
        let p = u.path.isEmpty ? "/" : u.path
        return u.query.map { "\(p)?\($0)" } ?? p
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        case 500...: .red
        default: .secondary
        }
    }
}

/// 单条 HTTP 交换的详情：请求 / 响应 × 头 / 体
struct ExchangeDetail: View {
    var exchange: HTTPExchange

    enum Side: String, CaseIterable { case request = "请求", response = "响应" }
    @State private var side: Side = .response
    @State private var mode: BodyFormatter.Mode = .auto

    private var headers: HeaderList { side == .request ? exchange.requestHeaders : exchange.responseHeaders }
    private var bodyData: Data { side == .request ? exchange.decodedRequestBody : exchange.decodedResponseBody }
    private var contentType: String? { side == .request ? exchange.requestHeader("Content-Type") : exchange.responseHeader("Content-Type") }
    private var truncated: Bool { side == .request ? exchange.requestBodyTruncated : exchange.responseBodyTruncated }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(exchange.method) \(exchange.url)").font(.caption).textSelection(.enabled).lineLimit(3)
            HStack {
                Picker("", selection: $side) { ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                Spacer()
                Button { copy(exchange.curlCommand) } label: { Label("cURL", systemImage: "terminal") }
                    .help("复制为 cURL 命令").controlSize(.small)
                Button { copy(BodyFormatter.format(bodyData, contentType: contentType, mode: mode == .hex ? .raw : mode)) } label: {
                    Label("Body", systemImage: "doc.on.doc")
                }
                .help("复制当前报文体").controlSize(.small).disabled(bodyData.isEmpty)
            }
            if !exchange.notes.isEmpty {
                ForEach(exchange.notes, id: \.self) { n in
                    Label(n, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.orange)
                }
            }
            GlassCard("Headers（\(headers.count)）", systemImage: "list.bullet", padding: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(h.name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(h.value).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            GlassCard("Body（\(Fmt.bytes(bodyData.count))\(truncated ? " · 已截断" : "")）", systemImage: "doc.plaintext", padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $mode) { ForEach(BodyFormatter.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    Text(BodyFormatter.format(bodyData, contentType: contentType, mode: mode))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
