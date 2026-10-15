import SwiftUI
import FlashKit

/// 菜单栏图标 + 实时速率
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isRunning ? "bolt.fill" : "bolt.slash")
            if model.settings.showMenuBarSpeed, model.isRunning {
                Text("↓\(Fmt.compactRate(model.speed.down)) ↑\(Fmt.compactRate(model.speed.up))")
                    .monospacedDigit()
                    .font(.system(size: 11))
            }
        }
    }
}

/// 菜单栏弹出面板
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var coreBinding: Binding<Bool> {
        Binding(get: { model.isRunning }, set: { _ in Task { await model.toggleCore() } })
    }
    private var proxyBinding: Binding<Bool> {
        Binding(get: { model.systemProxyOn }, set: { v in Task { await model.setSystemProxy(v) } })
    }
    private var quickGroup: PolicyInfo? {
        model.orderedGroups.first(where: { $0.isSelectable }) ?? model.orderedGroups.first
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(model.isRunning ? Color.green : Color.secondary).frame(width: 9, height: 9)
                    Text("Flash").font(.headline)
                    Spacer()
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("下载", systemImage: "arrow.down").font(.caption).foregroundStyle(Color.downColor)
                        Text(Fmt.rate(model.speed.down)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Label("上传", systemImage: "arrow.up").font(.caption).foregroundStyle(Color.upColor)
                        Text(Fmt.rate(model.speed.up)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))

                Picker("模式", selection: Binding(get: { model.outboundMode }, set: { m in Task { await model.setMode(m) } })) {
                    ForEach(OutboundMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(spacing: 6) {
                    Toggle("内核", isOn: coreBinding).disabled(model.busy)
                    Toggle("系统代理", isOn: proxyBinding).disabled(!model.isRunning)
                }
                .toggleStyle(.switch)

                if let group = quickGroup {
                    HStack {
                        Text(group.name).font(.callout)
                        Spacer()
                        Menu(group.now) {
                            ForEach(group.all, id: \.self) { name in
                                Button(name) { Task { await model.select(group: group.name, policy: name) } }
                            }
                        }
                        .disabled(!group.isSelectable)
                    }
                }

                Divider()
                HStack {
                    Button("打开 Flash") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Spacer()
                    Button("退出") { NSApp.terminate(nil) }
                }
            }
            .padding(16)
        }
        .frame(width: 310)
    }
}
