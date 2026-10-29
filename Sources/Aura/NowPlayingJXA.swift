import AppKit
import Foundation

/// Now-playing sensor for macOS 15.4+, where Apple blocks third-party
/// processes from reading MediaRemote directly: mediaremoted denies
/// MRMediaRemoteGetNowPlayingInfo (and the other getters) to any client
/// without Apple's entitlement. That is exactly the symptom seen on
/// macOS 15.7: Control Center (Apple's own UI) shows the track while a
/// third-party caller gets nil/empty, no matter how the call is made.
///
/// The workaround, used by the media-remote project and others: run a
/// small JXA script through /usr/bin/osascript — an Apple-signed system
/// binary — which reads the SAME info through the modern, synchronous
/// MRNowPlayingRequest API and prints it as JSON. No SIP change, no
/// daemon patching, no private entitlement needed.
///
/// Trade-offs vs the direct path (documented, accepted):
/// - Polling only (no change notifications); the app already polls
///   every second, so this costs one osascript spawn per tick.
/// - Browser elapsed time can go stale in the info dict; the script
///   prefers metadata.calculatedPlaybackPosition when available.
/// - Artwork is NOT in the per-second poll (base64 image bytes would
///   bloat every tick). It is fetched separately, once per track,
///   via fetchArtwork: the same nowPlayingInfo read, but returning
///   only the artwork bytes as base64 plus the title/artist they
///   belong to, so the caller can discard them if the track changed
///   mid-fetch. No online search is involved — the cover is exactly
///   what the playing app reports to the system.
enum NowPlayingJXA {
    private static let script = """
        ObjC.import('Foundation');
        function run() {
          try {
            var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
            // NOTE (JXA quirk): zero-argument ObjC methods are invoked by bare
            // property access. `bundle.load()` tries to CALL the BOOL result and
            // throws 'bundle.load is not a function' — this exact bug broke the
            // sensor until the standalone osascript run proved it.
            bundle.load;
            var MRNowPlayingRequest = $.NSClassFromString('MRNowPlayingRequest');
            if (!MRNowPlayingRequest) return JSON.stringify(null);
            var item = MRNowPlayingRequest.localNowPlayingItem;
            if (!item) return JSON.stringify(null);
            var info = item.nowPlayingInfo;
            if (!info) return JSON.stringify(null);
            function str(key) {
              var v = info.valueForKey(key);
              return v ? v.js : '';
            }
            function num(key) {
              var v = info.valueForKey(key);
              return v ? v.js : 0;
            }
            var position = num('kMRMediaRemoteNowPlayingInfoElapsedTime');
            try {
              var meta = item.metadata;
              if (meta) {
                var calc = meta.calculatedPlaybackPosition;
                if (calc && calc.js > 0) position = calc.js;
              }
            } catch (e) {}
            var client = '';
            try {
              var path = MRNowPlayingRequest.localNowPlayingPlayerPath;
              if (path && path.client && path.client.displayName) client = path.client.displayName.js;
            } catch (e) {}
            return JSON.stringify({
              title: str('kMRMediaRemoteNowPlayingInfoTitle'),
              artist: str('kMRMediaRemoteNowPlayingInfoArtist'),
              album: str('kMRMediaRemoteNowPlayingInfoAlbum'),
              duration: num('kMRMediaRemoteNowPlayingInfoDuration'),
              elapsed: position,
              rate: num('kMRMediaRemoteNowPlayingInfoPlaybackRate'),
              client: client
            });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        }
        """

    /// Runs the script off the main thread (an osascript spawn costs
    /// tens of milliseconds) and delivers the result on the main thread.
    /// The second value is the playing app's display name (e.g. "Google
    /// Chrome"), for diagnostics; empty when unknown. The third value
    /// explains a nil result (nil when a track was found), so a failed
    /// detection can be diagnosed from the log line alone instead of
    /// guessing which step broke.
    /// Seek the system now-playing client to `seconds` via the same
    /// osascript path as the sensor (MediaRemote is loaded from the
    /// private framework the same way). The C function
    /// MRMediaRemoteSetElapsedTime is called through the JXA bridge;
    /// if it is not reachable the script reports failure and the
    /// caller leaves the bar alone (it snaps back on next draw).
    /// Runs off the main thread; completion on main.
    static func seek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        // Numeric-formatted into the script (no user input): osascript
        // -e scripts do not reliably receive argv, so interpolation
        // is the dependable channel.
        let value = String(format: "%.3f", seconds)
        let script = """
        ObjC.import('Foundation');
        function run() {
          try {
            var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
            bundle.load;
            var fn = $.MRMediaRemoteSetElapsedTime;
            if (typeof fn !== 'function') return JSON.stringify({ error: 'no-seek-function' });
            fn(\(value));
            return JSON.stringify({ ok: true });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        }
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-l", "JavaScript", "-e", script]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            var ok = false
            do {
                try proc.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                   let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["ok"] as? Bool == true {
                    ok = true
                }
            } catch {
                ok = false
            }
            if !ok {
                print("[Aura] seek failed (target \(value)s)")
            }
            let result = ok
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func fetch(completion: @escaping (NowPlaying?, String, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = runScript()
            DispatchQueue.main.async {
                completion(result.now, result.client, result.failure)
            }
        }
    }

    /// Artwork for the CURRENT item only, as base64 image bytes from
    /// the same nowPlayingInfo dict the poll reads — i.e. exactly what
    /// the playing app reports, never an online guess. Delivered on the
    /// main thread as (title, artist, image): the title/artist use the
    /// same fallback as the poll (title, else artist, else "Musik"),
    /// so the caller can verify the artwork still belongs to the track
    /// it asked for. Empty title/artist means the script failed or no
    /// item exists; nil image with a title means the player simply
    /// provides no artwork (placeholder stays).
    static func fetchArtwork(completion: @escaping (String, String, NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = runArtworkScript()
            DispatchQueue.main.async {
                completion(result.title, result.artist, result.image)
            }
        }
    }

    private static let artworkScript = """
        ObjC.import('Foundation');
        ObjC.import('AppKit');
        function run() {
          try {
            var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
            // Same JXA quirk as the poll script: bare property access
            // invokes a zero-argument ObjC method; `bundle.load()` would
            // try to call the BOOL result.
            bundle.load;
            var MRNowPlayingRequest = $.NSClassFromString('MRNowPlayingRequest');
            if (!MRNowPlayingRequest) return JSON.stringify(null);
            var item = MRNowPlayingRequest.localNowPlayingItem;
            if (!item) return JSON.stringify(null);
            var info = item.nowPlayingInfo;
            if (!info) return JSON.stringify(null);
            function str(key) {
              var v = info.valueForKey(key);
              return v ? v.js : '';
            }
            function pngBase64(cgImage) {
              var rep = $.NSBitmapImageRep.alloc.initWithCGImage(cgImage);
              var data = rep.representationUsingTypeProperties(4, $.NSDictionary.dictionary);
              return data.base64EncodedStringWithOptions(0).js;
            }
            function tiffBase64(cgImage) {
              var img = $.NSImage.alloc.initWithCGImageSize(cgImage, { width: 600, height: 600 });
              var tiff = img.TIFFRepresentation;
              return tiff.base64EncodedStringWithOptions(0).js;
            }
            function imageBase64(value) {
              // Converts NSData / CGImage to base64, or null. Each
              // conversion guarded; a wrong type just returns null.
              if (!value) return null;
              try { var b = value.base64EncodedStringWithOptions(0).js; if (b) return b; } catch (e) {}
              try { var b2 = pngBase64(value); if (b2) return b2; } catch (e) {}
              try { var b3 = tiffBase64(value); if (b3) return b3; } catch (e) {}
              return null;
            }
            var b64 = null;
            var artPresent = false;
            try {
              var art = info.valueForKey('kMRMediaRemoteNowPlayingInfoArtwork');
              // The value is not always image data. For Chrome
              // sessions the probe showed typeofArt "function": the
              // value is an ObjC block (JXA bridges blocks as JS
              // functions), i.e. a lazy artwork provider that must be
              // CALLED to yield the image. That is why every earlier
              // attempt failed — a function was treated as data, and
              // forcing it into a CGImage slot passed NULL.
              // Other shapes: NSData (native players), CGImage, or
              // MPMediaItemArtwork (imageWithSize). Each step guarded;
              // failure falls through to the placeholder. The block
              // calls run in this osascript subprocess, so even a
              // crashing call cannot hurt the app itself.
              if (art) {
                artPresent = true;
                if (typeof art === 'function') {
                  try { b64 = imageBase64(art()); } catch (e) {}
                  if (!b64) {
                    try { b64 = imageBase64(art({ width: 600, height: 600 })); } catch (e) {}
                  }
                } else {
                  b64 = imageBase64(art);
                  if (!b64 && typeof art.imageWithSize === 'function') {
                    try { b64 = imageBase64(art.imageWithSize({ width: 600, height: 600 })); } catch (e) {}
                  }
                }
              }
            } catch (e) {}
            return JSON.stringify({
              title: str('kMRMediaRemoteNowPlayingInfoTitle'),
              artist: str('kMRMediaRemoteNowPlayingInfoArtist'),
              artwork: b64,
              artworkPresent: artPresent
            });
          } catch (e) {
            return JSON.stringify({ error: String(e) });
          }
        }
        """

    private static func runArtworkScript() -> (title: String, artist: String, image: NSImage?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", artworkScript]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return ("", "", nil)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if proc.isRunning {
                proc.terminate()
            }
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            return ("", "", nil)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines) != "null",
              let jsonData = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              obj["error"] == nil else {
            return ("", "", nil)
        }
        let rawTitle = obj["title"] as? String ?? ""
        let artist = obj["artist"] as? String ?? ""
        // Same fallback as the poll, so the caller compares like with like.
        let title = !rawTitle.isEmpty ? rawTitle : (!artist.isEmpty ? artist : "Musik")
        var image: NSImage?
        if let b64 = obj["artwork"] as? String,
           let imageData = Data(base64Encoded: b64) {
            image = NSImage(data: imageData)
        }
        return (title, artist, image)
    }

    private static func runScript() -> (now: NowPlaying?, client: String, failure: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return (nil, "", "osascript-gagal-dijalankan")
        }
        // Never let one stuck osascript block this sensor forever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if proc.isRunning {
                proc.terminate()
            }
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            return (nil, "", "osascript-status-\(proc.terminationStatus)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, "", "output-bukan-teks")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return (nil, "", "tidak-ada-item")
        }
        guard let jsonData = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return (nil, "", "output-bukan-json")
        }
        guard obj["error"] == nil else {
            return (nil, "", "script-error")
        }
        let title = obj["title"] as? String ?? ""
        let artist = obj["artist"] as? String ?? ""
        let rate = (obj["rate"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (obj["elapsed"] as? NSNumber)?.doubleValue ?? 0
        let duration = (obj["duration"] as? NSNumber)?.doubleValue ?? 0
        let client = obj["client"] as? String ?? ""
        guard !title.isEmpty || rate > 0 else {
            return (nil, "", "tidak-ada-item")
        }
        let displayTitle = !title.isEmpty ? title : (!artist.isEmpty ? artist : "Musik")
        let now = NowPlaying(
            title: displayTitle,
            artist: artist,
            isPlaying: rate > 0,
            position: elapsed,
            duration: duration,
            artwork: nil
        )
        return (now, client, nil)
    }
}
