import SwiftUI
import AppKit
import FlashKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var pendingRestart = false

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
                Text("Flash 使用 mihomo（Clash Meta）作为代理内核，遵循 GPL-3.0 协议开源。当前版本通过系统代理与本地端口接管流量，不含 TUN / MitM / 脚本等增强能力。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("mihomo 项目主页", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { launchAtLogin = model.settings.launchAtLogin }
    }
}
