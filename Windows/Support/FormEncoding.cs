using System.Net;

namespace MuseSaverWin.Support;

internal static class FormEncoding
{
    /// <summary>Encodes a dictionary as application/x-www-form-urlencoded body text.</summary>
    public static string Encode(IDictionary<string, string> parameters)
    {
        return string.Join("&", parameters.Select(kv =>
            $"{WebUtility.UrlEncode(kv.Key)}={WebUtility.UrlEncode(kv.Value)}"));
    }
}

internal static class Base64UrlEncoder
{
    /// <summary>Base64-URL encoding without padding, as required by PKCE (RFC 7636).</summary>
    public static string Encode(byte[] bytes)
    {
        return Convert.ToBase64String(bytes)
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');
    }
}
