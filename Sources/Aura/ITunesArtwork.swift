import AppKit
import Foundation

/// Final artwork fallback: the iTunes Search API, by song title +
/// artist. This is a catalog search, not the playing app's own image
/// — the exception to the "from the playing app" rule, brought back
/// by explicit user choice (Oct 2026) because it is the only method
/// that covers every case: it works when the tab has no video ID
/// (playing from home/recommendations, URL stays on home), when the
/// player is not Chrome at all, and when the system path yields
/// nothing. The chain is system -> Chrome tab (exact image from the
/// playing tab) -> iTunes (catalog image), so the search is only
/// reached when the exact sources already failed.
///
/// No API key: the iTunes Search API is public. Matching is strict
/// (title AND artist must both match, two-way containment like the
/// lyrics matcher) so a same-title song by another artist never
/// supplies a wrong cover; no match means nil, placeholder stays.
enum ITunesArtwork {
    /// Runs off the main thread (search + download); completion
    /// always on the main thread, like NowPlayingJXA.fetchArtwork.
    static func fetch(title: String, artist: String, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let image = fetchSync(title: title, artist: artist)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private static func fetchSync(title: String, artist: String) -> NSImage? {
        guard let artworkURL = matchingArtworkURL(title: title, artist: artist) else {
            return nil
        }
        guard let data = download(url: artworkURL),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    // MARK: - Search + match

    private static func matchingArtworkURL(title: String, artist: String) -> URL? {
        let wantTitle = normalized(title)
        let wantArtist = normalized(artist)
        guard !wantTitle.isEmpty, !wantArtist.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url,
              let data = download(url: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            return nil
        }
        for result in results {
            guard let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String,
                  let artwork = result["artworkUrl100"] as? String else {
                continue
            }
            let track = normalized(trackName)
            let trackArtist = normalized(artistName)
            let titleOK = track == wantTitle
                || track.contains(wantTitle) || wantTitle.contains(track)
            let artistOK = trackArtist == wantArtist
                || trackArtist.contains(wantArtist) || wantArtist.contains(trackArtist)
            guard titleOK && artistOK else { continue }
            // 600px is far more than the 56px cover needs; if the URL
            // does not carry the size pattern, use it as-is (100px).
            let large = artwork.replacingOccurrences(of: "100x100bb.jpg",
                                                     with: "600x600bb.jpg")
            return URL(string: large)
        }
        return nil
    }

    private static func normalized(_ s: String) -> String {
        // Same lowercase + punctuation-strip + whitespace-collapse as
        // the tab matcher, so sensor titles and catalog titles compare
        // like with like ("Sign Of The Times" == "Sign of the Times").
        let cleaned = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ")
        return cleaned.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Download

    private static func download(url: URL) -> Data? {
        var result: Data?
        var response: URLResponse?
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, resp, _ in
            result = data
            response = resp
            sem.signal()
        }
        task.resume()
        // Cap the wait: URLSession's own timeout is 60s, far too long
        // for a once-per-track fallback running on a background queue.
        _ = sem.wait(timeout: .now() + 12)
        if task.state == .running {
            task.cancel()
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data = result, !data.isEmpty else {
            return nil
        }
        return data
    }
}
