// MediaRemoteHelper
//
// Since macOS 15.4, MediaRemote.framework only returns now-playing data to
// Apple-signed processes. This dylib is loaded into /usr/bin/perl (which is
// Apple-signed) and acts as a tiny bridge:
//   stdout: one JSON object per line describing the current now-playing state
//   stdin : one command per line (toggle, play, pause, next, prev, prevtrack, smartprev <threshold> <cap> <fallback>, seek <sec>, refresh)

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientBundleFn)(id);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static MRRegisterFn MRRegister;
static MRGetInfoFn MRGetInfo;
static MRGetPlayingFn MRGetPlaying;
static MRGetPIDFn MRGetPID;
static MRGetClientFn MRGetClient;
static MRClientBundleFn MRClientBundle;
static MRClientBundleFn MRClientParentBundle;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;

static dispatch_queue_t q;
static NSString *lastArtworkId = nil;
static NSString *lastLine = nil;
static BOOL refreshScheduled = NO;

static void emit(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine]) return;
    lastLine = line;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id jsonSafe(id v) {
    if (!v || v == [NSNull null]) return [NSNull null];
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    return [v description];
}

static void refresh(void) {
    MRGetInfo(q, ^(NSDictionary *info) {
        MRGetPlaying(q, ^(Boolean playing) {
            MRGetPID(q, ^(int pid) {
                void (^finish)(NSString *, NSString *) = ^(NSString *bundle, NSString *parent) {
                    NSMutableDictionary *out = [NSMutableDictionary dictionary];
                    out[@"type"] = @"state";
                    out[@"playing"] = @(playing);
                    out[@"pid"] = @(pid);
                    out[@"bundle"] = bundle ?: (id)[NSNull null];
                    out[@"parentBundle"] = parent ?: (id)[NSNull null];
                    if (info.count == 0) {
                        out[@"hasInfo"] = @NO;
                        lastArtworkId = nil;
                        emit(out);
                        return;
                    }
                    out[@"hasInfo"] = @YES;
                    out[@"title"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                    out[@"artist"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                    out[@"album"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                    out[@"duration"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                    out[@"elapsed"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                    out[@"rate"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                    out[@"timestamp"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]);
                    out[@"contentId"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]);

                    // Some sources (Apple Music) publish an explicit flag directly.
                    for (NSString *key in info) {
                        if ([key rangeOfString:@"Explicit" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                            id v = info[key];
                            if ([v isKindOfClass:[NSNumber class]]) out[@"explicit"] = v;
                        }
                    }

                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([art isKindOfClass:[NSData class]] && art.length > 0) {
                        NSString *artId = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
                        if (![artId isKindOfClass:[NSString class]]) {
                            artId = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
                        }
                        out[@"artworkId"] = artId;
                        if (![artId isEqualToString:lastArtworkId]) {
                            // Artwork is only sent when it changes; the app caches it by id.
                            NSMutableDictionary *artMsg = [NSMutableDictionary dictionary];
                            artMsg[@"type"] = @"artwork";
                            artMsg[@"artworkId"] = artId;
                            artMsg[@"data"] = [art base64EncodedStringWithOptions:0];
                            lastLine = nil;
                            emit(artMsg);
                            lastArtworkId = artId;
                        }
                    } else {
                        out[@"artworkId"] = [NSNull null];
                        lastArtworkId = nil;
                    }
                    emit(out);
                };

                if (MRGetClient && MRClientBundle) {
                    MRGetClient(q, ^(id client) {
                        NSString *bundle = nil, *parent = nil;
                        if (client) {
                            bundle = (__bridge NSString *)MRClientBundle(client);
                            if (MRClientParentBundle) parent = (__bridge NSString *)MRClientParentBundle(client);
                        }
                        finish(bundle, parent);
                    });
                } else {
                    finish(nil, nil);
                }
            });
        });
    });
}

static void scheduleRefresh(void) {
    // Coalesce bursts of notifications into a single refresh.
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), q, ^{
        refreshScheduled = NO;
        refresh();
    });
}

// Rewind, then "previous": a player applying its own "restart if a few seconds in"
// rule (Spotify, Music) then always goes back a track.
static void previousTrack(void) {
    MRSetElapsed(0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), q, ^{ MRSendCommand(5, NULL); });
}

// The iOS Previous button, decided on the player's live position rather than the app's
// estimate (which lags, or misses seeks the player didn't announce): restart once it's
// `threshold` seconds in, otherwise go back a track. `cap`: the current item began at
// most this long ago (the app just skipped), or < 0. `fallback`: the app's estimate,
// for players that don't publish a position.
static void smartPrevious(double threshold, double cap, double fallback) {
    MRGetInfo(q, ^(NSDictionary *info) {
      MRGetPlaying(q, ^(Boolean playing) {
        double pos = fallback;
        id e = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
        // Paused, Spotify keeps publishing the pair from when playback started, so only a
        // playing position can be trusted; paused, the app's frozen one is right.
        if (playing && [e isKindOfClass:[NSNumber class]]) {
            pos = [e doubleValue];
            id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            id rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            double r = [rate isKindOfClass:[NSNumber class]] ? [rate doubleValue] : 0;
            if ([ts isKindOfClass:[NSDate class]] && r > 0) pos += [[NSDate date] timeIntervalSinceDate:ts] * r;
        }
        if (cap >= 0 && cap < pos) pos = cap;
        BOOL restart = pos >= threshold;
        if (restart) MRSetElapsed(0); else previousTrack();
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"type"] = @"previous";
        out[@"position"] = @(pos);
        out[@"action"] = restart ? @"restart" : @"previous";
        lastLine = nil;
        emit(out);
        lastLine = nil;
        scheduleRefresh();
      });
    });
}

static void handleCommand(NSString *line) {
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) return;
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts[0];
    // MRCommand values: 0 play, 1 pause, 2 toggle, 3 stop, 4 next, 5 previous
    if ([cmd isEqualToString:@"play"]) MRSendCommand(0, NULL);
    else if ([cmd isEqualToString:@"pause"]) MRSendCommand(1, NULL);
    else if ([cmd isEqualToString:@"toggle"]) MRSendCommand(2, NULL);
    else if ([cmd isEqualToString:@"next"]) MRSendCommand(4, NULL);
    else if ([cmd isEqualToString:@"prev"]) MRSendCommand(5, NULL);
    else if ([cmd isEqualToString:@"prevtrack"]) previousTrack();
    else if ([cmd isEqualToString:@"smartprev"] && parts.count > 3)
        smartPrevious([parts[1] doubleValue], [parts[2] doubleValue], [parts[3] doubleValue]);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) MRSetElapsed([parts[1] doubleValue]);
    else if ([cmd isEqualToString:@"refresh"]) { lastLine = nil; lastArtworkId = nil; }
    scheduleRefresh();
    // Some players update their published state lazily after a command.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), q, ^{ refresh(); });
}

// Called from perl as an XSUB; arguments are ignored. Never returns.
void DockMediaHelperRun(void *a, void *b) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { fprintf(stderr, "cannot load MediaRemote\n"); exit(2); }
        MRRegister = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRGetPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetPID = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        MRGetClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        MRClientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
        MRClientParentBundle = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
        MRSendCommand = dlsym(h, "MRMediaRemoteSendCommand");
        MRSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
        if (!MRRegister || !MRGetInfo || !MRGetPlaying || !MRGetPID || !MRSendCommand || !MRSetElapsed) {
            fprintf(stderr, "missing MediaRemote symbols\n"); exit(3);
        }

        q = dispatch_get_main_queue();
        MRRegister(q);

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            @"kMRNowPlayingPlaybackQueueChangedNotification",
            @"kMRPlaybackQueueContentItemsChangedNotification",
        ];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
                scheduleRefresh();
            }];
        }

        // Safety net: periodic refresh, since players don't always post notifications
        // (Spotify doesn't for seeks made outside its own player).
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 1.5 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{ refresh(); });
        dispatch_resume(timer);

        // Commands on stdin.
        dispatch_queue_t readQ = dispatch_queue_create("stdin", DISPATCH_QUEUE_SERIAL);
        dispatch_async(readQ, ^{
            char *buf = NULL; size_t cap = 0; ssize_t n;
            while ((n = getline(&buf, &cap, stdin)) > 0) {
                NSString *line = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
                dispatch_async(q, ^{ handleCommand(line); });
            }
            // Parent closed stdin → parent is gone. Exit so we never linger.
            exit(0);
        });

        // Exit if our parent dies (re-parented to launchd).
        pid_t parent = getppid();
        dispatch_source_t ps = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT, q);
        dispatch_source_set_event_handler(ps, ^{ exit(0); });
        dispatch_resume(ps);

        refresh();
    }
    CFRunLoopRun();
}
