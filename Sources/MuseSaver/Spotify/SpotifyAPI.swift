import Foundation

enum APIError: Error {
    case unauthorized
    case http(Int)
    case badResponse
}

/// Thin client for the Spotify Web API endpoints MuseSaver needs.
final class SpotifyAPI {
    private let auth: SpotifyAuth

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    /// Fetches the full player state (track, progress, shuffle/repeat). Returns
    /// `nil` when there is no active playback (Spotify replies with HTTP 204).
    func currentlyPlaying() async throws -> CurrentlyPlaying? {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }
        switch http.statusCode {
        case 204:
            return nil
        case 200:
            guard !data.isEmpty else { return nil }
            return try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.http(http.statusCode)
        }
    }

    /// Returns the upcoming tracks in the user's play queue (used to prefetch
    /// lyrics and artwork so track transitions are instant).
    func upcomingQueue() async throws -> [Track] {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        struct QueueResponse: Decodable {
            let queue: LossyArray<Track>
        }
        return ((try? JSONDecoder().decode(QueueResponse.self, from: data))?.queue.elements) ?? []
    }

    // MARK: - Playback commands (require user-modify-playback-state)

    func play() async throws { try await command("PUT", "play") }
    func pause() async throws { try await command("PUT", "pause") }
    func nextTrack() async throws { try await command("POST", "next") }
    func previousTrack() async throws { try await command("POST", "previous") }

    func seek(toMs positionMs: Int) async throws {
        try await command("PUT", "seek",
                          query: [URLQueryItem(name: "position_ms", value: String(positionMs))])
    }

    func setShuffle(_ on: Bool) async throws {
        try await command("PUT", "shuffle",
                          query: [URLQueryItem(name: "state", value: on ? "true" : "false")])
    }

    /// `mode` is one of "off", "context" (playlist/album), or "track".
    func setRepeat(_ mode: String) async throws {
        try await command("PUT", "repeat",
                          query: [URLQueryItem(name: "state", value: mode)])
    }

    private func command(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws {
        let token = try await auth.validAccessToken()
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }
        // 404 = no active device; 403 = missing scope or restricted (e.g. free tier).
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            throw APIError.http(http.statusCode)
        }
    }
}
