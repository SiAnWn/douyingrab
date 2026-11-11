import Foundation
import WebKit

struct PickedVideo {
    let url: URL
    let width: Int
    let height: Int
}

enum GError: LocalizedError {
    case noID, timeout, noDetail, noStream, http(Int)
    var errorDescription: String? {
        switch self {
        case .noID: return "链接里没找到视频ID"
        case .timeout: return "解析超时（抖音可能弹了登录/验证）"
        case .noDetail: return "没抓到接口数据"
        case .noStream: return "没有可用播放地址"
        case .http(let c): return "HTTP \(c)"
        }
    }
}

@MainActor
final class DouyinService: NSObject, WKScriptMessageHandler {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private var web: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var settled = false

    // MARK: - 解析视频 ID（跟随短链跳转，读最终 URL）
    func resolveID(from text: String) async -> String? {
        guard let r = RegexHelper.range(text, pattern: "https?://[^\\s，,、]+"),
              let url = URL(string: String(r)) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
                let final = (resp as? HTTPURLResponse)?.url?.absoluteString ?? url.absoluteString
                let id = RegexHelper.firstGroup(final, pattern: "/video/(\\d{15,20})")
                    ?? RegexHelper.firstGroup(final, pattern: "(\\d{15,20})")
                c.resume(returning: id)
            }
            task.resume()
        }
    }

    // MARK: - 用 WKWebView 打开视频页，拦截页面自己发的 aweme/detail 请求
    func fetchDetail(id: String) async throws -> Data {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "gotDetail")
        ucc.addUserScript(WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc

        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        w.customUserAgent = Self.ua
        self.web = w
        settled = false

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            self.continuation = c
            if let url = URL(string: "https://www.douyin.com/video/\(id)") {
                w.load(URLRequest(url: url))
            } else {
                fail(GError.noID)
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.fail(GError.timeout)
            }
        }
    }

    private func fail(_ e: Error) {
        guard !settled else { return }
        settled = true
        continuation?.resume(throwing: e); continuation = nil
        web?.stopLoading(); web = nil
    }
    private func succeed(_ d: Data) {
        guard !settled else { return }
        settled = true
        continuation?.resume(returning: d); continuation = nil
        web?.stopLoading(); web = nil
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "gotDetail",
           let s = message.body as? String,
           s.contains("aweme_detail"),
           let d = s.data(using: .utf8) {
            succeed(d)
        }
    }

    // MARK: - 挑选最高分辨率的无水印流
    func pickBest(_ data: Data) -> PickedVideo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let det = obj["aweme_detail"] as? [String: Any],
              let v = det["video"] as? [String: Any] else { return nil }
        var cands: [(score: Int, w: Int, h: Int, url: URL)] = []
        func add(_ pa: Any?) {
            guard let pa = pa as? [String: Any],
                  let arr = pa["url_list"] as? [String],
                  let w = pa["width"] as? Int, let h = pa["height"] as? Int else { return }
            for us in arr { if let u = URL(string: us) { cands.append((w * h, w, h, u)) } }
        }
        add(v["play_addr_265"])
        add(v["play_addr"])
        let brs = (det["bit_rate_list"] as? [[String: Any]]) ?? (v["bit_rate"] as? [[String: Any]])
        if let brs { for b in brs { add(b["play_addr"]) } }
        cands.sort { $0.score > $1.score }
        guard let top = cands.first else { return nil }
        return PickedVideo(url: top.url, width: top.w, height: top.h)
    }

    // MARK: - 下载
    func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GError.http(http.statusCode)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("douyin_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    static let hookJS = """
    (function(){
      function emit(u,t){ try{ if(u && u.indexOf('aweme/detail')>-1 && t && t.indexOf('aweme_detail')>-1){ window.webkit.messageHandlers.gotDetail.postMessage(t);} }catch(e){} }
      var of=window.fetch;
      if(of){ window.fetch=function(){ var a=arguments, u=(a[0]&&a[0].url)||a[0]; var p=of.apply(this,a); try{ p.then(function(r){ r.clone().text().then(function(t){emit(u,t);}); }); }catch(e){} return p; }; }
      var oo=XMLHttpRequest.prototype.open, os=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open=function(m,u){ this.__u=u; return oo.apply(this,arguments); };
      XMLHttpRequest.prototype.send=function(){ var x=this; x.addEventListener('load',function(){ try{emit(x.__u,x.responseText);}catch(e){} }); return os.apply(this,arguments); };
    })();
    """
}

enum RegexHelper {
    static func range(_ s: String, pattern: String) -> Range<String.Index>? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: ns), let r = Range(m.range, in: s) else { return nil }
        return r
    }
    static func firstGroup(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: ns) else { return nil }
        for g in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: g), in: s) { return String(s[r]) }
        }
        return nil
    }
}
