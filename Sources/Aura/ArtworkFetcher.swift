import AppKit
import Foundation

/// Album artwork via the iTunes Search API (free, no key). The JXA
/// sensor cannot read artwork from the system on macOS 15.4+, so the
/// cover is looked up online by title + artist instead. One lookup per
/// track; misses (obscure track, no network) are remembered for the
/// session so a failed lookup is not retried every second, and the
/// placeholder simply stays.
final class ArtworkFetcher {
    static let shared = ArtworkFetcher()

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    private init() {}

    func cachedArtwork(title: String, artist: String) -> NSImage? {
        cache["\(title)|\(artist)"]
    }

    /// Starts a lookup unless one is cached, in flight, or already
    /// failed for this track. Completion always runs on the main thread.
    func fetchArtwork(title: String, artist: String, completion: @escaping () -> Void) {
        let key = "\(title)|\(artist)"
        guard cache[key] == nil, !inFlight.contains(key), !failed.contains(key) else { return }
        inFlight.insert(key)
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else {
            finish(key: key, image: nil, completion: completion)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            var imageURL: URL?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first,
               var art = first["artworkUrl100"] as? String {
                // iTunes serves 100px by default; the same URL pattern
                // yields a 600px cover, which stays crisp in the card.
                art = art.replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
                imageURL = URL(string: art)
            }
            guard let imageURL else {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(key: key, image: nil, completion: completion)
                }
                return
            }
            URLSession.shared.dataTask(with: imageURL) { [weak self] imageData, _, _ in
                let image = imageData.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { [weak self] in
                    self?.finish(key: key, image: image, completion: completion)
                }
            }.resume()
        }.resume()
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
