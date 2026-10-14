import Foundation

/// 深度模型的工具集：网络搜索 + 网页阅读。
/// 优先走智谱 BigModel 工具 API（服务端执行、国内可达）；未配置 Key 时回退
/// DuckDuckGo Lite / 直接抓取（免费但受网络环境与页面结构影响）。
enum WebTools {
    // MARK: - Function calling schema（暴露给推理模型）

    static let schemas: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "搜索互联网，返回前 5 条结果的标题、摘要与链接。适合获取实时或未知信息。",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "搜索关键词（不超过 70 字）"],
                    ] as [String: Any],
                    "required": ["query"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": "read_webpage",
                "description": "读取指定网页的正文（纯文本，最多约 3000 字）。搜索后想深入了解某条结果时使用。",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "完整 URL（http/https）"],
                    ] as [String: Any],
                    "required": ["url"],
                ] as [String: Any],
            ] as [String: Any],
        ],
    ]

    /// 追加到系统提示词的 ReAct 指引。
    static let systemHint = """
    你可以按 ReAct 方式使用工具：先思考缺什么信息，再调用工具（web_search / read_webpage），\
    观察结果后继续推理。工具调用不超过 4 轮；最终回答要简洁，引用检索到的信息时附来源链接。
    """

    // MARK: - 执行入口

    /// 执行一次工具调用，返回给模型看的纯文本结果（出错也返回说明性文本，不让循环崩掉）。
    static func execute(_ call: ToolCall, glmKey: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "web_search":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "搜索关键词为空" }
            do {
                return try await search(query, glmKey: glmKey)
            } catch {
                return "搜索失败：\(error.localizedDescription)。请基于已有知识回答。"
            }
        case "read_webpage":
            let url = (args["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return "URL 为空" }
            do {
                return try await readPage(url, glmKey: glmKey)
            } catch {
                return "读取网页失败：\(error.localizedDescription)"
            }
        default:
            return "未知工具：\(call.name)"
        }
    }

    // MARK: - 搜索

    static func search(_ query: String, glmKey: String) async throws -> String {
        let key = glmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            return try await glmSearch(query, key: key)
        }
        return try await ddgSearch(query)
    }

    /// 智谱 BigModel 网络搜索 API（POST /paas/v4/web_search）。
    private static func glmSearch(_ query: String, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/paas/v4/web_search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "search_query": String(query.prefix(70)),
            "search_engine": "search_std",
            "search_intent": false,
            "count": 5,
            "content_size": "medium",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: String(data: data.prefix(200), encoding: .utf8) ?? ""
            )
        }

        struct GLMSearchResponse: Decodable {
            struct Item: Decodable {
                let title: String?
                let content: String?
                let link: String?
                let media: String?
            }
            let searchResult: [Item]?
            enum CodingKeys: String, CodingKey {
                case searchResult = "search_result"
            }
        }
        let decoded = try JSONDecoder().decode(GLMSearchResponse.self, from: data)
        let items = decoded.searchResult ?? []
        guard !items.isEmpty else { return "没有搜到结果" }
        return items.enumerated().map { i, item in
            let media = item.media.map { "（\($0)）" } ?? ""
            return "\(i + 1). \(item.title ?? "无标题")\(media)\n   \(item.content ?? "")\n   \(item.link ?? "")"
        }.joined(separator: "\n")
    }

    /// 免费回退：DuckDuckGo Lite HTML 解析。
    private static func ddgSearch(_ query: String) async throws -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)") else {
            throw AgentError.badBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.http(status: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let results = Self.parseDDGLite(html)
        guard !results.isEmpty else { return "没有搜到结果（DuckDuckGo 免费回退）" }
        return results.prefix(5).enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.snippet)\n   \(r.url)"
        }.joined(separator: "\n")
    }

    struct DDGResult {
        let title: String
        let snippet: String
        let url: String
    }

    static func parseDDGLite(_ html: String) -> [DDGResult] {
        var results: [DDGResult] = []
        guard let linkRegex = try? NSRegularExpression(
            pattern: #"<a rel="nofollow" href="([^"]+)">(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return results }
        guard let snippetRegex = try? NSRegularExpression(
            pattern: #"class="result-snippet">(.*?)</td>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return results }

        let range = NSRange(html.startIndex..., in: html)
        var links: [(url: String, title: String)] = []
        for m in linkRegex.matches(in: html, options: [], range: range) {
            guard let href = Range(m.range(at: 1), in: html),
                  let title = Range(m.range(at: 2), in: html) else { continue }
            let raw = String(html[href]).replacingOccurrences(of: "&amp;", with: "&")
            let cleanTitle = stripTags(String(html[title]))
            guard !cleanTitle.isEmpty else { continue }
            links.append((url: Self.realURL(fromDDGHref: raw), title: cleanTitle))
        }
        var snippets: [String] = []
        for m in snippetRegex.matches(in: html, options: [], range: range) {
            guard let s = Range(m.range(at: 1), in: html) else { continue }
            snippets.append(stripTags(String(html[s])))
        }
        for (i, link) in links.enumerated() where link.url.hasPrefix("http") {
            let snippet = i < snippets.count ? snippets[i] : ""
            results.append(DDGResult(title: link.title, snippet: snippet, url: link.url))
        }
        return results
    }

    /// DDG 跳转链接 //duckduckgo.com/l/?uddg=<encoded>&rut=… → 还原真实 URL。
    static func realURL(fromDDGHref href: String) -> String {
        guard href.contains("uddg=") else { return href.hasPrefix("//") ? "https:" + href : href }
        let part = href.contains("?") ? String(href.split(separator: "?", maxSplits: 1)[1]) : href
        for pair in part.split(separator: "&") {
            if pair.hasPrefix("uddg=") {
                let value = pair.dropFirst(5)
                return value.removingPercentEncoding ?? String(value)
            }
        }
        return href
    }

    // MARK: - 网页阅读

    static func readPage(_ urlString: String, glmKey: String) async throws -> String {
        let key = glmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            return try await glmRead(urlString, key: key)
        }
        return try await directRead(urlString)
    }

    /// 智谱 BigModel 网页阅读 API（POST /paas/v4/reader）。
    private static func glmRead(_ urlString: String, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/paas/v4/reader")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": urlString,
            "timeout": 15,
            "return_format": "text",
            "retain_images": false,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.http(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: String(data: data.prefix(200), encoding: .utf8) ?? ""
            )
        }

        struct GLMReaderResponse: Decodable {
            struct ReaderResult: Decodable {
                let title: String?
                let content: String?
            }
            let readerResult: ReaderResult?
            enum CodingKeys: String, CodingKey {
                case readerResult = "reader_result"
            }
        }
        let decoded = try JSONDecoder().decode(GLMReaderResponse.self, from: data)
        var content = decoded.readerResult?.content ?? ""
        if content.isEmpty { throw AgentError.emptyResponse }
        if content.count > 3000 { content = String(content.prefix(3000)) + " …（已截断）" }
        return content
    }

    /// 免费回退：直接抓取并剥离 HTML。
    private static func directRead(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AgentError.badBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.http(status: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "")
        }
        guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw AgentError.badResponse
        }
        text = stripTags(text)
        guard !text.isEmpty else { throw AgentError.emptyResponse }
        if text.count > 3000 { text = String(text.prefix(3000)) + " …（已截断）" }
        return text
    }

    // MARK: - HTML 清理

    static func stripTags(_ html: String) -> String {
        var text = html
        for pattern in [#"<script[^>]*>.*?</script>"#, #"<style[^>]*>.*?</style>"#, #"<!--.*?--> "#] {
            text = text.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
}
