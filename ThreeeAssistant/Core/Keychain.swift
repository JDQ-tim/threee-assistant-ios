import Foundation
import Security

/// 令牌的钥匙串存取。
///
/// 为什么不放 UserDefaults：那是明文 plist，越狱设备或备份文件里能直接读到。
/// 令牌等同于密码 —— 拿到它就能读写这个账号的全部日程。
enum Keychain {

    private static let service = "cn.threees.assistant.ios"

    static func save(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 先删再写：SecItemUpdate 在「条目不存在」时会失败，
        // 写成「删+加」两步比判断错误码简单且不会漏
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // 只在本机可用，且设备解锁后才读得到
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
