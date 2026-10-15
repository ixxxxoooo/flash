import SwiftUI
import AppKit
import FlashKit

struct SubscriptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var renaming: Subscription?
    @State private var renameText = ""
    @State private var deleting: Subscription?

    private var manager: SubscriptionManager { model.subscriptions }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader("订阅", subtitle: "支持 Clash YAML、分享链接（ss / vmess / trojan / vless / hysteria2 / tuic）、Base64 与 Surge 配置") {
                    HStack(spacing: 10) {
                        Button {
                            Task { await manager.updateAll(onlyDue: false) }
                        } label: { Label("全部更新", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.glass)
                            .disabled(manager.items.isEmpty || !manager.updating.isEmpty || model.isDemo)
                        Button { showAdd = true } label: { Label("添加订阅", systemImage: "plus") }
                            .buttonStyle(.glassProminent)
                    }
                }
                .padding(.top, 8)

                if manager.items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有订阅", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("添加机场订阅链接后，节点会并入策略组，并按间隔自动更新")
                    } actions: {
                        Button("添加订阅") { showAdd = true }.buttonStyle(.glassProminent)
                    }
                    .frame(minHeight: 320)
                } else {
                    ForEach(manager.items) { sub in
                        SubscriptionCard(sub: sub,
                                         onRename: { renaming = sub; renameText = sub.name },
                                         onDelete: { deleting = sub })
                    }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showAdd) { AddSubscriptionSheet().environment(model) }
        .alert("重命名订阅", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") { if let r = renaming { manager.rename(r.id, to: renameText) } }
        }
        .confirmationDialog("删除订阅「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let d = deleting { manager.remove(d.id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("其节点将从策略组中移除，此操作无法撤销。")
        }
    }
}

struct SubscriptionCard: View {
    @Environment(AppModel.self) private var model
    var sub: Subscription
    var onRename: () -> Void
    var onDelete: () -> Void

    private var manager: SubscriptionManager { model.subscriptions }

    private var host: String {
        if sub.isLocal { return "本地导入" }
        return URL(string: sub.url)?.host ?? sub.url
    }

    var body: some View {
        GlassCard(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sub.isLocal ? "doc.on.clipboard" : "link.circle.fill")
                    .font(.title).foregroundStyle(Color.flashAccent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(sub.name).font(.headline)
                        Pill(text: "\(sub.nodeCount) 节点", color: .flashAccent)
                        if let f = sub.format { Pill(text: f.rawValue, color: .secondary) }
                    }
                    Text(host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { sub.enabled }, set: { manager.setEnabled(sub.id, $0) }))
                    .toggleStyle(.switch).labelsHidden()
                if !sub.isLocal {
                    Button {
                        Task { _ = await manager.update(sub.id, force: true) }
                    } label: {
                        if manager.updating.contains(sub.id) { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .buttonStyle(.glass)
                    .help("立即更新")
                    .disabled(manager.updating.contains(sub.id) || model.isDemo)
                }
                Menu {
                    Button("重命名…", action: onRename)
                    if !sub.isLocal {
                        Menu("更新间隔") {
                            ForEach([6, 12, 24, 48, 168], id: \.self) { h in
                                Button { manager.setInterval(sub.id, hours: h) } label: {
                                    Label(h == 168 ? "每周" : "每 \(h) 小时", systemImage: sub.intervalHours == h ? "checkmark" : "")
                                }
                            }
                        }
                        Button("复制订阅链接") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sub.url, forType: .string)
                        }
                    }
                    Divider()
                    Button("删除", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
            }

            if let u = sub.usage, u.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: u.fraction).tint(u.fraction > 0.9 ? .red : (u.fraction > 0.75 ? .orange : .flashAccent))
                    HStack {
                        Text("已用 \(Fmt.bytes64(u.used)) / \(Fmt.bytes64(u.total))")
                        Text("· 剩余 \(Fmt.bytes64(u.remaining))")
                        Spacer()
                        if let e = u.expire {
                            let days = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0
                            Label(days < 0 ? "已过期" : "\(Fmt.date(e)) 到期（\(days) 天）", systemImage: "calendar")
                                .foregroundStyle(days < 7 ? .orange : .secondary)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if let t = sub.lastUpdated {
                    Label("更新于 \(Fmt.relative(t))", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                if !sub.isLocal {
                    Label("每 \(sub.intervalHours) 小时自动更新", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if let err = sub.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .opacity(sub.enabled ? 1 : 0.6)
    }
}

struct AddSubscriptionSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case url = "订阅链接", text = "粘贴内容"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .url
    @State private var name = ""
    @State private var url = ""
    @State private var text = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加订阅").font(.title2.weight(.semibold))
            Picker("方式", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            TextField("名称（可选）", text: $name).textFieldStyle(.roundedBorder)
            if mode == .url {
                TextField("https://…", text: $url).textFieldStyle(.roundedBorder)
                Text("将下载并识别格式，读取流量与到期信息").font(.caption).foregroundStyle(.secondary)
            } else {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("支持分享链接列表、Clash YAML、Base64 文本").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.buttonStyle(.glass)
                Button {
                    Task { await submit() }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("添加") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || (mode == .url ? url.trimmingCharacters(in: .whitespaces).isEmpty : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func submit() async {
        working = true
        error = nil
        defer { working = false }
        do {
            switch mode {
            case .url:
                let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                let n = name.isEmpty ? (URL(string: u)?.host ?? "订阅") : name
                _ = try await model.subscriptions.add(name: n, url: u)
            case .text:
                _ = try model.subscriptions.importText(name: name, text: text)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
