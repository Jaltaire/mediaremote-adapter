// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "private/MediaRemote.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

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

void adapter_clients() {
    bool debug = getEnvOption(@"debug") != nil;
    NSArray *clients = copyNowPlayingClients();
    NSMutableArray *entries = [NSMutableArray array];
    for (id client in clients) {
        [entries addObject:clientEntry(client, debug)];
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

void adapter_sendto(NSString *bundleIdentifier, MRACommand command) {
    if (command < kMRAPlay || command > kMRASkipFifteenSeconds) {
        failf(@"Invalid command: %d", (int)command);
    }
    if (!g_mediaRemote.sendCommandToClient) {
        fail(@"MRMediaRemoteSendCommandToClient is unavailable");
    }
    NSArray *clients = copyNowPlayingClients();
    id target = nil;
    for (id client in clients) {
        NSString *clientBundle =
            g_mediaRemote.nowPlayingClientGetBundleIdentifier
                ? g_mediaRemote.nowPlayingClientGetBundleIdentifier(client)
                : nil;
        NSString *parentBundle =
            g_mediaRemote.nowPlayingClientGetParentAppBundleIdentifier
                ? g_mediaRemote.nowPlayingClientGetParentAppBundleIdentifier(
                      client)
                : nil;
        if ([bundleIdentifier isEqualToString:clientBundle] ||
            [bundleIdentifier isEqualToString:parentBundle]) {
            target = client;
            break;
        }
    }
    if (target == nil) {
        failf(@"No now playing client matches bundle identifier: %@",
              bundleIdentifier);
    }
    id origin = localOrigin();
    if (origin == nil) {
        fail(@"The local MediaRemote origin is unavailable");
    }
    bool result = g_mediaRemote.sendCommandToClient(
        (MRCommand)command, nil, origin, target, 0, g_serialdispatchQueue,
        NULL);
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
