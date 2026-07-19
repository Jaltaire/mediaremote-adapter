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
    dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return result;
}


static id localOrigin();

static id copyFirstPlayerForClient(id origin, id client);

void adapter_clients() {
    bool debug = getEnvOption(@"debug") != nil;
    id origin = localOrigin();
    NSArray *clients = copyNowPlayingClients();
    NSMutableArray *entries = [NSMutableArray array];
    for (id client in clients) {
        NSMutableDictionary *entry = clientEntry(client, debug);
        // A session is controllable when it exposes a concrete player, which
        // means a fully specified player path can be built to address it
        // directly rather than the command falling through to the elected
        // player.
        id player = copyFirstPlayerForClient(origin, client);
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
    dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return result;
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
    dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                 CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return firstPlayer;
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
    dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, CLIENTS_TIMEOUT_MILLIS * NSEC_PER_MSEC));
    return pid;
}

void adapter_sendto(NSString *bundleIdentifier, MRACommand command) {
    if (command < kMRAPlay || command > kMRASkipFifteenSeconds) {
        failf(@"Invalid command: %d", (int)command);
    }
    if (!g_mediaRemote.sendCommandToPlayer) {
        fail(@"MRMediaRemoteSendCommandToPlayer is unavailable");
    }
    id origin = localOrigin();
    if (origin == nil) {
        fail(@"The local MediaRemote origin is unavailable");
    }

    // Commands must be sent to an active player path, otherwise MediaRemote
    // redirects them to the elected now playing player and controls the wrong
    // application. When the target already exposes an active path, send there.
    id targetPath = activePathForBundle(origin, bundleIdentifier);

    // Otherwise elect the target's player, confirm it actually became the now
    // playing application, and send to that player path. Some applications
    // decline election; sending anyway would control whichever player is
    // currently elected, so give up safely instead of controlling the wrong
    // application.
    if (targetPath == nil && g_mediaRemote.setNowPlayingPlayerIfPossible) {
        id electionPath = nil;
        int targetPid = 0;
        NSArray *clients = copyNowPlayingClients();
        for (id client in clients) {
            if (clientMatchesBundle(client, bundleIdentifier)) {
                id player = copyFirstPlayerForClient(origin, client);
                if (player != nil) {
                    electionPath = playerPathForClient(origin, client, player);
                    if (g_mediaRemote.nowPlayingClientGetProcessIdentifier) {
                        targetPid =
                            g_mediaRemote.nowPlayingClientGetProcessIdentifier(
                                client);
                    }
                }
                break;
            }
        }
        if (electionPath != nil) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            g_mediaRemote.setNowPlayingPlayerIfPossible(
                electionPath, g_serialdispatchQueue, ^(id error) {
                  dispatch_semaphore_signal(semaphore);
                });
            dispatch_semaphore_wait(
                semaphore,
                dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC));
            // Only send once the target application has genuinely become the
            // now playing application. Applications that decline election never
            // do, so the command is abandoned instead of controlling whichever
            // player is currently elected.
            for (int attempt = 0; attempt < 8 && targetPid != 0; attempt++) {
                if (nowPlayingPid() == targetPid) {
                    targetPath = electionPath;
                    break;
                }
                usleep(150 * 1000);
            }
        }
    }
    if (targetPath == nil) {
        failf(@"The application `%@` did not accept remote control.",
              bundleIdentifier);
    }
    bool result = g_mediaRemote.sendCommandToPlayer(
        (MRCommand)command, nil, targetPath, 0, g_serialdispatchQueue, NULL);
    if (!result) {
        failf(@"Failed to send command %d to %@", (int)command,
              bundleIdentifier);
    }
    waitForCommandCompletion();
}

void adapter_sendto_env() {
    NSString *bundleIdentifier =
        getEnvFuncParamSafe(@"adapter_sendto", 0, @"bundle");
    int command = getEnvFuncParamIntSafe(@"adapter_sendto", 1, @"command");
    adapter_sendto(bundleIdentifier, (MRACommand)command);
}
