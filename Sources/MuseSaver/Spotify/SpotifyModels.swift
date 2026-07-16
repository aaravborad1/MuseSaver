import Foundation

struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct CurrentlyPlaying: Decodable {
    let progressMs: Int?
    let isPlaying: Bool
    let item: Track?
    let shuffleState: Bool?
    let repeatState: String?

    enum CodingKeys: String, CodingKey {
        case progressMs = "progress_ms"
        case isPlaying = "is_playing"
        case item
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progressMs = try container.decodeIfPresent(Int.self, forKey: .progressMs)
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        // Lossy: podcast episodes don't decode as Track; treat them as no item
        // instead of failing the whole payload.
        item = try? container.decodeIfPresent(Track.self, forKey: .item)
        shuffleState = try container.decodeIfPresent(Bool.self, forKey: .shuffleState)
        repeatState = try container.decodeIfPresent(String.self, forKey: .repeatState)
    }
}

struct Track: Decodable, Equatable, Sendable {
    let id: String?
    let name: String
    let durationMs: Int
    let artists: [Artist]
    let album: Album

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case durationMs = "duration_ms"
        case artists
        case album
    }

    var artistNames: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var albumArtURL: URL? {
        // Spotify returns images largest-first.
        album.images.first.flatMap { URL(string: $0.url) }
    }
}

struct Artist: Decodable, Equatable, Sendable {
    let name: String
}

struct Album: Decodable, Equatable, Sendable {
    let name: String
    let images: [SpotifyImage]
}

struct SpotifyImage: Decodable, Equatable, Sendable {
    let url: String
    let width: Int?
    let height: Int?
}

/// Decodes an array, skipping elements that fail (e.g. podcast episodes mixed
/// into a track queue).
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                result.append(value)
            } else {
                _ = try? container.decode(Blank.self)
            }
        }
        elements = result
    }

    private struct Blank: Decodable {}
}
