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
/// Fallback 1 (Chrome tab, no extension): when the system path yields
/// no image for this track, the playing tab's own thumbnail is tried
/// (ChromeTabArtwork: match the tab by song title, video ID ->
/// i.ytimg.com thumbnail). That image is the tab's own cover, not a
/// search result — the "from the playing app" rule still holds, only
/// the channel changes. It cannot cover playing from home/
/// recommendations (the tab stays on the home URL, no video ID).
///
/// Fallback 2 (iTunes Search, by title + artist): the catalog search
/// brought back by explicit user choice (Oct 2026) as the final
/// fallback, precisely for the cases the exact sources cannot cover
/// (home/recommendations, non-Chrome players). It is a search, not
/// the playing app's image — the acknowledged exception, reached
/// only after system and tab both failed. A fallback miss counts as
/// a miss like any other (failed set), so neither fallback is
/// re-run every second.
///
/// Race guard: the artwork read returns the title/artist it belongs
/// to. If the track changed mid-fetch, the result is discarded (not
/// cached, not marked failed) — the new track's own refresh cycle
/// fetches its artwork. Only a title-matching result is cached, and
/// only a title-matching nil marks the track failed. The tab fallback
/// needs no extra guard: its image is matched by the requested title
/// itself, so it always belongs to the track key it is cached under.
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
            // System path hit: matching image, cache it and finish.
            if artTitle == title && artArtist == artist, let image {
                cache[cacheKey] = image
                inFlight.remove(cacheKey)
                completion()
                return
            }
            // Different non-empty track: the track changed mid-fetch.
            // Discard, fail nothing, no fallback — the new track
            // fetches its own artwork.
            if !artTitle.isEmpty && (artTitle != title || artArtist != artist) {
                inFlight.remove(cacheKey)
                completion()
                return
            }
            // System path yielded nothing for THIS track (matched but
            // nil, or the script failed): try the Chrome tab fallback,
            // then iTunes, before marking the track failed.
            ChromeTabArtwork.fetch(title: title, artist: artist) { [weak self] tabImage in
                guard let self else { return }
                if let tabImage {
                    cache[cacheKey] = tabImage
                    inFlight.remove(cacheKey)
                    completion()
                    return
                }
                ITunesArtwork.fetch(title: title, artist: artist) { [weak self] itunesImage in
                    guard let self else { return }
                    if let itunesImage {
                        cache[cacheKey] = itunesImage
                    } else {
                        // System, tab, and iTunes all provided nothing.
                        failed.insert(cacheKey)
                    }
                    inFlight.remove(cacheKey)
                    completion()
                }
            }
        }
    }
}
