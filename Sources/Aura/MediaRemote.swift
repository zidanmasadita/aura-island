import AppKit
import Darwin
import Foundation

/// Reads the system now-playing info through the private MediaRemote
/// framework, loaded at runtime with dlopen so the app has no link-time
/// dependency on a private framework.
///
/// Two sensors, like the built-in Now Playing UI:
/// - Event-driven: observes kMRMediaRemoteNowPlayingInfoDidChangeNotification
///   on the Darwin notification center and reads the info straight from
///   the notification (falling back to a re-fetch when the payload is
///   empty). This is the sensor Control Center uses, and it fires the
///   moment playback starts, pauses, or the track changes.
/// - Polling: fetchNowPlaying() every second keeps position/progress
///   fresh between events.
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
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    private var getInfo: GetInfoFn?

    /// Fired on the main thread whenever the system reports a now-playing
    /// change. The app wires this to refresh its session immediately,
    /// instead of waiting for the next poll.
    var onInfoChanged: ((NowPlaying?) -> Void)?

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
        }
        // Registering for now-playing notifications is what makes the
        // system start reporting clients (e.g. Chrome) to
        // GetNowPlayingInfo. Without this step, polling alone can return
        // nothing even while a browser is playing — which is why music
        // went undetected when the Chrome extension was not installed.
        if let regSym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            let register = unsafeBitCast(regSym, to: RegisterFn.self)
            register(DispatchQueue.main)
        }
        // Observe the system now-playing change notification, the same
        // sensor Control Center uses. The observer pointer is just this
        // object (unretained; it lives for the app's lifetime).
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            Self.notificationCallback,
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification" as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification" as CFString,
            nil
        )
    }

    private static let notificationCallback: CFNotificationCallback = { _, observer, _, _, userInfo in
        guard let observer else { return }
        let remote = Unmanaged<MediaRemote>.fromOpaque(observer).takeUnretainedValue()
        remote.handleNotification(userInfo: userInfo)
    }

    private func handleNotification(userInfo: CFDictionary?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let userInfo,
               let map = (userInfo as NSDictionary) as? [String: Any],
               let now = Self.parse(map) {
                self.onInfoChanged?(now)
            } else {
                // No usable payload: the change signal alone means
                // something changed, so re-fetch for fresh data.
                self.fetchNowPlaying { now in self.onInfoChanged?(now) }
            }
        }
    }

    private static func parse(_ map: [String: Any]) -> NowPlaying? {
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
            return nil
        }
        let displayTitle = !title.isEmpty ? title : (!artist.isEmpty ? artist : "Musik")
        return NowPlaying(
            title: displayTitle,
            artist: artist,
            isPlaying: rate > 0,
            position: elapsed,
            duration: duration,
            artwork: artwork
        )
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
            completion(Self.parse(map))
        }
    }
}
