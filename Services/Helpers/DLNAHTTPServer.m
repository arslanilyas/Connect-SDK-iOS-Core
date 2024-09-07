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
#import "GCDWebServerErrorResponse.h"

#define kFileReadBufferSize (16 * 1024)

#define originURLKey @"__hls_origin_url"

@interface DLNAHTTPServer()
@property (nonatomic, strong) NSString *tsFilePath;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@end

@implementation DLNAHTTPServer
{
    NSMutableDictionary *_allSubscriptions;
}

- (instancetype) init
{
    if (self = [super init])
    {
        _allSubscriptions = [NSMutableDictionary new];
    }
    
    return self;
}

- (BOOL) isRunning
{
    if (!_server)
        return NO;
    else
        return _server.isRunning;
}

- (void) start
{
    [self stop];
    self.fileNumber = 0;
    [_allSubscriptions removeAllObjects];
    
    _server = [[GCDWebServer alloc] init];
    _server.delegate = self;
    __weak typeof(self) weakSelf = self;
    GCDWebServerResponse *(^webServerResponseBlock)(GCDWebServerRequest *request) = ^GCDWebServerResponse *(GCDWebServerRequest *request) {
        [weakSelf processRequest:(GCDWebServerDataRequest *)request];
        NSLog(@"Request Method: %@", request.method);
        return [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
    };
    
    [self.server addDefaultHandlerForMethod:@"NOTIFY"
                               requestClass:[GCDWebServerDataRequest class]
                               processBlock:webServerResponseBlock];
    
    [self.server addDefaultHandlerForMethod:@"HEAD" requestClass:[GCDWebServerRequest self] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"ts"]) {
            GCDWebServerResponse *hResponse = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
            NSInteger CL = [[NSUserDefaults standardUserDefaults] integerForKey:@"CL"];
            hResponse.contentLength = CL;
            return hResponse;
        } else if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"mp4"]) {
            NSString *remoteUrl = [NSUserDefaults.standardUserDefaults objectForKey:@"stream"];
            NSMutableURLRequest *sizeRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:remoteUrl]];
            [sizeRequest setHTTPMethod:@"HEAD"];
            NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
            NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:config delegate:weakSelf delegateQueue:[NSOperationQueue mainQueue]];
            __block GCDWebServerResponse *gcdResponse = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
            NSLog(@"request headers: %@", request.headers);
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            NSURLSessionDataTask *dTask = [urlSession dataTaskWithRequest:sizeRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                gcdResponse.contentLength = response.expectedContentLength;
                gcdResponse.contentType = @"video/mp4";
                
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                NSDictionary *headers = httpResponse.allHeaderFields;
                
                NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
                [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
                weakSelf.fileSize = response.expectedContentLength;
                weakSelf.contentRange = [headers objectForKey:@"Content-Range"];
                dispatch_semaphore_signal(sema);
            }];
            [dTask resume];
            dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
            return gcdResponse;
        } else {
            NSString *resourceId = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"];
            if ([request.path containsString:resourceId]) {
                NSString *resourcePath = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceFilePath"];
                GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:resourcePath byteRange:request.byteRange];
                return response;
            }
            NSString *artworkId = [NSUserDefaults.standardUserDefaults objectForKey:@"ArtworkId"];
            if ([request.path containsString:artworkId]) {
                NSString *artworkPath = [NSUserDefaults.standardUserDefaults objectForKey:@"ArtworkFilePath"];
                NSLog(@"request path: %@", artworkPath);
                GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:artworkPath byteRange:request.byteRange];
                return response;
            }
        }
        
        return nil;
    }];
    
    [self AddDefaultGetHandler];
    
    [self.server startWithPort:49291 bonjourName:nil];
}

- (NSURL *)originURLFromRequest:(GCDWebServerRequest *)request {
    NSString *encodedURString = request.query[originURLKey];
    NSString *urlString = [encodedURString stringByRemovingPercentEncoding];
    NSURL *url = [NSURL URLWithString:urlString];
    return url;
}

- (void)AddDefaultGetHandler {
    __weak typeof(self) weakSelf = self;
    [self.server addDefaultHandlerForMethod:@"GET" requestClass:[GCDWebServerRequest self] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        weakSelf.isHLS = NO;
        if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"ts"]) {
            weakSelf.isHLS = YES;
            NSURL *originURL = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] objectForKey:@"stream"]];
            GCDWebServerResponse *response = [weakSelf sendRequest:request toExternalM3U8Url:originURL.absoluteString];
            return response;
        } else if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"mp4"]) {
            NSString *remoteUrl = [NSUserDefaults.standardUserDefaults objectForKey:@"stream"];
            GCDWebServerResponse *response = [weakSelf sendRequest:request toExternalUrl:remoteUrl];
            return response;
        } else {
            NSString *resourceId = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"];
            if ([request.path containsString:resourceId]) {
                NSString *resourcePath = [NSUserDefaults.standardUserDefaults objectForKey:@"ResourceFilePath"];
                GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:resourcePath byteRange:request.byteRange];
                return response;
            }
            NSString *artworkId = [NSUserDefaults.standardUserDefaults objectForKey:@"ArtworkId"];
            if ([request.path containsString:artworkId]) {
                NSString *artworkPath = [NSUserDefaults.standardUserDefaults objectForKey:@"ArtworkFilePath"];
                NSLog(@"request path: %@", artworkPath);
                GCDWebServerFileResponse *response = [GCDWebServerFileResponse responseWithFile:artworkPath byteRange:request.byteRange];
                return response;
            }
        }
        
        return nil;
    }];
}

- (void) stop
{
    if (!_server)
        return;
    
    self.server.delegate = nil;
    
    if (_server.isRunning)
        [self.server stop];
    
    _server = nil;
}

/// Returns a service subscription key for the given URL. Different service URLs
/// should produce different keys by extracting the relative path, e.g.:
/// "http://example.com:8888/foo/bar?q=a#abc" => "/foo/bar?q=a#abc"
- (NSString *)serviceSubscriptionKeyForURL:(NSURL *)url {
    NSString *resourceSpecifier = url.absoluteURL.resourceSpecifier;
    NSRange relativePathStartRange = [resourceSpecifier rangeOfString:@"/"
                                                              options:0
                                                                range:NSMakeRange(2, resourceSpecifier.length - 2)];
    NSAssert(NSNotFound != relativePathStartRange.location, @"Couldn't find relative path in %@", resourceSpecifier);
    return [resourceSpecifier substringFromIndex:relativePathStartRange.location];
}

- (void) addSubscription:(ServiceSubscription *)subscription
{
    @synchronized (_allSubscriptions)
    {
        NSString *serviceSubscriptionKey = [self serviceSubscriptionKeyForURL:subscription.target];
        
        if (!_allSubscriptions[serviceSubscriptionKey])
            _allSubscriptions[serviceSubscriptionKey] = [NSMutableArray new];
        
        NSMutableArray *serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
        [serviceSubscriptions addObject:subscription];
        subscription.isSubscribed = YES;
    }
}

- (void) removeSubscription:(ServiceSubscription *)subscription
{
    @synchronized (_allSubscriptions)
    {
        NSString *serviceSubscriptionKey = [self serviceSubscriptionKeyForURL:subscription.target];
        
        NSMutableArray *serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
        
        if (!_allSubscriptions[serviceSubscriptionKey])
            return;
        
        subscription.isSubscribed = NO;
        [serviceSubscriptions removeObject:subscription];
        
        if (serviceSubscriptions.count == 0)
            [_allSubscriptions removeObjectForKey:serviceSubscriptionKey];
    }
}

- (BOOL) hasSubscriptions
{
    @synchronized (_allSubscriptions)
    {
        return _allSubscriptions.count > 0;
    }
}

- (void) processRequest:(GCDWebServerDataRequest *)request
{
    NSLog(@"process request: %@", request);
    if (!request.data || request.data.length == 0)
        return;
    
    NSString *serviceSubscriptionKey = [[self serviceSubscriptionKeyForURL:request.URL]
                                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *serviceSubscriptions;
    
    @synchronized (_allSubscriptions)
    {
        serviceSubscriptions = _allSubscriptions[serviceSubscriptionKey];
    }
    
    if (!serviceSubscriptions || serviceSubscriptions.count == 0)
        return;
    
    NSError *xmlParseError;
    NSDictionary *requestDataXML = [CTXMLReader dictionaryForXMLData:request.data error:&xmlParseError];
    
    if (xmlParseError)
    {
        DLog(@"XML Parse error %@", xmlParseError.description);
        return;
    }
    
    NSString *eventXMLStringEncoded = requestDataXML[@"e:propertyset"][@"e:property"][@"LastChange"][@"text"];
    
    if (!eventXMLStringEncoded)
    {
        DLog(@"Received event with no LastChange data, ignoring...");
        return;
    }
    
    NSError *eventXMLParseError;
    NSDictionary *eventXML = [CTXMLReader dictionaryForXMLString:eventXMLStringEncoded
                                                           error:&eventXMLParseError];
    
    if (eventXMLParseError)
    {
        DLog(@"Could not parse event into usable format, ignoring… (%@)", eventXMLParseError);
        return;
    }
    
    [self handleEvent:eventXML forSubscriptions:serviceSubscriptions];
}

- (void) handleEvent:(NSDictionary *)eventInfo forSubscriptions:(NSArray *)subscriptions
{
    DLog(@"eventInfo: %@", eventInfo);
    
    [subscriptions enumerateObjectsUsingBlock:^(ServiceSubscription *subscription, NSUInteger subIdx, BOOL *subStop) {
        [subscription.successCalls enumerateObjectsUsingBlock:^(SuccessBlock success, NSUInteger successIdx, BOOL *successStop) {
            dispatch_on_main(^{
                success(eventInfo);
            });
        }];
    }];
}

#pragma mark - GCDWebServerDelegate

- (void) webServerDidStart:(GCDWebServer *)server {
    NSLog(@"web serv started");
}
- (void) webServerDidStop:(GCDWebServer *)server { }

#pragma mark - Utility

- (NSString *)getHostPath
{
    return [NSString stringWithFormat:@"http://%@:%d/", [self getIPAddress], 49291];
}

-(NSString *)getIPAddress
{
    NSString *address = @"error";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0)
    {
        temp_addr = interfaces;
        while(temp_addr != NULL)
        {
            if(temp_addr->ifa_addr->sa_family == AF_INET)
            {
                address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    
    freeifaddrs(interfaces);
    return address;
}

static inline BOOL WebServerIsValidByteRange(NSRange range) {
    return ((range.location != NSUIntegerMax) || (range.length > 0));
}

- (GCDWebServerResponse *)sendRequest:(GCDWebServerRequest *)request toExternalM3U8Url:(NSString *)m3u8Url {
    __block NSInteger offset = 0;
    GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse responseWithContentType:@"video/mp4" asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
        dispatch_queue_t myBackgroundQ = dispatch_queue_create("com.romanHouse.backgroundDelay", NULL);
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, 0.02 * NSEC_PER_SEC);
        dispatch_after(delay, myBackgroundQ, ^(void){
            NSString *filePath = [[NSUserDefaults standardUserDefaults] objectForKey:@"tsPath"];
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
            unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil] fileSize];
            NSUInteger chunkSize = 16 * 1024;
            NSInteger bufferSize = fileSize - offset > chunkSize ? chunkSize : fileSize - offset;
            if (offset < fileSize) {
                NSLog(@"offset: %li, bufferSize: %li", (long)offset, (long)bufferSize);
                
                [fileHandle seekToFileOffset:offset];
                NSLog(@"file offset: %li, bufferSize: %li, file size: %li", (long)fileHandle.offsetInFile, (long)bufferSize, (long)fileSize);
                NSData* chunk = [fileHandle readDataOfLength:bufferSize];
                completionBlock(chunk, nil);
                [fileHandle closeFile];
                NSLog(@"data received: %lu", (unsigned long)chunk.length);
                offset = offset + chunkSize;
                [[NSUserDefaults standardUserDefaults] setInteger:offset forKey:@"offset"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            } else {
                NSLog(@"file size reached, file size: %li", (long)fileSize);
                completionBlock([NSData data], nil);
            }
        });
    }];
    [response setStatusCode:kGCDWebServerHTTPStatusCode_PartialContent];
    NSInteger CL = [[NSUserDefaults standardUserDefaults] integerForKey:@"CL"];
    [response setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)0, (unsigned long)CL-1, (unsigned long)CL] forAdditionalHeader:@"Content-Range"];
    return response;
}

- (GCDWebServerResponse *)sendRequest:(GCDWebServerRequest *)request toExternalUrl:(NSString *)reverseProxyUrl {
    NSRange range = request.byteRange;
    BOOL hasByteRange = WebServerIsValidByteRange(range);
    if (hasByteRange) {
        if (range.location != NSUIntegerMax) {
            range.location = MIN(range.location, self.fileSize);
            range.length = MIN(range.length, self.fileSize - range.location);
        } else {
            range.length = MIN(range.length, self.fileSize);
            range.location = self.fileSize - range.length;
        }
        if (range.length == 0) {
            return nil;
        }
    } else {
        range.location = 0;
        range.length = self.fileSize;
    }
    
    self.offset = range.location;
    self.size = range.length;
    
    __block NSInteger offset = 0;
    self.sResponse = [GCDWebServerStreamedResponse responseWithContentType:@"video/mp4" asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
        dispatch_queue_t myBackgroundQ = dispatch_queue_create("com.romanHouse.backgroundDelay", NULL);
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, 0.02 * NSEC_PER_SEC);
        dispatch_after(delay, myBackgroundQ, ^(void){
            NSString *filePath = [[NSUserDefaults standardUserDefaults] objectForKey:@"mp4Path"];
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
            unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil] fileSize];
            NSUInteger chunkSize = 16 * 1024;
            NSInteger bufferSize = fileSize - offset > chunkSize ? chunkSize : fileSize - offset;
            if (offset < fileSize) {
                NSLog(@"offset: %li, bufferSize: %li", (long)offset, (long)bufferSize);
                
                [fileHandle seekToFileOffset:offset];
                NSLog(@"file offset: %li, bufferSize: %li, file size: %li", (long)fileHandle.offsetInFile, (long)bufferSize, (long)fileSize);
                NSData* chunk = [fileHandle readDataOfLength:bufferSize];
                completionBlock(chunk, nil);
                [fileHandle closeFile];
                NSLog(@"data received: %lu", (unsigned long)chunk.length);
                offset = offset + chunkSize;
                [[NSUserDefaults standardUserDefaults] setInteger:offset forKey:@"offset"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            } else {
                NSLog(@"file size reached, file size: %li", (long)fileSize);
                completionBlock([NSData data], nil);
            }
        });
    }];
    [self.sResponse setStatusCode:kGCDWebServerHTTPStatusCode_PartialContent];
    [self.sResponse setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)self.offset, (unsigned long)(self.offset + self.size - 1), (unsigned long)self.fileSize] forAdditionalHeader:@"Content-Range"];
    return self.sResponse;
}

- (void)addPlaylistHandler {
    __weak typeof(self) weakSelf = self;
    [self.server addHandlerForMethod:@"GET" pathRegex:@"^/.*\\.m3u8$" requestClass:[GCDWebServerRequest self] asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        NSURL *originURL = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] objectForKey:@"stream"]];
        if (originURL == nil) {
            return completionBlock([GCDWebServerErrorResponse responseWithStatusCode:400]);
        }
        
        NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithURL:originURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (data == nil || response == nil) {
                return completionBlock([GCDWebServerErrorResponse responseWithStatusCode:500]);
            }
            
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *documentsDirectory = [paths objectAtIndex:0];
            NSString *path = [documentsDirectory stringByAppendingPathComponent:@"test.m3u8"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            }
            
            [data writeToFile:path atomically:YES];
            
            GCDWebServerFileResponse *fileResponse = [GCDWebServerFileResponse responseWithFile:path byteRange:request.byteRange];
            completionBlock(fileResponse);
        }];
        [dataTask resume];
    }];
}

- (void)addSegmentHandler {
    __weak typeof(self) weakSelf = self;
    [self.server addHandlerForMethod:@"GET" pathRegex:@"^/.*\\.ts$" requestClass:[GCDWebServerRequest self] asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        NSString *fullBaseURLString = [[NSUserDefaults standardUserDefaults] objectForKey:@"baseUrl"];
        NSString *originURLString = [NSString stringWithFormat:@"%@%@", fullBaseURLString, request.path];
        NSURL *originURL = [NSURL URLWithString:originURLString];
        if (originURL == nil) {
            return completionBlock([GCDWebServerErrorResponse responseWithStatusCode:400]);
        }
        NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithURL:originURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (data == nil || response == nil) {
                return completionBlock([GCDWebServerErrorResponse responseWithStatusCode:500]);
            }
            NSString *contentType = @"video/mp2t";
            completionBlock([GCDWebServerDataResponse responseWithData:data contentType:contentType]);
        }];
        [dataTask resume];
    }];
}

- (NSURL *)reverseProxyURL:(NSURL *)originURL withLine:(NSString *)line {
    NSURLComponents *components = [NSURLComponents componentsWithURL:originURL resolvingAgainstBaseURL:false];
    components.scheme = @"http";
    components.host = [self getIPAddress];
    components.port = [NSNumber numberWithUnsignedInteger:(NSUInteger)self.server.port];
    
    NSURLQueryItem *originURLQueryItem = [NSURLQueryItem queryItemWithName:originURLKey value:originURL.absoluteString];
    components.queryItems = [components.queryItems == nil ? @[] : components.queryItems arrayByAddingObjectsFromArray:@[originURLQueryItem]];
    return components.URL;
}

- (NSURL *)reverseProxyURL:(NSURL *)originURL {
    NSURLComponents *components = [NSURLComponents componentsWithURL:originURL resolvingAgainstBaseURL:false];
    components.scheme = @"http";
    components.host = [self getIPAddress];
    components.port = [NSNumber numberWithUnsignedInteger:(NSUInteger)self.server.port];
    
    NSURLQueryItem *originURLQueryItem = [NSURLQueryItem queryItemWithName:originURLKey value:originURL.absoluteString];
    components.queryItems = [components.queryItems == nil ? @[] : components.queryItems arrayByAddingObjectsFromArray:@[originURLQueryItem]];
    return components.URL;
}

@end
