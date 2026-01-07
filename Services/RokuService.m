//
//  RokuService.m
//  ConnectSDK
//
//  Created by Jeremy White on 2/14/14.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RokuService_Private.h"
#import "ConnectError.h"
#import "CTXMLReader.h"
#import "ConnectUtil.h"
#import "DeviceServiceReachability.h"
#import "DiscoveryManager.h"
#import "DLNAHTTPServer.h"
#import "NSObject+FeatureNotSupported_Private.h"

@interface RokuService () <ServiceCommandDelegate, DeviceServiceReachabilityDelegate>
{
    DIALService *_dialService;
    DeviceServiceReachability *_serviceReachability;
    DLNAHTTPServer *_httpServer; // Use DLNAHTTPServer or a similar server
    NSMutableDictionary *_httpServerSessionIds; // Manage subscriptions
}
@end

static NSMutableArray *registeredApps = nil;
static NSString * const kCastStreamReceiverDevAppId = @"837661";

@implementation RokuService

+ (void) initialize
{
    registeredApps = [NSMutableArray arrayWithArray:@[
        @"YouTube",
        @"Netflix",
        @"Amazon"
    ]];
}

+ (NSDictionary *)discoveryParameters
{
    return @{
        @"serviceId" : kConnectSDKRokuServiceId,
        @"ssdp" : @{
            @"filter" : @"roku:ecp"
        }
    };
}

- (void) updateCapabilities
{
    NSArray *capabilities = @[
        kLauncherAppList,
        kLauncherApp,
        kLauncherAppParams,
        kLauncherAppStore,
        kLauncherAppStoreParams,
        kLauncherAppClose,
        
        kMediaPlayerDisplayImage,
        kMediaPlayerPlayVideo,
        kMediaPlayerPlayAudio,
        kMediaPlayerClose,
        kMediaPlayerMetaDataTitle,
        
        kMediaControlPlay,
        kMediaControlPause,
        kMediaControlRewind,
        kMediaControlFastForward,
        
        kTextInputControlSendText,
        kTextInputControlSendEnter,
        kTextInputControlSendDelete
    ];
    
    capabilities = [capabilities arrayByAddingObjectsFromArray:kKeyControlCapabilities];
    
    [self setCapabilities:capabilities];
}

+ (void) registerApp:(NSString *)appId
{
    if (![registeredApps containsObject:appId])
        [registeredApps addObject:appId];
}

- (void) probeForApps
{
    [registeredApps enumerateObjectsUsingBlock:^(NSString *appName, NSUInteger idx, BOOL *stop)
     {
        [self hasApp:appName success:^(AppInfo *appInfo)
         {
            NSString *capability = [NSString stringWithFormat:@"Launcher.%@", appName];
            NSString *capabilityParams = [NSString stringWithFormat:@"Launcher.%@.Params", appName];
            
            [self addCapabilities:@[capability, capabilityParams]];
        } failure:nil];
    }];
}

- (BOOL) isConnectable
{
    return YES;
}

- (void) connect
{
    NSString *targetPath = [NSString stringWithFormat:@"http://%@:%@/", self.serviceDescription.address, @(self.serviceDescription.port)];
    NSURL *targetURL = [NSURL URLWithString:targetPath];
    
    _serviceReachability = [DeviceServiceReachability reachabilityWithTargetURL:targetURL];
    _serviceReachability.delegate = self;
    [_serviceReachability start];
    
    self.connected = YES;
    
    if (!_httpServer) {
        _httpServer = [self createHTTPServer]; // Create and configure the HTTP server
    }

    [_httpServer start]; // Start the HTTP server
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceServiceConnectionSuccess:)])
        dispatch_on_main(^{ [self.delegate deviceServiceConnectionSuccess:self]; });
}

- (DLNAHTTPServer *)createHTTPServer {
    DLNAHTTPServer *server = [DLNAHTTPServer new];
    // Configure server if needed
    return server;
}

- (void) disconnect
{
    self.connected = NO;
    
    [_serviceReachability stop];
    
    if (_httpServer) {
        [_httpServer stop]; // Stop the HTTP server
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)])
        dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:nil]; });
}

- (void) didLoseReachability:(DeviceServiceReachability *)reachability
{
    if (self.connected)
        [self disconnect];
    else
        [_serviceReachability stop];
}

- (void)setServiceDescription:(ServiceDescription *)serviceDescription
{
    [super setServiceDescription:serviceDescription];
    
    self.serviceDescription.port = 8060;
    NSString *commandPath = [NSString stringWithFormat:@"http://%@:%@", self.serviceDescription.address, @(self.serviceDescription.port)];
    self.serviceDescription.commandURL = [NSURL URLWithString:commandPath];
    
    [self probeForApps];
}

- (DIALService *) dialService
{
    if (!_dialService)
    {
        ConnectableDevice *device = [[DiscoveryManager sharedManager].allDevices objectForKey:self.serviceDescription.address];
        __block DIALService *foundService;
        
        [device.services enumerateObjectsUsingBlock:^(DeviceService *service, NSUInteger idx, BOOL *stop)
         {
            if ([service isKindOfClass:[DIALService class]])
            {
                foundService = (DIALService *) service;
                *stop = YES;
            }
        }];
        
        if (foundService)
            _dialService = foundService;
    }
    
    return _dialService;
}

#pragma mark - Getters & Setters

/// Returns the set delegate property value or self.
- (id<ServiceCommandDelegate>)serviceCommandDelegate {
    return _serviceCommandDelegate ?: self;
}

#pragma mark - ServiceCommandDelegate

- (int) sendCommand:(ServiceCommand *)command withPayload:(NSDictionary *)payload toURL:(NSURL *)URL
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [request setTimeoutInterval:6];
    [request addValue:@"text/plain;charset=\"utf-8\"" forHTTPHeaderField:@"Content-Type"];
    
    if (payload || [command.HTTPMethod isEqualToString:@"POST"])
    {
        [request setHTTPMethod:@"POST"];    
        
        if (payload)
        {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
            [request addValue:[NSString stringWithFormat:@"%i", (unsigned int) [jsonData length]] forHTTPHeaderField:@"Content-Length"];
            [request setHTTPBody:jsonData];
        }
    } else
    {
        [request setHTTPMethod:@"GET"];
        [request addValue:@"0" forHTTPHeaderField:@"Content-Length"];
    }
    
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError)
     {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        
        if (connectionError)
        {
            if (command.callbackError)
                dispatch_on_main(^{ command.callbackError(connectionError); });
        } else
        {
            if ([httpResponse statusCode] < 200 || [httpResponse statusCode] >= 300)
            {
                NSError *error = [ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil];
                
                if (command.callbackError)
                    command.callbackError(error);
                
                return;
            }
            
            NSString *dataString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            if (command.callbackComplete)
                dispatch_on_main(^{ command.callbackComplete(dataString); });
        }
    }];
    
    // TODO: need to implement callIds in here
    return 0;
}

#pragma mark - Launcher

- (id <Launcher>)launcher
{
    return self;
}

- (CapabilityPriorityLevel)launcherPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)launchApp:(NSString *)appId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (!appId)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide an appId."]);
        return;
    }
    
    AppInfo *appInfo = [AppInfo appInfoForId:appId];
    
    [self launchAppWithInfo:appInfo params:nil success:success failure:failure];
}

- (void)launchAppWithInfo:(AppInfo *)appInfo success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchAppWithInfo:appInfo params:nil success:success failure:failure];
}

- (void)launchAppWithInfo:(AppInfo *)appInfo params:(NSDictionary *)params success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (!appInfo || !appInfo.id)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid AppInfo object."]);
        return;
    }
    
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"launch"];
    targetURL = [targetURL URLByAppendingPathComponent:appInfo.id];
    
    if (params)
    {
        __block NSString *queryParams = @"";
        __block int count = 0;
        
        [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            NSString *prefix = (count == 0) ? @"?" : @"&";
            
            NSString *urlSafeKey = [ConnectUtil urlEncode:key];
            NSString *urlSafeValue = [ConnectUtil urlEncode:value];
            
            NSString *appendString = [NSString stringWithFormat:@"%@%@=%@", prefix, urlSafeKey, urlSafeValue];
            queryParams = [queryParams stringByAppendingString:appendString];
            
            count++;
        }];
        
        NSString *targetPath = [NSString stringWithFormat:@"%@%@", targetURL.absoluteString, queryParams];
        targetURL = [NSURL URLWithString:targetPath];
    }
    
    ServiceCommand *command = [ServiceCommand commandWithDelegate:self target:targetURL payload:nil];
    command.callbackComplete = ^(id responseObject)
    {
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:appInfo.id];
        launchSession.name = appInfo.name;
        launchSession.sessionType = LaunchSessionTypeApp;
        launchSession.service = self;
        
        if (success)
            success(launchSession);
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchYouTube:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchYouTube:contentId startTime:0.0 success:success failure:failure];
}

- (void) launchYouTube:(NSString *)contentId startTime:(float)startTime success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (self.dialService)
        [self.dialService.launcher launchYouTube:contentId startTime:startTime success:success failure:failure];
    else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:@"Cannot reach DIAL service for launching with provided start time"]);
    }
}

- (void) launchAppStore:(NSString *)appId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    AppInfo *appInfo = [AppInfo appInfoForId:@"11"];
    appInfo.name = @"Channel Store";
    
    NSDictionary *params;
    
    if (appId && appId.length > 0)
        params = @{ @"contentId" : appId };
    
    [self launchAppWithInfo:appInfo params:params success:success failure:failure];
}

- (void)launchBrowser:(NSURL *)target success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)launchHulu:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)launchNetflix:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self getAppListWithSuccess:^(NSArray *appList)
     {
        __block AppInfo *foundAppInfo;
        
        [appList enumerateObjectsUsingBlock:^(AppInfo *appInfo, NSUInteger idx, BOOL *stop)
         {
            if ([appInfo.name isEqualToString:@"Netflix"])
            {
                foundAppInfo = appInfo;
                *stop = YES;
            }
        }];
        
        if (foundAppInfo)
        {
            NSMutableDictionary *params = [NSMutableDictionary new];
            params[@"mediaType"] = @"movie";
            if (contentId && contentId.length > 0) params[@"contentId"] = contentId;
            
            [self launchAppWithInfo:foundAppInfo params:params success:success failure:failure];
        } else
        {
            if (failure)
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Netflix app could not be found on TV"]);
        }
    } failure:failure];
}

- (void)closeApp:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.keyControl homeWithSuccess:success failure:failure];
}

- (void)getAppListWithSuccess:(AppListSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"query"];
    targetURL = [targetURL URLByAppendingPathComponent:@"apps"];
    
    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"GET";
    command.callbackComplete = ^(NSString *responseObject)
    {
        NSError *xmlError;
        NSDictionary *appListDictionary = [CTXMLReader dictionaryForXMLString:responseObject error:&xmlError];
        
        if (appListDictionary) {
            NSArray *apps;
            id appsObject = [appListDictionary valueForKeyPath:@"apps.app"];
            if ([appsObject isKindOfClass:[NSDictionary class]]) {
                apps = @[appsObject];
            } else if ([appsObject isKindOfClass:[NSArray class]]) {
                apps = appsObject;
            }
            
            NSMutableArray *appList = [NSMutableArray new];
            
            [apps enumerateObjectsUsingBlock:^(NSDictionary *appInfoDictionary, NSUInteger idx, BOOL *stop)
             {
                AppInfo *appInfo = [self appInfoFromDictionary:appInfoDictionary];
                [appList addObject:appInfo];
            }];
            
            if (success)
                success([NSArray arrayWithArray:appList]);
        } else {
            if (failure) {
                NSString *details = [NSString stringWithFormat:
                                     @"Couldn't parse apps XML (%@)", xmlError.localizedDescription];
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:details]);
            }
        }
    };
    command.callbackError = failure;
    [command send];
}

- (void)getAppState:(LaunchSession *)launchSession success:(AppStateSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeAppState:(LaunchSession *)launchSession success:(AppStateSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)getRunningAppWithSuccess:(AppInfoSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeRunningAppWithSuccess:(AppInfoSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

#pragma mark - MediaPlayer

- (id <MediaPlayer>)mediaPlayer
{
    return self;
}

- (CapabilityPriorityLevel)mediaPlayerPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)displayImage:(NSURL *)imageURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    MediaInfo *mediaInfo = [[MediaInfo alloc] initWithURL:imageURL mimeType:mimeType];
    mediaInfo.title = title;
    mediaInfo.description = description;
    ImageInfo *imageInfo = [[ImageInfo alloc] initWithURL:iconURL type:ImageTypeThumb];
    [mediaInfo addImage:imageInfo];
    
    [self displayImageWithMediaInfo:mediaInfo success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) displayImage:(MediaInfo *)mediaInfo
              success:(MediaPlayerDisplaySuccessBlock)success
              failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    [self displayImage:mediaInfo.url iconURL:iconURL title:mediaInfo.title description:mediaInfo.description mimeType:mediaInfo.mimeType success:success failure:failure];
}

- (void) displayImageWithMediaInfo:(MediaInfo *)mediaInfo
                           success:(MediaPlayerSuccessBlock)success
                           failure:(FailureBlock)failure
{
    NSURL *imageURL = mediaInfo.url;
    if (!imageURL)
    {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError
                                             andDetails:@"You need to provide an image URL"]);
        }
        return;
    }

    // Encode URL for use as contentId
    NSString *encodedContentId = [ConnectUtil urlEncode:imageURL.absoluteString];

    // We still declare mediaType=image so your BrightScript can read it if needed
    NSString *query = [NSString stringWithFormat:@"?contentId=%@&mediaType=image", encodedContentId];

    // ✅ New: route through helper that chooses /launch or /input
    [self sendCastStreamRequestWithQuery:query
                                 success:success
                                 failure:failure];
}

- (void) playMedia:(NSURL *)mediaURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    MediaInfo *mediaInfo = [[MediaInfo alloc] initWithURL:mediaURL mimeType:mimeType];
    mediaInfo.title = title;
    mediaInfo.description = description;
    ImageInfo *imageInfo = [[ImageInfo alloc] initWithURL:iconURL type:ImageTypeThumb];
    [mediaInfo addImage:imageInfo];
    
    [self playMediaWithMediaInfo:mediaInfo shouldLoop:shouldLoop success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) playMedia:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    [self playMedia:mediaInfo.url iconURL:iconURL title:mediaInfo.title description:mediaInfo.description mimeType:mediaInfo.mimeType shouldLoop:shouldLoop success:success failure:failure];
}

#pragma mark - CastStream Receiver routing

// Internal helper: actually send to /<pathComponent>/dev?...
- (void)sendCastStreamToPath:(NSString *)pathComponent
                       query:(NSString *)query
                     success:(MediaPlayerSuccessBlock)success
                     failure:(FailureBlock)failure
{
    NSURL *baseURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:pathComponent];
    baseURL = [baseURL URLByAppendingPathComponent:kCastStreamReceiverDevAppId];

    NSString *fullURLString = [baseURL.absoluteString stringByAppendingString:(query ?: @"")];
    NSURL *targetURL = [NSURL URLWithString:fullURLString];

    NSLog(@"[CastStream][Roku] sending to path '%@': %@", pathComponent, fullURLString);

    ServiceCommand *command =
        [ServiceCommand commandWithDelegate:self.serviceCommandDelegate
                                     target:targetURL
                                    payload:nil];
    command.HTTPMethod = @"POST";   // same as: curl -d '' ...

    command.callbackComplete = ^(id responseObject)
    {
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:kCastStreamReceiverDevAppId];
        launchSession.name = @"CastStream Receiver";
        launchSession.sessionType = LaunchSessionTypeMedia;
        launchSession.service = self;

        MediaLaunchObject *launchObject =
            [[MediaLaunchObject alloc] initWithLaunchSession:launchSession
                                              andMediaControl:self.mediaControl];

        if (success) {
            success(launchObject);
        }
    };

    command.callbackError = failure;
    [command send];
}

// ✅ Simplified: always use /input/dev, no /query/active-app
- (void)sendCastStreamRequestWithQuery:(NSString *)query
                               success:(MediaPlayerSuccessBlock)success
                               failure:(FailureBlock)failure
{
    NSString *pathComponent = @"input";

    NSLog(@"[CastStream][Roku] forcing path '%@' with query: %@",
          pathComponent, query);

    [self sendCastStreamToPath:pathComponent
                         query:query
                       success:success
                       failure:failure];
}




- (void) playMediaWithMediaInfo:(MediaInfo *)mediaInfo
                     shouldLoop:(BOOL)shouldLoop
                        success:(MediaPlayerSuccessBlock)success
                        failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if (mediaInfo.images) {
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }

    NSURL *mediaURL = mediaInfo.url;
    NSString *mimeType = mediaInfo.mimeType ?: @"";
    NSString *title     = mediaInfo.title ?: @"";
    NSString *desc      = mediaInfo.description ?: @"";

    if (!mediaURL)
    {
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError
                                             andDetails:@"You need to provide a media URL"]);
        }
        return;
    }

    // Decide mediaType=image|video|audio based on mimeType (fallback to video)
    NSString *lowerMime = mimeType.lowercaseString;
    NSString *mediaTypeParam = @"video";
    if ([lowerMime hasPrefix:@"image/"]) {
        mediaTypeParam = @"image";
    } else if ([lowerMime hasPrefix:@"audio/"]) {
        mediaTypeParam = @"audio";
    } else if ([lowerMime hasPrefix:@"video/"]) {
        mediaTypeParam = @"video";
    }

    // This is the URL the Roku receiver will play (HLS, MP4, MP3, etc.)
    NSString *encodedContentId = [ConnectUtil urlEncode:mediaURL.absoluteString];

    // Optional: pass title / description / icon to Roku (even if receiver ignores for now)
    NSString *encodedTitle       = [ConnectUtil urlEncode:title];
    NSString *encodedDescription = [ConnectUtil urlEncode:desc];
    NSString *encodedIcon        = iconURL ? [ConnectUtil urlEncode:iconURL.absoluteString] : @"";

    // Build query string (receiver currently only uses contentId/mediaType)
    NSMutableArray<NSString *> *queryParts = [NSMutableArray new];
    [queryParts addObject:[NSString stringWithFormat:@"contentId=%@", encodedContentId]];
    [queryParts addObject:[NSString stringWithFormat:@"mediaType=%@", mediaTypeParam]];

    if (encodedTitle.length > 0) {
        [queryParts addObject:[NSString stringWithFormat:@"title=%@", encodedTitle]];
    }
    if (encodedDescription.length > 0) {
        [queryParts addObject:[NSString stringWithFormat:@"description=%@", encodedDescription]];
    }
    if (encodedIcon.length > 0) {
        [queryParts addObject:[NSString stringWithFormat:@"icon=%@", encodedIcon]];
    }

    NSString *query = [NSString stringWithFormat:@"?%@", [queryParts componentsJoinedByString:@"&"]];

    // ✅ New: route through helper that picks /launch vs /input
    [self sendCastStreamRequestWithQuery:query
                                 success:success
                                 failure:failure];
}


- (void)closeMedia:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.keyControl homeWithSuccess:success failure:failure];
}

#pragma mark - MediaControl

- (id <MediaControl>)mediaControl
{
    return self;
}

- (CapabilityPriorityLevel)mediaControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)playWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure {
    [self getPositionWithSuccess:^(NSTimeInterval position) {
        NSUInteger positionMillis = (NSUInteger)(position * 1000);

        NSString *query = [NSString stringWithFormat:@"?action=play&position=%lu", (unsigned long)positionMillis];

        [self sendCastStreamRequestWithQuery:query
                                     success:^(MediaLaunchObject *launchObject) {
                                         if (success) success(nil);
                                     }
                                     failure:failure];
    } failure:^(NSError *error) {
        // fallback to no position
        [self sendCastStreamPlaybackCommand:@"play" success:success failure:failure];
    }];
}


- (void)pauseWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendCastStreamPlaybackCommand:@"pause" success:success failure:failure];
}

- (void)sendCastStreamPlaybackCommand:(NSString *)action
                              success:(SuccessBlock)success
                              failure:(FailureBlock)failure
{
    NSString *query = [NSString stringWithFormat:@"?action=%@", [ConnectUtil urlEncode:action]];
    [self sendCastStreamRequestWithQuery:query
                                 success:^(MediaLaunchObject *launchObject) {
                                     if (success) success(nil);  // ✅ Fix: pass dummy value
                                 }
                                 failure:failure];

}

- (void)stopWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendCastStreamPlaybackCommand:@"stop" success:success failure:failure];
}

- (void)rewindWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeRewind success:success failure:failure];
}

- (void)fastForwardWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeFastForward success:success failure:failure];
}


- (void)getPlayStateWithSuccess:(MediaPlayStateSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"query/media-player"];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"GET";

    command.callbackComplete = ^(NSString *responseObject)
    {
        NSLog(@"Roku media-player response: %@", responseObject);

        if (!responseObject || responseObject.length == 0) {
            if (failure) {
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:@"Empty response from Roku media-player"]);
            }
            return;
        }

        NSError *xmlError;
        NSDictionary *mediaPlayerData = [CTXMLReader dictionaryForXMLString:responseObject error:&xmlError];

        if (!mediaPlayerData || xmlError) {
            NSLog(@"XML Parsing Error: %@", xmlError.localizedDescription);
            if (failure) {
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:@"Failed to parse Roku media-player response"]);
            }
            return;
        }

        // Extract play state value using the correct key path
        NSString *stateString = [mediaPlayerData valueForKeyPath:@"player.state"];
        if (!stateString) {
            if (failure) {
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:@"Play state value not found in Roku response"]);
            }
            return;
        }

        // Convert Roku's state to ConnectSDK Media Control States
        MediaControlPlayState playState;

        if ([stateString isEqualToString:@"play"]) {
            playState = MediaControlPlayStatePlaying;
        } else if ([stateString isEqualToString:@"pause"]) {
            playState = MediaControlPlayStatePaused;
        } else if ([stateString isEqualToString:@"buffering"]) {
            playState = MediaControlPlayStateBuffering;
        } else if ([stateString isEqualToString:@"stopped"]) {
            playState = MediaControlPlayStateFinished;
        } else {
            playState = MediaControlPlayStateUnknown;
        }

        if (success) {
            success(playState);
        }
    };

    command.callbackError = ^(NSError *error) {
        NSLog(@"Roku API Error: %@", error.localizedDescription);
        if (failure) {
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeError
                                             andDetails:[NSString stringWithFormat:@"API error: %@", error.localizedDescription]]);
        }
    };

    [command send];
}


- (ServiceSubscription *)subscribePlayStateWithSuccess:(MediaPlayStateSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)getDurationWithSuccess:(MediaPositionSuccessBlock)success
                       failure:(FailureBlock)failure {
    [self sendNotSupportedFailure:failure];
}

- (void)getPositionWithSuccess:(MediaPositionSuccessBlock)success failure:(FailureBlock)failure
{
    // Construct URL to query Roku's media player status
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"query/media-player"];

    // Create a service command to fetch media status
    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"GET";
    
    command.callbackComplete = ^(NSString *responseObject)
    {
        NSError *xmlError;
        NSDictionary *mediaPlayerData = [CTXMLReader dictionaryForXMLString:responseObject error:&xmlError];

        if (mediaPlayerData) {
            // Extract the position value from XML response
            NSString *positionString = [mediaPlayerData valueForKeyPath:@"player.position.text"];
            NSTimeInterval position = [positionString doubleValue] / 1000.0; // Convert from milliseconds to seconds
            
            if (success) {
                success(position);
            }
        } else {
            if (failure) {
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:@"Failed to parse Roku media-player response"]);
            }
        }
    };
    
    command.callbackError = failure;
    [command send];
}


- (void)getMediaMetaDataWithSuccess:(SuccessBlock)success
                            failure:(FailureBlock)failure {
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeMediaInfoWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)seek:(NSTimeInterval)position success:(SuccessBlock)success failure:(FailureBlock)failure {
    NSUInteger positionSeconds = (NSUInteger)(position); // use seconds
    
    NSLog(@"====== position: %f =========", position);
    
    NSString *query = [NSString stringWithFormat:@"?action=seek&position=%lu", (unsigned long)positionSeconds];

    
    NSLog(@"====== query: %@ =========", query);

    [self sendCastStreamRequestWithQuery:query
                                 success:^(MediaLaunchObject *launchObject) {
                                     if (success) success(nil);
                                 }
                                 failure:failure];
}



#pragma mark - Key Control

- (id <KeyControl>) keyControl
{
    return self;
}

- (CapabilityPriorityLevel) keyControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)upWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeUp success:success failure:failure];
}

- (void)downWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeDown success:success failure:failure];
}

- (void)leftWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeLeft success:success failure:failure];
}

- (void)rightWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeRight success:success failure:failure];
}

- (void)homeWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeHome success:success failure:failure];
}

- (void)backWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeBack success:success failure:failure];
}

- (void)okWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeSelect success:success failure:failure];
}

- (void)sendKeyCode:(RokuKeyCode)keyCode success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (keyCode > kRokuKeyCodes.count)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:nil]);
        return;
    }
    
    NSString *keyCodeString = kRokuKeyCodes[keyCode];
    
    [self sendKeyPress:keyCodeString success:success failure:failure];
}

#pragma mark - Text Input Control

- (id <TextInputControl>) textInputControl
{
    return self;
}

- (CapabilityPriorityLevel) textInputControlPriority
{
    return CapabilityPriorityLevelNormal;
}

- (void) sendText:(NSString *)input success:(SuccessBlock)success failure:(FailureBlock)failure
{
    // TODO: optimize this with queueing similiar to webOS and Netcast services
    NSMutableArray *stringToSend = [NSMutableArray new];
    
    [input enumerateSubstringsInRange:NSMakeRange(0, input.length) options:(NSStringEnumerationByComposedCharacterSequences) usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop)
     {
        [stringToSend addObject:substring];
    }];
    
    [stringToSend enumerateObjectsUsingBlock:^(NSString *charToSend, NSUInteger idx, BOOL *stop)
     {
        
        NSString *codeToSend = [NSString stringWithFormat:@"%@%@", kRokuKeyCodes[RokuKeyCodeLiteral], [ConnectUtil urlEncode:charToSend]];
        
        [self sendKeyPress:codeToSend success:success failure:failure];
    }];
}

- (void)sendEnterWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeEnter success:success failure:failure];
}

- (void)sendDeleteWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeBackspace success:success failure:failure];
}

- (ServiceSubscription *) subscribeTextInputStatusWithSuccess:(TextInputStatusInfoSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

#pragma mark - Helper methods

- (void) sendKeyPress:(NSString *)keyCode success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"keypress"];
    targetURL = [NSURL URLWithString:[targetURL.absoluteString stringByAppendingPathComponent:keyCode]];
    
    ServiceCommand *command = [ServiceCommand commandWithDelegate:self target:targetURL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (AppInfo *)appInfoFromDictionary:(NSDictionary *)appDictionary
{
    NSString *id = [appDictionary objectForKey:@"id"];
    NSString *name = [appDictionary objectForKey:@"text"];
    
    AppInfo *appInfo = [AppInfo appInfoForId:id];
    appInfo.name = name;
    appInfo.rawData = [appDictionary copy];
    
    return appInfo;
}

- (void) hasApp:(NSString *)appName success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.launcher getAppListWithSuccess:^(NSArray *appList)
     {
        if (appList)
        {
            __block AppInfo *foundAppInfo;
            
            [appList enumerateObjectsUsingBlock:^(AppInfo *appInfo, NSUInteger idx, BOOL *stop)
             {
                if ([appInfo.name isEqualToString:appName])
                {
                    foundAppInfo = appInfo;
                    *stop = YES;
                }
            }];
            
            if (foundAppInfo)
            {
                if (success)
                    success(foundAppInfo);
            } else
            {
                if (failure)
                    failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Could not find this app on the TV"]);
            }
        } else
        {
            if (failure)
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Could not find any apps on the TV."]);
        }
    } failure:failure];
}

- (void)volumeUpWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyPress:@"VolumeUp" success:success failure:failure];
}

- (void)volumeDownWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyPress:@"VolumeDown" success:success failure:failure];
}

- (void)getMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure { 
    [self sendNotSupportedFailure:failure];
}


- (void)getVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure { 
    [self sendNotSupportedFailure:failure];
}


- (void)setMute:(BOOL)mute success:(SuccessBlock)success failure:(FailureBlock)failure { 
    [self sendNotSupportedFailure:failure];
}


- (void)setVolume:(float)volume success:(SuccessBlock)success failure:(FailureBlock)failure { 
    [self sendNotSupportedFailure:failure];
}


- (ServiceSubscription *)subscribeMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure { 
    return nil;
}


- (ServiceSubscription *)subscribeVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure { 
    return nil;
}


- (id<VolumeControl>)volumeControl { 
    return self;
}


- (CapabilityPriorityLevel)volumeControlPriority { 
    return CapabilityPriorityLevelNormal;
}


- (void)toggleMuteWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyPress:@"VolumeMute" success:success failure:failure];
}


- (id)initWithJSONObject:(NSDictionary *)dict { 
    return nil;
}

- (NSDictionary *)toJSONObject { 
    return nil;
}

@end
