// AppSettings — the Gemini API key (stored in the login Keychain) plus the model
// and an optional domain-context primer (in UserDefaults).
//
// The key lives in the Keychain rather than a plist because it's a secret; the
// app's stable signing identity keeps that Keychain item readable across rebuilds.

import Foundation
import Security

@MainActor
final class AppSettings: ObservableObject {
    static let defaultModel = "gemini-3.6-flash"

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, account: "geminiApiKey") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    /// Optional: names/jargon so Gemini spells them correctly.
    @Published var context: String {
        didSet { UserDefaults.standard.set(context, forKey: "context") }
    }

    init() {
        apiKey = Keychain.get(account: "geminiApiKey") ?? ""
        model = UserDefaults.standard.string(forKey: "model") ?? Self.defaultModel
        context = UserDefaults.standard.string(forKey: "context") ?? ""
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The model to actually send to Gemini. Falls back to the default when the
    /// field is left blank, so an empty model can never produce a bad request URL.
    var effectiveModel: String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? Self.defaultModel : m
    }
}

enum Keychain {
    private static let service = "com.jakelisten.app"

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
