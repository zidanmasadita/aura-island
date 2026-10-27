import AppKit
import Foundation

/// Album artwork from the playing app itself — never an online search.
/// The JXA sensor cannot read artwork from the system on macOS 15.4+,
/// so the per-second poll carries no artwork; instead, once per track,
/// a separate osascript read returns the current item's artwork bytes
/// (base64) from the same nowPlayingInfo dict. One lookup per track;
/// misses (player provides no artwork, script failure) are remembered
/// for the session so a failed lookup is not retried every second,
/// and the placeholder simply stays.
///
/// Race guard: the artwork read returns the title/artist it belongs
/// to. If the track changed mid-fetch, the result is discarded (not
/// cached, not marked failed) — the new track's own refresh cycle
/// fetches its artwork. Only a title-matching result is cached, and
/// only a title-matching nil marks the track failed.
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

    /// Starts a system-artwork fetch unless one is cached, in flight,
    /// or already failed for this track. Completion always runs on the
    /// main thread; it only signals "refresh and re-read the cache",
    /// the image itself is never passed through it.
    func fetchArtwork(title: String, artist: String, duration: Double, completion: @escaping () -> Void) {
        let cacheKey = key(title: title, artist: artist, duration: duration)
        guard cache[cacheKey] == nil, !inFlight.contains(cacheKey), !failed.contains(cacheKey) else { return }
        inFlight.insert(cacheKey)
        NowPlayingJXA.fetchArtwork { [weak self] artTitle, artArtist, image in
            guard let self else { return }
            inFlight.remove(cacheKey)
            if artTitle.isEmpty {
                // Script failed or no item: throttle like any miss.
                failed.insert(cacheKey)
            } else if artTitle == title && artArtist == artist {
                if let image {
                    cache[cacheKey] = image
                } else {
                    // Player provides no artwork for this track.
                    failed.insert(cacheKey)
                }
            }
            // Title mismatch = track changed mid-fetch: cache nothing,
            // fail nothing; the new track fetches its own artwork.
            completion()
        }
    }
}
