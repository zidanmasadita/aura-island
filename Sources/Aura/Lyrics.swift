import Foundation

/// LRCLIB lyrics client (no API key needed).
/// https://lrclib.net — same source Nusa uses. When LRCLIB has
/// nothing for a song, falls back to lyrics.ovh (plain lyrics).
final class LyricsClient {
    func fetchLyrics(title: String, artist: String, duration: Double,
                     completion: @escaping ([(time: Double, text: String)]) -> Void) {
        // LRCLIB has nothing for this song — fall back to lyrics.ovh
        // (plain lyrics, no timestamps), parsed through the same
        // even-spacing path as plain LRCLIB results.
        let fallbackToOvh: () -> Void = {
            Self.fetchOvhLyrics(title: title, artist: artist) { ovhText in
                let ovhLines = Self.parsePlain(ovhText, duration: duration) ?? []
                DispatchQueue.main.async { completion(ovhLines) }
            }
        }
        let finish: ([(time: Double, text: String)]) -> Void = { lines in
            if lines.isEmpty {
                fallbackToOvh()
            } else {
                DispatchQueue.main.async { completion(lines) }
            }
        }
        // Step 1 — LRCLIB /get, the exact endpoint: one object for
        // this track/artist/duration, not a search list. This is the
        // DynamicNotch order, and it is the main fix for "lyrics
        // rarely sync": the old code only searched, so a remix/live/
        // extended version with different timestamps could win.
        // Album is not sent: Aura's session does not carry an album
        // field (JXA reports it, but NowPlaying drops it), so /get
        // is narrowed by track + artist + duration only.
        if let getURL = Self.lrclibURL(endpoint: "get", title: title, artist: artist,
                                       duration: duration, includeDuration: true) {
            Self.fetchObject(url: getURL) { result in
                if let result,
                   let lines = Self.parseSynced(result["syncedLyrics"] as? String)
                       ?? Self.parsePlain(result["plainLyrics"] as? String, duration: duration) {
                    finish(lines)
                } else {
                    self.trySearch(title: title, artist: artist, duration: duration,
                                   attempt: 0, finish: finish, fallbackToOvh: fallbackToOvh)
                }
            }
        } else {
            trySearch(title: title, artist: artist, duration: duration,
                      attempt: 0, finish: finish, fallbackToOvh: fallbackToOvh)
        }
    }

    /// Sequential LRCLIB /search attempts, DynamicNotch order:
    /// (0) track + artist + duration, (1) track + artist,
    /// (2) free-text q = "artist title". Each attempt picks its best
    /// candidate by weighted score (see score(_:)); a later attempt
    /// only runs when the earlier one produced no usable lines.
    private func trySearch(title: String, artist: String, duration: Double,
                           attempt: Int,
                           finish: @escaping ([(time: Double, text: String)]) -> Void,
                           fallbackToOvh: @escaping () -> Void) {
        let attempts: [(includeDuration: Bool, useQuery: Bool)] = [
            (true, false), (false, false), (false, true),
        ]
        guard attempt < attempts.count else {
            fallbackToOvh()
            return
        }
        let spec = attempts[attempt]
        guard let url = Self.lrclibURL(endpoint: "search", title: title, artist: artist,
                                       duration: duration, includeDuration: spec.includeDuration,
                                       useQuery: spec.useQuery) else {
            trySearch(title: title, artist: artist, duration: duration,
                      attempt: attempt + 1, finish: finish, fallbackToOvh: fallbackToOvh)
            return
        }
        Self.fetchArray(url: url) { array in
            guard let array, !array.isEmpty else {
                self.trySearch(title: title, artist: artist, duration: duration,
                               attempt: attempt + 1, finish: finish, fallbackToOvh: fallbackToOvh)
                return
            }
            // Weighted pick, DynamicNotch scoring: exact title/artist
            // dominate, synced lyrics and a close duration are bonuses.
            // Exactness is a bonus, not a filter, so a sensor title
            // carrying "(Official Video)" still resolves to the best
            // candidate instead of nothing.
            let pool = array.filter { result in
                (result["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || (result["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            var best: [String: Any]? = nil
            var bestScore = Int.min
            for result in pool {
                let s = Self.score(result, title: title, artist: artist, duration: duration)
                if s > bestScore {
                    bestScore = s
                    best = result
                }
            }
            if let best,
               let lines = Self.parseSynced(best["syncedLyrics"] as? String)
                   ?? Self.parsePlain(best["plainLyrics"] as? String, duration: duration) {
                finish(lines)
            } else {
                self.trySearch(title: title, artist: artist, duration: duration,
                               attempt: attempt + 1, finish: finish, fallbackToOvh: fallbackToOvh)
            }
        }
    }

    private static func lrclibURL(endpoint: String, title: String, artist: String,
                                  duration: Double, includeDuration: Bool,
                                  useQuery: Bool = false) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")
        if useQuery {
            let q = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            guard !q.isEmpty else { return nil }
            components?.queryItems = [URLQueryItem(name: "q", value: q)]
        } else {
            var items = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            if includeDuration, duration > 0 {
                items.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))"))
            }
            components?.queryItems = items
        }
        return components?.url
    }

    private static func score(_ result: [String: Any], title: String, artist: String,
                              duration: Double) -> Int {
        let norm: (String) -> String = { s in
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .replacingOccurrences(of: "\u{2019}", with: "'")
        }
        var s = 0
        if !title.isEmpty, let track = result["trackName"] as? String, norm(track) == norm(title) {
            s += 120
        }
        if !artist.isEmpty, let name = result["artistName"] as? String, norm(name) == norm(artist) {
            s += 90
        }
        if let synced = result["syncedLyrics"] as? String,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += 20
        }
        if duration > 0, let d = result["duration"] as? Double, d > 0 {
            let delta = abs(Int(d.rounded()) - Int(duration.rounded()))
            if delta <= 2 { s += 24 } else if delta <= 6 { s += 12 }
        }
        return s
    }

    private static func fetchObject(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Aura-Island/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(obj)
        }.resume()
    }

    private static func fetchArray(url: URL, completion: @escaping ([[String: Any]]?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Aura-Island/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                completion(nil)
                return
            }
            completion(array)
        }.resume()
    }

    /// lyrics.ovh fallback (no API key): plain lyrics for songs
    /// LRCLIB does not have at all. Returns nil on any failure
    /// (network, 404, no lyrics field) — the caller then shows
    /// nothing, as before. 15s timeout so a slow fallback never
    /// hangs the lyrics display.
    private static func fetchOvhLyrics(title: String, artist: String,
                                       completion: @escaping (String?) -> Void) {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let artistEsc = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let titleEsc = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(artistEsc)/\(titleEsc)") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Aura-Island/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let lyrics = json["lyrics"] as? String, !lyrics.isEmpty else {
                completion(nil)
                return
            }
            completion(lyrics)
        }.resume()
    }

    /// Parses "[mm:ss.xx] text" lines into (seconds, text), sorted by
    /// time. Honors the "[offset:+/-ms]" tag when present: it shifts
    /// every timestamp (positive = lyrics sooner, per the LRC spec). The tag is usually
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
                    // LRC spec: positive [offset:] = lyrics appear
                    // SOONER, so it is subtracted (the old "+" made
                    // every offset-tagged file twice as far off).
                    times.append(max(0, minutes * 60 + seconds - offsetSeconds))
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
            // Strip enhanced-LRC word timings ("<00:12.34>word").
            while let open = line.firstIndex(of: "<"),
                  let close = line[open...].firstIndex(of: ">") {
                line.removeSubrange(open...close)
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
