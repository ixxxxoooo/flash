# Flash

macOS 原生的 Surge 风格网络工具：规则分流、策略组、订阅管理、实时请求查看，界面采用 macOS 26 的 **Liquid Glass** 设计语言。

代理内核使用 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta）作为子进程内置，界面、配置、订阅与流量分析由 SwiftUI 完成。

![概览](docs/screenshots/dashboard.png)

| 请求 | 策略 |
| --- | --- |
| ![请求](docs/screenshots/traffic.png) | ![策略](docs/screenshots/policies.png) |
| ![订阅](docs/screenshots/subscriptions.png) | ![深色模式](docs/screenshots/dashboard-dark.png) |

## 功能

- **流量接管**：一键启动内核并设为系统代理；同时提供本地混合端口（HTTP + SOCKS5，默认 `6152`）。正常退出、被信号终止时会恢复原有系统代理设置；若遇强制退出，下次启动时自动恢复。
- **Surge 风格配置**：`[General]` `[Proxy]` `[Proxy Group]` `[Rule]` `[Host]` `[Ruleset X]`、`#!include`、`#!MANAGED-CONFIG` 受管配置；支持本地覆盖层（更新受管配置不会丢失自己的规则）。
- **协议**：HTTP / HTTPS / SOCKS5 / Shadowsocks / VMess / Trojan / Hysteria2 / TUIC / Snell / AnyTLS（VLESS 通过订阅导入）。
- **策略组**：手动选择、自动测速、故障转移、负载均衡；支持 `policy-regex-filter`、`include-all-proxies`，按地区自动分组。
- **订阅**：Clash YAML、分享链接（ss / vmess / trojan / vless / hysteria2 / tuic）、Base64、Surge 配置；自动更新、ETag、流量用量与到期时间。
- **请求查看**：来自内核的实时连接表（进程、目标、规则、策略链、上下行速率）、详情检查器、已关闭历史、右键一键添加规则、断开连接。
- **增强模式（TUN）**：无需开发者账号。一次管理员授权安装特权后台服务，以 root 运行内核的 TUN，接管所有应用流量（mixed / system / gVisor 协议栈，fake-ip DNS + 嗅探）。
- **HTTPS 解密（MitM）**：本地根证书（ECDSA P-256）+ 内置 SwiftNIO 引擎，按 `[MITM] hostname` 选择性解密；支持 `[URL Rewrite]`（reject / 302 / header 重写）、`[Header Rewrite]`、`[Map Local]`、`[Script]`（JavaScriptCore，兼容常用 Surge `$request/$response/$done/$httpClient/$persistentStore` 等 API）。证书固定的站点连续握手失败 3 次后自动直通。
- **HTTP 报文查看**：请求页详情新增「报文」标签，展示被解密连接的请求 / 响应头与正文（JSON 美化 / 原文 / 十六进制），一键复制 cURL。
- **统计**：按进程 / 域名 / 策略聚合的每日流量（SQLite）。
- **规则测试**：输入域名 / IP / 端口 / 进程，本地模拟命中的规则。
- **菜单栏**：实时速率、模式切换、策略快速切换。
- **辅助功能**：遵循“降低透明度”，玻璃材质自动退化为不透明卡片；深色 / 浅色模式。

## 范围

默认通过**系统代理 + 本地端口**接管流量；需要接管全部应用时可在设置里安装并启用增强模式（TUN）。全部能力无需付费开发者账号。

限制与说明：
- MitM 仅处理 HTTP/1.1（不协商 h2）；WebSocket 升级后直接转发；证书固定（Certificate Pinning）的 App 无法解密，会被自动直通。
- 使用 MitM 前须在设置里生成并信任根证书（系统会弹出授权）；不再使用时请「移除信任」。
- 增强模式的安装需要管理员密码，内核以 root 运行，仅建议在自己的 Mac 上使用。
- 未实现：Network Extension、Surge 模块（`.sgmodule`）、命令行工具、HTTP/2 报文级解密。
- 未命中 `[MITM] hostname` 的连接只有**连接级**信息（来自 mihomo `/connections`）。

## 构建与运行

要求：macOS 26+、Xcode 26+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
scripts/fetch-core.sh        # 下载 mihomo 内核与 geo 数据（构建时也会自动执行）
xcodegen generate
open Flash.xcodeproj         # 或：scripts/build.sh 直接产出 dist/Flash.app 与 .dmg
```

### 打包

```bash
scripts/build.sh             # 生成 dist/Flash.app 与 dist/Flash-<版本>.dmg（ad-hoc 签名）
scripts/build.sh --no-dmg    # 只生成 .app
```

未经过公证，首次打开请在 Finder 中右键 → 打开。

### 测试与验收

```bash
cd Packages/FlashKit && swift test     # 单元测试 + 真实内核集成测试
scripts/smoke-test.sh                  # 内核冒烟测试
scripts/live-check.sh                  # 启动真实应用，检查连接捕获与进程识别（不改系统代理）
scripts/shot.sh dashboard              # 以演示模式启动并截图（FLASH_DARK=1 为深色）
```

演示模式：`Flash.app/Contents/MacOS/Flash --demo`，使用独立临时目录与模拟数据，不会触碰真实配置与系统代理。

## 架构

```
Flash/                     SwiftUI 应用（界面、AppModel、菜单栏）
Packages/FlashKit/         核心库
  Profile/                 Surge 配置解析 → 合成 → mihomo YAML 生成
  Subscription/            订阅下载、解码、更新
  Controller/              mihomo REST / WebSocket 客户端
  Core/                    内核进程管理（由 launchd 托管）
  System/                  系统代理（networksetup）备份、设置、恢复
  Traffic/                 连接差分引擎与每日流量统计
  MitM/                    根证书、HTTPS 解密引擎（SwiftNIO）、重写、Map Local、脚本引擎、报文记录
scripts/                   构建、打包、验收脚本
```

要点：

- 内核通过 `launchctl bootstrap` 以 launchd 任务运行。实测作为 App 的直接子进程时，macOS 会让内核读不到其他进程的套接字归属（进程识别失效）；另外**不要对内核二进制重新签名**，重签同样会使进程识别失效。
- 配置变更先用 `mihomo -t` 校验，通过后再热重载；校验失败保留当前运行配置。
- 系统代理设置前会备份并写入“脏标记”，下次启动若发现上次异常退出会先恢复。

## 许可

Flash 以 [GPL-3.0](LICENSE) 发布。内置的 mihomo 同为 GPL-3.0，其源码见 <https://github.com/MetaCubeX/mihomo>。
