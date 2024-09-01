//
//  DLNAHTTPServer.m
//  Connect SDK
//
//  Created by Jeremy White on 9/30/14.
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

#import <ifaddrs.h>
#import <arpa/inet.h>
#import "DLNAHTTPServer.h"
#import "DeviceService.h"
#import "CTXMLReader.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerHTTPStatusCodes.h"
#import "ConnectUtil.h"
#import "M3U8Kit.h"

@interface DLNAHTTPServer ()
@property (nonatomic, strong) M3U8PlaylistModel *model;
@property (nonatomic, strong) NSMutableDictionary *allSubscriptions;
@property (nonatomic, strong) GCDWebServer *server;
@end

@implementation DLNAHTTPServer

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        _allSubscriptions = [NSMutableDictionary new];
    }
    return self;
}

#pragma mark - Server Controls

- (BOOL)isRunning {
    return _server.isRunning;
}



- (void)start {
    [self stop];

    [_allSubscriptions removeAllObjects];

    _server = [[GCDWebServer alloc] init];
    _server.delegate = self;

    [self setupDefaultHandlers];

    [self.server startWithPort:49291 bonjourName:nil];
}

- (void)stop {
    if (!_server) return;

    _server.delegate = nil;
    if (_server.isRunning) {
        [_server stop];
    }
    _server = nil;
}

#pragma mark - Setup Server Handlers

- (void)setupDefaultHandlers {
    __weak typeof(self) weakSelf = self;
    [_server addDefaultHandlerForMethod:@"NOTIFY"
                           requestClass:[GCDWebServerDataRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        [weakSelf processRequest:(GCDWebServerDataRequest *)request];
        return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
    }];

    [_server addDefaultHandlerForMethod:@"HEAD"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf handleHeadRequest:request];
    }];

    [_server addDefaultHandlerForMethod:@"GET"
                           requestClass:[GCDWebServerDataRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [weakSelf handleGetRequest:request];
    }];
}


#pragma mark - Request Handlers

- (GCDWebServerResponse *)handleHeadRequest:(GCDWebServerRequest *)request {
    if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"ts"]) {
        // Case for "ts" files
        GCDWebServerResponse *hResponse = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
        return hResponse;
    } else if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"mp4"]) {
        // Case for "mp4" files
        NSString *remoteUrl = [NSUserDefaults.standardUserDefaults objectForKey:@"stream"];
        NSMutableURLRequest *sizeRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:remoteUrl]];
        [sizeRequest setHTTPMethod:@"HEAD"];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
        __block GCDWebServerResponse *gcdResponse = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        NSURLSessionDataTask *dTask = [urlSession dataTaskWithRequest:sizeRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            gcdResponse.contentLength = response.expectedContentLength;
            gcdResponse.contentType = @"video/mp4";
            dispatch_semaphore_signal(sema);
        }];
        [dTask resume];
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        return gcdResponse;
    } else {
        // Default case for handling other HEAD requests
        GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
        NSString *message = @"\n HEAD Request Received";
        NSData *logData = [message dataUsingEncoding:NSUTF8StringEncoding];
        NSString *logPath = [[NSUserDefaults standardUserDefaults] objectForKey:@"logPath"];
        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:logPath];
        [handle seekToEndOfFile];
        [handle writeData:logData];
        [handle closeFile];
        NSString *resourceId = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"];
        if ([request.path containsString:resourceId]) {
            NSString *resourcePath = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceFilePath"];
            NSData *fileData = [NSData dataWithContentsOfFile:resourcePath];
            response.contentLength = fileData.length;
        }
        return response;
    }
}

- (GCDWebServerResponse *)handleGetRequest:(GCDWebServerRequest *)request {
    self.isHLS = NO;
    if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"ts"]) {
        self.isHLS = YES;
        NSURL *originURL = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] objectForKey:@"stream"]];
        GCDWebServerResponse *response = [self sendRequest:request toRemoteM3U8:originURL.absoluteString];
        return response;
    } else if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"mp4"]) {
        NSString *remoteUrl = [NSUserDefaults.standardUserDefaults objectForKey:@"stream"];
        GCDWebServerResponse *response = [self sendRequest:request toExternalUrl:remoteUrl];
        return response;
    } else {
        NSString *message = @"\n GET Request Received";
        NSData *logData = [message dataUsingEncoding:NSUTF8StringEncoding];
        NSString *logPath = [[NSUserDefaults standardUserDefaults] objectForKey:@"logPath"];
        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:logPath];
        [handle seekToEndOfFile];
        [handle writeData:logData];
        [handle closeFile];
        NSString *resourceId = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"];
        if ([request.path containsString:resourceId]) {
            NSString *resourcePath = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceFilePath"];
            GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:resourcePath byteRange:request.byteRange];
            return response;
        }
        return nil;
    }
}

#pragma mark - Subscription Management

- (NSString *)serviceSubscriptionKeyForURL:(NSURL *)url {
    NSString *resourceSpecifier = url.absoluteURL.resourceSpecifier;
    NSRange relativePathStartRange = [resourceSpecifier rangeOfString:@"/" options:0 range:NSMakeRange(2, resourceSpecifier.length - 2)];
    NSAssert(NSNotFound != relativePathStartRange.location, @"Couldn't find relative path in %@", resourceSpecifier);
    return [resourceSpecifier substringFromIndex:relativePathStartRange.location];
}

- (void)addSubscription:(ServiceSubscription *)subscription {
    @synchronized (_allSubscriptions) {
        NSString *serviceSubscriptionKey = [self serviceSubscriptionKeyForURL:subscription.target];

        if (!_allSubscriptions[serviceSubscriptionKey]) {
            _allSubscriptions[serviceSubscriptionKey] = [NSMutableArray new];
        }

        NSMutableArray *serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
        [serviceSubscriptions addObject:subscription];
        subscription.isSubscribed = YES;
    }
}

- (void)removeSubscription:(ServiceSubscription *)subscription {
    @synchronized (_allSubscriptions) {
        NSString *serviceSubscriptionKey = [self serviceSubscriptionKeyForURL:subscription.target];
        NSMutableArray *serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];

        if (!serviceSubscriptions) return;

        subscription.isSubscribed = NO;
        [serviceSubscriptions removeObject:subscription];

        if (serviceSubscriptions.count == 0) {
            [_allSubscriptions removeObjectForKey:serviceSubscriptionKey];
        }
    }
}

- (BOOL)hasSubscriptions {
    @synchronized (_allSubscriptions) {
        return _allSubscriptions.count > 0;
    }
}

#pragma mark - Request Processing

- (void)processRequest:(GCDWebServerDataRequest *)request {
    if (!request.data || request.data.length == 0) return;

    [self logRequestData:request.data];
    
    NSString *serviceSubscriptionKey = [[self serviceSubscriptionKeyForURL:request.URL] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *serviceSubscriptions;

    @synchronized (_allSubscriptions) {
        serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
    }

    if (!serviceSubscriptions || serviceSubscriptions.count == 0) return;

    NSError *xmlParseError;
    NSDictionary *requestDataXML = [CTXMLReader dictionaryForXMLData:request.data error:&xmlParseError];

    if (xmlParseError) {
        DLog(@"XML Parse error %@", xmlParseError.description);
        return;
    }

    NSString *eventXMLStringEncoded = requestDataXML[@"e:propertyset"][@"e:property"][@"LastChange"][@"text"];

    if (!eventXMLStringEncoded) {
        DLog(@"Received event with no LastChange data, ignoring...");
        return;
    }

    NSError *eventXMLParseError;
    NSDictionary *eventXML = [CTXMLReader dictionaryForXMLString:eventXMLStringEncoded error:&eventXMLParseError];

    if (eventXMLParseError) {
        DLog(@"Could not parse event into usable format, ignoring… (%@)", eventXMLParseError);
        return;
    }

    [self handleEvent:eventXML forSubscriptions:serviceSubscriptions];
}

- (void)handleEvent:(NSDictionary *)eventInfo forSubscriptions:(NSArray *)subscriptions {
    DLog(@"eventInfo: %@", eventInfo);

    [subscriptions enumerateObjectsUsingBlock:^(ServiceSubscription *subscription, NSUInteger subIdx, BOOL *subStop) {
        [subscription.successCalls enumerateObjectsUsingBlock:^(SuccessBlock success, NSUInteger successIdx, BOOL *successStop) {
            dispatch_on_main(^{
                success(eventInfo);
            });
        }];
    }];
}

#pragma mark - Logging

- (void)logRequestData:(NSData *)data {
    NSString *logPath = [[NSUserDefaults standardUserDefaults] objectForKey:@"logPath"];
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:logPath];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

- (GCDWebServerResponse *)logAndReturnResponseForRequest:(GCDWebServerRequest *)request {
    NSString *message = @"\n HEAD Request Received";
    NSData *logData = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSString *logPath = [[NSUserDefaults standardUserDefaults] objectForKey:@"logPath"];
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:logPath];
    [handle seekToEndOfFile];
    [handle writeData:logData];
    [handle closeFile];
    
    NSString *resourceId = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"];
    if ([request.path containsString:resourceId]) {
        message = @"\n HEAD Request Served";
        logData = [message dataUsingEncoding:NSUTF8StringEncoding];
        handle = [NSFileHandle fileHandleForUpdatingAtPath:logPath];
        [handle seekToEndOfFile];
        [handle writeData:logData];
        [handle closeFile];
        
        NSString *resourcePath = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceFilePath"];
        NSData *fileData = [NSData dataWithContentsOfFile:resourcePath];
        GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
        response.contentLength = fileData.length;
        return response;
    }
    return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
}

#pragma mark - Streaming Handlers

- (GCDWebServerResponse *)sendRequest:(GCDWebServerRequest *)request toRemoteM3U8:(NSString *)m3u8Url {
    NSError *error = nil;
    NSURL *url = [NSURL URLWithString:m3u8Url];
    self.model = [[M3U8PlaylistModel alloc] initWithURL:url error:&error];
    if (self.model == nil) {
        return nil;
    }
    
    self.segmentIndex = 0;
    GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse responseWithContentType:@"video/mp4" asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
        if (self.segmentIndex < self.model.mainMediaPl.segmentList.count) {
            NSURLRequest *req = [NSURLRequest requestWithURL:[self.model.mainMediaPl.segmentList segmentInfoAtIndex:self.segmentIndex].mediaURL];
            NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
            NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:config];
            NSURLSessionDataTask *dataTask = [urlSession dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                if (data != nil) {
                    completionBlock(data, nil);
                }
                self.segmentIndex++;
            }];
            [dataTask resume];
        } else {
            completionBlock([NSData data], nil);
        }
    }];
    return response;
}

- (GCDWebServerResponse *)sendRequest:(GCDWebServerRequest *)request toExternalUrl:(NSString *)reverseProxyUrl {
    NSRange range = request.byteRange;
    BOOL hasByteRange = range.location != NSUIntegerMax || range.length > 0;
    if (hasByteRange) {
        if (range.location != NSUIntegerMax) {
            range.location = MIN(range.location, self.fileSize);
            range.length = MIN(range.length, self.fileSize - range.location);
        } else {
            range.length = MIN(range.length, self.fileSize);
            range.location = self.fileSize - range.length;
        }
        if (range.length == 0) {
            return nil;  // TODO: Return 416 status code and "Content-Range: bytes */{file length}" header
        }
    } else {
        range.location = 0;
        range.length = self.fileSize;
    }
    
    self.offset = range.location;
    self.size = range.length;
    
    __block NSInteger offset = 0;
    GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse responseWithContentType:@"video/mp4" asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
        dispatch_queue_t backgroundQueue = dispatch_queue_create("com.romanHouse.backgroundDelay", NULL);
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, 0.02 * NSEC_PER_SEC);
        dispatch_after(delay, backgroundQueue, ^{
            NSString *filePath = [[NSUserDefaults standardUserDefaults] objectForKey:@"mp4Path"];
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
            unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil] fileSize];
            NSUInteger chunkSize = 16 * 1024;
            NSInteger bufferSize = fileSize - offset > chunkSize ? chunkSize : fileSize - offset;
            if (offset < fileSize) {
                [fileHandle seekToFileOffset:offset];
                NSData *chunk = [fileHandle readDataOfLength:bufferSize];
                completionBlock(chunk, nil);
                [fileHandle closeFile];
                offset += chunkSize;
                [[NSUserDefaults standardUserDefaults] setInteger:offset forKey:@"offset"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            } else {
                completionBlock([NSData data], nil);
            }
        });
    }];
    [response setStatusCode:kGCDWebServerHTTPStatusCode_PartialContent];
    [response setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)self.offset, (unsigned long)(self.offset + self.size - 1), (unsigned long)self.fileSize] forAdditionalHeader:@"Content-Range"];
    return response;
}

#pragma mark - Utility

- (NSString *)getHostPath {
    return [NSString stringWithFormat:@"http://%@:%d/", [self getIPAddress], 49291];
}

- (NSString *)getIPAddress {
    NSString *address = @"error";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;

    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
            }
            temp_addr = temp_addr->ifa_next;
        }
    }

    freeifaddrs(interfaces);
    return address;
}

@end
