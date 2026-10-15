import Foundation

/// 组合器：合并基础配置、本地覆盖层与订阅节点，解析策略组成员，并校验策略引用
public enum ProfileComposer {
    static let builtinPolicies: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

    public static func compose(base: Profile, overlay: Profile?, subscriptions: [SubscriptionNodes]) -> Profile {
        var p = merge(base: base, overlay: overlay)

        // 1. 汇总节点，名称去重
        var nodes: [ProxyNode] = []
        var usedNames = Set<String>(p.groups.map(\.name))
        func unique(_ name: String) -> String {
            guard usedNames.contains(name) || Self.builtinPolicies.contains(name) else { usedNames.insert(name); return name }
            var i = 2
            while usedNames.contains("\(name) \(i)") { i += 1 }
            let n = "\(name) \(i)"
            usedNames.insert(n)
            return n
        }
        for var n in p.nodes {
            n.name = unique(n.name)
            nodes.append(n)
        }
        var subNames: [(sub: SubscriptionNodes, names: [String])] = []
        for sub in subscriptions {
            var names: [String] = []
            for var n in sub.nodes {
                n.name = unique(n.name)
                n.source = sub.name
                nodes.append(n)
                names.append(n.name)
            }
            subNames.append((sub, names))
        }
        p.nodes = nodes
        let allNames = nodes.map(\.name)
        let nodeSet = Set(allNames)

        // 2. 解析策略组成员
        let alias = p.policyAliases
        func resolveAlias(_ s: String) -> String { alias[s] ?? s }
        let regexCache: (String?) -> NSRegularExpression? = { pattern in
            guard let pattern, !pattern.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: pattern)
        }

        struct Resolved { var spec: GroupSpec; var dynamic: Bool }
        var resolved: [Resolved] = []
        for g in p.groups {
            var spec = g
            var members = g.members.map(resolveAlias)
            var dynamicNames: [String] = []
            let dynamic = g.includeAllProxies || g.policyPath != nil || (g.regexFilter?.isEmpty == false)

            if let path = g.policyPath, !path.isEmpty {
                if let hit = subNames.first(where: { $0.sub.name == path || $0.sub.url == path }) {
                    dynamicNames += hit.names
                } else if g.includeAllProxies == false {
                    p.diagnostics.append(.init(line: 0, severity: .warning, message: "策略组 \(g.name): 未找到 policy-path 对应的订阅「\(path)」"))
                }
            }
            if g.includeAllProxies || (g.policyPath == nil && g.regexFilter?.isEmpty == false) {
                dynamicNames += allNames
            }
            if let rx = regexCache(g.regexFilter) {
                dynamicNames = dynamicNames.filter {
                    rx.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }
            } else if let f = g.regexFilter, !f.isEmpty {
                p.diagnostics.append(.init(line: 0, severity: .warning, message: "策略组 \(g.name): 正则无效 \(f)"))
            }
            var seen = Set(members)
            for n in dynamicNames where seen.insert(n).inserted { members.append(n) }
            spec.members = members
            resolved.append(Resolved(spec: spec, dynamic: dynamic))
        }

        // 3. 丢弃动态匹配后为空的组，并清理引用（循环直到稳定）
        var dropped = Set<String>()
        var changed = true
        while changed {
            changed = false
            let groupNames = Set(resolved.map(\.spec.name))
            for i in resolved.indices {
                let before = resolved[i].spec.members
                resolved[i].spec.members = before.filter { m in
                    Self.builtinPolicies.contains(m) || nodeSet.contains(m) || groupNames.contains(m)
                }
                if resolved[i].spec.members.count != before.count { changed = true }
            }
            for r in resolved where r.spec.members.isEmpty && r.dynamic {
                dropped.insert(r.spec.name)
            }
            if !dropped.isEmpty {
                let before = resolved.count
                resolved.removeAll { dropped.contains($0.spec.name) }
                if resolved.count != before { changed = true }
            }
        }
        for name in dropped {
            p.diagnostics.append(.init(line: 0, severity: .info, message: "策略组 \(name) 没有匹配到任何节点，已自动省略"))
        }
        for i in resolved.indices where resolved[i].spec.members.isEmpty {
            resolved[i].spec.members = ["DIRECT"]
            p.diagnostics.append(.init(line: 0, severity: .warning, message: "策略组 \(resolved[i].spec.name) 没有可用成员，已回退为 DIRECT"))
        }
        p.groups = resolved.map(\.spec)

        // 4. 规则：别名替换、校验策略与规则集引用
        let valid = Self.builtinPolicies.union(nodeSet).union(p.groups.map(\.name))
        let providerNames = Set(p.ruleProviders.map(\.name))
        var rules: [RuleSpec] = []
        for var r in p.rules {
            r.policy = resolveAlias(r.policy)
            if r.body.hasPrefix("RULE-SET,") {
                let name = String(r.body.dropFirst("RULE-SET,".count))
                if name.uppercased() == "LAN" {
                    r.body = "GEOIP,LAN"; r.noResolve = true
                } else if !providerNames.contains(name) {
                    p.diagnostics.append(.init(line: r.line, severity: .warning, message: "规则集 \(name) 未定义，已跳过该规则"))
                    continue
                }
            }
            if !valid.contains(r.policy) {
                let reason = dropped.contains(r.policy) ? "没有可用节点" : "不存在"
                p.diagnostics.append(.init(line: r.line, severity: .warning, message: "规则引用的策略 \(r.policy) \(reason)，已改为 DIRECT"))
                r.policy = "DIRECT"
            }
            rules.append(r)
        }
        // 只保留第一个 FINAL 及其之前的规则
        if let idx = rules.firstIndex(where: { $0.isFinal }) { rules = Array(rules[...idx]) }
        if rules.last?.isFinal != true {
            p.diagnostics.append(.init(line: 0, severity: .warning, message: "规则列表缺少 FINAL，已补充 FINAL,DIRECT"))
            rules.append(RuleSpec(body: "MATCH", policy: "DIRECT"))
        }
        p.rules = rules

        // 5. 仅保留被引用的规则集（避免无谓下载）
        let used = Set(rules.compactMap { r -> String? in
            r.body.hasPrefix("RULE-SET,") ? String(r.body.dropFirst("RULE-SET,".count)) : nil
        })
        p.ruleProviders = p.ruleProviders.filter { used.contains($0.name) }
        return p
    }

    // MARK: 合并

    static func merge(base: Profile, overlay: Profile?) -> Profile {
        guard let o = overlay else { return base }
        var p = base
        p.general.merge(o.general) { _, new in new }
        p.hosts.merge(o.hosts) { _, new in new }
        p.nameserverPolicy.merge(o.nameserverPolicy) { _, new in new }
        p.policyAliases.merge(o.policyAliases) { _, new in new }
        p.nodes += o.nodes
        for g in o.groups {
            if let i = p.groups.firstIndex(where: { $0.name == g.name }) { p.groups[i] = g } else { p.groups.append(g) }
        }
        p.rules = o.rules.filter { !$0.isFinal } + base.rules
        for rp in o.ruleProviders {
            if let i = p.ruleProviders.firstIndex(where: { $0.name == rp.name }) { p.ruleProviders[i] = rp } else { p.ruleProviders.append(rp) }
        }
        p.mitm = base.mitm.merged(with: o.mitm)
        p.diagnostics += o.diagnostics
        return p
    }
}
