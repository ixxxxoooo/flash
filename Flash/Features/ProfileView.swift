import SwiftUI
import FlashKit

struct ProfileView: View {
    enum Target: String, CaseIterable, Identifiable {
        case main = "主配置", overlay = "本地覆盖"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var target: Target = .main
    @State private var mainDraft = ""
    @State private var overlayDraft = ""
    @State private var loaded = false
    @State private var showManaged = false
    @State private var managedURL = ""
    @State private var managedError: String?
    @State private var importing = false

    private var profiles: ProfileStore { model.profiles }

    private var dirty: Bool {
        loaded && (mainDraft != profiles.mainText || overlayDraft != profiles.overlayText)
    }

    private var draft: Binding<String> { target == .main ? $mainDraft : $overlayDraft }
    private var editable: Bool { !(target == .main && profiles.isManaged) }

    var body: some View {
        VStack(spacing: 14) {
            PageHeader("配置", subtitle: "Surge 风格文本。本地覆盖层优先于主配置，更新受管配置时不会被覆盖") {
                HStack(spacing: 10) {
                    Picker("编辑对象", selection: $target) {
                        ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                    Menu {
                        Button("导入受管配置…") { showManaged = true }
                        if profiles.isManaged {
                            Button("立即更新受管配置") { Task { await profiles.refreshManaged(force: true) } }
                            Button("转为本地副本") { profiles.detachManaged(); mainDraft = profiles.mainText }
                        }
                        Divider()
                        Button("在本地覆盖中插入 MitM / 重写 / 脚本模板") { insertMitMTemplate() }
                        Divider()
                        Button("恢复默认主配置", role: .destructive) { profiles.resetToDefault(); mainDraft = profiles.mainText }
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).buttonStyle(.glass)
                    Button("还原") { mainDraft = profiles.mainText; overlayDraft = profiles.overlayText }
                        .buttonStyle(.glass).disabled(!dirty)
                    Button {
                        save()
                    } label: { Label("保存并应用", systemImage: "checkmark") }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!dirty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            if let m = profiles.managed {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Color.flashAccent)
                    Text("受管配置：\(m.url)").lineLimit(1).truncationMode(.middle)
                    if let u = profiles.managedUpdated { Text("· 更新于 \(Fmt.relative(u))").foregroundStyle(.secondary) }
                    Spacer()
                    if let e = profiles.managedError { Text(e).foregroundStyle(.red).lineLimit(1) }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 24)
            }

            CodeEditor(text: draft, isEditable: editable)
                .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.separator, lineWidth: 0.5) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 24)

            summary
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .onAppear {
            if !loaded { mainDraft = profiles.mainText; overlayDraft = profiles.overlayText; loaded = true }
        }
        .onChange(of: profiles.mainText) { _, v in if !dirty || mainDraft.isEmpty { mainDraft = v } }
        .sheet(isPresented: $showManaged) { managedSheet }
    }

    /// 把 MitM / 重写 / 脚本的示例段落追加到本地覆盖，并切换到该标签
    private func insertMitMTemplate() {
        let template = """


        # ===== MitM 与重写示例（取消注释后保存即可；需在设置里信任根证书并开启 MitM）=====
        [MITM]
        # hostname = *.example.com, api.example.com:8443, -skip.example.com

        [URL Rewrite]
        # ^https?://ad\\.example\\.com/ - reject
        # ^https://old\\.example\\.com/(.*) https://new.example.com/$1 302

        [Header Rewrite]
        # http-request ^https://api\\.example\\.com/ header-add X-Debug 1
        # http-response ^https://api\\.example\\.com/ header-del Set-Cookie

        [Map Local]
        # ^https://api\\.example\\.com/ping data-type=text data="{"ok":true}" status-code=200 header="Content-Type:application/json"

        [Script]
        # demo = type=http-response, pattern=^https://api\\.example\\.com/, script-path=/path/to/demo.js, requires-body=true
        """
        target = .overlay
        if !overlayDraft.contains("[MITM]") { overlayDraft += template }
    }

    private func save() {
        if !profiles.isManaged, mainDraft != profiles.mainText { profiles.saveMain(mainDraft) }
        profiles.saveOverlay(overlayDraft)
        model.noticeMessage = "配置已保存并应用"
    }

    // MARK: 摘要与诊断

    private var summary: some View {
        let c = model.composed
        return GlassCard(padding: 12) {
            HStack(spacing: 14) {
                Label("\(c.nodes.count) 节点", systemImage: "server.rack")
                Label("\(c.groups.count) 策略组", systemImage: "point.3.connected.trianglepath.dotted")
                Label("\(c.rules.count) 规则", systemImage: "arrow.triangle.branch")
                Label("\(c.ruleProviders.count) 规则集", systemImage: "tray.full")
                if !c.mitm.isEmpty {
                    Label("MitM \(c.mitm.hostPatterns.count) 主机 · \(c.mitm.urlRewrites.count + c.mitm.headerRewrites.count) 重写 · \(c.mitm.mapLocals.count) 映射 · \(c.mitm.scripts.count) 脚本",
                          systemImage: "lock.open.display")
                }
                Spacer()
                if c.diagnostics.isEmpty {
                    Pill(text: "无问题", color: .green, systemImage: "checkmark.circle")
                } else {
                    Pill(text: "\(c.diagnostics.count) 条提示", color: .orange, systemImage: "exclamationmark.triangle")
                }
            }
            .font(.callout)
            if !c.diagnostics.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(c.diagnostics) { d in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: d.severity == .error ? "xmark.octagon.fill" : (d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                                    .foregroundStyle(d.severity == .error ? .red : (d.severity == .warning ? .orange : .secondary))
                                    .font(.caption)
                                if d.line > 0 { Text("第 \(d.line) 行").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                Text(d.message).font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    private var managedSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入受管配置").font(.title2.weight(.semibold))
            Text("输入以 #!MANAGED-CONFIG 声明的 Surge 配置链接，将自动下载并按间隔更新。").font(.callout).foregroundStyle(.secondary)
            TextField("https://…", text: $managedURL).textFieldStyle(.roundedBorder)
            if let managedError { Label(managedError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { showManaged = false }.buttonStyle(.glass)
                Button {
                    Task {
                        importing = true; defer { importing = false }
                        do {
                            try await profiles.importManaged(url: managedURL.trimmingCharacters(in: .whitespacesAndNewlines))
                            mainDraft = profiles.mainText
                            showManaged = false
                            managedError = nil
                        } catch { managedError = error.localizedDescription }
                    }
                } label: { if importing { ProgressView().controlSize(.small) } else { Text("导入") } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importing || managedURL.isEmpty)
            }
        }
        .padding(24).frame(width: 480)
    }
}
