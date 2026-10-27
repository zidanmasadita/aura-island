import AppKit
import Foundation

/// Album artwork via the iTunes Search API (free, no key). The JXA
/// sensor cannot read artwork from the system on macOS 15.4+, so the
/// cover is looked up online by title + artist instead. One lookup per
/// track; misses (obscure track, no network) are remembered for the
/// session so a failed lookup is not retried every second, and the
/// placeholder simply stays.
///
/// Accuracy: the lookup fetches several candidates and picks the best
/// match — exact title, then artist, then closest duration to the
/// playing track — instead of blindly taking the first result, which
/// is often a remix, live version, compilation, or a different song
/// with a similar title (and therefore the wrong cover). This mirrors
/// the lyrics fix, where the first LRCLIB hit was often the wrong
/// version. A candidate whose title does not match the query at all
/// is rejected, so a bad lookup shows the placeholder rather than a
/// stranger's cover.
final class ArtworkFetcher {
    static let shared = ArtworkFetcher()

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    private init() {}

    private func key(title: String, artist: String, duration: Double) -> String {
        "\(title)|\(artist)|\(Int(duration))"
    }

    func cachedArtwork(title: String, artist: String, duration: Double) -> NSImage? {
        cache[key(title: title, artist: artist, duration: duration)]
    }

    /// Starts a lookup unless one is cached, in flight, or already
    /// failed for this track. Completion always runs on the main thread.
    func fetchArtwork(title: String, artist: String, duration: Double, completion: @escaping () -> Void) {
        let cacheKey = key(title: title, artist: artist, duration: duration)
        guard cache[cacheKey] == nil, !inFlight.contains(cacheKey), !failed.contains(cacheKey) else { return }
        inFlight.insert(cacheKey)
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: artist.isEmpty ? title : "\(title) \(artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else {
            finish(key: cacheKey, image: nil, completion: completion)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            var imageURL: URL?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]] {
                imageURL = Self.bestArtworkURL(results: results, title: title, artist: artist, duration: duration)
            }
            guard let imageURL else {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(key: cacheKey, image: nil, completion: completion)
                }
                return
            }
            URLSession.shared.dataTask(with: imageURL) { [weak self] imageData, _, _ in
                let image = imageData.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { [weak self] in
                    self?.finish(key: cacheKey, image: image, completion: completion)
                }
            }.resume()
        }.resume()
    }

    /// Picks the best-matching candidate's artwork URL, or nil when no
    /// candidate's title matches the query at all.
    private static func bestArtworkURL(results: [[String: Any]], title: String, artist: String, duration: Double) -> URL? {
        let wantTitle = normalize(title)
        guard !wantTitle.isEmpty else { return nil }
        let wantArtist = normalize(artist)
        var best: (score: Double, url: URL)?
        for result in results {
            guard let trackName = result["trackName"] as? String,
                  var art = result["artworkUrl100"] as? String else { continue }
            let track = normalize(trackName)
            let trackArtist = normalize(result["artistName"] as? String ?? "")
            // Title must match (either direction, to tolerate
            // "(Official Video)"-style suffixes on either side).
            // Without this, a same-word different song could win.
            let titleScore: Double
            if track == wantTitle {
                titleScore = 100
            } else if track.contains(wantTitle) || wantTitle.contains(track) {
                titleScore = 40
            } else {
                continue
            }
            var score = titleScore
            if !wantArtist.isEmpty {
                if trackArtist == wantArtist {
                    score += 50
                } else if trackArtist.contains(wantArtist) || wantArtist.contains(trackArtist) {
                    score += 20
                }
            }
            if duration > 0, let millis = result["trackTimeMillis"] as? Double {
                score -= min(abs(millis / 1000.0 - duration), 300)
            }
            // iTunes serves 100px by default; the same URL pattern
            // yields a 600px cover, which stays crisp in the card.
            art = art.replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
            guard let url = URL(string: art) else { continue }
            if best == nil || score > best!.score {
                best = (score, url)
            }
        }
        return best?.url
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private func finish(key: String, image: NSImage?, completion: () -> Void) {
        inFlight.remove(key)
        if let image {
            cache[key] = image
        } else {
            failed.insert(key)
        }
        completion()
    }
}
