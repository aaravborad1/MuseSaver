import Foundation

extension Notification.Name {
    /// Posted whenever the Spotify connection state changes (connect / disconnect).
    static let spotifyConnectionChanged = Notification.Name("com.musesaver.spotifyConnectionChanged")
}

extension Data {
    /// Base64-URL encoding without padding, as required by PKCE (RFC 7636).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum FormEncoding {
    /// Encodes a dictionary as `application/x-www-form-urlencoded` body text.
    static func encode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
