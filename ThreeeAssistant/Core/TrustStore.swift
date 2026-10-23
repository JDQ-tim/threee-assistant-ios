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
///
/// ⚠️ 这个类型会被 `URLSessionDelegate` 的**后台线程**调用（证书校验回调），
///    同时也会被主线程的设置页调用。UserDefaults 本身线程安全，
///    但「读-改-写」的 map 组合操作不是，所以统一用 `lock` 串行化。
enum TrustStore {

    private static let defaultsKey = "threees.trustedHosts"

    /// 保护 `map` 的读改写；UserDefaults 自身的读写是线程安全的，
    /// 这里锁的是「取出字典→改一项→写回」这个复合操作
    private static let lock = NSLock()

    /// host → SHA256(证书 DER)
    private static var map: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func fingerprint(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map[host.lowercased()]
    }

    static func remember(_ fingerprint: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        var m = map
        m[host.lowercased()] = fingerprint
        map = m
    }

    static func forget(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        var m = map
        m.removeValue(forKey: host.lowercased())
        map = m
    }

    /// 「设置」里的那个按钮：一次清掉全部
    static func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return map.isEmpty
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
