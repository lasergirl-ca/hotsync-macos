import Foundation
import Security

/// Der Cradle-Schlüssel eines Palms, der CradleSync nicht ausführen kann
/// (Palm OS 3 und 4): ein Ed25519-Seed von 32 Bytes je HotSync-User-ID, im
/// Schlüsselbund des Benutzers. hotsync-session beantwortet damit die
/// Authentifizierung des Airlocks an Stelle des Palms ("relaykey"); der
/// Schlüssel sagt dem Airlock "dieser HotSync kam über diesen Mac".
enum CradleKeyStore {
    private static let service = "HotSync Cradle key"

    private static func account(_ userId: UInt32) -> String { "palm-\(userId)" }

    private static func query(_ userId: UInt32) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(userId)]
    }

    /// Der Seed als 64 Hex-Zeichen; `create` legt einen neuen an, wenn der
    /// Palm noch keinen hat. nil: der Schlüsselbund hat nicht mitgespielt.
    static func seed(for userId: UInt32, create: Bool) -> String? {
        var q = query(userId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        guard create, status == errSecItemNotFound || status == errSecSuccess else { return nil }

        var seed = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess else { return nil }
        var add = query(userId)
        add[kSecValueData as String] = Data(seed)
        add[kSecAttrLabel as String] = "HotSync: Cradle key for Palm \(userId)"
        add[kSecAttrDescription as String] = "Ed25519 seed"
        if status == errSecSuccess {
            // ein Eintrag mit falscher Länge: ersetzen
            SecItemDelete(query(userId) as CFDictionary)
        }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return seed.map { String(format: "%02x", $0) }.joined()
    }

    /// Hat dieser Palm einen Schlüssel?
    static func hasKey(for userId: UInt32) -> Bool {
        var q = query(userId)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Vergisst den Schlüssel; der nächste HotSync meldet einen neuen an -
    /// den der Airlock erst nimmt, wenn dort der Authenticator des Palms
    /// zurückgesetzt wurde.
    static func forget(for userId: UInt32) {
        SecItemDelete(query(userId) as CFDictionary)
    }
}
