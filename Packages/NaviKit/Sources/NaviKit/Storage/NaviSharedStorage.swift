import Foundation
import Valet

// MARK: - NaviSharedStorage

enum NaviSharedStorage {
    // MARK: Internal

    static let appGroupID = "AQ5WW4KNGB.group.com.manik.Navi"
    static let modelIDKey = "assistant.model_id"
    static let vllmBaseURLKey = "assistant.vllm.base_url"
    static let defaultProvider = NaviProvider.anthropic

    static func selectedProvider() -> NaviProvider {
        guard let defaults = try? userDefaults(),
              let raw = defaults.string(forKey: "provider"),
              let provider = NaviProvider(rawValue: raw) else {
            return defaultProvider
        }
        return provider
    }

    static func setSelectedProvider(_ provider: NaviProvider) {
        guard let defaults = try? userDefaults() else { return }
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(provider.defaultModelID, forKey: modelIDKey)
    }

    static func userDefaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw NaviSharedStorageError.unavailable
        }
        return defaults
    }

    static func credentialStorage() throws -> CredentialStorage {
        guard let identifier = SharedGroupIdentifier(appIDPrefix: teamIDPrefix, nonEmptyGroup: "com.manik.Navi") else {
            throw NaviSharedStorageError.unavailable
        }
        return CredentialStorage(sharedAccessGroupIdentifier: identifier)
    }

    // MARK: Private

    private static let teamIDPrefix = "AQ5WW4KNGB"
}

// MARK: - NaviSharedStorageError

enum NaviSharedStorageError: LocalizedError {
    case unavailable

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The shared app group container is unavailable."
        }
    }
}
