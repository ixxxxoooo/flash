import SwiftUI
import AppKit
import FlashKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var pendingRestart = false
    @State private var mitmMessage: String?

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("通用") {
                Toggle("启动应用时自动开启内核", isOn: $settings.startCoreOnLaunch)
                Toggle("内核启动后自动设为系统代理", isOn: $settings.autoSystemProxy)
                Toggle("开机自动启动", isOn: Binding(get: { launchAtLogin }, set: { v in
                    do { try model.settings.setLaunchAtLogin(v); launchAtLogin = v; launchError = nil }
                    catch { launchError = error.localizedDescription; launchAtLogin = model.settings.launchAtLogin }
                }))
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                Toggle("菜单栏显示实时速率", isOn: $settings.showMenuBarSpeed)
            }

            Section {
                HStack {
                    Text("混合代理端口（HTTP + SOCKS5）")
                    Spacer()
                    TextField("", value: $settings.mixedPort, format: .number.grouping(.never))
                        .frame(width: 80).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        .onChange(of: settings.mixedPort) { _, _ in pendingRestart = true }
                }
                Toggle("允许局域网设备连接", isOn: $settings.allowLan).onChange(of: settings.allowLan) { _, _ in pendingRestart = true }
                Toggle("启用 IPv6", isOn: $settings.ipv6).onChange(of: settings.ipv6) { _, _ in pendingRestart = true }
                Picker("内核日志级别", selection: $settings.logLevel) {
                    Text("调试").tag("debug"); Text("信息").tag("info"); Text("警告").tag("warning"); Text("错误").tag("error")
                }
                .onChange(of: settings.logLevel) { _, _ in pendingRestart = true }
                if pendingRestart && model.core.status.isRunning {
                    HStack {
                        Label("以上更改需要重启内核后生效", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
                        Spacer()
                        Button("立即重启") { pendingRestart = false; Task { await model.restartCore() } }
                            .buttonStyle(.glassProminent)
                    }
                }
            } header: { Text("网络") }

            tunSection(settings: settings)

            mitmSection(settings: settings)

            Section("数据") {
                Stepper(value: $settings.historyLimit, in: 500...50000, step: 500) {
                    HStack { Text("已关闭连接历史上限"); Spacer(); Text("\(settings.historyLimit) 条").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("清除流量统计", role: .destructive) { Task { await model.stats.clear() } }
                    Button("打开数据目录") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDir]) }
                    Button("打开内核日志") { NSWorkspace.shared.open(AppPaths.coreLog) }
                }
            }

            Section("内核") {
                LabeledContent("状态", value: model.statusText)
                LabeledContent("版本", value: "mihomo \(model.coreVersion)")
                LabeledContent("路径") {
                    Text(CoreLocator.binary()?.path ?? "未找到").font(.caption).textSelection(.enabled)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("重启内核") { Task { await model.restartCore() } }.disabled(model.isDemo || model.busy)
                    Button("重新加载配置") { Task { await model.applyConfig() } }.disabled(!model.core.status.isRunning)
                    Button("清空 DNS 缓存") { Task { try? await model.core.client?.flushDNS() } }.disabled(!model.core.status.isRunning)
                }
            }

            Section("关于") {
                LabeledContent("Flash", value: "v\(bundleVersion)")
                Text("Flash 使用 mihomo（Clash Meta）作为代理内核，遵循 GPL-3.0 协议开源。可通过系统代理与本地端口接管流量，也可在上方安装并启用增强模式（TUN）。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("mihomo 项目主页", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { launchAtLogin = model.settings.launchAtLogin; model.tunInstalled = PrivilegedCore.isInstalled }
    }

    /// 增强模式（TUN）设置区
    /// - Parameter settings: 应用设置
    @ViewBuilder
    private func tunSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("组件状态") {
                if model.tunBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(model.tunInstalled ? "已安装" : "未安装").foregroundStyle(model.tunInstalled ? .green : .secondary)
                }
            }
            Toggle("启用增强模式（TUN，接管所有应用的流量）", isOn: $settings.tunEnabled)
                .disabled(!model.tunInstalled)
                .onChange(of: settings.tunEnabled) { _, _ in pendingRestart = true }
            Picker("协议栈", selection: $settings.tunStack) {
                Text("混合（推荐）").tag("mixed"); Text("系统").tag("system"); Text("gVisor").tag("gvisor")
            }
            .disabled(!model.tunInstalled)
            .onChange(of: settings.tunStack) { _, _ in pendingRestart = true }
            if model.tunActive {
                Label("增强模式运行中", systemImage: "bolt.horizontal.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Button(model.tunInstalled ? "重新安装 / 升级组件" : "安装增强模式组件") { Task { await model.installTun() } }
                    .disabled(model.tunBusy || model.isDemo)
                if model.tunInstalled {
                    Button("卸载组件", role: .destructive) { Task { await model.uninstallTun() } }
                        .disabled(model.tunBusy || model.isDemo)
                }
            }
            if pendingRestart && model.core.status.isRunning {
                HStack {
                    Label("增强模式更改需要重启内核后生效", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
                    Spacer()
                    Button("立即重启") { pendingRestart = false; Task { await model.restartCore() } }
                        .buttonStyle(.glassProminent)
                }
            }
            Text("无需开发者账号：安装时需要一次管理员授权，把内核放到系统目录并注册后台服务；之后开关内核无需再输入密码。运行在 root 权限，请仅在自己的 Mac 上使用。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("增强模式") }
    }

    /// MitM（HTTPS 解密）设置区
    /// - Parameter settings: 应用设置
    @ViewBuilder
    private func mitmSection(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        let mitm = model.mitm
        Section {
            LabeledContent("根证书") {
                Text(!mitm.caGenerated ? "未生成" : (mitm.caTrusted ? "已生成并受信任" : "已生成，未信任"))
                    .foregroundStyle(mitm.caTrusted ? .green : .secondary)
            }
            HStack {
                if !mitm.caGenerated {
                    Button("生成根证书") { Task { mitmMessage = await mitm.generateCA() } }
                } else {
                    Button(mitm.caTrusted ? "重新信任" : "安装并信任") { Task { mitmMessage = await mitm.trustCA() } }
                        .disabled(mitm.busy)
                    Button("导出") { mitmMessage = mitm.exportCA() }
                    Button("移除信任", role: .destructive) { Task { mitmMessage = await mitm.untrustCA() } }
                        .disabled(mitm.busy || !mitm.caTrusted)
                    Button("重新生成", role: .destructive) { Task { mitmMessage = await mitm.regenerateCA() } }
                }
            }
            Toggle("启用 MitM（解密配置中 [MITM] hostname 列出的站点）", isOn: $settings.mitmEnabled)
                .disabled(!mitm.caTrusted)
                .onChange(of: settings.mitmEnabled) { _, _ in Task { await model.applyConfig() } }
            Toggle("记录解密后的 HTTP 报文（请求页「报文」标签）", isOn: $settings.mitmRecord)
                .onChange(of: settings.mitmRecord) { _, v in mitm.recorder.enabled = v }
            LabeledContent("监听的主机名", value: "\(model.composed.mitm.hostPatterns.count) 条")
            LabeledContent("改写 / 本地映射 / 脚本",
                           value: "\(model.composed.mitm.urlRewrites.count + model.composed.mitm.headerRewrites.count) / \(model.composed.mitm.mapLocals.count) / \(model.composed.mitm.scripts.count)")
            if !mitm.bypassed.isEmpty {
                HStack(alignment: .top) {
                    Text("已自动直通：\(mitm.bypassed.joined(separator: "、"))（疑似证书固定）")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("清除") { mitm.clearBypass() }
                }
            }
            if let mitmMessage { Text(mitmMessage).font(.caption).foregroundStyle(.red) }
            Text("在「配置」页的 [MITM] 段填写 hostname，并在 [URL Rewrite] / [Header Rewrite] / [Map Local] / [Script] 段编写规则即可。仅 HTTP/1.1；证书固定的 App 会被自动直通。需要信任根证书才能开启。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("HTTPS 解密（MitM）") }
        .task { mitm.refreshCAState() }
    }
}
