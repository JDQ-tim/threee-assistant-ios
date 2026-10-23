import Foundation
import CryptoKit
import Security

/// 记录「这台设备信任过哪台服务器的哪张证书」。
///
/// ## 为什么需要它
///
/// 服务端是**自托管**的，首次启动会自己生成一张自签证书（见服务端 README 的
/// `certs/server.crt`）。iOS 不像安卓那样可以往 APK 里塞一个 CA 文件当信任锚，
/// 而如果直接「无条件接受任何证书」，等于把这个 App 变成中间人的靶子 ——
/// 同一批人还会用它同步私人日程。
///
/// 所以走 **TOFU（Trust On First Use）**：第一次连某台服务器时把它的证书指纹
/// 记下来，以后每次都比对。指纹对不上就断开，让用户自己决定要不要重新信任。
///
/// 这比「接受一切」安全得多，又不用逼用户去装描述文件。
enum TrustStore {

    private static let defaultsKey = "threees.trustedHosts"

    /// host → SHA256(证书 DER)
    private static var map: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func fingerprint(for host: String) -> String? {
        map[host.lowercased()]
    }

    static func remember(_ fingerprint: String, for host: String) {
        var m = map
        m[host.lowercased()] = fingerprint
        map = m
    }

    static func forget(_ host: String) {
        var m = map
        m.removeValue(forKey: host.lowercased())
        map = m
    }

    /// 「设置」里的那个按钮：一次清掉全部
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static var isEmpty: Bool { map.isEmpty }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
