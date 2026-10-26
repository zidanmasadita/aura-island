import Foundation

/// LRCLIB lyrics client (no API key needed).
/// https://lrclib.net — same source Nusa uses.
final class LyricsClient {
    func fetchLyrics(title: String, artist: String, completion: @escaping ([(time: Double, text: String)]) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = components?.url else {
            completion([])
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Aura-Island/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                  let first = array.first else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let lines = Self.parseSynced(first["syncedLyrics"] as? String)
                ?? Self.parsePlain(first["plainLyrics"] as? String)
                ?? []
            DispatchQueue.main.async { completion(lines) }
        }.resume()
    }

    /// Parses "[mm:ss.xx] text" lines into (seconds, text).
    private static func parseSynced(_ synced: String?) -> [(time: Double, text: String)]? {
        guard let synced, !synced.isEmpty else { return nil }
        var out: [(time: Double, text: String)] = []
        for rawLine in synced.components(separatedBy: "\n") {
            guard rawLine.hasPrefix("["),
                  let close = rawLine.firstIndex(of: "]") else { continue }
            let stamp = String(rawLine[rawLine.index(after: rawLine.startIndex)..<close])
            let text = String(rawLine[rawLine.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let parts = stamp.components(separatedBy: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { continue }
            out.append((time: minutes * 60 + seconds, text: text))
        }
        return out.isEmpty ? nil : out
    }

    /// Plain lyrics without timestamps: single block at time 0.
    private static func parsePlain(_ plain: String?) -> [(time: Double, text: String)]? {
        guard let plain, !plain.isEmpty else { return nil }
        return [(time: 0, text: plain)]
    }
}
