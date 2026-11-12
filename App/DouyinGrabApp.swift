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
    @State private var progress: Double = 0
    @State private var speedText: String = ""
    @State private var showProgress: Bool = false
    @State private var quota = Quota.zero
    @State private var qMin = ""
    @State private var qHour = ""
    @State private var qDay = ""
    @State private var qMonth = ""
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
                    if showProgress {
                        ProgressView(value: min(max(progress, 0), 1))
                        Text("\(Int(progress * 100))% · \(speedText)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("接口配额（可手动校正，app 自动累加本机调用）") {
                    quotaRow("本分钟", $qMin, .minute, CallStats.limits.minute)
                    quotaRow("本小时", $qHour, .hour, CallStats.limits.hour)
                    quotaRow("今日", $qDay, .day, CallStats.limits.day)
                    quotaRow("本月", $qMonth, .month, CallStats.limits.month)
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
            .onAppear { history = HistoryStore.load(); refreshQuota() }
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
        if let reason = CallStats.blockReason() {
            refreshQuota()
            status = "已达限制：\(reason)"
            return
        }
        busy = true; defer { busy = false }
        do {
            status = "解析中…"
            result = try await DouyinAPI.parse(link: link)
            CallStats.record(); refreshQuota()
            status = "选一个清晰度下载"
        } catch {
            CallStats.record(); refreshQuota()
            if let g = error as? GError, case .http(429) = g {
                status = "已达频率限制(429)，请稍后再试"
            } else {
                status = "失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshQuota() {
        let q = CallStats.current()
        quota = q
        qMin = "\(q.minute)"; qHour = "\(q.hour)"; qDay = "\(q.day)"; qMonth = "\(q.month)"
    }

    @ViewBuilder
    private func quotaRow(_ label: String, _ text: Binding<String>, _ w: CallStats.Window, _ limit: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .border(Color.secondary.opacity(0.35), width: 1)
            Text("/\(limit)").font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: text.wrappedValue) { nv in
            if let v = Int(nv) { CallStats.set(w, v); quota = CallStats.current() }
        }
    }

    @MainActor
    private func pick(_ res: ParseResult, _ opt: QualityOption) async {
        let dkey = "\(res.videoID)|\(opt.label)"
        result = nil
        busy = true; defer { busy = false }
        do {
            status = "下载 \(opt.label)…"
            showProgress = true; progress = 0; speedText = ""
            let file = try await DouyinAPI.download(opt.url) { frac, sps in
                Task { @MainActor in
                    self.progress = frac
                    self.speedText = Self.fmtSpeed(sps)
                }
            }
            showProgress = false
            let name = Self.fileName(res.author, res.title, opt)
            if SavePaths.write(file, name: name) {
                DownloadStore.set(dkey, name)
                status = "已保存到 文件App › 我的iPhone › DouyinGrab › \(name)"
                recordHistory(res)
            } else {
                status = "保存失败：无法写入目录"
            }
        } catch {
            showProgress = false
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

    static func fmtSpeed(_ bps: Double) -> String {
        if bps <= 0 { return "计算中…" }
        if bps >= 1048576 { return String(format: "%.1f MB/s", bps / 1048576.0) }
        return String(format: "%.0f KB/s", bps / 1024.0)
    }
}

struct QualitySheet: View {
    let result: ParseResult
    let downloaded: (QualityOption) -> Bool
    let onPick: (QualityOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOpt: QualityOption?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(result.options.enumerated()), id: \.offset) { _, opt in
                        Button {
                            if downloaded(opt) { confirmOpt = opt } else { onPick(opt) }
                        } label: {
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
            .alert("已经下载过",
                   isPresented: Binding(get: { confirmOpt != nil },
                                       set: { if !$0 { confirmOpt = nil } }),
                   presenting: confirmOpt) { opt in
                Button("取消", role: .cancel) {}
                Button("重新下载") { onPick(opt) }
            } message: { _ in
                Text("这个清晰度之前已下载过，要重新下载吗？")
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
