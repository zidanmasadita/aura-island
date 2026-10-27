import Foundation

/// LRCLIB lyrics client (no API key needed).
/// https://lrclib.net — same source Nusa uses.
final class LyricsClient {
    func fetchLyrics(title: String, artist: String, duration: Double,
                     completion: @escaping ([(time: Double, text: String)]) -> Void) {
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
                  !array.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            // Pick the best version, not just the first hit: LRCLIB
            // search returns several versions of a song (remix,
            // extended, live) whose lyric timestamps differ, and the
            // first hit is often the wrong one — the common "lyrics
            // out of sync" cause. Prefer a result with synced lyrics
            // whose duration matches the playing track; when durations
            // are unknown, fall back to the first hit as before.
            let score: ([String: Any]) -> Double = { result in
                guard duration > 0,
                      let d = result["duration"] as? Double, d > 0 else {
                    return .greatestFiniteMagnitude
                }
                return abs(d - duration)
            }
            let withSynced = array.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            let pool = withSynced.isEmpty ? array : withSynced
            let best = pool.min(by: { score($0) < score($1) }) ?? array[0]
            let lines = Self.parseSynced(best["syncedLyrics"] as? String)
                ?? Self.parsePlain(best["plainLyrics"] as? String)
                ?? []
            DispatchQueue.main.async { completion(lines) }
        }.resume()
    }

    /// Parses "[mm:ss.xx] text" lines into (seconds, text).
    /// Honors the "[offset:+/-ms]" tag when present: it shifts every
    /// timestamp (positive = lyrics later). The tag is usually at the
    /// top, but it applies to the whole file regardless of position.
    private static func parseSynced(_ synced: String?) -> [(time: Double, text: String)]? {
        guard let synced, !synced.isEmpty else { return nil }
        var offsetSeconds = 0.0
        for rawLine in synced.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[offset:") && line.hasSuffix("]") {
                let numStr = line.dropFirst("[offset:".count).dropLast()
                if let ms = Double(numStr) { offsetSeconds = ms / 1000.0 }
            }
        }
        var out: [(time: Double, text: String)] = []
        for rawLine in synced.components(separatedBy: "\n") {
            guard rawLine.hasPrefix("["),
                  let close = rawLine.firstIndex(of: "]") else { continue }
            let stamp = String(rawLine[rawLine.index(after: rawLine.startIndex)..<close])
            let text = String(rawLine[rawLine.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = stamp.components(separatedBy: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { continue }
            out.append((time: max(0, minutes * 60 + seconds + offsetSeconds), text: text))
        }
        return out.isEmpty ? nil : out
    }

    /// Plain lyrics without timestamps: single block at time 0.
    private static func parsePlain(_ plain: String?) -> [(time: Double, text: String)]? {
        guard let plain, !plain.isEmpty else { return nil }
        return [(time: 0, text: plain)]
    }
}
