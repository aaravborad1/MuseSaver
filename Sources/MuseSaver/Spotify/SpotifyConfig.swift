import Foundation

/// Static configuration for the Spotify integration.
///
/// The client ID is read from the `SPOTIFY_CLIENT_ID` environment variable if set,
/// otherwise it falls back to the constant below. Register your own app at
/// https://developer.spotify.com/dashboard and paste the client ID here (or export
/// the environment variable before launching). No client secret is required because
/// MuseSaver uses the Authorization Code flow with PKCE.
enum SpotifyConfig {
    static var clientID: String {
        if let env = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"],
           !env.isEmpty {
            return env
        }
        return "42f10bf595ee4c7db07f7be487b5009f"
    }

    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let callbackPort: UInt16 = 8888
    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"
}
