import SwiftUI

@main
struct DouyinGrabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var input: String = ""
    @State private var status: String = "粘贴抖音分享链接或口令，点“解析并下载”。视频会存到 文件App › 我的iPhone › DouyinGrab"
    @State private var busy: Bool = false
    @State private var history: [HistoryItem] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("链接") {
                    HStack {
                        TextField("抖音链接 / 分享口令", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !input.isEmpty {
                            Button { input = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            guard let id = await DouyinService().resolveID(from: input) else {
                                status = GError.noID.errorDescription ?? "解析失败"; return
                            }
                            await process(id: id, force: false)
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "处理中…" : "解析并下载")
                        }
                    }
                    .disabled(busy)

                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !history.isEmpty {
                    Section {
                        ForEach(history) { item in
                            Button {
                                Task { await process(id: item.id, force: true) }
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
                        HStack {
                            Text("解析历史（\(history.count)）")
                            Spacer()
                            Button("清空") { history = []; HistoryStore.save([]) }.font(.caption)
                        }
                    }
                    footer: { Text("点一条可重新下载。已解析过的链接不会重复下载。")
                        .font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("抖音原画质")
            .onAppear { history = HistoryStore.load() }
        }
    }

    @MainActor
    private func process(id: String, force: Bool) async {
        if !force, let dup = history.first(where: { $0.id == id }) {
            status = "已解析过：\(dup.author)《\(dup.title)》，见历史（点它能重存）"
            return
        }
        busy = true
        defer { busy = false }
        do {
            status = "打开页面取接口（约10秒）…"
            let svc = DouyinService()
            let data = try await svc.fetchDetail(id: id)
            status = "挑选最高画质…"
            guard let best = svc.pickBest(data) else {
                status = GError.noStream.errorDescription ?? "无可用流"; return
            }
            status = "下载 \(best.width)x\(best.height)…"
            let file = try await svc.download(best.url)
            let name = Self.safeFileName(best.author, best.title, w: best.width, h: best.height)
            status = Self.saveToDocuments(file, name: name)

            let item = HistoryItem(id: best.id.isEmpty ? id : best.id,
                                   title: best.title, author: best.author,
                                   date: Date(), filename: name)
            history.removeAll { $0.id == item.id }
            history.insert(item, at: 0)
            if history.count > 100 { history = Array(history.prefix(100)) }
            HistoryStore.save(history)
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }

    static func saveToDocuments(_ file: URL, name: String) -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: file, to: dest)) != nil {
            return "已保存到 文件App › 我的iPhone › DouyinGrab › \(name)"
        }
        return "保存失败：无法写入自己的目录"
    }

    static func safeFileName(_ author: String, _ title: String, w: Int, h: Int) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        func clean(_ s: String) -> String {
            var t = s.components(separatedBy: illegal).joined(separator: " ")
            while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let a = clean(author), c = clean(title)
        var base = [a, c].filter { !$0.isEmpty }.joined(separator: " ")
        if base.count > 48 { base = String(base.prefix(48)) }
        if base.isEmpty { base = "douyin_\(w)x\(h)_\(Int(Date().timeIntervalSince1970))" }
        return base + ".mp4"
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
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
