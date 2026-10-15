import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTLS

/// 单个 HTTP 交换的运行期状态
final class Exchange {
    var record = HTTPExchange()
    var scheme = "https"
    var targetHost = ""
    var targetPort = 443
    var method = HTTPMethod.GET
    var uri = "/"
    var url = ""
    var requestHeaders: HeaderList = []
    var requestKeepAlive = true

    // 请求侧
    var requestScripts: [ScriptRule] = []
    var bufferRequestBody = false
    var requestBuffer = ByteBuffer()
    var headSent = false
    var requestEnded = false
    var synthetic: SyntheticResponse?

    // 响应侧
    var responseHead: HTTPResponseHead?
    var responseHeaders: HeaderList = []
    var responseScripts: [ScriptRule] = []
    var bufferResponseBody = false
    var responseBuffer = ByteBuffer()
    var responseFinished = false
    var responseKeepAlive = true
}

/// 上游（真实服务器）事件
enum UpstreamEvent {
    case head(HTTPResponseHead)
    case body(ByteBuffer)
    case end
    case closed(Error?)
}

/// 上游通道处理器：把响应事件转交给会话处理器
final class UpstreamHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private weak var owner: MitMHTTPHandler?
    init(owner: MitMHTTPHandler) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): owner?.upstreamEvent(.head(h), from: context.channel)
        case .body(let b): owner?.upstreamEvent(.body(b), from: context.channel)
        case .end: owner?.upstreamEvent(.end, from: context.channel)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.upstreamEvent(.closed(nil), from: context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.upstreamEvent(.closed(error), from: context.channel)
        context.close(promise: nil)
    }
}

/// 客户端侧 HTTP 处理器：对每个请求执行重写 / Map Local / 脚本 / 记录，并与上游互转。
///
/// 请求与响应都有两种模式：
/// - 流式：头部处理完后直接转发正文（适合大文件、视频、SSE）；
/// - 缓冲：仅当脚本声明 `requires-body` 且正文不超过 `max-size` 时，完整收集后再交给脚本。
///
/// @author ygw
final class MitMHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: MitMServer
    private let defaultHost: String
    private let defaultPort: Int
    private let isTLS: Bool
    private var context: ChannelHandlerContext!
    private var loop: EventLoop { context.eventLoop }

    private var upstream: Channel?
    private var upstreamKey = ""
    private var ex: Exchange?
    private var handshakeDone = false
    private var handshakeReported = false

    private var reqQueue: [HTTPServerRequestPart] = []
    private var reqReady = false
    private var resQueue: [UpstreamEvent] = []
    private var resReady = false

    init(server: MitMServer, host: String, port: Int, isTLS: Bool) {
        self.server = server; self.defaultHost = host; self.defaultPort = port; self.isTLS = isTLS
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    // MARK: TLS 握手状态

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? TLSUserEvent, case .handshakeCompleted = e {
            handshakeDone = true
            if !handshakeReported { handshakeReported = true; server.reportHandshake(host: defaultHost, success: true) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func reportFailureIfNeeded() {
        if isTLS, !handshakeDone, !handshakeReported {
            handshakeReported = true
            server.reportHandshake(host: defaultHost, success: false)
        }
    }

    // MARK: 客户端 → 引擎

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let h):
            beginExchange(h)
        case .body, .end:
            if reqReady { handleRequestPart(part) } else { reqQueue.append(part) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportFailureIfNeeded()
        if let e = ex, !e.responseFinished {
            e.record.notes.append("客户端提前断开")
            e.record.duration = Date().timeIntervalSince(e.record.startedAt)
            server.recorder.upsert(e.record)
        }
        upstream?.close(promise: nil)
        upstream = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reportFailureIfNeeded()
        context.close(promise: nil)
    }

    // MARK: 请求头处理

    private func beginExchange(_ h: HTTPRequestHead) {
        if ex != nil { context.close(promise: nil); return }
        let e = Exchange()
        ex = e
        reqReady = false; reqQueue = []; resReady = false; resQueue = []

        var headers: HeaderList = h.headers.map { ($0.name, $0.value) }
        let hostHeader = headers.first { $0.name.caseInsensitiveCompare("Host") == .orderedSame }?.value ?? defaultHost
        e.scheme = isTLS ? "https" : "http"
        e.targetHost = defaultHost
        e.targetPort = defaultPort
        e.method = h.method
        e.requestKeepAlive = h.isKeepAlive
        var uri = h.uri
        if uri.hasPrefix("http://") || uri.hasPrefix("https://"), let c = URLComponents(string: uri) {
            uri = (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?\($0)" } ?? "")
        }
        e.uri = uri
        e.url = "\(e.scheme)://\(hostHeader)\(uri)"

        e.record.scheme = e.scheme
        e.record.host = defaultHost
        e.record.method = h.method.rawValue
        e.record.url = e.url
        e.record.requestHeaders = headers
        server.recorder.upsert(e.record)

        let state = server.currentState()
        switch state.rewrite.evaluateRequest(url: e.url, headers: &headers) {
        case .respond(let resp):
            e.synthetic = resp
            e.record.notes.append(resp.note)
            reqReady = true
            return
        case .forward(let newURL):
            if newURL != e.url { applyURLChange(e, newURL: newURL, headers: &headers) }
        }
        e.requestHeaders = headers
        e.record.requestHeaders = headers

        let rules = server.scriptRules(.request, url: e.url)
        e.requestScripts = rules
        if rules.isEmpty {
            forwardHead(e)
            return
        }
        let needBody = rules.contains { $0.requiresBody }
        let maxSize = rules.map(\.maxSize).max() ?? 0
        let length = headers.first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }.flatMap { Int($0.value) }
        if needBody, length.map({ $0 <= maxSize }) ?? true, h.method != .GET || length != nil {
            e.bufferRequestBody = true
            reqReady = true            // 正文开始缓冲，等 .end 后统一处理
            if length == nil && h.method == .GET { runRequestScripts(e) }
            return
        }
        runRequestScripts(e)
    }

    /// 应用重写后的新 URL：更新目标、Host 头与 URI
    private func applyURLChange(_ e: Exchange, newURL: String, headers: inout HeaderList) {
        guard let c = URLComponents(string: newURL), let host = c.host else { return }
        let scheme = (c.scheme ?? e.scheme).lowercased()
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        e.record.notes.append("URL 改写 → \(newURL)")
        e.url = newURL
        e.scheme = scheme
        e.targetHost = host
        e.targetPort = port
        e.uri = (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?\($0)" } ?? "")
        let hostValue = (c.port == nil) ? host : "\(host):\(port)"
        headers.removeAll { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
        headers.insert(("Host", hostValue), at: 0)
        e.record.url = newURL
        e.record.host = host
    }

    /// 在流式模式下对头部运行请求脚本（不带正文），随后转发
    private func runRequestScripts(_ e: Exchange) {
        let rules = e.requestScripts
        let body: Data? = e.bufferRequestBody ? Data(e.requestBuffer.readableBytesView) : nil
        let engine = server.scripts
        let loop = self.loop
        let snapshot = ScriptRequest(url: e.url, method: e.method.rawValue, headers: e.requestHeaders, body: body)
        Task { [weak self] in
            var current = snapshot
            var respond: (Int, HeaderList, Data)?
            for rule in rules {
                switch await engine.runRequest(rule: rule, request: current) {
                case .unchanged: break
                case .modified(let url, let method, let headers, let newBody):
                    if let url { current.url = url }
                    if let method { current.method = method }
                    if let headers { current.headers = headers }
                    if let newBody { current.body = newBody }
                case .respond(let status, let headers, let b):
                    respond = (status, headers, b)
                }
                if respond != nil { break }
            }
            loop.execute {
                guard let self, let e = self.ex else { return }
                e.record.notes.append("脚本：" + rules.map(\.name).joined(separator: "、"))
                if let (status, headers, b) = respond {
                    var hs = headers.filter { $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame }
                    hs.append(("Content-Length", "\(b.count)"))
                    e.synthetic = SyntheticResponse(status: status, headers: hs, body: b, note: "脚本直接响应")
                    if e.requestEnded || !e.bufferRequestBody { self.reqReady = true; self.drainRequestQueue() }
                    if e.requestEnded { self.sendSynthetic(e) }
                    return
                }
                if current.url != e.url {
                    var hs = current.headers
                    self.applyURLChange(e, newURL: current.url, headers: &hs)
                    current.headers = hs
                }
                e.method = HTTPMethod(rawValue: current.method)
                e.requestHeaders = current.headers
                e.record.requestHeaders = current.headers
                if e.bufferRequestBody, let nb = current.body {
                    var buf = ByteBufferAllocator().buffer(capacity: nb.count)
                    buf.writeBytes(nb)
                    e.requestBuffer = buf
                    e.record.requestBody = nb.prefix(HTTPRecorder.bodyLimit)
                }
                self.forwardHead(e)
            }
        }
    }

    // MARK: 请求转发

    /// 连接上游并发送请求头（缓冲模式下同时发送正文与结束标记）
    private func forwardHead(_ e: Exchange) {
        ensureUpstream(e).whenComplete { [weak self] result in
            guard let self, self.ex === e else { return }
            switch result {
            case .failure(let err):
                self.respondError(e, status: 502, message: "无法连接上游 \(e.targetHost):\(e.targetPort)：\(Self.describe(err))")
            case .success(let up):
                var headers = e.requestHeaders.filter {
                    let n = $0.name.lowercased()
                    return n != "proxy-connection" && n != "expect"
                }
                if e.bufferRequestBody {
                    headers.removeAll { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame || $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }
                    if e.requestBuffer.readableBytes > 0 || e.method != .GET { headers.append(("Content-Length", "\(e.requestBuffer.readableBytes)")) }
                }
                let head = HTTPRequestHead(version: .http1_1, method: e.method, uri: e.uri, headers: HTTPHeaders(headers.map { ($0.name, $0.value) }))
                up.write(HTTPClientRequestPart.head(head), promise: nil)
                e.headSent = true
                if e.bufferRequestBody {
                    if e.requestBuffer.readableBytes > 0 { up.write(HTTPClientRequestPart.body(.byteBuffer(e.requestBuffer)), promise: nil) }
                    up.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    e.requestEnded = true
                    _ = self.context.channel.setOption(ChannelOptions.autoRead, value: false)
                } else {
                    up.flush()
                }
                self.reqReady = true
                self.drainRequestQueue()
            }
        }
    }

    private func drainRequestQueue() {
        let queued = reqQueue
        reqQueue = []
        for p in queued { handleRequestPart(p) }
    }

    private func handleRequestPart(_ part: HTTPServerRequestPart) {
        guard let e = ex else { return }
        if e.synthetic != nil {
            if case .end = part { e.requestEnded = true; sendSynthetic(e) }
            return
        }
        switch part {
        case .head: break
        case .body(let buf):
            if e.record.requestBody.count < HTTPRecorder.bodyLimit {
                let room = HTTPRecorder.bodyLimit - e.record.requestBody.count
                e.record.requestBody.append(contentsOf: buf.readableBytesView.prefix(room))
                if buf.readableBytes > room { e.record.requestBodyTruncated = true }
            }
            if e.bufferRequestBody && !e.headSent {
                var copy = buf
                e.requestBuffer.writeBuffer(&copy)
                let limit = e.requestScripts.map(\.maxSize).max() ?? 0
                if limit > 0 && e.requestBuffer.readableBytes > limit {
                    // 超出脚本允许的大小：放弃脚本，改为流式转发（先发已收集的部分）
                    e.bufferRequestBody = false
                    e.requestScripts = []
                    e.record.notes.append("请求体超过 max-size，已跳过脚本")
                    let prefix = e.requestBuffer
                    e.requestBuffer = ByteBuffer()
                    reqReady = false
                    sendPrefixThenForward(e, prefix: prefix)
                }
            } else if let up = upstream {
                up.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buf)), promise: nil)
            }
        case .end:
            e.requestEnded = true
            if e.bufferRequestBody && !e.headSent {
                runRequestScripts(e)
            } else {
                upstream?.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            }
        }
    }

    private func sendPrefixThenForward(_ e: Exchange, prefix: ByteBuffer) {
        ensureUpstream(e).whenComplete { [weak self] result in
            guard let self, self.ex === e else { return }
            guard case .success(let up) = result else { self.respondError(e, status: 502, message: "无法连接上游"); return }
            let headers = e.requestHeaders.filter { $0.name.lowercased() != "proxy-connection" && $0.name.lowercased() != "expect" }
            up.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: e.method, uri: e.uri,
                                                                 headers: HTTPHeaders(headers.map { ($0.name, $0.value) }))), promise: nil)
            e.headSent = true
            up.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(prefix)), promise: nil)
            self.reqReady = true
            self.drainRequestQueue()
        }
    }

    // MARK: 上游连接

    private func ensureUpstream(_ e: Exchange) -> EventLoopFuture<Channel> {
        let tls = e.scheme == "https"
        let key = "\(tls)|\(e.targetHost):\(e.targetPort)"
        if let u = upstream, u.isActive, upstreamKey == key { return loop.makeSucceededFuture(u) }
        upstream?.close(promise: nil)
        upstream = nil
        let host = e.targetHost, port = e.targetPort
        let verify = !server.currentState().config.skipServerCertVerify
        return server.connectUpstream(loop: loop, host: host, port: port).flatMapThrowing { [weak self] ch -> Channel in
            guard let self else { throw ChannelError.ioOnClosedChannel }
            let ops = ch.pipeline.syncOperations
            if tls {
                let ctx = try self.server.upstreamTLSContext(verify: verify)
                let isIP = CertificateAuthority.ipv4Bytes(host) != nil
                try ops.addHandler(try NIOSSLClientHandler(context: ctx, serverHostname: isIP ? nil : host), name: "up.ssl")
            }
            try ops.addHandler(RawSwitch(), name: "up.switch")
            try ops.addHTTPClientHandlers(position: .last, leftOverBytesStrategy: .forwardBytes)
            try ops.addHandler(UpstreamHandler(owner: self), name: "up.handler")
            self.upstream = ch
            self.upstreamKey = key
            return ch
        }
    }

    // MARK: 上游 → 引擎

    /// 把底层错误转成易懂的中文说明（NIOSSL 的默认描述只有“error 0”之类，无法定位）
    /// - Parameter error: 底层错误
    /// - Returns: 展示文本
    static func describe(_ error: Error) -> String {
        if let ssl = error as? NIOSSLError {
            switch ssl {
            case .uncleanShutdown:
                return "上游在 TLS 握手期间关闭了连接（节点超时或目标不可达）"
            case .handshakeFailed(let inner):
                return "TLS 握手失败：\(inner)"
            default:
                return "TLS 错误：\(ssl)"
            }
        }
        return error.localizedDescription
    }

    func upstreamEvent(_ event: UpstreamEvent, from channel: Channel) {
        let run = { [weak self] in
            guard let self, channel === self.upstream else { return }
            self.dispatchUpstream(event)
        }
        if loop.inEventLoop { run() } else { loop.execute(run) }
    }

    private func dispatchUpstream(_ event: UpstreamEvent) {
        guard let e = ex else { return }
        switch event {
        case .head(let h):
            beginResponse(e, h)
        case .body, .end:
            if resReady { handleResponsePart(e, event) } else { resQueue.append(event) }
        case .closed(let err):
            upstream = nil
            if !e.responseFinished {
                if e.responseHead == nil {
                    respondError(e, status: 502, message: "上游连接中断" + (err.map { "：\(Self.describe($0))" } ?? ""))
                } else if resReady {
                    handleResponsePart(e, .end)
                } else {
                    resQueue.append(.end)
                }
            }
        }
    }

    // MARK: 响应头处理

    private func beginResponse(_ e: Exchange, _ h: HTTPResponseHead) {
        e.responseHead = h
        var headers: HeaderList = h.headers.map { ($0.name, $0.value) }
        let status = Int(h.status.code)
        e.record.statusCode = status
        let state = server.currentState()
        state.rewrite.applyResponseHeaders(url: e.url, headers: &headers)
        e.responseHeaders = headers
        e.responseKeepAlive = h.isKeepAlive

        if status == 101 { upgradeToRelay(e, head: h, headers: headers); return }

        let rules = server.scriptRules(.response, url: e.url)
        e.responseScripts = rules
        let noBody = e.method == .HEAD || status == 204 || status == 304 || (100..<200).contains(status)
        if rules.isEmpty || noBody {
            writeResponseHead(e)
            return
        }
        let needBody = rules.contains { $0.requiresBody }
        let maxSize = rules.map(\.maxSize).max() ?? 0
        let length = headers.first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }.flatMap { Int($0.value) }
        if needBody, length.map({ $0 <= maxSize }) ?? true {
            e.bufferResponseBody = true
            resReady = true
            return
        }
        runResponseScripts(e, body: nil)
    }

    private func writeResponseHead(_ e: Exchange) {
        let h = e.responseHead!
        let head = HTTPResponseHead(version: .http1_1, status: h.status, headers: HTTPHeaders(e.responseHeaders.map { ($0.name, $0.value) }))
        e.record.responseHeaders = e.responseHeaders
        e.record.statusCode = Int(h.status.code)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        resReady = true
        let queued = resQueue
        resQueue = []
        for ev in queued { handleResponsePart(e, ev) }
        context.flush()
    }

    private func handleResponsePart(_ e: Exchange, _ event: UpstreamEvent) {
        switch event {
        case .body(let buf):
            if e.record.responseBody.count < HTTPRecorder.bodyLimit {
                let room = HTTPRecorder.bodyLimit - e.record.responseBody.count
                e.record.responseBody.append(contentsOf: buf.readableBytesView.prefix(room))
                if buf.readableBytes > room { e.record.responseBodyTruncated = true }
            }
            if e.bufferResponseBody {
                var copy = buf
                e.responseBuffer.writeBuffer(&copy)
                let limit = e.responseScripts.map(\.maxSize).max() ?? 0
                if limit > 0 && e.responseBuffer.readableBytes > limit {
                    // 超限：放弃脚本，先写头再写已缓冲的正文，后续流式
                    e.bufferResponseBody = false
                    e.responseScripts = []
                    e.record.notes.append("响应体超过 max-size，已跳过脚本")
                    let prefix = e.responseBuffer
                    e.responseBuffer = ByteBuffer()
                    resReady = false
                    writeResponseHead(e)
                    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(prefix))), promise: nil)
                }
            } else {
                context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            }
        case .end:
            if e.bufferResponseBody {
                runResponseScripts(e, body: Data(e.responseBuffer.readableBytesView))
            } else {
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                finishExchange(e)
            }
        default: break
        }
    }

    /// 运行响应脚本。`body` 为 nil 表示流式模式（只处理头部）
    private func runResponseScripts(_ e: Exchange, body: Data?) {
        let rules = e.responseScripts
        let engine = server.scripts
        let loop = self.loop
        let encoding = e.responseHeaders.first { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }?.value
        var decoded = body
        var decodeFailed = false
        if let raw = body, !raw.isEmpty {
            if let d = ContentDecoder.decode(raw, encoding: encoding) { decoded = d } else { decodeFailed = true }
        }
        let requestView = ScriptRequest(url: e.url, method: e.method.rawValue, headers: e.requestHeaders, body: nil)
        let status = Int(e.responseHead!.status.code)
        let startHeaders = e.responseHeaders
        Task { [weak self] in
            var cur = ScriptResponse(status: status, headers: startHeaders, body: decoded)
            var changedBody = false
            if !decodeFailed {
                for rule in rules {
                    if case .modified(let s, let h, let b) = await engine.runResponse(rule: rule, request: requestView, response: cur) {
                        if let s { cur.status = s }
                        if let h { cur.headers = h }
                        if let b { cur.body = b; changedBody = true }
                    }
                }
            }
            let final = cur
            let bodyChanged = changedBody
            loop.execute {
                guard let self, let e = self.ex else { return }
                e.record.notes.append(decodeFailed ? "响应体解码失败，已跳过脚本" : "脚本：" + rules.map(\.name).joined(separator: "、"))
                var headers = final.headers
                var outBody: Data?
                if let raw = body {
                    // 缓冲模式：脚本改过正文则以解码后的内容输出；否则原样输出
                    if bodyChanged || (!decodeFailed && encoding != nil && decoded != nil) {
                        outBody = bodyChanged ? final.body : decoded
                        headers.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
                    } else {
                        outBody = raw
                    }
                    headers.removeAll { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame || $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }
                    headers.append(("Content-Length", "\(outBody?.count ?? 0)"))
                }
                e.responseHeaders = headers
                let original = e.responseHead!
                e.responseHead = HTTPResponseHead(version: original.version, status: HTTPResponseStatus(statusCode: final.status), headers: original.headers)
                if body == nil {
                    // 流式：只改头部，之后的正文继续流式转发
                    self.writeResponseHead(e)
                } else {
                    self.writeResponseHead(e)
                    if let out = outBody, !out.isEmpty {
                        var buf = ByteBufferAllocator().buffer(capacity: out.count)
                        buf.writeBytes(out)
                        self.context.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                    }
                    self.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    self.finishExchange(e)
                }
            }
        }
    }

    // MARK: 合成响应与错误

    private func sendSynthetic(_ e: Exchange) {
        guard let s = e.synthetic, !e.responseFinished else { return }
        e.responseFinished = true
        var headers = s.headers
        if !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            headers.append(("Content-Length", "\(s.body.count)"))
        }
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: s.status), headers: HTTPHeaders(headers.map { ($0.name, $0.value) }))
        e.record.statusCode = s.status
        e.record.responseHeaders = headers
        e.record.responseBody = s.body.prefix(HTTPRecorder.bodyLimit)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !s.body.isEmpty && e.method != .HEAD {
            var buf = ByteBufferAllocator().buffer(capacity: s.body.count)
            buf.writeBytes(s.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        e.responseKeepAlive = e.requestKeepAlive
        finishExchange(e)
    }

    private func respondError(_ e: Exchange, status: Int, message: String) {
        guard !e.responseFinished else { return }
        e.record.notes.append(message)
        server.log("warning", "[MitM] \(e.url)：\(message)")
        e.synthetic = SyntheticResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Connection", "close")],
                                        body: Data(message.utf8), note: message)
        e.responseKeepAlive = false
        sendSynthetic(e)
    }

    // MARK: 升级（WebSocket）

    private func upgradeToRelay(_ e: Exchange, head: HTTPResponseHead, headers: HeaderList) {
        guard let up = upstream else { return }
        e.record.statusCode = 101
        e.record.notes.append("协议升级（WebSocket 等），之后直接转发")
        e.record.responseHeaders = headers
        e.record.finished = true
        e.record.duration = Date().timeIntervalSince(e.record.startedAt)
        server.recorder.upsert(e.record)
        e.responseFinished = true
        let outHead = HTTPResponseHead(version: .http1_1, status: head.status, headers: HTTPHeaders(headers.map { ($0.name, $0.value) }))
        context.writeAndFlush(wrapOutboundOut(.head(outHead)), promise: nil)
        // 两侧的字节切换器互联：之后的字节直接绕过 HTTP 编解码器双向转发
        do {
            let clientSwitch = try context.pipeline.syncOperations.handler(type: RawSwitch.self)
            let upSwitch = try up.pipeline.syncOperations.handler(type: RawSwitch.self)
            RawSwitch.link(clientSwitch, upSwitch)
            // 升级前为了背压可能暂停过读取，进入原始转发后必须恢复
            _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
            _ = up.setOption(ChannelOptions.autoRead, value: true)
        } catch {
            context.close(promise: nil)
            return
        }
        ex = nil
        upstream = nil
    }

    // MARK: 收尾

    private func finishExchange(_ e: Exchange) {
        e.responseFinished = true
        e.record.finished = true
        e.record.duration = Date().timeIntervalSince(e.record.startedAt)
        server.recorder.upsert(e.record)
        let close = !(e.requestKeepAlive && e.responseKeepAlive)
        ex = nil
        reqQueue = []; resQueue = []; reqReady = false; resReady = false
        if close {
            context.flush()
            context.close(promise: nil)
        } else {
            _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
            context.read()
        }
    }
}
