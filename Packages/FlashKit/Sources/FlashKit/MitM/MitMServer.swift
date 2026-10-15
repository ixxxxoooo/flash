import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// MitM 引擎：本地 SOCKS5 入口，按主机名决定解密（TLS 终结 + HTTP 重写/脚本/记录）或原样转发。
///
/// 数据流：mihomo 把命中 `[MITM]` 主机名的连接以 SOCKS5 交给本引擎 → 引擎终结 TLS →
/// 应用重写 / Map Local / 脚本 → 经 mihomo 的独立 SOCKS 入站（`upstreamSocksPort`）连接真实服务器，
/// 这样上游流量仍遵循原有分流规则与策略。`upstreamSocksPort` 为空时直接连接目标（仅用于测试）。
///
/// @author ygw
public final class MitMServer: @unchecked Sendable {
    // MARK: 配置状态（可热更新）

    struct ConfigState {
        var config: MitMConfig
        var rewrite: RewriteEngine
        var scriptRules: [(regex: NSRegularExpression, rule: ScriptRule)]
    }

    private let stateLock = NSLock()
    private var state: ConfigState

    let group: MultiThreadedEventLoopGroup
    let ca: CertificateAuthority
    public let recorder: HTTPRecorder
    public let scripts: ScriptEngine
    private var serverChannel: Channel?
    /// 上游 SOCKS 端口（mihomo 的 mitm-up 入站）；nil 表示直连
    public var upstreamSocksPort: Int?
    /// 引擎日志（级别, 内容）
    public var logHandler: (@Sendable (String, String) -> Void)?
    /// 当前监听端口
    public private(set) var port: Int = 0

    private var clientContext: NIOSSLContext?
    private var insecureClientContext: NIOSSLContext?
    private let pinLock = NSLock()
    private var handshakeFailures: [String: Int] = [:]
    private var bypassHosts: Set<String> = []
    /// 连续握手失败多少次后判定为证书固定并自动放行
    static let pinThreshold = 3

    public init(ca: CertificateAuthority, recorder: HTTPRecorder = HTTPRecorder(), scripts: ScriptEngine = ScriptEngine(),
                config: MitMConfig = MitMConfig(), threads: Int = max(2, min(4, System.coreCount))) {
        self.ca = ca
        self.recorder = recorder
        self.scripts = scripts
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        self.state = MitMServer.makeState(config)
    }

    private static func makeState(_ config: MitMConfig) -> ConfigState {
        let rules = config.scripts.compactMap { r -> (NSRegularExpression, ScriptRule)? in
            guard let re = try? NSRegularExpression(pattern: r.pattern) else { return nil }
            return (re, r)
        }
        return ConfigState(config: config, rewrite: RewriteEngine(config: config), scriptRules: rules)
    }

    // MARK: 生命周期

    /// 更新配置（热生效，已有连接继续使用旧配置直到结束）
    public func update(config: MitMConfig) {
        let s = Self.makeState(config)
        stateLock.lock(); state = s; stateLock.unlock()
    }

    func currentState() -> ConfigState {
        stateLock.lock(); defer { stateLock.unlock() }
        return state
    }

    /// 开始监听
    /// - Parameter port: 端口，0 表示自动分配
    /// - Returns: 实际监听端口
    @discardableResult
    public func start(port: Int = 0) async throws -> Int {
        try ca.ensureCA()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 512)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
                return channel.pipeline.addHandler(Socks5ServerHandler(server: self))
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        serverChannel = ch
        self.port = ch.localAddress?.port ?? port
        return self.port
    }

    /// 停止监听并关闭线程组
    public func stop() async {
        try? await serverChannel?.close().get()
        serverChannel = nil
        try? await group.shutdownGracefully()
    }

    func log(_ level: String, _ message: String) { logHandler?(level, message) }

    // MARK: 证书固定自动放行

    func isBypassed(_ host: String) -> Bool {
        pinLock.lock(); defer { pinLock.unlock() }
        return bypassHosts.contains(host.lowercased())
    }

    func reportHandshake(host: String, success: Bool) {
        let h = host.lowercased()
        pinLock.lock()
        if success {
            handshakeFailures[h] = nil
            pinLock.unlock()
            return
        }
        let n = (handshakeFailures[h] ?? 0) + 1
        handshakeFailures[h] = n
        let added = n >= Self.pinThreshold && bypassHosts.insert(h).inserted
        pinLock.unlock()
        if added { log("warning", "[MitM] \(host) 连续 \(n) 次 TLS 握手被客户端拒绝，疑似证书固定，已自动改为直通") }
    }

    /// 已被自动放行的主机列表（用于界面展示）
    public var bypassedHosts: [String] {
        pinLock.lock(); defer { pinLock.unlock() }
        return bypassHosts.sorted()
    }

    /// 清除自动放行记录
    public func clearBypass() {
        pinLock.lock(); bypassHosts.removeAll(); handshakeFailures.removeAll(); pinLock.unlock()
    }

    // MARK: 上游连接

    /// 经 mihomo 的 SOCKS 入站（或直连）连接真实服务器
    func connectUpstream(loop: EventLoop, host: String, port: Int) -> EventLoopFuture<Channel> {
        let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(12))
        guard let up = upstreamSocksPort else {
            return bootstrap.connect(host: host, port: port)
        }
        let promise = loop.makePromise(of: Void.self)
        return bootstrap
            .channelInitializer { $0.pipeline.addHandler(Socks5ClientHandler(host: host, port: port, promise: promise)) }
            .connect(host: "127.0.0.1", port: up)
            .flatMap { ch in promise.futureResult.map { ch }.flatMapError { err in ch.close(promise: nil); return loop.makeFailedFuture(err) } }
    }

    /// 上游 TLS 客户端上下文
    func upstreamTLSContext(verify: Bool) throws -> NIOSSLContext {
        pinLock.lock(); defer { pinLock.unlock() }
        if verify, let c = clientContext { return c }
        if !verify, let c = insecureClientContext { return c }
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.applicationProtocols = ["http/1.1"]
        cfg.certificateVerification = verify ? .fullVerification : .none
        let ctx = try NIOSSLContext(configuration: cfg)
        if verify { clientContext = ctx } else { insecureClientContext = ctx }
        return ctx
    }

    // MARK: 会话入口

    /// SOCKS 握手完成后，根据首字节决定解密或透传
    func beginSession(channel: Channel, host: String, port: Int, leftover: ByteBuffer?) {
        let sniffer = FirstBytesSniffer(server: self, host: host, port: port, initial: leftover)
        channel.pipeline.addHandler(sniffer).whenFailure { _ in channel.close(promise: nil) }
    }

    /// 与目标连接匹配的脚本规则
    func scriptRules(_ direction: RewriteDirection, url: String) -> [ScriptRule] {
        let s = currentState()
        return s.scriptRules.compactMap { item in
            guard item.rule.direction == direction,
                  item.regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { return nil }
            return item.rule
        }
    }
}

// MARK: - SOCKS5 服务端

/// 极简 SOCKS5 服务端：仅支持无认证的 CONNECT
final class Socks5ServerHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private enum Stage { case greeting, request }
    private let server: MitMServer
    private var stage = Stage.greeting
    private var buffer = ByteBuffer()

    init(server: MitMServer) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        while true {
            switch stage {
            case .greeting:
                guard buffer.readableBytes >= 2, let ver = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
                      let n = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) else { return }
                guard ver == 5 else { context.close(promise: nil); return }
                guard buffer.readableBytes >= 2 + Int(n) else { return }
                buffer.moveReaderIndex(forwardBy: 2 + Int(n))
                var reply = context.channel.allocator.buffer(capacity: 2)
                reply.writeBytes([0x05, 0x00])
                context.writeAndFlush(NIOAny(reply), promise: nil)
                stage = .request
            case .request:
                guard buffer.readableBytes >= 5 else { return }
                let r = buffer.readerIndex
                let cmd = buffer.getInteger(at: r + 1, as: UInt8.self) ?? 0
                let atyp = buffer.getInteger(at: r + 3, as: UInt8.self) ?? 0
                var total = 0
                switch atyp {
                case 1: total = 4 + 4 + 2
                case 3: total = 4 + 1 + Int(buffer.getInteger(at: r + 4, as: UInt8.self) ?? 0) + 2
                case 4: total = 4 + 16 + 2
                default: context.close(promise: nil); return
                }
                guard buffer.readableBytes >= total else { return }
                var host = ""
                var offset = r + 4
                switch atyp {
                case 1:
                    let b = buffer.getBytes(at: offset, length: 4) ?? [0, 0, 0, 0]
                    host = b.map(String.init).joined(separator: ".")
                    offset += 4
                case 3:
                    let len = Int(buffer.getInteger(at: offset, as: UInt8.self) ?? 0)
                    host = buffer.getString(at: offset + 1, length: len) ?? ""
                    offset += 1 + len
                default:
                    let b = buffer.getBytes(at: offset, length: 16) ?? []
                    var parts: [String] = []
                    for i in stride(from: 0, to: 16, by: 2) { parts.append(String(Int(b[i]) << 8 | Int(b[i + 1]), radix: 16)) }
                    host = parts.joined(separator: ":")
                    offset += 16
                }
                let port = Int(buffer.getInteger(at: offset, as: UInt16.self) ?? 0)
                buffer.moveReaderIndex(forwardBy: total)
                guard cmd == 1 else {
                    var rep = context.channel.allocator.buffer(capacity: 10)
                    rep.writeBytes([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                    context.writeAndFlush(NIOAny(rep)).whenComplete { _ in context.close(promise: nil) }
                    return
                }
                var rep = context.channel.allocator.buffer(capacity: 10)
                rep.writeBytes([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                context.writeAndFlush(NIOAny(rep), promise: nil)
                let leftover = buffer.readableBytes > 0 ? buffer : nil
                let channel = context.channel
                let server = self.server
                context.pipeline.removeHandler(context: context).whenSuccess {
                    server.beginSession(channel: channel, host: host, port: port, leftover: leftover)
                }
                return
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// MARK: - SOCKS5 客户端（连接 mihomo 的 mitm-up 入站）

final class Socks5ClientHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case method, reply }
    private let host: String
    private let port: Int
    private let promise: EventLoopPromise<Void>
    private var stage = Stage.method
    private var buffer = ByteBuffer()
    private var completed = false

    init(host: String, port: Int, promise: EventLoopPromise<Void>) {
        self.host = host; self.port = port; self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var b = context.channel.allocator.buffer(capacity: 3)
        b.writeBytes([0x05, 0x01, 0x00])
        context.writeAndFlush(wrapOutboundOut(b), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        switch stage {
        case .method:
            guard buffer.readableBytes >= 2 else { return }
            let m = buffer.readBytes(length: 2) ?? []
            guard m == [0x05, 0x00] else { fail(context, "SOCKS5 方法协商失败"); return }
            var req = context.channel.allocator.buffer(capacity: 7 + host.utf8.count)
            req.writeBytes([0x05, 0x01, 0x00])
            if let ip = CertificateAuthority.ipv4Bytes(host) {
                req.writeBytes([0x01]); req.writeBytes(ip)
            } else {
                req.writeBytes([0x03, UInt8(min(255, host.utf8.count))]); req.writeString(String(host.prefix(255)))
            }
            req.writeInteger(UInt16(port))
            context.writeAndFlush(wrapOutboundOut(req), promise: nil)
            stage = .reply
            fallthrough
        case .reply:
            guard buffer.readableBytes >= 5 else { return }
            let r = buffer.readerIndex
            let rep = buffer.getInteger(at: r + 1, as: UInt8.self) ?? 1
            let atyp = buffer.getInteger(at: r + 3, as: UInt8.self) ?? 1
            let total: Int
            switch atyp {
            case 1: total = 10
            case 3: total = 4 + 1 + Int(buffer.getInteger(at: r + 4, as: UInt8.self) ?? 0) + 2
            default: total = 22
            }
            guard buffer.readableBytes >= total else { return }
            buffer.moveReaderIndex(forwardBy: total)
            guard rep == 0 else { fail(context, "上游拒绝连接 \(host):\(port)（SOCKS5 错误码 \(rep)）"); return }
            completed = true
            let leftover = buffer.readableBytes > 0 ? buffer : nil
            let promise = self.promise
            context.pipeline.removeHandler(context: context).whenSuccess {
                promise.succeed(())
            }
            if let leftover { context.fireChannelRead(NIOAny(leftover)) }
        }
    }

    private func fail(_ context: ChannelHandlerContext, _ message: String) {
        guard !completed else { return }
        completed = true
        promise.fail(NSError(domain: "Flash.MitM", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed { fail(context, "上游连接提前关闭") }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed { fail(context, error.localizedDescription) }
        context.close(promise: nil)
    }
}

// MARK: - 首字节嗅探与分流

/// 读取客户端首批数据，决定：TLS 解密 / 明文 HTTP 解密 / 原样透传
final class FirstBytesSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let server: MitMServer
    private let host: String
    private let port: Int
    private var initial: ByteBuffer?
    private var decided = false

    init(server: MitMServer, host: String, port: Int, initial: ByteBuffer?) {
        self.server = server; self.host = host; self.port = port; self.initial = initial
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if let buf = initial, buf.readableBytes > 0 {
            initial = nil
            decide(context: context, buffer: buf)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !decided else { context.fireChannelRead(data); return }
        decide(context: context, buffer: unwrapInboundIn(data))
    }

    private func decide(context: ChannelHandlerContext, buffer: ByteBuffer) {
        decided = true
        guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { context.close(promise: nil); return }
        let state = server.currentState()
        let wantsIntercept = state.config.shouldIntercept(host: host, port: port) && !server.isBypassed(host)
        let isLetter = (first >= 0x41 && first <= 0x5A)
        let pipeline = context.pipeline

        if wantsIntercept, first == 0x16 {
            do {
                let ctx = try server.ca.serverContext(for: host)
                let handlers: [(String, ChannelHandler)] = [
                    ("mitm.ssl", NIOSSLServerHandler(context: ctx)),
                    ("mitm.switch", RawSwitch()),
                    ("mitm.decoder", ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))),
                    ("mitm.encoder", HTTPResponseEncoder()),
                    ("mitm.http", MitMHTTPHandler(server: server, host: host, port: port, isTLS: true)),
                ]
                try install(handlers, after: context, pipeline: pipeline)
                context.fireChannelRead(NIOAny(buffer))
                pipeline.removeHandler(context: context, promise: nil)
                return
            } catch {
                server.log("error", "[MitM] 为 \(host) 签发证书失败：\(error.localizedDescription)，已改为直通")
            }
        } else if wantsIntercept, isLetter {
            let handlers: [(String, ChannelHandler)] = [
                ("mitm.switch", RawSwitch()),
                ("mitm.decoder", ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))),
                ("mitm.encoder", HTTPResponseEncoder()),
                ("mitm.http", MitMHTTPHandler(server: server, host: host, port: port, isTLS: false)),
            ]
            do {
                try install(handlers, after: context, pipeline: pipeline)
                context.fireChannelRead(NIOAny(buffer))
                pipeline.removeHandler(context: context, promise: nil)
                return
            } catch {
                server.log("error", "[MitM] 安装明文处理链失败：\(error.localizedDescription)")
            }
        }

        // 透传
        let tunnel = TunnelHandler(server: server, host: host, port: port)
        do {
            try pipeline.syncOperations.addHandler(tunnel, position: .after(self))
            context.fireChannelRead(NIOAny(buffer))
            pipeline.removeHandler(context: context, promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    /// 依次把处理器加到嗅探器之后（保持顺序）
    private func install(_ handlers: [(String, ChannelHandler)], after context: ChannelHandlerContext, pipeline: ChannelPipeline) throws {
        var previous: ChannelHandler = self
        for (name, h) in handlers {
            try pipeline.syncOperations.addHandler(h, name: name, position: .after(previous))
            previous = h
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// MARK: - 透传

/// 连接上游并双向转发；上游就绪前缓存客户端数据
final class TunnelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let server: MitMServer
    private let host: String
    private let port: Int
    private var pending: [ByteBuffer] = []
    private var upstream: Channel?
    private var failed = false

    init(server: MitMServer, host: String, port: Int) { self.server = server; self.host = host; self.port = port }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        server.connectUpstream(loop: context.eventLoop, host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.failed = true
                self.server.log("warning", "[MitM] 透传 \(self.host):\(self.port) 失败：\(err.localizedDescription)")
                channel.close(promise: nil)
            case .success(let up):
                if !channel.isActive { up.close(promise: nil); return }
                self.upstream = up
                let a = RelayHandler(partner: up)
                let b = RelayHandler(partner: channel)
                do {
                    try up.pipeline.syncOperations.addHandler(b)
                    try channel.pipeline.syncOperations.addHandler(a)
                } catch { channel.close(promise: nil); up.close(promise: nil); return }
                for buf in self.pending { up.write(NIOAny(buf), promise: nil) }
                if !self.pending.isEmpty { up.flush() }
                self.pending.removeAll()
                channel.pipeline.removeHandler(self, promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if let up = upstream { up.writeAndFlush(NIOAny(buf), promise: nil) } else if !failed { pending.append(buf) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// 原始字节切换器：位于 TLS 与 HTTP 编解码器之间。
/// 平时透传；协议升级（WebSocket 等）后与对端切换器互联，字节直接绕过 HTTP 编解码器双向转发。
final class RawSwitch: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var context: ChannelHandlerContext?
    private var peer: RawSwitch?

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; peer = nil }

    /// 与对端互联，之后双方进入原始转发模式
    static func link(_ a: RawSwitch, _ b: RawSwitch) {
        a.peer = b
        b.peer = a
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let peer else { context.fireChannelRead(data); return }
        peer.send(unwrapInboundIn(data))
        if let pc = peer.context, !pc.channel.isWritable { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
    }

    /// 直接写入本通道（绕过其后的 HTTP 编码器）
    func send(_ buf: ByteBuffer) {
        guard let context else { return }
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if let peer, let pc = peer.context { _ = pc.channel.setOption(ChannelOptions.autoRead, value: context.channel.isWritable) }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let peer, let pc = peer.context { pc.close(promise: nil) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if peer != nil { context.close(promise: nil) } else { context.fireErrorCaught(error) }
    }
}

/// 双向字节转发（带简单背压）
final class RelayHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let partner: Channel
    init(partner: Channel) { self.partner = partner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner.writeAndFlush(data, promise: nil)
        if !partner.isWritable { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        _ = partner.setOption(ChannelOptions.autoRead, value: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        partner.close(promise: nil)
    }
}
