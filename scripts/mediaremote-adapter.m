// mediaremote-adapter.m — Langkah 0 untuk cover Aura.
//
// Membaca now playing LANGSUNG dari framework MediaRemote di sisi
// native (bukan lewat bridge JXA), untuk menjawab satu pertanyaan:
// apakah byte artwork memang ada di sisi native?
//
// Kenapa bukan Perl: Perl macOS tidak punya bridge ke framework
// ObjC/C, jadi tidak bisa memanggil MediaRemote langsung. Adapter
// ini adalah binary native kecil dengan bentuk CLI yang sama seperti
// yang direncanakan: mediaremote-adapter <path-framework> get
// (path boleh berupa bundle .framework atau binary di dalamnya).
//
// Build (di Mac, butuh Xcode Command Line Tools):
//   clang -fobjc-arc -framework Foundation \
//     -o mediaremote-adapter scripts/mediaremote-adapter.m
//
// Jalankan SAAT Chrome memutar YouTube Music:
//   ./mediaremote-adapter \
//     /System/Library/PrivateFrameworks/MediaRemote.framework get
//
// Output: satu objek JSON ke stdout.
//   - infoPresent=false  -> dict nil: helper ikut diblokir (seperti
//     Aura direct) ATAU tidak ada lagu yang jalan. Pastikan Chrome
//     memutar dulu sebelum menyimpulkan diblokir.
//   - artwork.length > 0 -> byte ADA di sisi native: masalahnya di
//     JXA, pindahkan pembacaan ke helper ini.
//   - artwork.length == 0 DAN artworkViaFunction.length == 0 ->
//     Chrome tidak meneruskan byte lewat MediaRemote: pakai
//     Fallback 1 (cover dari tab Chrome via AppleScript).
//
// Sengaja TIDAK memanggil nilai artwork bila ia berupa block: block
// yang dipanggil dengan signature yang salah bisa crash, dan untuk
// Langkah 0 cukup tahu CLASS-nya apa (artwork.class) + apakah fungsi
// artwork khusus mengembalikan byte. Bila class-nya ternyata block,
// barulah dirancang pemanggilan block yang benar (v2).
//
// Catatan: helper ini TIDAK di-link ke MediaRemote saat build
// (dlopen saat jalan), jadi tidak ada masalah link-time dengan
// private framework. Entitlement tetap berlaku saat jalan: helper
// pihak ketiga bisa saja mengembalikan nil seperti Aura direct —
// justru itu yang diuji Langkah 0 ini.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/runtime.h>

typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t queue,
                                      void (^)(CFDictionaryRef info));
typedef void (*MRGetNowPlayingArtworkFn)(dispatch_queue_t queue,
                                         void (^)(NSData *artwork));

static NSString *classNameOf(id value) {
    if (value == nil) return nil;
    Class cls = object_getClass(value);
    if (cls == Nil) return nil;
    const char *name = class_getName(cls);
    return name ? [NSString stringWithUTF8String:name] : nil;
}

static void printJSON(NSDictionary *dict) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:0
                                                     error:&error];
    if (data == nil) {
        fprintf(stderr, "{\"error\":\"json encode failed\"}\n");
        return;
    }
    printf("%s\n", [[NSString alloc] initWithData:data
                                         encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || strcmp(argv[2], "get") != 0) {
            fprintf(stderr,
                    "Usage: %s <path-framework> get\n"
                    "  path-framework: /System/Library/PrivateFrameworks/"
                    "MediaRemote.framework (bundle atau binary)\n",
                    argv[0]);
            return 2;
        }

        // Terima bundle .framework maupun path binary langsung.
        NSString *frameworkPath = [NSString stringWithUTF8String:argv[1]];
        if ([frameworkPath hasSuffix:@".framework"]) {
            frameworkPath =
                [frameworkPath stringByAppendingPathComponent:@"MediaRemote"];
        }

        void *handle = dlopen(frameworkPath.UTF8String, RTLD_NOW);
        if (handle == NULL) {
            printJSON(@{
                @"error" : @"dlopen failed",
                @"detail" : [NSString stringWithUTF8String:dlerror()],
                @"frameworkPath" : frameworkPath,
            });
            return 1;
        }

        MRGetNowPlayingInfoFn getInfo =
            (MRGetNowPlayingInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        if (getInfo == NULL) {
            printJSON(@{
                @"error" : @"MRMediaRemoteGetNowPlayingInfo not found",
                @"frameworkPath" : frameworkPath,
            });
            return 1;
        }

        // --- now playing info (nilai disalin di dalam callback, jadi
        // tidak bergantung pada lifetime dict setelah callback kembali).
        __block NSDictionary *infoCopy = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        getInfo(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                ^(CFDictionaryRef info) {
                    if (info != NULL) {
                        infoCopy = (__bridge NSDictionary *)info;
                    }
                    dispatch_semaphore_signal(sem);
                });
        long waited = dispatch_semaphore_wait(
            sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (waited != 0 || infoCopy == nil) {
            printJSON(@{
                @"infoPresent" : @NO,
                @"error" : (waited != 0
                                ? @"timeout waiting for nowPlayingInfo"
                                : @"nowPlayingInfo is nil (blocked or nothing playing)"),
            });
            // info nil BUKAN crash: ini satu hasil Langkah 0 yang sah
            // (diblokir entitlement, atau tidak ada lagu yang jalan).
            return 0;
        }

        NSString *title =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoTitle"];
        NSString *artist =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoArtist"];
        NSString *album =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoAlbum"];
        NSNumber *duration =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoDuration"];
        NSNumber *elapsed =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
        NSNumber *rate =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        NSString *artworkId =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
        NSString *artworkMime =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"];
        NSNumber *artworkWidth =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoArtworkDataWidth"];
        NSNumber *artworkHeight =
            infoCopy[@"kMRMediaRemoteNowPlayingInfoArtworkDataHeight"];

        // --- artwork dari dict (bentuk apa pun: NSData, block, dll).
        id artworkValue = infoCopy[@"kMRMediaRemoteNowPlayingInfoArtwork"];
        NSString *artworkClass = classNameOf(artworkValue);
        NSData *artworkData = nil;
        if ([artworkValue isKindOfClass:[NSData class]]) {
            artworkData = (NSData *)artworkValue;
        }
        NSMutableDictionary *artworkJSON = [NSMutableDictionary dictionary];
        artworkJSON[@"present"] = @(artworkValue != nil);
        if (artworkClass != nil) artworkJSON[@"class"] = artworkClass;
        artworkJSON[@"length"] = @(artworkData != nil ? artworkData.length : 0);
        if (artworkData != nil) {
            artworkJSON[@"base64"] =
                [artworkData base64EncodedStringWithOptions:0];
        }

        // --- artwork via fungsi khusus (jalur aman kedua, tanpa
        // menebak bentuk nilai di dict).
        NSMutableDictionary *viaFnJSON = [NSMutableDictionary dictionary];
        MRGetNowPlayingArtworkFn getArtwork =
            (MRGetNowPlayingArtworkFn)dlsym(handle,
                                            "MRMediaRemoteGetNowPlayingArtwork");
        viaFnJSON[@"functionFound"] = @(getArtwork != NULL);
        if (getArtwork != NULL) {
            __block NSData *fnData = nil;
            dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
            getArtwork(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                       ^(NSData *artwork) {
                           fnData = artwork;
                           dispatch_semaphore_signal(sem2);
                       });
            long waited2 = dispatch_semaphore_wait(
                sem2, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            if (waited2 != 0) {
                viaFnJSON[@"error"] = @"timeout waiting for artwork";
            } else {
                viaFnJSON[@"length"] = @(fnData != nil ? fnData.length : 0);
                if (fnData != nil && fnData.length > 0) {
                    NSString *b64 =
                        [fnData base64EncodedStringWithOptions:0];
                    // Prefix saja untuk cek keberadaan; base64 penuh
                    // diambil dari jalur dict bila itu yang berisi byte.
                    viaFnJSON[@"base64Prefix"] =
                        [b64 substringToIndex:MIN(80, b64.length)];
                }
            }
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"infoPresent"] = @YES;
        if (title != nil) out[@"title"] = title;
        if (artist != nil) out[@"artist"] = artist;
        if (album != nil) out[@"album"] = album;
        if (duration != nil) out[@"duration"] = duration;
        if (elapsed != nil) out[@"elapsed"] = elapsed;
        if (rate != nil) out[@"playbackRate"] = rate;
        if (artworkId != nil) out[@"artworkIdentifier"] = artworkId;
        if (artworkMime != nil) out[@"artworkMIMEType"] = artworkMime;
        if (artworkWidth != nil) out[@"artworkDataWidth"] = artworkWidth;
        if (artworkHeight != nil) out[@"artworkDataHeight"] = artworkHeight;
        out[@"artwork"] = artworkJSON;
        out[@"artworkViaFunction"] = viaFnJSON;
        printJSON(out);
        return 0;
    }
}
