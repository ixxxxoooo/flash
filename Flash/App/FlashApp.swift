import SwiftUI
import AppKit
import FlashKit

@main
struct FlashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // 演示模式使用独立的临时数据目录，避免污染真实配置
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flash-demo-\(getpid())")
            setenv("FLASH_HOME", dir.path, 1)
        }
        _model = State(initialValue: AppModel.shared)
    }

    var body: some Scene {
        Window("Flash", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 660)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("内核") {
                Button(model.core.status.isRunning ? "停止内核" : "启动内核") {
                    Task { await model.toggleCore() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("重新加载配置") { Task { await model.applyConfig() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button(model.systemProxyOn ? "关闭系统代理" : "开启系统代理") {
                    Task { await model.setSystemProxy(!model.systemProxyOn) }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560, height: 620)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private var replied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 验收用：强制外观
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        // 收到终止信号时恢复系统代理并结束内核，避免遗留“幽灵”代理
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    SystemProxy.shared.restoreSilently()
                    AppModel.shared.core.terminateNow()
                }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.shutdown()
            self.finishTerminate()
        }
        // 兜底：清理超时也要退出
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            self.finishTerminate()
        }
        return .terminateLater
    }

    private func finishTerminate() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.core.terminateNow()
    }
}
