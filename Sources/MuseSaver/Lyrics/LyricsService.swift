import Foundation

struct LyricLine: Equatable, Sendable, Codable {
    let time: TimeInterval
    let text: String
}

private struct LRCLibResult: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
}

/// Fetches time-synced lyrics from lrclib.net and caches them per track.
actor LyricsService {
    private var cache: [String: [LyricLine]] = [:]

    /// Returns synced lyric lines for a track, or an empty array when none are found.
    /// Results are cached in memory and on disk (lrclib can be slow, ~10s per
    /// request at times, so a track should never be fetched twice).
    func lyrics(for track: Track) async -> [LyricLine] {
        let key = track.id ?? "\(track.name)::\(track.artistNames)"
        if let cached = cache[key] {
            return cached
        }
        if let disk = Self.readDiskCache(key: key) {
            cache[key] = disk
            return disk
        }
        let lines = (try? await fetch(track: track)) ?? []
        cache[key] = lines
        // Only persist hits — a miss today might be filled in on lrclib later.
        if !lines.isEmpty {
            Self.writeDiskCache(key: key, lines: lines)
        }
        return lines
    }

    // MARK: - Fetching

    private func fetch(track: Track) async throws -> [LyricLine] {
        // Race the exact-match /get and the fuzzier /search in parallel; the
        // first non-empty result wins. Sequential fetching doubled the wait
        // when lrclib is slow.
        await withTaskGroup(of: [LyricLine]?.self) { group in
            group.addTask { try? await self.fetchExact(track: track) }
            group.addTask { try? await self.fetchSearch(track: track) }
            for await result in group {
                if let lines = result, !lines.isEmpty {
                    group.cancelAll()
                    return lines
                }
            }
            return []
        }
    }

    private func fetchExact(track: Track) async throws -> [LyricLine]? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artists.first?.name ?? track.artistNames),
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "album_name", value: track.album.name),
            URLQueryItem(name: "duration", value: String(track.durationMs / 1000))
        ]
        guard let result = try await request(components) else { return nil }
        return synced(from: result)
    }

    private func fetchSearch(track: Track) async throws -> [LyricLine]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artists.first?.name ?? track.artistNames)
        ]
        guard let url = components.url else { return nil }
        var urlRequest = URLRequest(url: url, timeoutInterval: 25)
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let results = try JSONDecoder().decode([LRCLibResult].self, from: data)
        // Pick the first result that actually has synced lyrics.
        for result in results {
            if let lines = synced(from: result), !lines.isEmpty {
                return lines
            }
        }
        return nil
    }

    private func request(_ components: URLComponents) async throws -> LRCLibResult? {
        guard let url = components.url else { return nil }
        var urlRequest = URLRequest(url: url, timeoutInterval: 25)
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try JSONDecoder().decode(LRCLibResult.self, from: data)
    }

    private func synced(from result: LRCLibResult) -> [LyricLine]? {
        guard let raw = result.syncedLyrics, !raw.isEmpty else { return nil }
        return Self.parseLRC(raw)
    }

    private static let userAgent = "MuseSaver/1.0 (https://github.com/example/musesaver)"

    // MARK: - Disk cache

    private static let cacheDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MuseSaver/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func cacheFile(for key: String) -> URL? {
        let safe = Data(key.utf8).base64URLEncodedString()
        return cacheDir?.appendingPathComponent(safe + ".json")
    }

    private static func readDiskCache(key: String) -> [LyricLine]? {
        guard let file = cacheFile(for: key),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([LyricLine].self, from: data)
    }

    private static func writeDiskCache(key: String, lines: [LyricLine]) {
        guard let file = cacheFile(for: key),
              let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: file)
    }

    // MARK: - LRC parsing

    /// Parses LRC-format text into sorted, timestamped lines. A single line can
    /// carry multiple timestamps (e.g. a repeated chorus), which are expanded.
    static func parseLRC(_ raw: String) -> [LyricLine] {
        let pattern = "\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{1,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []
        for rawLine in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }

            let textStart = last.range.location + last.range.length
            let text = ns.substring(from: textStart)
                .trimmingCharacters(in: .whitespaces)

            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                let fractionRange = match.range(at: 3)
                if fractionRange.location != NSNotFound {
                    let fractionString = ns.substring(with: fractionRange)
                    fraction = (Double(fractionString) ?? 0) / pow(10, Double(fractionString.count))
                }
                let time = minutes * 60 + seconds + fraction
                lines.append(LyricLine(time: time, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
