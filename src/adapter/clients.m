// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "private/MediaRemote.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <unistd.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/now_playing.h"
#import "utility/helpers.h"

#define CLIENTS_TIMEOUT_MILLIS 2000

static NSString *kMRADisplayName = @"displayName";
static NSString *kMRAPlaybackState = @"playbackState";
static NSString *kMRADebugDescription = @"debugDescription";

static NSMutableDictionary *clientEntry(id client, bool debug) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (g_mediaRemote.nowPlayingClientGetBundleIdentifier) {
        NSString *bundleIdentifier =
            g_mediaRemote.nowPlayingClientGetBundleIdentifier(client);
        if (bundleIdentifier != nil) {
            entry[kMRABundleIdentifier] = bundleIdentifier;
        }
    }
    if (g_mediaRemote.nowPlayingClientGetParentAppBundleIdentifier) {
        NSString *parentBundleIdentifier =
            g_mediaRemote.nowPlayingClientGetParentAppBundleIdentifier(client);
        if (parentBundleIdentifier != nil) {
            entry[kMRAParentApplicationBundleIdentifier] =
                parentBundleIdentifier;
        }
    }
    if (g_mediaRemote.nowPlayingClientGetProcessIdentifier) {
        int pid = g_mediaRemote.nowPlayingClientGetProcessIdentifier(client);
        if (pid != 0) {
            entry[kMRAProcessIdentifier] = @(pid);
        }
    }
    if (g_mediaRemote.nowPlayingClientGetDisplayName) {
        NSString *displayName =
            g_mediaRemote.nowPlayingClientGetDisplayName(client);
        if (displayName != nil) {
            entry[kMRADisplayName] = displayName;
        }
    }
    @try {
        if ([client respondsToSelector:@selector(playbackState)]) {
            NSNumber *playbackState = [client valueForKey:@"playbackState"];
            if (playbackState != nil) {
                entry[kMRAPlaybackState] = playbackState;
            }
        }
    } @catch (NSException *exception) {
    }
    if (debug) {
        entry[kMRADebugDescription] = [client description];
    }
    return entry;
}

static NSArray *copyNowPlayingClients() {
    if (!g_mediaRemote.getNowPlayingClients) {
        fail(@"MRMediaRemoteGetNowPlayingClients is unavailable");
        return nil;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray *result = nil;
    g_mediaRemote.getNowPlayingClients(
        g_serialdispatchQueue, ^(NSArray *clients) {
          result = clients;
          dispatch_semaphore_signal(semaphore);
        });
    long waitStatus = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    if (waitStatus != 0) {
        fail(@"The MediaRemote client list request timed out.");
        return nil;
    }
    return result;
}


static id localOrigin();

static id copyFirstPlayerForClient(id origin, id client);

static id playerPathForClient(id origin, id client, id player);

static NSDictionary *copyNowPlayingInfoForClient(id origin, id client) {
    if (!g_mediaRemote.getNowPlayingInfoForClient) {
        return nil;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    g_mediaRemote.getNowPlayingInfoForClient(
        client, origin, NO, g_serialdispatchQueue,
        ^(NSDictionary *information, id error) {
          result = information;
          dispatch_semaphore_signal(semaphore);
        });
    long waitStatus = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return waitStatus == 0 ? result : nil;
}

static NSNumber *copyPlaybackStateForPlayer(id playerPath) {
    if (playerPath == nil || !g_mediaRemote.getPlaybackStateForPlayer) {
        return nil;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSNumber *result = nil;
    g_mediaRemote.getPlaybackStateForPlayer(
        playerPath, g_serialdispatchQueue,
        ^(unsigned int playbackState, NSError *error) {
          (void)error;
          result = @(playbackState);
          dispatch_semaphore_signal(semaphore);
        });
    long waitStatus = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return waitStatus == 0 ? result : nil;
}

void adapter_clients() {
    bool debug = getEnvOption(@"debug") != nil;
    id origin = localOrigin();
    NSArray *clients = copyNowPlayingClients();
    NSMutableArray *entries = [NSMutableArray array];
    for (id client in clients) {
        NSMutableDictionary *entry = clientEntry(client, debug);
        NSDictionary *information = copyNowPlayingInfoForClient(origin, client);
        NSString *title = information[kMRMediaRemoteNowPlayingInfoTitle];
        NSString *artist = information[kMRMediaRemoteNowPlayingInfoArtist];
        NSString *album = information[kMRMediaRemoteNowPlayingInfoAlbum];
        NSNumber *playbackRate =
            information[kMRMediaRemoteNowPlayingInfoPlaybackRate];
        if (title != nil) {
            entry[@"title"] = title;
        }
        if (artist != nil) {
            entry[@"artist"] = artist;
        }
        if (album != nil) {
            entry[@"album"] = album;
        }
        if ([playbackRate isKindOfClass:[NSNumber class]]) {
            entry[kMRAPlaying] =
                [playbackRate doubleValue] != 0.0 ? @YES : @NO;
        }
        // A session is controllable when it exposes a concrete player, which
        // means a fully specified player path can be built to address it
        // directly rather than the command falling through to the elected
        // player.
        id player = copyFirstPlayerForClient(origin, client);
        id playerPath = playerPathForClient(origin, client, player);
        NSNumber *playbackState = copyPlaybackStateForPlayer(playerPath);
        if (playbackState != nil) {
            entry[kMRAPlaybackState] = playbackState;
            if (g_mediaRemote.playbackStateIsAdvancing) {
                entry[kMRAPlaying] = g_mediaRemote.playbackStateIsAdvancing(
                                         [playbackState unsignedIntValue])
                                         ? @YES
                                         : @NO;
            }
        }
        entry[@"controllable"] = player != nil ? @YES : @NO;
        [entries addObject:entry];
    }
    NSString *json =
        serializeJsonDictionarySafe(@{@"clients" : entries}, debug);
    printOut(json);
}

static id localOrigin() {
    Class originClass = NSClassFromString(@"MROrigin");
    if (originClass == nil ||
        ![originClass respondsToSelector:@selector(localOrigin)]) {
        return nil;
    }
    return [originClass performSelector:@selector(localOrigin)];
}

static NSArray *copyActivePlayerPaths(id origin) {
    if (!g_mediaRemote.getActivePlayerPathsForOrigin) {
        return nil;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray *result = nil;
    g_mediaRemote.getActivePlayerPathsForOrigin(
        origin, g_serialdispatchQueue, ^(NSArray *paths) {
          result = paths;
          dispatch_semaphore_signal(semaphore);
        });
    long waitStatus = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return waitStatus == 0 ? result : nil;
}

static bool clientMatchesBundle(id client, NSString *bundleIdentifier) {
    if (client == nil) {
        return false;
    }
    NSString *clientBundle =
        g_mediaRemote.nowPlayingClientGetBundleIdentifier
            ? g_mediaRemote.nowPlayingClientGetBundleIdentifier(client)
            : nil;
    NSString *parentBundle =
        g_mediaRemote.nowPlayingClientGetParentAppBundleIdentifier
            ? g_mediaRemote.nowPlayingClientGetParentAppBundleIdentifier(client)
            : nil;
    return [bundleIdentifier isEqualToString:clientBundle] ||
           [bundleIdentifier isEqualToString:parentBundle];
}

static id copyFirstPlayerForClient(id origin, id client) {
    if (!g_mediaRemote.getPlayersForClient) {
        return nil;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block id firstPlayer = nil;
    g_mediaRemote.getPlayersForClient(
        client, origin, g_serialdispatchQueue, ^(NSArray *players) {
          if (players.count > 0) {
              firstPlayer = players[0];
          }
          dispatch_semaphore_signal(semaphore);
        });
    long waitStatus = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return waitStatus == 0 ? firstPlayer : nil;
}

static id playerPathForClient(id origin, id client, id player) {
    Class playerPathClass = NSClassFromString(@"MRPlayerPath");
    if (playerPathClass == nil) {
        return nil;
    }
    SEL initSel = NSSelectorFromString(@"initWithOrigin:client:player:");
    id path = [playerPathClass alloc];
    if (![path respondsToSelector:initSel]) {
        return nil;
    }
    id (*initImp)(id, SEL, id, id, id) =
        (id (*)(id, SEL, id, id, id))[path methodForSelector:initSel];
    return initImp(path, initSel, origin, client, player);
}

static id activePathForBundle(id origin, NSString *bundleIdentifier) {
    NSArray *paths = copyActivePlayerPaths(origin);
    for (id path in paths) {
        id client = g_mediaRemote.nowPlayingPlayerPathGetClient
                        ? g_mediaRemote.nowPlayingPlayerPathGetClient(path)
                        : nil;
        if (clientMatchesBundle(client, bundleIdentifier)) {
            return path;
        }
    }
    return nil;
}

static int nowPlayingPid() {
    if (!g_mediaRemote.getNowPlayingApplicationPID) {
        return 0;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block int pid = 0;
    g_mediaRemote.getNowPlayingApplicationPID(
        g_serialdispatchQueue, ^(int value) {
          pid = value;
          dispatch_semaphore_signal(semaphore);
        });
    long waitStatus = dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return waitStatus == 0 ? pid : 0;
}

void adapter_sendto(NSString *bundleIdentifier, MRACommand command) {
    if (command < kMRAPlay || command > kMRASkipFifteenSeconds) {
        failf(@"Invalid command: %d", (int)command);
    }
    if (!g_mediaRemote.sendCommandToPlayer) {
        fail(@"MRMediaRemoteSendCommandToPlayer is unavailable.");
    }
    if (!g_mediaRemote.setOverriddenNowPlayingApplication) {
        fail(@"MRMediaRemoteSetOverriddenNowPlayingApplication is unavailable.");
    }
    if (!g_mediaRemote.nowPlayingClientGetBundleIdentifier ||
        !g_mediaRemote.nowPlayingClientGetProcessIdentifier ||
        !g_mediaRemote.getNowPlayingApplicationPID) {
        fail(@"The MediaRemote target identity functions are unavailable.");
    }
    id origin = localOrigin();
    if (origin == nil) {
        fail(@"The local MediaRemote origin is unavailable.");
    }
    id targetClient = nil;
    for (id client in copyNowPlayingClients()) {
        if (clientMatchesBundle(client, bundleIdentifier)) {
            targetClient = client;
            break;
        }
    }
    if (targetClient == nil) {
        failf(@"The application `%@` has no registered media session.",
              bundleIdentifier);
    }
    NSString *targetBundleIdentifier =
        g_mediaRemote.nowPlayingClientGetBundleIdentifier(targetClient);
    int targetPid =
        g_mediaRemote.nowPlayingClientGetProcessIdentifier(targetClient);
    id targetPath = activePathForBundle(origin, bundleIdentifier);
    if (targetPath == nil) {
        id player = copyFirstPlayerForClient(origin, targetClient);
        targetPath = playerPathForClient(origin, targetClient, player);
    }
    if (targetBundleIdentifier.length == 0 || targetPid == 0 ||
        targetPath == nil) {
        failf(@"The application `%@` does not expose a controllable media session.",
              bundleIdentifier);
    }
    g_mediaRemote.setOverriddenNowPlayingApplication(targetBundleIdentifier);
    int electedPid = 0;
    for (int attempt = 0; attempt < 20; attempt++) {
        electedPid = nowPlayingPid();
        if (electedPid == targetPid) {
            break;
        }
        usleep(25 * 1000);
    }
    bool result = false;
    long waitStatus = 0;
    if (electedPid == targetPid) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        result = g_mediaRemote.sendCommandToPlayer(
            (MRCommand)command, nil, targetPath, 0, g_serialdispatchQueue,
            ^(id commandResult) {
              (void)commandResult;
              dispatch_semaphore_signal(semaphore);
            });
        if (result) {
            waitStatus = dispatch_semaphore_wait(
                semaphore,
                dispatch_time(DISPATCH_TIME_NOW,
                              CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
        }
    }
    g_mediaRemote.setOverriddenNowPlayingApplication(nil);
    nowPlayingPid();
    if (electedPid != targetPid) {
        failf(@"The application `%@` could not become the temporary MediaRemote target.",
              bundleIdentifier);
    }
    if (waitStatus != 0) {
        failf(@"Command %d to `%@` timed out.", (int)command,
              bundleIdentifier);
    }
    if (!result) {
        failf(@"Command %d could not be sent to `%@`.", (int)command,
              bundleIdentifier);
    }
}

void adapter_sendto_env() {
    NSString *bundleIdentifier =
        getEnvFuncParamSafe(@"adapter_sendto", 0, @"bundle");
    int command = getEnvFuncParamIntSafe(@"adapter_sendto", 1, @"command");
    adapter_sendto(bundleIdentifier, (MRACommand)command);
}
