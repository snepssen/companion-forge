import CompanionCore
import CryptoKit
import Foundation
import Security

/// The key what it remembers is sealed with, kept in the Keychain on this
/// device only (never synced, never in a backup it could be restored from
/// elsewhere), and the folder it all lives in, protected on iPhone and iPad
/// so it can't be read while the device is locked.
public enum Vault {
    static let service = "com.snepssen.companion"
    static let account = "memory key"

    /// The sealer for this device; made on first use. Plain, with a reason,
    /// when the Keychain won't give the key.
    public static func sealer() -> (sealer: Sealer, problem: String?) {
        if let key = key() { return (Sealer(key: key), nil) }
        return (.plain, "Couldn't get its memory key from the Keychain, so what it remembers isn't encrypted this time.")
    }

    static func key() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        // Denied, or something odd: never make a new key over an old one,
        // which would lock away everything sealed with it.
        guard status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrLabel as String: "Companion memory key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }

    /// On iPhone and iPad: the folder, and what's in it, unreadable while
    /// the device is locked. New files inherit it. (A Mac relies on the
    /// sealing, and on FileVault.)
    public static func protect(_ folder: URL) {
        #if os(iOS)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? FileManager.default.setAttributes(protection, ofItemAtPath: folder.path)
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            try? FileManager.default.setAttributes(protection, ofItemAtPath: item.path)
        }
        #endif
    }
}
