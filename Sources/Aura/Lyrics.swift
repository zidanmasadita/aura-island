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
            // whose title AND artist match the query (either direction,
            // to tolerate "(Official Video)"-style suffixes on either
            // side) and whose duration matches the playing track. When
            // no candidate matches title/artist, fall back to the full
            // pool rather than showing nothing — the sensor title may
            // itself carry a suffix the API does not. When durations
            // are unknown, fall back to the first hit as before.
            let normalize: (String) -> String = { s in
                s.lowercased().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            let wantTitle = normalize(title)
            let wantArtist = normalize(artist)
            let matchesQuery: ([String: Any]) -> Bool = { result in
                guard let trackName = result["trackName"] as? String else { return false }
                let track = normalize(trackName)
                let titleOK = !wantTitle.isEmpty
                    && (track == wantTitle || track.contains(wantTitle) || wantTitle.contains(track))
                guard titleOK else { return false }
                guard !wantArtist.isEmpty,
                      let artistName = result["artistName"] as? String else { return true }
                let trackArtist = normalize(artistName)
                return trackArtist == wantArtist
                    || trackArtist.contains(wantArtist) || wantArtist.contains(trackArtist)
            }
            let score: ([String: Any]) -> Double = { result in
                guard duration > 0,
                      let d = result["duration"] as? Double, d > 0 else {
                    return .greatestFiniteMagnitude
                }
                return abs(d - duration)
            }
            let withSynced = array.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            let pool = withSynced.isEmpty ? array : withSynced
            let verified = pool.filter(matchesQuery)
            let selectionPool = verified.isEmpty ? pool : verified
            let best = selectionPool.min(by: { score($0) < score($1) }) ?? array[0]
            let lines = Self.parseSynced(best["syncedLyrics"] as? String)
                ?? Self.parsePlain(best["plainLyrics"] as? String, duration: duration)
                ?? []
            DispatchQueue.main.async { completion(lines) }
        }.resume()
    }

    /// Parses "[mm:ss.xx] text" lines into (seconds, text), sorted by
    /// time. Honors the "[offset:+/-ms]" tag when present: it shifts
    /// every timestamp (positive = lyrics later). The tag is usually
    /// at the top, but it applies to the whole file regardless of
    /// position. A line may carry several timestamps
    /// ("[00:12.00][00:15.00] text" — a repeated chorus): each one
    /// becomes its own entry with the same text, so the line reappears
    /// at every occurrence instead of showing the second stamp as
    /// literal text. Metadata brackets ([ti:], [ar:], [al:], [by:])
    /// before the first timestamp are skipped; a non-timestamp bracket
    /// after timestamps (e.g. "[Chorus]") stays part of the text.
    /// Non-vocal markers are dropped: during a melody part (no vocal),
    /// the file often marks the gap with a blank line, note symbols,
    /// or "(Instrumental)" — without dropping those, the panel and
    /// the pill would show the marker instead of keeping the last
    /// sung line through the gap.
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
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            var times: [Double] = []
            while line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { break }
                let stamp = String(line[line.index(after: line.startIndex)..<close])
                let rest = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = stamp.components(separatedBy: ":")
                if parts.count == 2,
                   let minutes = Double(parts[0]),
                   let seconds = Double(parts[1]) {
                    times.append(max(0, minutes * 60 + seconds + offsetSeconds))
                    line = rest
                } else if times.isEmpty {
                    // Metadata prefix ([ti:], [ar:], ...) — skip it and
                    // keep scanning for a timestamp.
                    line = rest
                } else {
                    // Non-timestamp bracket after timestamps — part of
                    // the lyric text, not another stamp.
                    break
                }
            }
            guard !times.isEmpty else { continue }
            for time in times {
                out.append((time: time, text: line))
            }
        }
        // Drop non-vocal markers so the last sung line persists
        // through melody parts instead of being replaced by a blank
        // line, note symbols, or "(Instrumental)".
        out = out.filter { !isNonVocalMarker($0.text) }
        out.sort { $0.time < $1.time }
        return out.isEmpty ? nil : out
    }

    /// True for lines that mark a non-vocal stretch rather than a sung
    /// lyric: blank, only note symbols (and wrappers/spaces), or a
    /// wrapped word marker like "(Instrumental)", "[Interlude]",
    /// "(Musik)". Word markers must be wrapped — a bare sung word is
    /// never mistaken for one.
    private static func isNonVocalMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Only note symbols, wrappers, asterisks, and spaces remain.
        let symbolsOnly = t.filter { !"♪♫♩♬🎵🎶()[]{}* ".contains($0) }
        if symbolsOnly.isEmpty { return true }
        let wrappers = CharacterSet(charactersIn: "()[]{}")
        guard let first = t.unicodeScalars.first, let last = t.unicodeScalars.last,
              wrappers.contains(first), wrappers.contains(last) else { return false }
        var inner = t.trimmingCharacters(in: wrappers)
        inner = inner.filter { !"♪♫♩♬🎵🎶* ".contains($0) }
        let word = inner.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["instrumental", "music", "musik", "interlude", "intro", "outro"].contains(word)
    }

    /// Plain lyrics without timestamps: one entry per non-empty line,
    /// spaced evenly across the track duration. Returning the whole
    /// block as one entry (the old behavior) broke rendering: the
    /// text contains newlines, and drawText renders them as extra
    /// visual rows — the closed pill showed several rows in 32px,
    /// and the panel's wrapped lines overlapped each other (the panel
    /// budgets height for wrapped lines only, but each embedded
    /// newline renders an extra row on top of the next wrapped line).
    /// Songs with synced lyrics never hit this (their lines are
    /// already per-line); only plain-only songs like The Visitor did
    /// (LRCLIB has no synced version of it at all). Even spacing is
    /// an approximation — LRCLIB has no timestamps for these songs —
    /// so the lines will not match the vocal exactly, but they
    /// display one at a time, correctly.
    private static func parsePlain(_ plain: String?, duration: Double) -> [(time: Double, text: String)]? {
        guard let plain, !plain.isEmpty else { return nil }
        let lines = plain.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isNonVocalMarker($0) }
        guard !lines.isEmpty else { return nil }
        // Line i at i * duration / count, so the last line starts
        // before the track ends and shows until it. When the duration
        // is unknown, fall back to 5s apart (an estimate — better
        // than one block, and the lines still advance).
        let step = duration > 0 ? duration / Double(lines.count) : 5.0
        return lines.enumerated().map { (time: Double($0.offset) * step, text: $0.element) }
    }
}
