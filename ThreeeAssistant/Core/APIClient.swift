import Foundation
import Security

/// 与自建服务端通信的唯一入口。
///
/// ## 两个和普通 App 不一样的地方
///
/// **① 自签证书**：服务端首次启动自己生成证书，iOS 默认会直接拒绝。
///    这里用 [TrustStore] 做「首次信任 + 之后比对指纹」，具体见 `urlSession(_:didReceive:)`。
///
/// **② 可能是 http**：很多人在局域网里还没配证书，直接 `http://192.168.x.x:8443`。
///    Info.plist 里开了 `NSAllowsArbitraryLoads`，否则 http 请求会被系统拦掉。
///    ⚠️ 这一条是为了「能连上自己的局域网服务器」，代价是 http 下没有加密 ——
///    正式环境请务必用 https。
final class APIClient: NSObject, @unchecked Sendable {

    static let shared = APIClient()

    /// `baseURL` 和 `token` 会被主线程写（登录、登出）、被网络回调的后台线程读。
    /// `@unchecked Sendable` 等于向编译器承诺「我自己保证线程安全」，
    /// 所以这里必须自己加锁——否则这个承诺是假的。
    private let stateLock = NSLock()
    private var _baseURL: URL?
    private var _token: String?

    private var baseURL: URL? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _baseURL }
    }

    private var token: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _token }
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        // 每次都问服务器要最新的：日程是多端同步的，缓存会让人看到「改了没变」
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - 配置

    func configure(baseURL: URL, token: String?) {
        stateLock.lock()
        _baseURL = baseURL
        _token = token
        stateLock.unlock()
    }

    func setToken(_ token: String?) {
        stateLock.lock()
        _token = token
        stateLock.unlock()
    }

    /// 把用户输入的一行字变成一个能用的地址。
    ///
    /// 老人机式地宽容：没写协议就补 https，没写端口就补 8443，
    /// 末尾多打了斜杠也能吃掉。**猜错的代价是「连不上」，而报错文案会指回来。**
    static func normalize(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw APIError.badURL(raw) }

        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }

        guard var comps = URLComponents(string: s) else { throw APIError.badURL(raw) }
        if comps.port == nil, comps.scheme == "https" { comps.port = 8443 }
        guard let url = comps.url else { throw APIError.badURL(raw) }
        return url
    }

    // MARK: - 请求

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, body: Data?) async throws -> T {
        try await send("POST", path, query: [], body: body)
    }

    func put<T: Decodable>(_ path: String, body: Data?) async throws -> T {
        try await send("PUT", path, query: [], body: body)
    }

    /// 删除类接口只关心成败，响应体（`{"ok":true}`）没有解析价值。
    ///
    /// `query` 默认空 —— 绝大多数删除（整条日程、日历）走路径参数就够。
    /// 但**删重复日程里的某一次**是例外：服务端要的是
    /// `DELETE /api/events/{id}/occurrence?key=<epoch秒>`，
    /// 用 query 而不是请求体（见 `handleDeleteOccurrence` 里的
    /// `r.URL.Query().Get("key")`）。DELETE 带 body 在部分代理上会被吃掉，
    /// 服务端也没去读，所以这里只能走 query。
    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await sendRaw("DELETE", path, query: query, body: nil)
    }

    /// 同样「不关心响应体」的 POST（登出用）
    @discardableResult
    func postRaw(_ path: String, body: Data?) async throws -> Data {
        try await sendRaw("POST", path, query: [], body: body)
    }

    /// 「不关心响应体」的 PUT。
    ///
    /// 改单次日程的接口返回的是 `{"event": {...}}`，
    /// 但调用方紧接着就会 `refresh()` 重拉实例列表，
    /// 把这个响应强类型解码出来纯属多此一举 —— 多定义一个模型就多一处会过期的假设。
    @discardableResult
    func putRaw(_ path: String, body: Data?) async throws -> Data {
        try await sendRaw("PUT", path, query: [], body: body)
    }

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> T {
        let data = try await sendRaw(method, path, query: query, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func sendRaw(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Data {
        guard let base = baseURL else { throw APIError.notConfigured }

        // ⚠️ 用 URL(string:relativeTo:) 而不是 appendingPathComponent：
        //    appendingPathComponent 会把 "/api/health" 里的斜杠当成路径分隔再拼一次，
        //    拼出来是 "/api/health" 还是 "%2Fapi%2Fhealth" 取决于前导斜杠，很容易踩坑。
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.badURL(path)
        }
        comps.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL(path) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData = body {
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .cancelled:
                throw CancellationError()
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                throw APIError.certificateMismatch
            default:
                throw APIError.network(e.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("响应格式不对")
        }

        // 服务端的错误统一是 {"error": "给人看的话"}，优先用它的文案 ——
        // 那些句子是服务端作者针对具体场景写的（「这个日历你没有编辑权限」等），
        // 客户端自己编一句只会更模糊
        let serverMessage = Self.errorMessage(from: data)

        if http.statusCode == 401 {
            throw APIError.unauthorized(serverMessage ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, serverMessage ?? "请求失败（\(http.statusCode)）")
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["error"] as? String
        else { return nil }
        return msg
    }
}

// MARK: - 自签证书

extension APIClient: URLSessionDelegate {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // 取叶子证书算指纹
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = TrustStore.sha256(of: der)

        if let known = TrustStore.fingerprint(for: host) {
            if known == fingerprint {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                // 指纹变了：可能是换了服务器，也可能是有人在中间。
                // 这里**不弹窗**——弹窗会被用户一律点「继续」，等于没做校验。
                // 交给设置页让用户明确地重新信任。
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // 第一次见这台服务器：记下来。用户是在「填写自己服务器的地址」之后
        // 才走到这一步的，这本身就是一次明确的意图表达。
        TrustStore.remember(fingerprint, for: host)
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
