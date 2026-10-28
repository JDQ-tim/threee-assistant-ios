import Foundation

/// 网络层抛出的错误。
///
/// 设计意图：**每一种失败都带着「用户该怎么处理」**。
/// 自托管场景下「连不上」有四五种完全不同的原因（地址错、端口错、不在同一网络、
/// 证书没被信任、服务端没起），如果统一报「网络错误」，用户只能来问你。
enum APIError: Error, LocalizedError {
    case notConfigured
    case badURL(String)
    case network(String)
    case certificateMismatch
    case unauthorized(String)
    case server(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有设置服务器地址"
        case .badURL(let s):
            return "服务器地址不对：\(s)\n应该像 https://example.com:8443 这样"
        case .network(let detail):
            // 底层原因单独一行、缩进放最后，不打断前面三步排查指引。
            // 写「网络错误」而不写原因的话，四五种完全不同的失败看起来一模一样，用户没法自救。
            let hint = """
            连不上服务器。

            检查三件事：
            1. iPad/iPhone 和服务器在同一个网络（或者服务器有公网地址）
            2. 地址和端口写对了，自建服务默认是 8443
            3. 服务器正在运行
            """
            return detail.isEmpty ? hint : "\(hint)\n\n系统提示：\(detail)"
        case .certificateMismatch:
            return """
            服务器的证书变了，和第一次连接时记录的不一样。

            如果确实换过服务器或重新生成过证书，
            请到「设置 → 安全 → 忘记已信任的服务器」重新信任一次。
            """
        case .unauthorized(let msg):
            return msg.isEmpty ? "登录已失效，请重新登录" : msg
        case .server(_, let msg):
            return msg
        case .decoding(let detail):
            return "服务器返回的内容看不懂：\(detail)\n多半是服务端版本和这个 App 对不上"
        }
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}
