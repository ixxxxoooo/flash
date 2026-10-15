import SwiftUI

/// 是否强制使用不透明样式（验收用：--opaque 启动参数，模拟“降低透明度”）
enum ForcedAppearance {
    static let opaque = ProcessInfo.processInfo.arguments.contains("--opaque")
}

/// 卡片背景：默认使用 Liquid Glass；开启“降低透明度”时退化为不透明底色 + 细描边
struct FlashGlass: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency || ForcedAppearance.opaque {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.separator, lineWidth: 0.5) }
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func flashGlass(radius: CGFloat = 22) -> some View { modifier(FlashGlass(radius: radius)) }
}

/// 玻璃卡片：内容层之上的“功能层”容器
struct GlassCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(.secondary)
                    }
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flashGlass(radius: 22)
    }
}

/// 指标磁贴：大号数字 + 标题
struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color = .flashAccent
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flashGlass(radius: 22)
    }
}

/// 小型状态胶囊
struct Pill: View {
    var text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// 页面标题栏
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.weight(.bold))
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

/// 氛围背景：随运行状态变化色调的网格渐变，内容层的最底层
struct AmbientBackground: View {
    var active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency || ForcedAppearance.opaque {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            let base: Color = active ? .flashAccent : .gray
            let alt: Color = active ? .indigo : .gray
            let strength = scheme == .dark ? 0.32 : 0.20
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.55, 0.45], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    base.opacity(strength), alt.opacity(strength * 0.6), .clear,
                    .clear, base.opacity(strength * 0.5), alt.opacity(strength * 0.5),
                    alt.opacity(strength * 0.7), .clear, base.opacity(strength * 0.8),
                ]
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(.easeInOut(duration: 0.8), value: active)
        }
    }
}

/// 错误 / 提示横幅
struct Banner: View {
    var message: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(tint.opacity(0.25)), in: .capsule)
        .padding(.horizontal, 24)
    }
}
