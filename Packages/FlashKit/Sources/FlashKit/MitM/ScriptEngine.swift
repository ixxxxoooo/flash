import Foundation
import JavaScriptCore

/// 交给脚本的请求视图
public struct ScriptRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: HeaderList
    public var body: Data?
    public init(url: String, method: String, headers: HeaderList, body: Data?) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

/// 交给脚本的响应视图
public struct ScriptResponse: Sendable {
    public var status: Int
    public var headers: HeaderList
    public var body: Data?
    public init(status: Int, headers: HeaderList, body: Data?) { self.status = status; self.headers = headers; self.body = body }
}

/// 脚本对请求的处理结果
public enum ScriptRequestResult: Sendable {
    case unchanged
    case modified(url: String?, method: String?, headers: HeaderList?, body: Data?)
    case respond(status: Int, headers: HeaderList, body: Data)
}

/// 脚本对响应的处理结果
public enum ScriptResponseResult: Sendable {
    case unchanged
    case modified(status: Int?, headers: HeaderList?, body: Data?)
}

/// 脚本执行器：基于系统 JavaScriptCore，兼容 Surge 的常用脚本 API。
///
/// 支持 `$request` `$response` `$done` `$argument` `$persistentStore` `$notification`
/// `$httpClient` `$environment` `$script` `console` `atob/btoa` `setTimeout`。
/// 脚本异常或超时时一律放行原请求 / 响应。
///
/// @author ygw
public final class ScriptEngine: @unchecked Sendable {
    /// 脚本日志回调（级别, 内容）
    public var logHandler: (@Sendable (String, String) -> Void)?
    /// 脚本里发起的网络请求所走的本地 SOCKS 端口（走内核分流，同时避免再次被 MitM）
    public var socksProxyPort: Int?

    private let resources: ResourceCache
    private let storeURL: URL
    private let storeLock = NSLock()
    private var store: [String: String]

    public init(resources: ResourceCache = .shared,
                storeURL: URL = AppPaths.supportDir.appendingPathComponent("mitm/persistent-store.json")) {
        self.resources = resources
        self.storeURL = storeURL
        self.store = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: storeURL))) ?? [:]
    }

    // MARK: 对外接口

    /// 执行 http-request 脚本
    public func runRequest(rule: ScriptRule, request: ScriptRequest) async -> ScriptRequestResult {
        let out = await execute(rule: rule, request: request, response: nil)
        guard let d = out else { return .unchanged }
        if let r = d["response"] as? [String: Any] {
            let status = (r["status"] as? Int) ?? 200
            let headers = Self.headerList(r["headers"])
            let body = Self.bodyData(r, binary: rule.binaryBodyMode)
            return .respond(status: status, headers: headers, body: body ?? Data())
        }
        let url = d["url"] as? String
        let method = d["method"] as? String
        let headers = d["headers"] != nil ? Self.headerList(d["headers"]) : nil
        let body = (d["body"] != nil || d["bodyB64"] != nil) ? Self.bodyData(d, binary: rule.binaryBodyMode) : nil
        if url == nil, method == nil, headers == nil, body == nil { return .unchanged }
        return .modified(url: url, method: method, headers: headers, body: body)
    }

    /// 执行 http-response 脚本
    public func runResponse(rule: ScriptRule, request: ScriptRequest, response: ScriptResponse) async -> ScriptResponseResult {
        guard let d = await execute(rule: rule, request: request, response: response) else { return .unchanged }
        let status = d["status"] as? Int
        let headers = d["headers"] != nil ? Self.headerList(d["headers"]) : nil
        let body = (d["body"] != nil || d["bodyB64"] != nil) ? Self.bodyData(d, binary: rule.binaryBodyMode) : nil
        if status == nil, headers == nil, body == nil { return .unchanged }
        return .modified(status: status, headers: headers, body: body)
    }

    // MARK: 转换工具

    static func headerList(_ any: Any?) -> HeaderList {
        guard let dict = any as? [String: Any] else { return [] }
        return dict.sorted { $0.key < $1.key }.map { ($0.key, "\($0.value)") }
    }

    static func bodyData(_ d: [String: Any], binary: Bool) -> Data? {
        if let b64 = d["bodyB64"] as? String { return Data(base64Encoded: b64) }
        if let s = d["body"] as? String { return Data(s.utf8) }
        return nil
    }

    // MARK: 执行

    private func execute(rule: ScriptRule, request: ScriptRequest, response: ScriptResponse?) async -> [String: Any]? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.executeSync(rule: rule, request: request, response: response))
            }
        }
    }

    private func log(_ level: String, _ msg: String) { logHandler?(level, msg) }

    /// 同步执行脚本（在后台线程调用），返回 `$done` 传入对象的规整结果
    private func executeSync(rule: ScriptRule, request: ScriptRequest, response: ScriptResponse?) -> [String: Any]? {
        guard let data = resources.cached(rule.scriptPath), let source = String(data: data, encoding: .utf8) else {
            log("warning", "[脚本 \(rule.name)] 脚本内容不可用：\(rule.scriptPath)")
            return nil
        }
        guard let ctx = JSContext() else { return nil }
        let sem = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var finished = false
        var result: [String: Any]?

        ctx.exceptionHandler = { [weak self] _, ex in
            self?.log("error", "[脚本 \(rule.name)] 异常：\(ex?.toString() ?? "未知")")
            // 脚本抛出异常后不会再调用 $done，立即结束等待，放行原请求 / 响应
            stateLock.lock()
            let first = !finished
            finished = true
            stateLock.unlock()
            if first { sem.signal() }
        }
        install(into: ctx, rule: rule)

        // 规整 $done 参数：统一输出为 JSON 文本
        ctx.evaluateScript("""
        var __flashNormalize = function(v) {
          if (v === undefined || v === null || typeof v !== 'object') return '{}';
          var pick = function(o) {
            var r = {};
            if (o.url !== undefined) r.url = String(o.url);
            if (o.method !== undefined) r.method = String(o.method);
            if (o.status !== undefined) r.status = (typeof o.status === 'string') ? parseInt(o.status) || 200 : o.status;
            if (o.headers !== undefined && o.headers !== null) r.headers = o.headers;
            if (o.body !== undefined && o.body !== null) {
              if (o.body instanceof Uint8Array || Object.prototype.toString.call(o.body) === '[object Uint8Array]') {
                var s = ''; for (var i = 0; i < o.body.length; i++) s += String.fromCharCode(o.body[i]); r.bodyB64 = btoa(s);
              } else if (typeof o.body === 'object') { r.body = JSON.stringify(o.body); }
              else { r.body = String(o.body); }
            }
            return r;
          };
          var out = pick(v);
          if (v.response && typeof v.response === 'object') out.response = pick(v.response);
          return JSON.stringify(out);
        };
        var __flashBytes = function(b64) {
          var s = atob(b64), n = s.length, u = new Uint8Array(n);
          for (var i = 0; i < n; i++) u[i] = s.charCodeAt(i);
          return u;
        };
        """)
        let done: @convention(block) (JSValue?) -> Void = { value in
            stateLock.lock()
            if finished { stateLock.unlock(); return }
            finished = true
            stateLock.unlock()
            if let value, !value.isUndefined, !value.isNull,
               let json = ctx.objectForKeyedSubscript("__flashNormalize")?.call(withArguments: [value])?.toString(),
               let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                result = obj
            }
            sem.signal()
        }
        ctx.setObject(done, forKeyedSubscript: "$done" as NSString)

        // 请求 / 响应对象
        ctx.setObject(Self.makeObject(ctx, url: request.url, method: request.method, status: nil, headers: request.headers,
                                      body: request.body, binary: rule.binaryBodyMode), forKeyedSubscript: "$request" as NSString)
        if let response {
            ctx.setObject(Self.makeObject(ctx, url: nil, method: nil, status: response.status, headers: response.headers,
                                          body: response.body, binary: rule.binaryBodyMode), forKeyedSubscript: "$response" as NSString)
        }

        // 包一层函数，允许脚本顶层使用 return
        ctx.evaluateScript("(function(){\n\(source)\n})();")

        stateLock.lock(); let already = finished; stateLock.unlock()
        if !already {
            if sem.wait(timeout: .now() + .seconds(max(1, rule.timeout))) == .timedOut {
                stateLock.lock(); finished = true; stateLock.unlock()
                log("warning", "[脚本 \(rule.name)] 执行超过 \(rule.timeout) 秒，已放行")
                return nil
            }
        }
        return result
    }

    /// 构造 `$request` / `$response` 对象
    private static func makeObject(_ ctx: JSContext, url: String?, method: String?, status: Int?, headers: HeaderList,
                                   body: Data?, binary: Bool) -> JSValue {
        let obj = JSValue(newObjectIn: ctx)!
        if let url { obj.setObject(url, forKeyedSubscript: "url" as NSString) }
        if let method { obj.setObject(method, forKeyedSubscript: "method" as NSString) }
        if let status { obj.setObject(status, forKeyedSubscript: "status" as NSString) }
        let h = JSValue(newObjectIn: ctx)!
        for (k, v) in headers {
            if let old = h.objectForKeyedSubscript(k), !old.isUndefined, k.lowercased() != "set-cookie" {
                h.setObject("\(old.toString() ?? ""), \(v)", forKeyedSubscript: k as NSString)
            } else {
                h.setObject(v, forKeyedSubscript: k as NSString)
            }
        }
        obj.setObject(h, forKeyedSubscript: "headers" as NSString)
        if let body, !body.isEmpty {
            if binary {
                let fn = ctx.objectForKeyedSubscript("__flashBytes")
                if let arr = fn?.call(withArguments: [body.base64EncodedString()]) { obj.setObject(arr, forKeyedSubscript: "body" as NSString) }
            } else {
                obj.setObject(String(decoding: body, as: UTF8.self), forKeyedSubscript: "body" as NSString)
            }
        }
        return obj
    }

    // MARK: 全局 API

    private func install(into ctx: JSContext, rule: ScriptRule) {
        // console
        let console = JSValue(newObjectIn: ctx)!
        for level in ["log", "info", "warn", "error", "debug"] {
            let fn: @convention(block) () -> Void = { [weak self] in
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let text = args.map { $0.isObject && !$0.isString ? ($0.toDictionary().map { "\($0)" } ?? $0.toString() ?? "") : ($0.toString() ?? "") }.joined(separator: " ")
                self?.log(level == "error" ? "error" : (level == "warn" ? "warning" : "info"), "[脚本 \(rule.name)] \(text)")
            }
            console.setObject(fn, forKeyedSubscript: level as NSString)
        }
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        // atob / btoa
        let btoa: @convention(block) (String) -> String = { s in
            Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }).base64EncodedString()
        }
        let atob: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s.padding(toLength: ((s.count + 3) / 4) * 4, withPad: "=", startingAt: 0)) else { return "" }
            return String(String.UnicodeScalarView(d.map { Unicode.Scalar($0) }))
        }
        ctx.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        ctx.setObject(atob, forKeyedSubscript: "atob" as NSString)

        // setTimeout（简化版）
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { fn, ms in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms)))) { _ = fn.call(withArguments: []) }
            return 1
        }
        ctx.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        let clearTimeout: @convention(block) (JSValue) -> Void = { _ in }
        ctx.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)

        // 基本信息
        ctx.setObject(rule.argument, forKeyedSubscript: "$argument" as NSString)
        ctx.setObject(["system": "macOS", "surge-build": "Flash", "surge-version": "Flash 1.1", "language": "zh-Hans"],
                      forKeyedSubscript: "$environment" as NSString)
        ctx.setObject(["name": rule.name, "type": rule.direction.rawValue], forKeyedSubscript: "$script" as NSString)

        // $persistentStore
        let ps = JSValue(newObjectIn: ctx)!
        let read: @convention(block) (String) -> Any = { [weak self] key in
            guard let self else { return NSNull() }
            self.storeLock.lock(); defer { self.storeLock.unlock() }
            return self.store[key] ?? NSNull()
        }
        let write: @convention(block) (String, String) -> Bool = { [weak self] value, key in
            guard let self else { return false }
            self.storeLock.lock()
            self.store[key] = value
            let snapshot = self.store
            self.storeLock.unlock()
            try? FileManager.default.createDirectory(at: self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: self.storeURL, options: .atomic)
            return true
        }
        ps.setObject(read, forKeyedSubscript: "read" as NSString)
        ps.setObject(write, forKeyedSubscript: "write" as NSString)
        ctx.setObject(ps, forKeyedSubscript: "$persistentStore" as NSString)

        // $notification
        let note = JSValue(newObjectIn: ctx)!
        let post: @convention(block) (JSValue, JSValue, JSValue) -> Void = { title, subtitle, body in
            Self.notify(title: title.toString() ?? "", subtitle: subtitle.isUndefined ? "" : (subtitle.toString() ?? ""),
                        body: body.isUndefined ? "" : (body.toString() ?? ""))
        }
        note.setObject(post, forKeyedSubscript: "post" as NSString)
        ctx.setObject(note, forKeyedSubscript: "$notification" as NSString)

        // $httpClient
        let client = JSValue(newObjectIn: ctx)!
        for method in ["get", "post", "put", "delete", "head", "options", "patch"] {
            let fn: @convention(block) (JSValue, JSValue) -> Void = { [weak self] options, callback in
                self?.httpClient(method: method.uppercased(), options: options, callback: callback, ctx: ctx)
            }
            client.setObject(fn, forKeyedSubscript: method as NSString)
        }
        ctx.setObject(client, forKeyedSubscript: "$httpClient" as NSString)
    }

    /// 发送系统通知（通过 osascript，无需额外授权）
    static func notify(title: String, subtitle: String, body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        if !subtitle.isEmpty { script += " subtitle \"\(esc(subtitle))\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// `$httpClient.xxx(options, callback)`
    private func httpClient(method: String, options: JSValue, callback: JSValue, ctx: JSContext) {
        var urlString = ""
        var headers: [String: String] = [:]
        var bodyData: Data?
        var timeout = 5.0
        if options.isString {
            urlString = options.toString() ?? ""
        } else if options.isObject {
            urlString = options.forProperty("url")?.toString() ?? ""
            if let h = options.forProperty("headers")?.toDictionary() as? [String: Any] { headers = h.mapValues { "\($0)" } }
            if let b = options.forProperty("body"), !b.isUndefined, !b.isNull { bodyData = Data((b.toString() ?? "").utf8) }
            if let t = options.forProperty("timeout"), t.isNumber { timeout = max(1, t.toDouble()) }
        }
        guard let url = URL(string: urlString) else {
            _ = callback.call(withArguments: ["无效的 URL: \(urlString)", NSNull(), NSNull()])
            return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = bodyData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral
        if let port = socksProxyPort {
            config.connectionProxyDictionary = [
                "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port,
            ]
        }
        let session = URLSession(configuration: config)
        session.dataTask(with: req) { data, resp, error in
            if let error {
                _ = callback.call(withArguments: [error.localizedDescription, NSNull(), NSNull()])
            } else if let http = resp as? HTTPURLResponse {
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields { h["\(k)"] = "\(v)" }
                let respObj: [String: Any] = ["status": http.statusCode, "headers": h]
                let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                _ = callback.call(withArguments: [NSNull(), respObj, text])
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }
}
