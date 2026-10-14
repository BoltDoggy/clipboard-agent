import Foundation

/// 一个被复制的文件的元信息（从 URL 派生，读大小/时间各一次）。
struct CopiedFile: Equatable {
    let url: URL
    let isDirectory: Bool
    let sizeBytes: Int64
    let modifiedAt: Date?

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var path: String { url.path }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        self.isDirectory = values?.isDirectory ?? false
        self.sizeBytes = values?.fileSize.map(Int64.init) ?? 0
        self.modifiedAt = values?.contentModificationDate
    }

    var sizeLabel: String {
        guard sizeBytes > 0 else { return isDirectory ? "文件夹" : "—" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// 文本类扩展名白名单：内容可以安全读取并喂给模型。
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "csv", "json", "xml", "yaml", "yml", "toml", "ini", "plist",
        "swift", "m", "h", "c", "cpp", "cc", "hpp", "py", "rb", "go", "rs", "java", "kt", "kts",
        "js", "ts", "tsx", "jsx", "vue", "svelte", "html", "css", "scss", "sh", "bash", "zsh",
        "sql", "gitignore", "env", "lock", "gradle", "makefile", "dockerfile",
    ]

    var isTextLike: Bool { !isDirectory && Self.textExtensions.contains(ext) }
}

enum FileAnalyzer {
    /// 预览文案：第一个文件名 + 数量；多文件时列出前几个。
    static func previewTitle(_ files: [CopiedFile]) -> String {
        guard let first = files.first else { return "" }
        if files.count == 1 { return first.name }
        let names = files.prefix(3).map(\.name).joined(separator: "、")
        return files.count > 3 ? "\(names) 等 \(files.count) 个" : names
    }

    /// 文本内容摘录：读第一个文本类文件（≤200KB），截 4000 字。非文本返回占位说明。
    static func textPreview(_ files: [CopiedFile]) -> String {
        guard let file = files.first(where: \.isTextLike) else {
            return "（非文本类文件，无法直接读取内容）"
        }
        guard file.sizeBytes <= 200 * 1024 else {
            return "（文本文件过大：\(file.sizeLabel)，跳过内容读取）"
        }
        guard let text = try? String(contentsOf: file.url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "（无法按 UTF-8 解码文件内容）"
        }
        return text.count > 4000 ? String(text.prefix(4000)) + "\n…（已截断）" : text
    }

    /// 拼给深度模型的输入。
    static func deepInput(_ files: [CopiedFile]) -> String {
        let list = files.prefix(5).map { file -> String in
            var line = "- \(file.name)（\(file.isDirectory ? "文件夹" : file.ext.isEmpty ? "无扩展名" : file.ext) 文件，\(file.sizeLabel)"
            if let date = file.modifiedAt {
                line += "，修改于 \(date.formatted(.dateTime.month().day().hour().minute()))"
            }
            line += "）路径：\(file.path)"
            return line
        }.joined(separator: "\n")
        let extra = files.count > 5 ? "\n（另有 \(files.count - 5) 个未列出）" : ""
        return """
        用户在 Finder 复制了文件：
        \(list)\(extra)

        【文件内容摘录】
        \(textPreview(files))
        """
    }

    /// 本地即时操作（不依赖模型，文件事件一到就显示）。
    static func localActions(_ files: [CopiedFile]) -> [RecommendedAction] {
        guard let first = files.first else { return [] }
        let path = first.path
        let name = first.name
        let markdown = "[\(name)](file://\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))"
        return [
            RecommendedAction(label: "复制路径", type: "copy", arg: path),
            RecommendedAction(label: "复制文件名", type: "copy", arg: name),
            RecommendedAction(label: "Finder 中显示", type: "reveal", arg: path),
            RecommendedAction(label: "复制 MD 链接", type: "copy", arg: markdown),
        ]
    }
}
