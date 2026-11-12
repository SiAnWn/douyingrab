import Foundation

struct QualityOption {
    let label: String
    let url: URL
    let width: Int
    let height: Int
    let sizeBytes: Int
    let isOriginal: Bool
}

struct ParseResult: Identifiable {
    let id = UUID()
    let videoID: String
    let title: String
    let author: String
    let options: [QualityOption]
}

enum GError: LocalizedError {
    case noURL, failed(String), noData, noStream, http(Int)
    var errorDescription: String? {
        switch self {
        case .noURL: return "链接里没找到网址"
        case .failed(let m): return m
        case .noData: return "接口没返回数据"
        case .noStream: return "没有可下载的清晰度"
        case .http(let c): return "HTTP \(c)"
        }
    }
}

enum DouyinAPI {
    static let endpoint = "https://api-new.ifphp.com/api/dyjx"
    static let key = "bp_live_5c7f4981cc4b27d09b57821cf98e1d270b0a812c9607b4f559d14d14df39122a"
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func extractURL(_ text: String) -> String? {
        if let r = RegexHelper.range(text, pattern: "https?://[^\\s，,、]+") {
            return String(text[r])
        }
        return nil
    }

    static func parse(link: String) async throws -> ParseResult {
        guard let u = extractURL(link) else { throw GError.noURL }
        guard var comp = URLComponents(string: endpoint) else { throw GError.noData }
        comp.queryItems = [URLQueryItem(name: "key", value: key),
                           URLQueryItem(name: "url", value: u)]
        guard let reqURL = comp.url else { throw GError.noData }
        var req = URLRequest(url: reqURL)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            throw GError.http(h.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GError.noData
        }
        let code = (obj["code"] as? Int) ?? ((obj["code"] as? NSNumber)?.intValue ?? -1)
        if code != 200 {
            throw GError.failed((obj["message"] as? String) ?? (obj["error"] as? String) ?? "解析失败")
        }
        guard let d = obj["data"] as? [String: Any] else { throw GError.noData }
        let title = (d["desc"] as? String) ?? (d["title"] as? String) ?? ""
        let author = ((d["author"] as? [String: Any])?["name"] as? String) ?? ""
        let vid = strOf(d["video_id"]) ?? ""

        var opts: [QualityOption] = []
        if let s = d["url"] as? String, let uu = URL(string: s) {
            opts.append(QualityOption(label: "原画（最高画质）",
                                      url: uu,
                                      width: intOf(d["width"]) ?? 0,
                                      height: intOf(d["height"]) ?? 0,
                                      sizeBytes: intOf(d["size"]) ?? 0,
                                      isOriginal: true))
        }
        if let vb = d["video_backup"] as? [[String: Any]] {
            for b in vb {
                guard let s = b["url"] as? String, let uu = URL(string: s) else { continue }
                let label = (b["label"] as? String) ?? (b["quality"] as? String) ?? "视频"
                opts.append(QualityOption(label: label,
                                          url: uu,
                                          width: intOf(b["width"]) ?? 0,
                                          height: intOf(b["height"]) ?? 0,
                                          sizeBytes: intOf(b["size"]) ?? 0,
                                          isOriginal: false))
            }
        }
        if opts.isEmpty { throw GError.noStream }
        return ParseResult(videoID: vid.isEmpty ? u : vid, title: title, author: author, options: opts)
    }

    static func download(_ url: URL, progress: @escaping @Sendable (Double, Double) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        return try await d.start(url, referer: "https://www.douyin.com/", ua: ua)
    }

    private static func strOf(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}

enum RegexHelper {
    static func range(_ s: String, pattern: String) -> Range<String.Index>? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: ns), let r = Range(m.range, in: s) else { return nil }
        return r
    }
}

final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let progress: @Sendable (Double, Double) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var smooth: Double = 0

    init(progress: @escaping @Sendable (Double, Double) -> Void) { self.progress = progress }

    func start(_ url: URL, referer: String, ua: String) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: req)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            self.cont = c
            self.lastTime = Date()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        let frac = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        if dt > 0 {
            let inst = Double(totalBytesWritten - lastBytes) / dt
            smooth = smooth == 0 ? inst : smooth * 0.8 + inst * 0.2
        }
        lastBytes = totalBytesWritten
        lastTime = now
        progress(frac, smooth)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dy_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil {
            cont?.resume(returning: dest)
        } else {
            cont?.resume(throwing: GError.failed("保存临时文件失败"))
        }
        cont = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error, cont != nil {
            cont?.resume(throwing: e)
            cont = nil
            session.finishTasksAndInvalidate()
        }
    }
}
