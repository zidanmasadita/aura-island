import AppKit
import Darwin
import Foundation

/// Reads the system now-playing info through the private MediaRemote
/// framework, loaded at runtime with dlopen so the app has no link-time
/// dependency on a private framework.
///
/// MediaRemote is a private Apple framework: this works for a personal,
/// non-sandboxed app, but would not pass App Store review. The framework
/// binary exists on every macOS install at the path below.
final class MediaRemote {
    // NOTE: the block parameter MUST be @escaping. MRMediaRemoteGetNowPlayingInfo
    // keeps the block and calls it later (async); without @escaping Swift
    // treats it as @noescape and the runtime traps with
    // "closure argument passed as @noescape to Objective-C has escaped"
    // the moment the framework retains it — which crashed the app on launch.
    private typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping InfoBlock) -> Void

    private var getInfo: GetInfoFn?

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return }
        getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
    }

    func fetchNowPlaying(completion: @escaping (NowPlaying?) -> Void) {
        guard let getInfo else {
            completion(nil)
            return
        }
        getInfo(DispatchQueue.main) { dict in
            guard let nsDict = dict as NSDictionary?,
                  let map = nsDict as? [String: Any] else {
                completion(nil)
                return
            }
            let title = map["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = map["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let duration = (map["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
            let elapsed = (map["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
            let rate = (map["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            let artworkData = map["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            let artwork = artworkData.flatMap { NSImage(data: $0) }
            // Some sources report playback without a title. Previously such
            // sessions were dropped entirely ("music not detected") even
            // though something was playing. Keep them with a fallback title;
            // only treat it as "nothing" when there is no title AND nothing
            // is playing.
            guard !title.isEmpty || rate > 0 else {
                completion(nil)
                return
            }
            let displayTitle = !title.isEmpty ? title : (!artist.isEmpty ? artist : "Musik")
            completion(NowPlaying(
                title: displayTitle,
                artist: artist,
                isPlaying: rate > 0,
                position: elapsed,
                duration: duration,
                artwork: artwork
            ))
        }
    }
}
