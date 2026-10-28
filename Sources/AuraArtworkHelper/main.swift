// AuraArtworkHelper — Phase 0 prototype, standalone test only.
//
// Purpose: answer one question on the user's Mac, before any Aura
// integration: does a separate process reading MediaRemote directly
// still get album artwork on macOS 15.4+ (where the in-app
// MediaRemote read returns nil), or is it blocked the same way?
//
// This is the DynamicNotch idea (a helper process streams
// now-playing info + artwork), re-implemented from scratch for Aura:
// no DynamicNotch code, no Perl, no prebuilt framework. It uses the
// same dlopen pattern Aura's own MediaRemote.swift already uses,
// just in its own process.
//
// Usage (on a Mac, from the repo root, while a song is playing):
//   swift build --product AuraArtworkHelper
//   .build/debug/AuraArtworkHelper --once
//   .build/debug/AuraArtworkHelper --poll 30
//
// --once prints one JSON line and exits. --poll N polls every 2s
// for N seconds. Each JSON line carries title/artist/duration/
// elapsed/playing, artworkPresent, artworkBytes, and (when artwork
// exists) artworkPath — the full artwork written to that file so it
// can be opened and eyeballed, instead of dumping base64 to the
// terminal. Diagnostics go to stderr, JSON to stdout.
import AppKit
import Darwin
import Foundation

private typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping InfoBlock) -> Void
private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

func log(_ message: String) {
    FileHandle.standardError.write(Data("[helper] \(message)\n".utf8))
}

let args = CommandLine.arguments
let once = args.contains("--once")
var pollSeconds = 0
if let i = args.firstIndex(of: "--poll"), i + 1 < args.count {
    pollSeconds = Int(args[i + 1]) ?? 0
}
let outPath = "/tmp/aura-helper-artwork.jpg"

let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(path, RTLD_NOW) else {
    log("dlopen FAILED: \(String(cString: dlerror()))")
    exit(1)
}
log("dlopen ok")
guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
    log("MRMediaRemoteGetNowPlayingInfo symbol NOT FOUND")
    exit(1)
}
private let getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
if let regSym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
    let register = unsafeBitCast(regSym, to: RegisterFn.self)
    register(DispatchQueue.main)
    log("registered for now-playing notifications")
} else {
    log("register symbol NOT FOUND (polling only)")
}

func fetchOnce(completion: @escaping () -> Void) {
    getInfo(DispatchQueue.main) { dict in
        defer { completion() }
        guard let nsDict = dict as NSDictionary?,
              let map = nsDict as? [String: Any] else {
            print("{\"error\":\"no now-playing info\"}")
            return
        }
        let title = map["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = map["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = map["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (map["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (map["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let rate = (map["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let artworkData = map["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        var artworkPath: String? = nil
        if let artworkData, !artworkData.isEmpty {
            // Validate it is really an image, not just non-empty bytes.
            if NSImage(data: artworkData) != nil {
                try? artworkData.write(to: URL(fileURLWithPath: outPath))
                artworkPath = outPath
            } else {
                log("artworkData present (\(artworkData.count) bytes) but NOT a valid image")
            }
        }
        let payload: [String: Any] = [
            "title": title,
            "artist": artist,
            "album": album,
            "duration": duration,
            "elapsed": elapsed,
            "playing": rate > 0,
            "artworkPresent": artworkData != nil && !(artworkData?.isEmpty ?? true),
            "artworkBytes": artworkData?.count ?? 0,
            "artworkPath": artworkPath as Any,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }
}

if once {
    let sema = DispatchSemaphore(value: 0)
    fetchOnce { sema.signal() }
    // The callback runs on the main queue; pump the run loop until it fires.
    while sema.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    exit(0)
}

let deadline = Date(timeIntervalSinceNow: TimeInterval(max(pollSeconds, 10)))
while Date() < deadline {
    let sema = DispatchSemaphore(value: 0)
    fetchOnce { sema.signal() }
    while sema.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    Thread.sleep(forTimeInterval: 2)
}
