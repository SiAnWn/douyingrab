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

    var body: some View {
        NavigationStack {
            Form {
                Section("链接") {
                    TextField("抖音链接 / 分享口令", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("保存目录") {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Text("选择 SlidePlay 目录…")
                    }
                    if chosenName.isEmpty {
                        Text("未设置：将用系统分享面板。请先选一次 On My iPhone/SlidePlay 目录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("当前：\(chosenName)").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除") { FolderStore.clear(); chosenName = "" }
                                .font(.footnote)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await run() }
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
            }
            .navigationTitle("抖音原画质")
            .onAppear { chosenName = FolderStore.load()?.lastPathComponent ?? "" }
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
                ActivityView(items: [item.url])
                    .ignoresSafeArea()
            }
        }
    }

    @MainActor
    private func run() async {
        busy = true
        defer { busy = false }
        do {
            status = "解析视频ID…"
            let svc = DouyinService()
            guard let id = await svc.resolveID(from: input) else {
                status = GError.noID.errorDescription ?? "解析失败"; return
            }
            status = "打开页面取接口（约10秒）…"
            let data = try await svc.fetchDetail(id: id)
            status = "挑选最高画质…"
            guard let best = svc.pickBest(data) else {
                status = GError.noStream.errorDescription ?? "无可用流"; return
            }
            status = "下载 \(best.width)x\(best.height)…"
            let file = try await svc.download(best.url)
            let name = Self.safeFileName(best.title, w: best.width, h: best.height)

            var saved = false
            if let dir = FolderStore.load(), dir.startAccessingSecurityScopedResource() {
                let dest = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: file, to: dest)
                    status = "已保存到「\(dir.lastPathComponent)/\(name)」，去 SlidePlay 里就能播"
                    saved = true
                } catch {
                    status = "写入目录失败：\(error.localizedDescription)"
                }
                dir.stopAccessingSecurityScopedResource()
            }
            if !saved {
                shareItem = ShareItem(url: file)
                status = "未设置保存目录，已弹出分享；请先点上方“选择 SlidePlay 目录”"
            }
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }

    static func safeFileName(_ title: String, w: Int, h: Int) -> String {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        base = base.components(separatedBy: illegal).joined(separator: " ")
        while base.contains("  ") { base = base.replacingOccurrences(of: "  ", with: " ") }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.count > 40 { base = String(base.prefix(40)) }
        if base.isEmpty { base = "douyin_\(w)x\(h)_\(Int(Date().timeIntervalSince1970))" }
        return base + ".mp4"
    }
}

enum FolderStore {
    private static let key = "saveFolderBookmark"
    static func save(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data.base64EncodedString(), forKey: key)
        }
    }
    static func load() -> URL? {
        guard let s = UserDefaults.standard.string(forKey: key),
              let data = Data(base64Encoded: s) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
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
