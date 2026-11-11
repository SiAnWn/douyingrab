import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var status: String = "粘贴抖音分享链接或口令，点“解析并下载”"
    @State private var busy: Bool = false
    @State private var shareItem: ShareItem?
    @State private var showFolderPicker: Bool = false
    @State private var chosenName: String = ""
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
                            Button {
                                input = ""
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
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

                Section("保存目录（可选）") {
                    Button { showFolderPicker = true } label: { Text("选择文件夹…") }
                    if chosenName.isEmpty {
                        Text("未设置则用系统分享面板。注意：iOS 不允许选到别的 app 的目录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("当前：\(chosenName)").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除") { FolderStore.clear(); chosenName = "" }.font(.footnote)
                        }
                    }
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
                            Button("清空") { history = []; HistoryStore.save([]) }
                                .font(.caption)
                        }
                    }
                    footer: { Text("点一条可重新下载。已解析过的链接不会重复下载。")
                        .font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("抖音原画质")
            .onAppear {
                chosenName = FolderStore.load()?.lastPathComponent ?? ""
                history = HistoryStore.load()
            }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { res in
                switch res {
                case .success(let urls):
                    if let url = urls.first {
                        let ok = url.startAccessingSecurityScopedResource()
                        FolderStore.save(url)
                        if ok { url.stopAccessingSecurityScopedResource() }
                        chosenName = url.lastPathComponent
                        status = "已设置保存目录：\(url.lastPathComponent)"
                    }
                case .failure(let e):
                    status = "选择目录失败：\(e.localizedDescription)"
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url]).ignoresSafeArea()
            }
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

            var saved = false
            if let dir = FolderStore.load(), dir.startAccessingSecurityScopedResource() {
                let dest = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: file, to: dest)
                    status = "已保存到「\(dir.lastPathComponent)/\(name)」"
                    saved = true
                } catch { status = "写入目录失败：\(error.localizedDescription)" }
                dir.stopAccessingSecurityScopedResource()
            }
            if !saved {
                shareItem = ShareItem(url: file)
                status = "已下载，点右上角“分享”→存储到文件→选 SlidePlay 目录"
            }

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

enum FolderStore {
    private static let key = "saveFolderBookmark"
    static func save(_ url: URL) {
        if let data = try? url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data.base64EncodedString(), forKey: key)
        }
    }
    static func load() -> URL? {
        guard let s = UserDefaults.standard.string(forKey: key),
              let data = Data(base64Encoded: s) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
