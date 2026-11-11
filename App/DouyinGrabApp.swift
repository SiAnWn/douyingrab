import SwiftUI
import UIKit

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
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("链接") {
                    TextField("抖音链接 / 分享口令", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.primary)
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
            .sheet(item: $shareURL) { url in
                ActivityView(items: [url])
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
            shareURL = file
            status = "完成，点右上角“分享”存到文件/相册"
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable {
    var id: String { absoluteString }
}
