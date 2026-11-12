import SwiftUI

@main
struct DouyinGrabApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var input: String = ""
    @State private var status: String = "粘贴抖音链接 → 选清晰度 → 自动存到 文件App › 我的iPhone › DouyinGrab"
    @State private var busy: Bool = false
    @State private var history: [HistoryItem] = []
    @State private var result: ParseResult?
    @FocusState private var linkFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("链接") {
                    HStack {
                        TextField("抖音链接 / 分享口令", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($linkFocused)
                        if !input.isEmpty {
                            Button { input = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    Button {
                        linkFocused = false
                        Task { await doParse(link: input) }
                    } label: {
                        HStack { if busy { ProgressView() }; Text(busy ? "处理中…" : "解析 / 选清晰度") }
                    }
                    .disabled(busy)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }

                if !history.isEmpty {
                    Section {
                        ForEach(history) { item in
                            Button {
                                linkFocused = false
                                Task { await doParse(link: "https://www.douyin.com/video/\(item.id)") }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.author.isEmpty ? "抖音" : item.author) · \(item.title.isEmpty ? item.id : item.title)")
                                        .font(.callout).lineLimit(2)
                                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        HStack { Text("解析历史（\(history.count)）"); Spacer()
                            Button("清空") { history = []; HistoryStore.save([]) }.font(.caption) }
                    }
                    footer: { Text("点一条可重新选清晰度下载。")
                        .font(.caption).foregroundStyle(.secondary) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("收起键盘") { linkFocused = false } }
                }
            }
            .navigationTitle("抖音原画质")
            .onAppear { history = HistoryStore.load() }
            .sheet(item: $result) { res in
                QualitySheet(
                    result: res,
                    downloaded: { opt in isDownloaded(res, opt) },
                    onPick: { opt in Task { await pick(res, opt) } }
                )
            }
        }
    }

    @MainActor
    private func doParse(link: String) async {
        busy = true; defer { busy = false }
        do {
            status = "解析中…"
            result = try await DouyinAPI.parse(link: link)
            status = "选一个清晰度下载"
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func pick(_ res: ParseResult, _ opt: QualityOption) async {
        let dkey = "\(res.videoID)|\(opt.label)"
        if let fn = DownloadStore.map()[dkey], SavePaths.exists(fn) {
            result = nil
            status = "已下载过：\(fn)，去 文件App 里看"
            return
        }
        result = nil
        busy = true; defer { busy = false }
        do {
            status = "下载 \(opt.label)…"
            let file = try await DouyinAPI.download(opt.url)
            let name = Self.fileName(res.author, res.title, opt)
            if SavePaths.write(file, name: name) {
                DownloadStore.set(dkey, name)
                status = "已保存到 文件App › 我的iPhone › DouyinGrab › \(name)"
                recordHistory(res)
            } else {
                status = "保存失败：无法写入目录"
            }
        } catch {
            status = "下载失败：\(error.localizedDescription)"
        }
    }

    private func isDownloaded(_ res: ParseResult, _ opt: QualityOption) -> Bool {
        guard let fn = DownloadStore.map()["\(res.videoID)|\(opt.label)"] else { return false }
        return SavePaths.exists(fn)
    }

    private func recordHistory(_ res: ParseResult) {
        let item = HistoryItem(id: res.videoID, title: res.title, author: res.author,
                               date: Date(), filename: "")
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        HistoryStore.save(history)
    }

    static func fileName(_ author: String, _ title: String, _ opt: QualityOption) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        func clean(_ s: String) -> String {
            var t = s.components(separatedBy: illegal).joined(separator: " ")
            while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let a = clean(author), c = clean(title)
        var base = [a, c].filter { !$0.isEmpty }.joined(separator: " ")
        let tag = clean(opt.label).replacingOccurrences(of: "（最高画质）", with: "")
        if !tag.isEmpty { base += "_" + tag }
        if base.count > 60 { base = String(base.prefix(60)) }
        if base.isEmpty { base = "douyin_\(opt.width)x\(opt.height)_\(Int(Date().timeIntervalSince1970))" }
        return base + ".mp4"
    }
}

struct QualitySheet: View {
    let result: ParseResult
    let downloaded: (QualityOption) -> Bool
    let onPick: (QualityOption) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(result.options.enumerated()), id: \.offset) { _, opt in
                        Button { onPick(opt) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.label + (opt.isOriginal ? "  ⭐" : "")).font(.body)
                                    Text("\(opt.width)×\(opt.height) · \(Self.size(opt.sizeBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if downloaded(opt) { Text("已下载").font(.caption).foregroundStyle(.green) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("\(result.author.isEmpty ? "" : result.author + " · ")\(result.title)")
                        .font(.caption).lineLimit(2)
                }
            }
            .navigationTitle("选择清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    static func size(_ b: Int) -> String {
        b > 0 ? String(format: "%.1f MB", Double(b) / 1048576.0) : "大小未知"
    }
}

struct HistoryItem: Codable, Identifiable {
    let id: String
    var title: String
    var author: String
    var date: Date
    var filename: String
}

enum HistoryStore {
    private static let key = "parseHistory"
    static func load() -> [HistoryItem] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([HistoryItem].self, from: d) else { return [] }
        return arr
    }
    static func save(_ items: [HistoryItem]) {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

enum SavePaths {
    static var dir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }
    static func write(_ file: URL, name: String) -> Bool {
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.copyItem(at: file, to: dest)) != nil
    }
}

enum DownloadStore {
    private static let key = "downloadedMap"
    static func map() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
    static func set(_ k: String, _ name: String) {
        var m = map(); m[k] = name; UserDefaults.standard.set(m, forKey: key)
    }
}
