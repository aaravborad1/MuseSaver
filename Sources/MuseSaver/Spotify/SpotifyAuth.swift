import AppKit
import CryptoKit
import Foundation

enum AuthError: Error {
    case notConnected
    case tokenMissing
    case badResponse
}

/// Handles the OAuth 2.0 Authorization Code + PKCE flow, token storage, and refresh.
///
/// The refresh token is persisted in the Keychain. The access token lives only in
/// memory and is refreshed on demand shortly before it expires.
///
/// IMPORTANT: Keychain reads can block on a securityd permission dialog (e.g. after
/// the binary is re-signed), so `isConnected` is a cached flag — the actual Keychain
/// read happens off the main thread at startup and on state changes. Never call
/// `Keychain.get` from the main thread.
final class SpotifyAuth {
    private static let refreshTokenAccount = "refresh-token"
    private let refreshTokenAccount = SpotifyAuth.refreshTokenAccount

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    private var codeVerifier: String?
    private var server: LocalCallbackServer?
    private var refreshTask: Task<String, Error>?

    /// Cached connection state; safe to read from the main thread.
    private(set) var isConnected = false

    init() {
        // Probe the Keychain in the background so a securityd dialog can never
        // freeze the UI. The menu updates via the notification when this lands.
        DispatchQueue.global(qos: .utility).async {
            let present = Keychain.get(account: Self.refreshTokenAccount) != nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected != present else { return }
                self.isConnected = present
                NotificationCenter.default.post(name: .spotifyConnectionChanged, object: nil)
            }
        }
    }

    private func setConnected(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isConnected != connected else { return }
            self.isConnected = connected
            NotificationCenter.default.post(name: .spotifyConnectionChanged, object: nil)
        }
    }

    // MARK: - Authorization

    /// Kicks off the PKCE authorization flow: starts the local callback server and
    /// opens the Spotify consent page in the user's browser.
    func connect() {
        let verifier = Self.randomCodeVerifier()
        codeVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)

        let server = LocalCallbackServer(port: SpotifyConfig.callbackPort)
        server.onCode = { [weak self] code in
            Task { await self?.exchangeCode(code) }
        }
        server.onError = { error in
            NSLog("MuseSaver: authorization error — \(error.localizedDescription)")
        }
        do {
            try server.start()
        } catch {
            NSLog("MuseSaver: failed to start callback server — \(error.localizedDescription)")
            return
        }
        self.server = server

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: SpotifyConfig.scopes)
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    func disconnect() {
        accessToken = nil
        accessTokenExpiry = nil
        setConnected(false)
        DispatchQueue.global(qos: .utility).async {
            Keychain.delete(account: Self.refreshTokenAccount)
        }
    }

    private func exchangeCode(_ code: String) async {
        guard let verifier = codeVerifier else { return }
        let body = FormEncoding.encode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "client_id": SpotifyConfig.clientID,
            "code_verifier": verifier
        ])
        do {
            let token = try await postToken(body: body)
            apply(token)
            server?.stop()
            server = nil
        } catch {
            NSLog("MuseSaver: token exchange failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Access token

    /// Returns a valid access token, refreshing it first if necessary.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = accessTokenExpiry, expiry > Date() {
            return token
        }
        // Coalesce concurrent refreshes into a single in-flight request.
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.notConnected }
            return try await self.performRefresh()
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refreshToken = Keychain.get(account: refreshTokenAccount) else {
            throw AuthError.notConnected
        }
        let body = FormEncoding.encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": SpotifyConfig.clientID
        ])
        let token = try await postToken(body: body)
        apply(token)
        guard let access = accessToken else { throw AuthError.tokenMissing }
        return access
    }

    private func postToken(body: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.badResponse
        }
        if http.statusCode == 400 {
            // Refresh token has been revoked — force the user to reconnect.
            Keychain.delete(account: refreshTokenAccount)
            setConnected(false)
            throw AuthError.notConnected
        }
        guard (200...299).contains(http.statusCode) else {
            throw AuthError.badResponse
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func apply(_ token: TokenResponse) {
        accessToken = token.accessToken
        // Refresh a minute early to avoid using a token that expires mid-request.
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn - 60))
        if let refresh = token.refreshToken {
            Keychain.set(refresh, account: refreshTokenAccount)
        }
        setConnected(true)
    }

    // MARK: - PKCE helpers

    private static func randomCodeVerifier() -> String {
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { allowed[Int($0) % allowed.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}
