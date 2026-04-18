import Foundation
import Observation

// MARK: - AuthController

@Observable
@MainActor public final class AuthController {
    // MARK: Lifecycle

    public init(urlOpener: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.urlOpener = urlOpener
        _provider = NaviSharedStorage.selectedProvider()
        Task { await refreshState() }
    }

    // MARK: Public

    public private(set) var isAuthenticated = false
    public private(set) var isWorking = false
    public private(set) var statusMessage = ""
    public private(set) var errorMessage: String?
    public private(set) var authorizationURL: URL?
    public private(set) var codePrompt: String?
    public var codeInput = ""

    public var vllmBaseURL = ""
    public var vllmAPIKey = ""
    public var vllmModelID = ""

    public var provider: NaviProvider {
        get { _provider }
        set {
            guard newValue != _provider else { return }
            cancelCodeEntry()
            _provider = newValue
            NaviSharedStorage.setSelectedProvider(newValue)
            Task { await refreshState() }
        }
    }

    public var bridgeState: AuthBridgeState {
        AuthBridgeState(
            isAuthenticated: isAuthenticated,
            isWorking: isWorking,
            statusMessage: statusMessage,
            errorMessage: errorMessage,
            codePrompt: codePrompt,
            authorizationURL: authorizationURL?.absoluteString
        )
    }

    public func refreshState() async {
        do {
            let storage = try NaviSharedStorage.credentialStorage()
            let defaults = try NaviSharedStorage.userDefaults()
            if defaults.string(forKey: NaviSharedStorage.modelIDKey)?.isEmpty != false {
                defaults.set(_provider.defaultModelID, forKey: NaviSharedStorage.modelIDKey)
            }

            if _provider == .vllm {
                loadVLLMFields(defaults: defaults, storage: storage)
                isAuthenticated = hasValidVLLMConfiguration(defaults: defaults, storage: storage)
                if !isWorking {
                    statusMessage = isAuthenticated
                        ? "vLLM endpoint is configured. Navi can use your local or self-hosted model in Safari."
                        : "Configure vLLM base URL, API key, and model to enable the Safari extension."
                }
            } else {
                isAuthenticated = storage.has(_provider.oauthProviderID)
                if !isWorking {
                    statusMessage = isAuthenticated
                        ? "\(_provider.displayName) is connected. Navi can use it in Safari."
                        : "Sign in with \(_provider.displayName) to enable the Safari extension."
                }
            }
        } catch {
            isAuthenticated = false
            statusMessage = error.localizedDescription
        }
    }

    public func login() async {
        guard !isWorking else { return }

        errorMessage = nil
        isWorking = true

        do {
            switch _provider {
            case .vllm:
                statusMessage = "Saving vLLM settings…"
                try saveVLLMConfiguration()
                authorizationURL = nil
                codePrompt = nil
                promptContinuation = nil
                isWorking = false
                statusMessage = "vLLM endpoint is configured. You can use Navi in Safari now."
                await refreshState()
            case .anthropic, .codex:
                statusMessage = "Preparing \(_provider.displayName) sign-in…"
                try await performOAuthLogin()
                authorizationURL = nil
                codePrompt = nil
                promptContinuation = nil
                isWorking = false
                statusMessage = "\(_provider.displayName) is connected. You can use Navi in Safari now."
                await refreshState()
            }
        } catch {
            promptContinuation = nil
            codePrompt = nil
            authorizationURL = nil
            isWorking = false
            errorMessage = error.localizedDescription
            statusMessage = "\(_provider.displayName) setup failed."
            await refreshState()
        }
    }

    public func submitCode() {
        guard let continuation = promptContinuation else { return }

        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = "Paste the authorization code or redirect URL."
            return
        }

        promptContinuation = nil
        codePrompt = nil
        errorMessage = nil
        statusMessage = "Finishing \(_provider.displayName) sign-in…"
        continuation.resume(returning: code)
    }

    public func cancelCodeEntry() {
        if let callbackServer {
            Task { await callbackServer.cancel() }
            self.callbackServer = nil
        }
        guard let continuation = promptContinuation else { return }

        promptContinuation = nil
        codePrompt = nil
        statusMessage = "\(_provider.displayName) sign-in cancelled."
        continuation.resume(throwing: AuthError.cancelled)
    }

    public func logout() async {
        do {
            let storage = try NaviSharedStorage.credentialStorage()
            let defaults = try NaviSharedStorage.userDefaults()

            storage.remove(_provider.oauthProviderID)

            if _provider == .vllm {
                defaults.removeObject(forKey: NaviSharedStorage.vllmBaseURLKey)
                defaults.removeObject(forKey: NaviSharedStorage.modelIDKey)
                vllmBaseURL = ""
                vllmAPIKey = ""
                vllmModelID = ""
            }

            errorMessage = nil
            authorizationURL = nil
            codePrompt = nil
            promptContinuation = nil
            statusMessage = "\(_provider.displayName) has been disconnected."
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func reopenAuthorizationPage() {
        guard let authorizationURL else { return }
        urlOpener(authorizationURL)
    }

    // MARK: Private

    private var _provider: NaviProvider
    private var promptContinuation: CheckedContinuation<String, Error>?
    private var oauthVerifier: String?
    private let urlOpener: @MainActor (URL) -> Void

    private var callbackServer: OAuthCallbackServer?

    private func performOAuthLogin() async throws {
        switch _provider {
        case .anthropic:
            try await performAnthropicLogin()
        case .codex:
            try await performCodexLogin()
        case .vllm:
            try saveVLLMConfiguration()
        }
    }

    private func loadVLLMFields(defaults: UserDefaults, storage: CredentialStorage) {
        let storedBaseURL = defaults.string(forKey: NaviSharedStorage.vllmBaseURLKey) ?? ""
        let storedModelID = defaults.string(forKey: NaviSharedStorage.modelIDKey) ?? NaviProvider.vllm.defaultModelID
        let storedAPIKey = (try? storageHashedKey(storage: storage)) ?? ""

        if vllmBaseURL.isEmpty {
            vllmBaseURL = storedBaseURL
        }
        if vllmModelID.isEmpty {
            vllmModelID = storedModelID
        }
        if vllmAPIKey.isEmpty {
            vllmAPIKey = storedAPIKey
        }
    }

    private func saveVLLMConfiguration() throws {
        let baseURL = vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = vllmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = vllmModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty else {
            throw AuthError.invalidVLLMConfiguration("Enter a vLLM base URL, for example http://127.0.0.1:8000/v1")
        }

        guard !modelID.isEmpty else {
            throw AuthError.invalidVLLMConfiguration("Enter a model ID, for example qwen3.6-35b or gpt-oss-120b")
        }

        guard !apiKey.isEmpty else {
            throw AuthError.invalidVLLMConfiguration("Enter an API key for the vLLM endpoint")
        }

        guard URL(string: baseURL) != nil else {
            throw AuthError.invalidVLLMConfiguration("The vLLM base URL is not valid")
        }

        let storage = try NaviSharedStorage.credentialStorage()
        let defaults = try NaviSharedStorage.userDefaults()

        defaults.set(baseURL, forKey: NaviSharedStorage.vllmBaseURLKey)
        defaults.set(modelID, forKey: NaviSharedStorage.modelIDKey)
        storage.set(NaviProvider.vllm.oauthProviderID, accessToken: apiKey, refreshToken: nil, expiresAt: nil)

        vllmBaseURL = baseURL
        vllmModelID = modelID
        vllmAPIKey = apiKey
    }

    private func hasValidVLLMConfiguration(defaults: UserDefaults, storage: CredentialStorage) -> Bool {
        let baseURL = defaults.string(forKey: NaviSharedStorage.vllmBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelID = defaults.string(forKey: NaviSharedStorage.modelIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasKey = storage.has(NaviProvider.vllm.oauthProviderID)
        return !baseURL.isEmpty && !modelID.isEmpty && hasKey
    }

    private func storageHashedKey(storage: CredentialStorage) throws -> String {
        // We reuse access token slot for vLLM API key; surface it back in UI for editing.
        // Access is read through async API in runtime, but here we only need quick form prefill.
        if let key = try storage.directValue(for: NaviProvider.vllm.oauthProviderID, field: "access"), !key.isEmpty {
            return key
        }
        return ""
    }

    private func performAnthropicLogin() async throws {
        let storage = try NaviSharedStorage.credentialStorage()
        let flow = AnthropicOAuthFlow()

        let (authURL, verifier) = try flow.startAuthorization()
        oauthVerifier = verifier

        authorizationURL = authURL
        statusMessage = "Complete the sign-in in your browser, then paste the code here."
        urlOpener(authURL)

        codeInput = ""
        codePrompt = "Paste the authorization code or redirect URL:"
        statusMessage = "Paste the authorization code or redirect URL to finish sign-in."

        let code = try await withCheckedThrowingContinuation { continuation in
            self.promptContinuation = continuation
        }

        guard let verifier = oauthVerifier else {
            throw AuthError.cancelled
        }

        statusMessage = "Exchanging code for tokens…"
        let tokens = try await flow.exchangeCode(code, verifier: verifier)
        oauthVerifier = nil

        storage.set(
            _provider.oauthProviderID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt
        )
    }

    private func performCodexLogin() async throws {
        let storage = try NaviSharedStorage.credentialStorage()
        let flow = CodexOAuthFlow()

        let (authURL, verifier) = try flow.startAuthorization()
        oauthVerifier = verifier

        let parts = verifier.split(separator: "#", maxSplits: 1)
        let expectedState = parts.count > 1 ? String(parts[1]) : nil

        let callbackServer = OAuthCallbackServer()
        self.callbackServer = callbackServer

        authorizationURL = authURL
        statusMessage = "Signing in with Codex…"
        urlOpener(authURL)

        codeInput = ""
        codePrompt = "Or paste the redirect URL here if the browser didn't redirect:"

        Task {
            if let code = try? await callbackServer.start(expectedState: expectedState) {
                if let continuation = self.promptContinuation {
                    self.promptContinuation = nil
                    self.codePrompt = nil
                    continuation.resume(returning: code)
                }
            }
        }

        let code = try await withCheckedThrowingContinuation { continuation in
            self.promptContinuation = continuation
        }
        await callbackServer.stop()
        self.callbackServer = nil

        guard let verifier = oauthVerifier else {
            throw AuthError.cancelled
        }

        statusMessage = "Exchanging code for tokens…"
        let tokens = try await flow.exchangeCode(code, verifier: verifier)
        oauthVerifier = nil

        storage.set(
            _provider.oauthProviderID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt
        )
        storage.setExtra(_provider.oauthProviderID, key: "accountID", value: tokens.accountID)
    }
}

// MARK: - AuthError

enum AuthError: LocalizedError {
    case cancelled
    case invalidVLLMConfiguration(String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Sign-in was cancelled."
        case let .invalidVLLMConfiguration(message):
            message
        }
    }
}
