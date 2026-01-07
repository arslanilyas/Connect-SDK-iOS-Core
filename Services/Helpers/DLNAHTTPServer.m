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
#import "M3U8PlaylistModel.h"
#import <CommonCrypto/CommonCrypto.h>
#import "GCDWebServerFunctions.h"

#define kFileReadBufferSize (16 * 1024)

#define originURLKey @"__hls_origin_url"

/// Queues created once
static dispatch_queue_t IPTVStreamQueue;
static dispatch_queue_t IPTVPfetchQueue;
static dispatch_once_t kIPTVQueuesOnce = 0;

@interface IPTVSeg : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) NSTimeInterval dur;
@property (nonatomic, assign) NSInteger seq;     // for IV fallback
@property (nonatomic, strong) NSURL *keyURL;     // EXT-X-KEY URI
@property (nonatomic, strong) NSData *iv;        // parsed IV (if present)

// 🔽 NEW: BYTERANGE support
@property (nonatomic, assign) BOOL hasByteRange;
@property (nonatomic, assign) uint64_t brLength;
@property (nonatomic, assign) uint64_t brOffset;
@end

@implementation IPTVSeg @end

@interface _PipeState : NSObject
@property (nonatomic, strong) NSMutableData *buffer;                 // small ring buffer
@property (nonatomic, copy)   GCDWebServerBodyReaderCompletionBlock pendingWriter;
@property (nonatomic, weak)   NSURLSessionDataTask *task;
@property (nonatomic, assign) BOOL suspended;
@end
@implementation _PipeState @end



// ── Global cancel registry: sid -> cancel block (invokes the connection’s endStream)
static NSMutableDictionary<NSString *, void(^)(void)> *gCancelBySid;
static dispatch_queue_t gCancelQ;
__attribute__((constructor))
static void IPTVInitCancelRegistry(void) {
  gCancelBySid = [NSMutableDictionary dictionary];
  gCancelQ = dispatch_queue_create("iptv.cancel.registry.q", DISPATCH_QUEUE_SERIAL);
}
static void IPTVRegisterCanceller(NSString *sid, void (^cancel)(void)) {
  if (!sid || !cancel) return;
  dispatch_async(gCancelQ, ^{ gCancelBySid[sid] = [cancel copy]; });
}
static void IPTVUnregisterCanceller(NSString *sid) {
  if (!sid) return;
  dispatch_async(gCancelQ, ^{ [gCancelBySid removeObjectForKey:sid]; });
}
static void IPTVCancelNow(NSString *sid) {
  if (!sid) return;
  dispatch_async(gCancelQ, ^{
    void (^cancel)(void) = gCancelBySid[sid];
    if (cancel) cancel();
  });
}

// === SID generation & single-tuner arbitration (file-scope) ===
static NSMutableDictionary<NSString *, NSNumber *> *gSidGen;
static dispatch_queue_t gSidQ;

static NSString  *gActiveSid = nil;   // optional single-tuner helper
static NSInteger  gActiveGen = 0;

__attribute__((constructor))
static void IPTVInitSIDGlobals(void) {
  gSidGen = [NSMutableDictionary dictionary];
  gSidQ   = dispatch_queue_create("iptv.sid.gen.q", DISPATCH_QUEUE_SERIAL);
}



// Keep a small rolling buffer to sniff MP4 atoms
static BOOL IPTVDataContains(const NSData *d, const char *needle, size_t nlen) {
  if (!d || d.length < (NSInteger)nlen) return NO;
  const uint8_t *p = d.bytes, *end = p + d.length - nlen + 1;
  for (const uint8_t *q = p; q < end; q++) if (memcmp(q, needle, nlen) == 0) return YES;
  return NO;
}
static BOOL IPTVLooksLikeMP4Header(const NSData *d) {
  return IPTVDataContains(d, "ftyp", 4);
}
static BOOL IPTVHasMoov(const NSData *d) {
  return IPTVDataContains(d, "moov", 4);
}
static BOOL IPTVHasMdat(const NSData *d) {
  return IPTVDataContains(d, "mdat", 4);
}


// Read a query value from request URL (?name=...)
static NSString *IPTVQueryValue(GCDWebServerRequest *req, NSString *name) {
  if (!req.URL) return nil;
  NSURLComponents *c = [NSURLComponents componentsWithURL:req.URL resolvingAgainstBaseURL:NO];
  for (NSURLQueryItem *qi in c.queryItems ?: @[]) {
    if ([qi.name isEqualToString:name]) return qi.value;
  }
  return nil;
}

// If 'abs' has no query but 'base' does, inherit base.query
static NSURL *IPTVInheritQueryIfMissing(NSURL *abs, NSURL *base) {
  if (abs && !abs.query.length && base.query.length) {
    NSURLComponents *cc = [NSURLComponents componentsWithURL:abs resolvingAgainstBaseURL:NO];
    cc.query = base.query;
    return cc.URL;
  }
  return abs;
}

// Simple FNV-1a 64 hash -> hex
static NSString *IPTVHash64(NSString *s) {
  uint64_t h = 1469598103934665603ULL;
  NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *p = d.bytes;
  for (NSUInteger i = 0; i < d.length; i++) { h ^= p[i]; h *= 1099511628211ULL; }
  return [NSString stringWithFormat:@"%llx", h];
}

static inline NSString *IPTVSnip(NSString *s, NSUInteger maxLen) {
  if (!s) return @"<nil>";
  return (s.length <= maxLen) ? s : [[s substringToIndex:maxLen] stringByAppendingString:@"…"];
}

static NSData *IPTVHexToData(NSString *hex) {
  if (!hex.length) return nil;
  NSString *clean = [hex hasPrefix:@"0x"] || [hex hasPrefix:@"0X"] ? [hex substringFromIndex:2] : hex;
  NSMutableData *data = [NSMutableData dataWithCapacity:clean.length/2];
  for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
    unsigned int byte = 0;
    [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
    uint8_t b = (uint8_t)byte; [data appendBytes:&b length:1];
  }
  return data;
}

static NSData *IPTVIVFromSeq(NSInteger seq) {
  // 16-byte big-endian sequence number per HLS spec when IV is omitted
  uint8_t ivBytes[16] = {0};
  ivBytes[12] = (seq >> 24) & 0xFF;
  ivBytes[13] = (seq >> 16) & 0xFF;
  ivBytes[14] = (seq >>  8) & 0xFF;
  ivBytes[15] = (seq      ) & 0xFF;
  return [NSData dataWithBytes:ivBytes length:16];
}

static NSData *IPTVAES128CBCDecrypt(NSData *cipher, NSData *key, NSData *iv, NSError **errorOut) {
  if (!cipher.length || !key.length || key.length != 16 || !iv.length || iv.length != 16) return nil;
  size_t outLen = cipher.length + kCCBlockSizeAES128;
  void *outBuf = malloc(outLen);
  size_t moved = 0;
  CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES,
                                   kCCOptionPKCS7Padding, key.bytes, key.length,
                                   iv.bytes, cipher.bytes, cipher.length,
                                   outBuf, outLen, &moved);
  if (status != kCCSuccess) {
    if (errorOut) *errorOut = [NSError errorWithDomain:@"iptv.crypto" code:status userInfo:nil];
    free(outBuf); return nil;
  }
  return [NSData dataWithBytesNoCopy:outBuf length:moved freeWhenDone:YES];
}

// Parse small ints from query with default
static NSInteger IPTVIntQuery(GCDWebServerRequest *req, NSString *name, NSInteger defVal) {
  NSString *v = IPTVQueryValue(req, name);
  return v.length ? v.integerValue : defVal;
}

// ABR picker: best BANDWIDTH <= min(hardCap, allowedBw). Falls back to lowest available.
static NSURL* IPTVVariantBestForBw(NSString *master, NSURL *base, NSInteger hardCap, double allowedBw /* bps */) {
  NSInteger bestBW = -1;
  NSURL *bestURL = nil;

  NSArray<NSString *> *lines = [master componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];

  // First pass: respect both caps
  for (NSInteger i = 0; i < lines.count; i++) {
    NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;

    NSInteger bw = -1;
    for (NSString *part in [line componentsSeparatedByString:@","]) {
      NSRange r = [part rangeOfString:@"BANDWIDTH="];
      if (r.location != NSNotFound) { bw = [[part substringFromIndex:(r.location + r.length)] integerValue]; break; }
    }
    if (bw <= 0 || i + 1 >= lines.count) continue;

    NSString *uri = [lines[i+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([uri hasPrefix:@"#"]) continue;

    NSURL *abs = [NSURL URLWithString:uri relativeToURL:base].absoluteURL;
    abs = IPTVInheritQueryIfMissing(abs, base);

    if (hardCap > 0 && bw > hardCap) continue;
    if (allowedBw > 0 && bw > (NSInteger)llround(allowedBw)) continue;

    if (bw > bestBW) { bestBW = bw; bestURL = abs; }
  }

  // Fallback to lowest (respecting hardCap only)
  if (!bestURL) {
    NSInteger lowestBW = INT_MAX;
    for (NSInteger i = 0; i < lines.count; i++) {
      NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
      NSInteger bw = -1;
      for (NSString *part in [line componentsSeparatedByString:@","]) {
        NSRange r = [part rangeOfString:@"BANDWIDTH="];
        if (r.location != NSNotFound) { bw = [[part substringFromIndex:(r.location + r.length)] integerValue]; break; }
      }
      if (bw <= 0 || (hardCap > 0 && bw > hardCap)) continue;
      if (i + 1 >= lines.count) continue;
      NSString *uri = [lines[i+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if ([uri hasPrefix:@"#"]) continue;

      NSURL *abs = [NSURL URLWithString:uri relativeToURL:base].absoluteURL;
      abs = IPTVInheritQueryIfMissing(abs, base);
      if (bw < lowestBW) { lowestBW = bw; bestURL = abs; }
    }
  }

  if (bestURL) NSLog(@"🎚️ ABR choose variant: %@ (cap=%ld, allowed=%.0f)", bestURL, (long)hardCap, allowedBw);
  return bestURL;
}

// Percent-encode a full URL for use as a query value
static inline NSString *IPTVURLEncode(NSString *s) {
  if (!s) return @"";
  NSCharacterSet *set = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"] invertedSet];
  return [s stringByAddingPercentEncodingWithAllowedCharacters:set];
}


typedef NS_OPTIONS(NSUInteger, IPTVPlaylistFlags) {
  IPTVFlagNone           = 0,
  IPTVFlagMaster         = 1 << 0, // #EXT-X-STREAM-INF
  IPTVFlagByterange      = 1 << 1, // #EXT-X-BYTERANGE
  IPTVFlagDiscontinuity  = 1 << 2, // #EXT-X-DISCONTINUITY
  IPTVFlagLLParts        = 1 << 3, // #EXT-X-PART
  IPTVFlagCMAF           = 1 << 4  // #EXT-X-MAP or *.m4s/*.mp4
};

static IPTVPlaylistFlags IPTVDetectFlags(NSString *txt) {
  if (!txt.length) return IPTVFlagNone;
  IPTVPlaylistFlags f = IPTVFlagNone;
  if ([txt rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound) f |= IPTVFlagMaster;
  if ([txt rangeOfString:@"#EXT-X-BYTERANGE"].location != NSNotFound)  f |= IPTVFlagByterange;
  if ([txt rangeOfString:@"#EXT-X-DISCONTINUITY"].location != NSNotFound) f |= IPTVFlagDiscontinuity;
  if ([txt rangeOfString:@"#EXT-X-PART"].location != NSNotFound)       f |= IPTVFlagLLParts;

  BOOL hasMap = [txt rangeOfString:@"#EXT-X-MAP"].location != NSNotFound;
  BOOL hasM4s = ([txt rangeOfString:@".m4s"].location != NSNotFound ||
                 [txt rangeOfString:@".mp4"].location != NSNotFound);
  if (hasMap || hasM4s) f |= IPTVFlagCMAF;
  return f;
}

// Build a stable identity for a segment that survives URL re-signing:
// host + path (no query/fragment) + optional "#len@off" for BYTERANGE.
static NSString *IPTVStableKeyForURL(NSURL *u, BOOL hasBR, uint64_t len, uint64_t off) {
  if (!u) return @"";
  NSURLComponents *cc = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
  cc.query = nil; cc.fragment = nil; cc.user = nil; cc.password = nil;
  NSString *host = cc.host.length ? cc.host.lowercaseString : @"";
  NSString *path = cc.percentEncodedPath.length ? cc.percentEncodedPath : (cc.path ?: @"");
  NSString *core = host.length ? [host stringByAppendingString:path] : path;
  if (hasBR && len > 0) {
    return [NSString stringWithFormat:@"%@#%llu@%llu",
            core, (unsigned long long)len, (unsigned long long)off];
  }
  return core;
}

/// Build proxied QS preserving optional ua/ref/cookie
static NSString *IPTVBuildQs(NSURL *abs, GCDWebServerRequest *req) {
  NSMutableArray *pairs = [NSMutableArray array];
  NSString *enc = [abs.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:
                   [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"] invertedSet]];
  [pairs addObject:[NSString stringWithFormat:@"url=%@", enc ?: @""]];
  NSString *ua  = IPTVQueryValue(req, @"ua");     if (ua.length)  [pairs addObject:[NSString stringWithFormat:@"ua=%@",  [ua stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]]];
  NSString *ref = IPTVQueryValue(req, @"ref");    if (ref.length) [pairs addObject:[NSString stringWithFormat:@"ref=%@", [ref stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]]];
  NSString *ck  = IPTVQueryValue(req, @"cookie"); if (ck.length)  [pairs addObject:[NSString stringWithFormat:@"cookie=%@", [ck stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]]];
  return [pairs componentsJoinedByString:@"&"];
}

/// Keep #EXT-X-KEY but rewrite URI="..." → http://<host>:8181/hls/key/<file>?url=...
static const int kIPTVPort = 8181;

// Rewrites: #EXT-X-KEY:... URI="https://origin/key.bin"  ->  URI="http://<host>:8181/hls/key?url=..."
static NSString *IPTVRewriteKeyLineWithHost(NSString *line, NSURL *base, NSString *host, GCDWebServerRequest *req) {
  NSRange r = [line rangeOfString:@"URI=\""];
  if (r.location == NSNotFound) return line;
  NSUInteger start = r.location + r.length;
  NSRange rest = NSMakeRange(start, line.length - start);
  NSRange q = [line rangeOfString:@"\"" options:0 range:rest];
  if (q.location == NSNotFound) return line;

  NSString *uriStr = [line substringWithRange:NSMakeRange(start, q.location - start)];
  NSURL *abs = [NSURL URLWithString:uriStr relativeToURL:base].absoluteURL;
  abs = IPTVInheritQueryIfMissing(abs, base);

  NSString *qs = IPTVBuildQs(abs, req);
  NSString *local = [NSString stringWithFormat:@"URI=\"http://%@:%d/hls/key?%@\"", host, kIPTVPort, qs];

  NSMutableString *out = [line mutableCopy];
  [out replaceCharactersInRange:NSMakeRange(r.location, q.location - r.location + 1) withString:local];
  return out;
}

// Rewrites: #EXT-X-MEDIA:... URI="https://origin/audio.m3u8" -> URI="http://<host>:8181/hls/proxy.m3u8?url=..."
static NSString *IPTVRewriteMediaLineWithHost(NSString *line, NSURL *base, NSString *host, GCDWebServerRequest *req) {
  if (![line hasPrefix:@"#EXT-X-MEDIA:"]) return line;
  NSRange r = [line rangeOfString:@"URI=\""];
  if (r.location == NSNotFound) return line;

  NSUInteger start = NSMaxRange(r);
  NSRange rest = NSMakeRange(start, line.length - start);
  NSRange endq = [line rangeOfString:@"\"" options:0 range:rest];
  if (endq.location == NSNotFound) return line;

  NSString *uriStr = [line substringWithRange:NSMakeRange(start, endq.location - start)];
  NSURL *abs = [NSURL URLWithString:uriStr relativeToURL:base].absoluteURL;
  abs = IPTVInheritQueryIfMissing(abs, base);

  NSString *qs = IPTVBuildQs(abs, req); // preserves ua/ref/cookie
  NSString *local = [NSString stringWithFormat:@"URI=\"http://%@:%d/hls/proxy.m3u8?%@\"", host, kIPTVPort, qs];

  NSMutableString *out = [line mutableCopy];
  [out replaceCharactersInRange:NSMakeRange(r.location, endq.location - r.location + 1) withString:local];
  return out;
}


// Rewrites: #EXT-X-MAP:... URI="https://origin/init.m4s" ->  URI="http://<host>:8181/hls/seg/init.m4s?url=..."
static NSString *IPTVRewriteMapLineWithHost(NSString *line, NSURL *base, NSString *host, GCDWebServerRequest *req) {
  NSRange r = [line rangeOfString:@"URI=\""];
  if (r.location == NSNotFound) return line;
  NSUInteger start = r.location + r.length;
  NSRange rest = NSMakeRange(start, line.length - start);
  NSRange q = [line rangeOfString:@"\"" options:0 range:rest];
  if (q.location == NSNotFound) return line;

  NSString *uriStr = [line substringWithRange:NSMakeRange(start, q.location - start)];
  NSURL *abs = [NSURL URLWithString:uriStr relativeToURL:base].absoluteURL;
  abs = IPTVInheritQueryIfMissing(abs, base);

  NSString *leaf = abs.lastPathComponent.length ? abs.lastPathComponent : @"init.bin";
  NSString *qs = IPTVBuildQs(abs, req);
  NSString *local = [NSString stringWithFormat:@"URI=\"http://%@:%d/hls/seg/%@?%@\"", host, kIPTVPort, leaf, qs];

  NSMutableString *out = [line mutableCopy];
  [out replaceCharactersInRange:NSMakeRange(r.location, q.location - r.location + 1) withString:local];
  return out;
}


/// Rewrite a media segment line to our proxy while keeping original filename
static NSString *IPTVRewriteSegLineWithHost(NSString *line, NSURL *base, NSString *host, GCDWebServerRequest *req) {
  NSURL *abs = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
  abs = IPTVInheritQueryIfMissing(abs, base);
  NSString *name = abs.lastPathComponent.length ? abs.lastPathComponent : @"seg.ts";
  NSString *qs   = IPTVBuildQs(abs, req);
  return [NSString stringWithFormat:@"http://%@:8181/hls/seg/%@?%@", host, name, qs];
}




@interface DLNAHTTPServer () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, GCDWebServerBodyReaderCompletionBlock> *writers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, GCDWebServerStreamedResponse*> *responses;
@property (nonatomic, strong) NSString *tsFilePath;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, strong) NSString *originalM3U8URL;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *bytesSentByTask;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableData *> *firstKBByTask;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDate *> *startTimeByTask;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, _PipeState*> *pipes;

@end

// ===== Key cache helpers (file scope) =====
static NSCache<NSString*, NSData*> *KeyCacheSingleton(void) {
  static NSCache<NSString*, NSData*> *c;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    c = [NSCache new];
    c.countLimit     = 512;           // max distinct key URIs
    c.totalCostLimit = 256 * 1024;    // ~256 KB (cost = URL length)
  });
  return c;
}

static inline NSData *KeyCacheGet(NSString *k) {
  return k ? [KeyCacheSingleton() objectForKey:k] : nil;
}

static inline void KeyCachePut(NSString *k, NSData *v) {
  if (!k || !v) return;
  [KeyCacheSingleton() setObject:v forKey:k cost:(int)k.length];
}

static inline void KeyCacheRemoveAll(void) {
  [KeyCacheSingleton() removeAllObjects];
}

// ===== class implementation starts =====
@implementation DLNAHTTPServer
{
    NSMutableDictionary *_allSubscriptions;
}

- (instancetype) init
{
    if (self = [super init])
    {
        _allSubscriptions = [NSMutableDictionary new];
        _writers = [NSMutableDictionary dictionary];
        _responses = [NSMutableDictionary dictionary];
        
        _bytesSentByTask = [NSMutableDictionary dictionary];
        _firstKBByTask   = [NSMutableDictionary dictionary];
        _startTimeByTask = [NSMutableDictionary dictionary];
        
        _pipes = [NSMutableDictionary dictionary];


    }
    
    return self;
}


// Tunables
static const NSUInteger kChunkToTV = 32 * 1024;       // how much we give TV per callback
static const NSUInteger kBufferCap = 1 * 1024 * 1024; // max per-conn buffer = 1MB

- (void)_pipeTryFlushForTaskID:(NSNumber *)tid {
  _PipeState *pipe = nil;
  @synchronized (self) { pipe = self.pipes[tid]; }
  if (!pipe) return;

  NSData *chunkToSend = nil;
  GCDWebServerBodyReaderCompletionBlock writerToCall = nil;
  BOOL shouldResumeUpstream = NO;

  // Take the chunk atomically with the deletion.
  @synchronized (pipe) {
    if (!pipe.pendingWriter) return;
    if (pipe.buffer.length == 0) return;

    const NSUInteger n = MIN(kChunkToTV, pipe.buffer.length);

    // Grab chunk and delete that exact range while still locked.
    chunkToSend = [[pipe.buffer subdataWithRange:NSMakeRange(0, n)] copy];
    [pipe.buffer replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];

    writerToCall = [pipe.pendingWriter copy];
    pipe.pendingWriter = nil;

    // Decide if we should resume upstream now that buffer shrank.
    if (pipe.suspended && pipe.buffer.length < kBufferCap) {
      pipe.suspended = NO;
      shouldResumeUpstream = YES;
    }
  }

  // Do callbacks / resuming outside the lock.
  if (writerToCall) writerToCall(chunkToSend ?: [NSData data], nil);
  if (shouldResumeUpstream) {
    [pipe.task resume];
  }
}


// push chunks to the correct response
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data
{
  @autoreleasepool {
    if (!data.length) return;

    // Update lightweight stats + sniff (bounded)
    NSNumber *old = nil;
    NSMutableData *sniff = nil;
    @synchronized (self) {
      old = self.bytesSentByTask[@(task.taskIdentifier)] ?: @(0);
      self.bytesSentByTask[@(task.taskIdentifier)] = @(old.unsignedLongLongValue + data.length);

      sniff = self.firstKBByTask[@(task.taskIdentifier)];
      if (sniff && sniff.length < 8192) {
        const NSUInteger room = 8192 - sniff.length;
        if (room) [sniff appendData:(data.length > room ? [data subdataWithRange:NSMakeRange(0, room)] : data)];
      }
    }

    _PipeState *pipe = nil;
    @synchronized (self) { pipe = self.pipes[@(task.taskIdentifier)]; }
    if (!pipe) return;

    BOOL shouldSuspendUpstream = NO;

    // Append atomically; decide suspension while locked
    @synchronized (pipe) {
      [pipe.buffer appendData:data];

      if (!pipe.suspended && pipe.buffer.length >= kBufferCap) {
        pipe.suspended = YES;
        shouldSuspendUpstream = YES;
      }
    }

    // Perform the suspend outside the lock to avoid deadlocks with Apple internals
    if (shouldSuspendUpstream) {
      [pipe.task suspend];
    }

    // If TV is waiting, push exactly one chunk now
    [self _pipeTryFlushForTaskID:@(task.taskIdentifier)];

    // Throttled log
    static NSUInteger kEveryN = 32;
    static _Atomic(uint64_t) seq = 0;
    if (((++seq) % kEveryN) == 0) {
      unsigned long long total = 0;
      NSUInteger bufLen = 0;
      BOOL paused = NO;
      @synchronized (self) {
        total = self.bytesSentByTask[@(task.taskIdentifier)].unsignedLongLongValue;
      }
      @synchronized (pipe) {
        bufLen = pipe.buffer.length;
        paused = pipe.suspended;
      }
      NSLog(@"📦 chunk task=%lu size=%lu total=%llu buf=%lu%s",
            (unsigned long)task.taskIdentifier, (unsigned long)data.length,
            total, (unsigned long)bufLen, paused ? " (paused)" : "");
    }
  }
}


- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
  @autoreleasepool {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSLog(@"🛰️ didReceiveResponse task=%lu URL=%@ status=%ld MIME=%@ expectedLen=%lld",
          (unsigned long)task.taskIdentifier, response.URL.absoluteString,
          (long)http.statusCode, http.MIMEType, (long long)response.expectedContentLength);
    NSLog(@"🛰️ Origin headers: %@", http.allHeaderFields);

    // Init per-task stats
    @synchronized (self) {
      self.bytesSentByTask[@(task.taskIdentifier)] = @(0);
      self.firstKBByTask[@(task.taskIdentifier)]   = [NSMutableData dataWithCapacity:8192];
      self.startTimeByTask[@(task.taskIdentifier)] = [NSDate date];
    }

    // Reflect headers to downstream (as you had)
    GCDWebServerStreamedResponse *resp = nil;
    @synchronized (self.responses) { resp = self.responses[@(task.taskIdentifier)]; }
    if (resp) {
      NSString *mime = http.MIMEType;
      if (mime.length == 0) {
        NSString *ext = response.URL.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"ts"]) mime = @"video/mp2t";
        else if ([ext isEqualToString:@"m4s"] || [ext isEqualToString:@"mp4"]) mime = @"video/mp4";
        else mime = resp.contentType ?: @"application/octet-stream";
      }
      resp.contentType = mime;

      NSString *cr = http.allHeaderFields[@"Content-Range"];
      NSString *ar = http.allHeaderFields[@"Accept-Ranges"];

      if (http.statusCode == 206 || cr.length) {
        resp.statusCode = 206;
        if (cr.length) [resp setValue:cr forAdditionalHeader:@"Content-Range"];
        [resp setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
      } else {
        resp.statusCode = (int)http.statusCode ?: 200;
        if (ar.length)  [resp setValue:ar forAdditionalHeader:@"Accept-Ranges"];
        else            [resp setValue:@"none" forAdditionalHeader:@"Accept-Ranges"];
      }

      NSString *cc = http.allHeaderFields[@"Cache-Control"];
      if (cc.length) [resp setValue:cc forAdditionalHeader:@"Cache-Control"];

      NSLog(@"🧾 Outgoing to TV → status=%d contentType=%@ contentLength=%lld (chunked=%@)",
            resp.statusCode, resp.contentType, (long long)resp.contentLength,
            (resp.contentLength > 0 ? @"NO" : @"YES"));
    }
  }
  completionHandler(NSURLSessionResponseAllow);
}


- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
  @autoreleasepool {
    NSNumber *tid = @(task.taskIdentifier);

    // Stats/log
    NSNumber *total = nil; NSMutableData *sniff = nil; NSDate *t0 = nil;
    @synchronized (self) {
      total = self.bytesSentByTask[tid] ?: @(0);
      sniff = self.firstKBByTask[tid];
      t0    = self.startTimeByTask[tid];
      [self.bytesSentByTask removeObjectForKey:tid];
      [self.firstKBByTask removeObjectForKey:tid];
      [self.startTimeByTask removeObjectForKey:tid];
    }

    NSTimeInterval dt = t0 ? [[NSDate date] timeIntervalSinceDate:t0] : 0;
    double mbps = (dt > 0 ? ((double)total.unsignedLongLongValue * 8.0 / 1e6) / dt : 0);
    BOOL hasFTYP = IPTVLooksLikeMP4Header(sniff);
    BOOL hasMOOV = IPTVHasMoov(sniff);
    BOOL hasMDAT = IPTVHasMdat(sniff);

    NSLog(@"✅ task end=%lu err=%@ sent=%lluB time=%.3fs rate=%.2f Mbps  sniff: ftyp=%d moov=%d mdat=%d",
          (unsigned long)task.taskIdentifier, error.localizedDescription ?: @"(nil)",
          (unsigned long long)total.unsignedLongLongValue, dt, mbps,
          hasFTYP, hasMOOV, hasMDAT);

    // Final flush if anything left and TV is waiting
    [self _pipeTryFlushForTaskID:tid];

    // Close downstream writer (EOF)
    GCDWebServerBodyReaderCompletionBlock writer = nil;
    @synchronized (self.writers) {
      writer = self.writers[tid];
      [self.writers removeObjectForKey:tid];
    }
    if (writer) writer([NSData data], nil);

    // Clean pipe + response map
    @synchronized (self) {
      [self.responses removeObjectForKey:tid];
      [self.pipes removeObjectForKey:tid];
    }
  }

  [session finishTasksAndInvalidate];
}


// DLNAHTTPServer.m
+ (instancetype)sharedInstance {
    static DLNAHTTPServer *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[DLNAHTTPServer alloc] init];
    });
    return sharedInstance;
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
            GCDWebServerResponse *hResponse = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
            return hResponse;
        }
        
        return nil;
    }];
    
    [self addFileProxyHandler];
    
    // POST /hls/stop?sid=...  → ends the stream for that sid (generation bump + immediate cancel)
    [self.server addHandlerForMethod:@"POST"
                                path:@"/hls/stop"
                        requestClass:[GCDWebServerRequest class]
                        processBlock:^GCDWebServerResponse *(__kindof GCDWebServerRequest *req) {

      // Reuse the same sid extraction logic as your GET handler
      NSString *sid = IPTVQueryValue(req, @"sid") ?: IPTVQueryValue(req, @"session");
      if (sid.length == 0) {
        return [GCDWebServerDataResponse responseWithStatusCode:400];
      }

      // 1) Bump generation so any running loop observing isCancelled() will exit
     
      dispatch_async(gSidQ, ^{
        NSInteger next = gSidGen[sid] ? gSidGen[sid].integerValue + 1 : 1;
        gSidGen[sid] = @(next);
      });

      // 2) Ask the active connection (if any) to end immediately
      IPTVCancelNow(sid);

      return [GCDWebServerDataResponse responseWithStatusCode:200];
    }];

    
    [self addHLSHeadRoute];
    [self addHLSProxyTSHandler];
    
    [self addHLSProxyM3U8Handler];
    [self addHLSSegmentAndKeyHandlers];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];

    if (!documentsDirectory) {
        NSLog(@"❌ Error: Documents directory path is nil!");
        return;
    }

    NSLog(@"📂 Documents Directory Path: %@", documentsDirectory);

    
    [self.server addGETHandlerForBasePath:@"/Documents/"
                             directoryPath:documentsDirectory
                             indexFilename:nil
                                  cacheAge:3600
                       allowRangeRequests:YES];

    
    [self.server startWithPort:8181 bonjourName:nil];
}

- (void)addFileProxyHandler {
  __weak typeof(self) weakSelf = self;

  [self.server addHandlerForMethod:@"GET"
                              path:@"/file/proxy"
                      requestClass:[GCDWebServerRequest class]
               asyncProcessBlock:^(__kindof GCDWebServerRequest *req, GCDWebServerCompletionBlock done) {

    NSString *raw = req.query[@"url"];
    if (raw.length == 0) { done([GCDWebServerDataResponse responseWithStatusCode:400]); return; }
    NSString *decoded = raw.stringByRemovingPercentEncoding ?: raw;
    NSURL *u = [NSURL URLWithString:decoded];
    if (!u || ![@[@"http",@"https"] containsObject:u.scheme.lowercaseString]) {
      done([GCDWebServerDataResponse responseWithStatusCode:400]); return;
    }

    NSString *ext = u.pathExtension.lowercaseString;
    NSString *defaultCT = ([ext isEqualToString:@"ts"] ? @"video/mp2t"
                          : ([ext isEqualToString:@"m4s"] || [ext isEqualToString:@"mp4"] ? @"video/mp4"
                          : @"application/octet-stream"));

    __block NSURLSessionDataTask *task = nil;

    GCDWebServerStreamedResponse *resp =
      [GCDWebServerStreamedResponse responseWithContentType:defaultCT
                                           asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock body) {

      // If upstream already running, TV is asking for next chunk: just mark writer and try flush once
      if (task) {
        @synchronized (weakSelf) {
          _PipeState *pipe = weakSelf.pipes[@(task.taskIdentifier)];
          if (pipe) pipe.pendingWriter = [body copy];
        }
        [weakSelf _pipeTryFlushForTaskID:@(task.taskIdentifier)];
        return;
      }

      // First call: create session, pipe, start upstream
      NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
      cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
      cfg.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:0 diskCapacity:0 diskPath:nil];
      cfg.timeoutIntervalForRequest = 60.0;
      cfg.timeoutIntervalForResource = 0.0;
      cfg.HTTPShouldUsePipelining = NO;

      NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg delegate:weakSelf delegateQueue:nil];

      NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u];
      NSString *ua  = req.query[@"ua"];
      NSString *ref = req.query[@"ref"];
      NSString *ck  = req.query[@"cookie"];
      if (ua.length)  [rq setValue:ua  forHTTPHeaderField:@"User-Agent"];
      if (ref.length) [rq setValue:ref forHTTPHeaderField:@"Referer"];
      if (ck.length)  [rq setValue:ck  forHTTPHeaderField:@"Cookie"];
      [rq setValue:@"*/*"        forHTTPHeaderField:@"Accept"];
      [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
      [rq setValue:@"identity"   forHTTPHeaderField:@"Accept-Encoding"]; // keep raw bytes

      NSString *rangeHdr = req.headers[@"Range"] ?: req.headers[@"range"];
      if (rangeHdr.length) [rq setValue:rangeHdr forHTTPHeaderField:@"Range"];

      task = [sess dataTaskWithRequest:rq];

      _PipeState *pipe = [_PipeState new];
      pipe.buffer = [NSMutableData dataWithCapacity:256*1024];
      pipe.pendingWriter = [body copy];
      pipe.task = task;

      // keep your existing maps for stats / header mirroring
      @synchronized (weakSelf) {
        weakSelf.pipes[@(task.taskIdentifier)] = pipe;
        weakSelf.writers[@(task.taskIdentifier)] = [body copy];
        weakSelf.responses[@(task.taskIdentifier)] = resp;
      }

      [task resume];
    }];

    // DLNA / misc headers (unchanged)
    [resp setValue:@"Streaming" forAdditionalHeader:@"transferMode.dlna.org"];
    [resp setValue:@"DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
     forAdditionalHeader:@"contentFeatures.dlna.org"];
    [resp setValue:@"keep-alive" forAdditionalHeader:@"Connection"];
    [resp setValue:@"*"          forAdditionalHeader:@"Access-Control-Allow-Origin"];

    NSLog(@"➡️ /file/proxy to TV: status=%d type=%@ contentLength=%lld (chunked=%@) RangeIn=%@",
          resp.statusCode, resp.contentType, (long long)resp.contentLength,
          (resp.contentLength > 0 ? @"NO" : @"YES"),
          (req.headers[@"Range"] ?: req.headers[@"range"] ?: @"(none)"));

    done(resp);
  }];
}


#pragma mark - HLS A/V helpers (file-scope C functions)

static BOOL IPTVLineHasAudioCodec(NSString *lc) {
  lc = lc.lowercaseString ?: @"";
  return ([lc containsString:@"mp4a"] ||
          [lc containsString:@"ac-3"] ||
          [lc containsString:@"ec-3"] ||
          [lc containsString:@"opus"]);
}

static BOOL IPTVLineHasVideoCodec(NSString *lc) {
  lc = lc.lowercaseString ?: @"";
  return ([lc containsString:@"avc1"] ||
          [lc containsString:@"hvc1"] || [lc containsString:@"hev1"] ||
          [lc containsString:@"av01"] ||
          [lc containsString:@"dvh1"] ||
          [lc containsString:@"vp9"]);
}

static void IPTVLogMasterAVSummary(NSString *master, NSURL *base) {
  if (master.length == 0) return;
  NSArray<NSString *> *lines =
    [master componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];

  // Collect AUDIO rendition groups
  NSMutableDictionary<NSString *, NSNumber *> *audioGroups = [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *audioRenditions = [NSMutableArray array];

  for (NSString *raw in lines) {
    NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![line hasPrefix:@"#EXT-X-MEDIA:"]) continue;

    BOOL isAudio = NO; NSString *gid = nil; NSString *name = nil; NSString *lang = nil;
    for (NSString *kv in [line componentsSeparatedByString:@","]) {
      NSArray *pair = [kv componentsSeparatedByString:@"="]; if (pair.count < 2) continue;
      NSString *k = [pair[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      NSString *v = [[pair subarrayWithRange:NSMakeRange(1, pair.count-1)] componentsJoinedByString:@"="];
      v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([v hasPrefix:@"\""] && [v hasSuffix:@"\""]) v = [v substringWithRange:NSMakeRange(1, v.length-2)];
      if ([k isEqualToString:@"TYPE"] && [v.uppercaseString isEqualToString:@"AUDIO"]) isAudio = YES;
      else if ([k isEqualToString:@"GROUP-ID"]) gid = v;
      else if ([k isEqualToString:@"NAME"]) name = v;
      else if ([k isEqualToString:@"LANGUAGE"]) lang = v;
    }
    if (isAudio) {
      NSInteger c = audioGroups[gid ?: @"-"].integerValue + 1;
      audioGroups[gid ?: @"-"] = @(c);
      [audioRenditions addObject:[NSString stringWithFormat:@"gid=%@ name=%@ lang=%@",
                                  gid ?: @"-", name ?: @"-", lang ?: @"-"]];
    }
  }

  // Variants
  NSMutableArray<NSString *> *variantLogs = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
    NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;

    NSInteger bw = -1; NSString *codecs = nil; NSString *audioGroup = nil;
    for (NSString *kv in [line componentsSeparatedByString:@","]) {
      NSRange r1 = [kv rangeOfString:@"BANDWIDTH="];
      NSRange r2 = [kv rangeOfString:@"CODECS=\""];
      NSRange r3 = [kv rangeOfString:@"AUDIO=\""];
      if (r1.location != NSNotFound)
        bw = [[kv substringFromIndex:(r1.location + r1.length)] integerValue];
      else if (r2.location != NSNotFound) {
        NSUInteger s = NSMaxRange(r2);
        NSRange rr = [line rangeOfString:@"\"" options:0 range:NSMakeRange(s, line.length - s)];
        if (rr.location != NSNotFound) codecs = [line substringWithRange:NSMakeRange(s, rr.location - s)];
      } else if (r3.location != NSNotFound) {
        NSUInteger s = NSMaxRange(r3);
        NSRange rr = [line rangeOfString:@"\"" options:0 range:NSMakeRange(s, line.length - s)];
        if (rr.location != NSNotFound) audioGroup = [line substringWithRange:NSMakeRange(s, rr.location - s)];
      }
    }

    BOOL hasA = IPTVLineHasAudioCodec(codecs);
    BOOL hasV = IPTVLineHasVideoCodec(codecs);
    BOOL muxed     = (hasA && hasV && (audioGroup.length == 0));
    BOOL videoOnly = (hasV && !hasA);
    BOOL audioOnly = (hasA && !hasV);

    NSString *klass = muxed ? @"muxed A/V"
                     : videoOnly ? (audioGroup.length ? [NSString stringWithFormat:@"video-only (AUDIO=%@)", audioGroup] : @"video-only")
                     : audioOnly ? @"audio-only"
                     : @"unknown";

    [variantLogs addObject:[NSString stringWithFormat:@"- BW=%ld, CODECS=\"%@\", class=%@%@",
                            (long)bw, codecs ?: @"",
                            klass, (audioGroup.length ? [NSString stringWithFormat:@", AUDIO-group=%@", audioGroup] : @"")]];
  }

  NSLog(@"🔎 MASTER A/V SUMMARY: audio-groups=%@, renditions=%@", audioGroups, audioRenditions);
  for (NSString *vlog in variantLogs) NSLog(@"   %@", vlog);
}

// CMAF init probe helpers
static BOOL IPTVDataHasBytes(NSData *d, const char *needle, size_t nlen) {
  if (!d || d.length < (NSInteger)nlen) return NO;
  const uint8_t *p = d.bytes, *end = p + d.length - nlen + 1;
  for (const uint8_t *q = p; q < end; q++) if (memcmp(q, needle, nlen) == 0) return YES;
  return NO;
}
static BOOL IPTVDataHasFourCC(NSData *d, const char *fcc) { return IPTVDataHasBytes(d, fcc, 4); }

static NSDictionary *IPTVQuickISOBMFFProbe(NSData *initData) {
  if (!initData.length) return @{};
  BOOL hasVide = IPTVDataHasFourCC(initData, "vide");
  BOOL hasSoun = IPTVDataHasFourCC(initData, "soun");

  BOOL hasAVC  = IPTVDataHasFourCC(initData, "avc1");
  BOOL hasHEV1 = IPTVDataHasFourCC(initData, "hev1") || IPTVDataHasFourCC(initData, "hvc1");
  BOOL hasAV01 = IPTVDataHasFourCC(initData, "av01");
  BOOL hasDV   = IPTVDataHasFourCC(initData, "dvh1") || IPTVDataHasFourCC(initData, "dvhe") || IPTVDataHasFourCC(initData, "dvav");

  BOOL hasMP4A = IPTVDataHasFourCC(initData, "mp4a");
  BOOL hasAC3  = IPTVDataHasFourCC(initData, "ac-3");
  BOOL hasEC3  = IPTVDataHasFourCC(initData, "ec-3");
  BOOL hasOPUS = IPTVDataHasFourCC(initData, "Opus") || IPTVDataHasFourCC(initData, "opus");

  NSMutableArray *v = [NSMutableArray array];
  if (hasAVC)  [v addObject:@"avc1"];
  if (hasHEV1) [v addObject:@"hev1/hvc1"];
  if (hasAV01) [v addObject:@"av01"];
  if (hasDV)   [v addObject:@"dolby-vision"];

  NSMutableArray *a = [NSMutableArray array];
  if (hasMP4A) [a addObject:@"mp4a"];
  if (hasAC3)  [a addObject:@"ac-3"];
  if (hasEC3)  [a addObject:@"ec-3"];
  if (hasOPUS) [a addObject:@"opus"];

  return @{
    @"hasVideo": @(hasVide || v.count > 0),
    @"hasAudio": @(hasSoun || a.count > 0),
    @"videoCodecs": v,
    @"audioCodecs": a
  };
}


#pragma mark - HLS → TS proxy (Objective-C)

// === sid → origin URL mapping ===
static NSMutableDictionary<NSString *, NSString *> *gSidOrigin;
static dispatch_once_t gSidOriginOnce;
static dispatch_queue_t gSidOriginQ2;

static void IPTVSidSetOriginURLForSid(NSString *sid, NSString *url) {
  if (!sid.length || !url.length) return;

  // Persist
  NSString *key = [@"hls_origin_" stringByAppendingString:sid];
  [[NSUserDefaults standardUserDefaults] setObject:url forKey:key];
  [[NSUserDefaults standardUserDefaults] synchronize];

  // Optional in-memory cache
  dispatch_once(&gSidOriginOnce, ^{
    gSidOrigin   = [NSMutableDictionary dictionary];
    gSidOriginQ2 = dispatch_queue_create("iptv.sid.origin.q", DISPATCH_QUEUE_SERIAL);
  });
  dispatch_async(gSidOriginQ2, ^{
    gSidOrigin[sid] = url;
  });
}


static NSString *IPTVSidOriginURLForSid(NSString *sid) {
  if (!sid.length) return nil;

  // 1) First, trust UserDefaults (Swift writes here)
  NSString *key   = [@"hls_origin_" stringByAppendingString:sid];
  NSString *udVal = [[NSUserDefaults standardUserDefaults] stringForKey:key];
  if (udVal.length) {
    return udVal;
  }

  // 2) Optional: legacy in-memory map fallback
  dispatch_once(&gSidOriginOnce, ^{
    gSidOrigin   = [NSMutableDictionary dictionary];
    gSidOriginQ2 = dispatch_queue_create("iptv.sid.origin.q", DISPATCH_QUEUE_SERIAL);
  });

  __block NSString *u = nil;
  dispatch_sync(gSidOriginQ2, ^{
    u = gSidOrigin[sid];
  });

  return u;
}


static void IPTVSidClearOriginForSid(NSString *sid) {
  if (!sid.length) return;

  // Remove from UserDefaults
  NSString *key = [@"hls_origin_" stringByAppendingString:sid];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];

  // Remove from in-memory map
  dispatch_once(&gSidOriginOnce, ^{
    gSidOrigin   = [NSMutableDictionary dictionary];
    gSidOriginQ2 = dispatch_queue_create("iptv.sid.origin.q", DISPATCH_QUEUE_SERIAL);
  });
  dispatch_async(gSidOriginQ2, ^{
    [gSidOrigin removeObjectForKey:sid];
  });
}



- (void)addHLSHeadRoute {
  [self.server addHandlerForMethod:@"HEAD"
                              path:@"/hls/playlist.ts"
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse* (GCDWebServerRequest *request) {
    GCDWebServerResponse *r = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_OK];
    r.contentType = @"video/vnd.dlna.mpeg-tts";
    [r setValue:@"Streaming" forAdditionalHeader:@"transferMode.dlna.org"];
    [r setValue:@"DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
 forAdditionalHeader:@"contentFeatures.dlna.org"];
    [r setValue:@"no-store, no-cache, must-revalidate" forAdditionalHeader:@"Cache-Control"];
    [r setValue:@"no-cache" forAdditionalHeader:@"Pragma"];
    [r setValue:@"0" forAdditionalHeader:@"Expires"];
    [r setValue:@"keep-alive" forAdditionalHeader:@"Connection"];
    return r;
  }];
}

- (void)addHLSProxyTSHandler {
  [self.server addHandlerForMethod:@"GET"
                              path:@"/hls/playlist.ts"
                      requestClass:[GCDWebServerRequest class]
               asyncProcessBlock:^(__kindof GCDWebServerRequest *req, GCDWebServerCompletionBlock done) {

    // Queues (global)
//    dispatch_once(&kIPTVQueuesOnce, ^{
//      IPTVStreamQueue = dispatch_queue_create("iptv.stream.queue", DISPATCH_QUEUE_SERIAL);
//      IPTVPfetchQueue = dispatch_queue_create("iptv.prefetch.queue", DISPATCH_QUEUE_CONCURRENT);
//    });
      
      // Queues (per-connection; no global blocking)
      dispatch_queue_t streamQ  = dispatch_queue_create("iptv.stream.queue", DISPATCH_QUEUE_SERIAL);
      dispatch_queue_t prefetchQ = dispatch_queue_create("iptv.prefetch.queue", DISPATCH_QUEUE_CONCURRENT);


    // ===== Session-cancellation by sid =====

    // sid: ?sid=..., else remote address fallback, else random
    NSString *sid = IPTVQueryValue(req, @"sid") ?: IPTVQueryValue(req, @"session");
    if (sid.length == 0) {
      NSString *remoteAddr = nil;
      @try { remoteAddr = [req valueForKey:@"remoteAddressString"]; } @catch (__unused NSException *e) {}
      sid = remoteAddr.length ? [@"tv-" stringByAppendingString:remoteAddr] : [NSUUID UUID].UUIDString;
    }
    __block NSInteger myGen = 0;
    dispatch_sync(gSidQ, ^{
      NSInteger next = gSidGen[sid] ? gSidGen[sid].integerValue + 1 : 1;
      gSidGen[sid] = @(next);
      myGen = next;
    });
    NSLog(@"🎫 HLS session start sid=%@ gen=%ld (path=%@, query=%@)", sid, (long)myGen, req.path, req.URL.query);
      
      // ── Single-tuner: cancel the previously active stream ONLY if it’s a different sid
      dispatch_sync(gSidQ, ^{
        if (gActiveSid && ![gActiveSid isEqualToString:sid]) {
          NSInteger prevGen = [gSidGen[gActiveSid] integerValue];
          gSidGen[gActiveSid] = @(prevGen + 1);   // flip old (different) sid to cancelled
        }
        // Mark THIS request as the active one
        gActiveSid = sid;
        gActiveGen = myGen;
      });



    BOOL (^isCancelled)(void) = ^BOOL{
      __block BOOL cancelled = NO;
      dispatch_sync(gSidQ, ^{ cancelled = ([gSidGen[sid] integerValue] != myGen); });
      return cancelled;
    };

      // ===== Inputs & session =====

      // Whatever the TV / client is passing right now (often the proxy.m3u8)
      NSString *rawParam = IPTVQueryValue(req, @"url") ?: IPTVQueryValue(req, @"__hls_origin_url");

      // 🔹 NEW: prefer the origin URL we stored for this sid (if any)
      NSString *savedForSid = IPTVSidOriginURLForSid(sid);   // helper you already use / or add (see below)

      NSString *raw = nil;
      if (savedForSid.length) {
        // Use the “true” origin we stored when the session started
        raw = savedForSid;
      } else {
        // Fallback to whatever was passed in the query
        raw = rawParam;
      }

      if (raw.length == 0) {
        NSLog(@"❌ Missing playlist url (sid=%@)", sid);
        done([GCDWebServerDataResponse responseWithStatusCode:400]);
        return;
      }

      NSString *decoded = raw.stringByRemovingPercentEncoding ?: raw;
      __block NSURL *playlistURL = [NSURL URLWithString:decoded];
      if (!playlistURL || ![@[@"http",@"https"] containsObject:playlistURL.scheme.lowercaseString]) {
        NSLog(@"❌ Bad origin URL for sid=%@: %@", sid, decoded);
        done([GCDWebServerDataResponse responseWithStatusCode:400]);
        return;
      }
      NSLog(@"🔗 Origin playlist URL (sid=%@): %@", sid, playlistURL.absoluteString);


    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.timeoutIntervalForRequest  = 15;
    cfg.timeoutIntervalForResource = 30;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSString *ua  = IPTVQueryValue(req, @"ua");  if (ua.length)  headers[@"User-Agent"] = ua;
    NSString *ref = IPTVQueryValue(req, @"ref"); if (ref.length) headers[@"Referer"]    = ref;
    NSString *ck  = IPTVQueryValue(req, @"cookie"); if (ck.length) headers[@"Cookie"]   = ck;
    if (headers.count) {
        cfg.HTTPAdditionalHeaders = headers;
        NSLog(@"🧾 Extra headers: %@", headers);
    }

      // Harden session lifecycle
      cfg.URLCache = nil;  // avoid any in-memory URL cache
      __block NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
      __block BOOL sessionClosed = NO;   // guard all network calls after endStream
      
      // Effective client headers we’ll reuse in requests
      NSString *uaDefault = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1";
      __block NSString *effUA     = (headers[@"User-Agent"] ?: uaDefault);
      __block NSString *effCookie = headers[@"Cookie"]; // may be nil


    NSURL *cacheBase = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *cacheDir  = [cacheBase URLByAppendingPathComponent:@"iptv_cache" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSLog(@"📂 Cache dir: %@", cacheDir.path);

    // ===== Per-connection state =====
    __block NSString *lastServedName = nil;
    __block NSInteger lastSeq = -1; // forward-only watermark
    __block NSMutableSet<NSString *> *prefetching = [NSMutableSet new];
    __block NSMutableDictionary<NSString *, NSData *> *memCache = [NSMutableDictionary new];
      

    __block NSData *curSegData = nil;
    __block NSUInteger curSegPos = 0;
    __block NSTimeInterval lastSegDur = 0.0;   // duration of the segment currently being sent
      
      // VOD completion tracking
      __block BOOL servedLastOfVOD = NO;
      __block NSInteger lastPickIdx = -1;

      
      // CMAF/fMP4 per-connection state
      __block BOOL isCMAFStream = NO;
      __block NSURL *mapURL = nil;
      __block BOOL mapSent = NO;

      // Once we choose a variant (e.g., 720p), keep it
      __block BOOL variantLocked = NO;
      __block BOOL lastKnownIsVOD = NO;   // default assume LIVE until we parse a playlist



    // Tuning
    const NSUInteger TS_PKT = 188;
    __block NSInteger lagSegments   = MAX(1, MIN(IPTVIntQuery(req, @"lag", 4), 6));
    __block NSInteger prefetchAhead = MAX(0, MIN(IPTVIntQuery(req, @"prefetch", 2), 4));
      
      void (^trimMemCache)(void) = ^{
        while ((NSInteger)memCache.count > prefetchAhead) {
          NSString *anyKey = memCache.allKeys.firstObject;
          if (!anyKey) break;
          [memCache removeObjectForKey:anyKey];
        }
        const NSUInteger kMemCapBytes = 6 * 1024 * 1024; // ~6 MB safety cap
        NSUInteger total = 0;
        for (NSData *d in memCache.allValues) total += d.length;
        if (total <= kMemCapBytes) return;
        for (NSString *k in memCache.allKeys) {
          if (total <= kMemCapBytes) break;
          total -= memCache[k].length;
          [memCache removeObjectForKey:k];
        }
      };


      
    __block NSInteger hardCapBw     = MAX(0, IPTVIntQuery(req, @"maxbw", 0));
    __block NSUInteger chunkSize = MAX(TS_PKT, (NSUInteger)IPTVIntQuery(req, @"chunk", (int)(TS_PKT * 128)));
    if (chunkSize % TS_PKT) chunkSize -= (chunkSize % TS_PKT);

      
      
    __block double tput_bps = 0.0;
    const double abr_alpha = 0.35;

    NSURL* (^inheritQueryIfMissing)(NSURL *, NSURL *) = ^NSURL* (NSURL *abs, NSURL *base) {
      if (!abs) return nil;
      BOOL relative = (abs.host == nil);
      BOOL sameHost = (!relative && base.host && [abs.host caseInsensitiveCompare:base.host] == NSOrderedSame);
      if (!abs.query.length && base.query.length && (relative || sameHost)) {
        NSURLComponents *cc = [NSURLComponents componentsWithURL:abs resolvingAgainstBaseURL:NO];
        cc.query = base.query; return cc.URL;
      }
      return abs;
    };

      // Parse #EXT-X-MAP:URI="..."
      NSURL* (^parseMapURI)(NSString *text, NSURL *base) = ^NSURL* (NSString *text, NSURL *base) {
        __block NSURL *mapURL = nil;
        [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
          NSString *s = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
          if ([s hasPrefix:@"#EXT-X-MAP:"]) {
            NSRange uir = [s rangeOfString:@"URI=\""];
            if (uir.location != NSNotFound) {
              NSUInteger start = NSMaxRange(uir);
              NSRange rest = NSMakeRange(start, s.length - start);
              NSRange endq = [s rangeOfString:@"\"" options:0 range:rest];
              if (endq.location != NSNotFound) {
                NSString *rel = [s substringWithRange:NSMakeRange(start, endq.location - start)];
                NSURL *abs = [NSURL URLWithString:rel relativeToURL:base].absoluteURL;
                mapURL = abs ?: mapURL;
                *stop = YES;
              }
            }
          }
        }];
        return mapURL;
      };

      
      // RETURNs playlist body AND updates *outFinalURL to the final (post-redirect) URL
      NSString* (^fetchTextFinal)(NSURL *, NSURL **) = ^NSString* (NSURL *u, NSURL **outFinalURL) {
          if (isCancelled() || sessionClosed || session == nil) return nil;

        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u];

        // Seed headers similar to Safari (helps some CDNs to redirect properly)
          NSString *uaSeed  = effUA;
          NSString *refSeed = headers[@"Referer"] ?: u.absoluteString;
          NSString *ckSeed  = effCookie;

        [rq setValue:uaSeed  forHTTPHeaderField:@"User-Agent"];
        [rq setValue:refSeed forHTTPHeaderField:@"Referer"];
        if (ckSeed.length) [rq setValue:ckSeed forHTTPHeaderField:@"Cookie"];
        [rq setValue:@"*/*"        forHTTPHeaderField:@"Accept"];
        [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
        [rq setValue:@"identity"   forHTTPHeaderField:@"Accept-Encoding"];

        NSLog(@"🌐 GET %@", u.absoluteString);

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSData *data = nil; __block NSError *err = nil; __block NSURLResponse *resp = nil;

        [[session dataTaskWithRequest:rq
                    completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
          data = d; err = e; resp = r; dispatch_semaphore_signal(sema);
        }] resume];

        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        if (err || isCancelled()) { if (err) NSLog(@"❌ GET error: %@", err); return nil; }

        NSURL *finalURL = resp.URL ?: u;
        if (outFinalURL) *outFinalURL = finalURL;

          // WITH:
          __block NSString *txt = nil;
          @autoreleasepool {
            if (data.length) txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
          }
          static NSUInteger kPreviewEvery = 0;
          if (txt.length && ((kPreviewEvery++ % 25) == 0)) {
            NSLog(@"📄 Playlist preview (sample):\n%@", IPTVSnip(txt, 180));
          }
        return txt;
      };


    // Index of the first segment AFTER the last #EXT-X-DISCONTINUITY in this playlist text
    NSInteger (^firstSegIndexAfterLastDiscontinuity)(NSString *) =
    ^NSInteger (NSString *text) {
      NSInteger anchorIdx = -1;
      NSInteger segIdx = -1; // becomes 0 at first URI
      for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"#EXT-X-DISCONTINUITY"]) {
          // next URI we see will be the first after this discontinuity
          anchorIdx = segIdx + 1;
        } else if (![line hasPrefix:@"#"]) {
          segIdx += 1; // count URIs only
        }
      }
      return anchorIdx; // -1 if none
    };

    // === BYTERANGE-aware parser (stable identity) ===
    NSArray<IPTVSeg *>* (^parseMedia)(NSString *, NSURL *, NSTimeInterval *) =
    ^NSArray<IPTVSeg *> * (NSString *text, NSURL *base, NSTimeInterval *targetOut) {
      NSMutableArray<IPTVSeg *> *arr = [NSMutableArray new];
      NSNumber *pending = nil; NSTimeInterval target = 2.0;
      NSInteger mediaSeq = 0; NSURL *currentKeyURL = nil; NSData *currentIV = nil;

      // BYTERANGE state per RFC: offset sticks if no @offset given
      NSString *pendingByteRangeLine = nil;
      uint64_t lastByteOffsetForURI = 0;

      for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length == 0) continue;

        if ([line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
          mediaSeq = [[line substringFromIndex:22] integerValue];

        } else if ([line hasPrefix:@"#EXT-X-TARGETDURATION:"]) {
          NSString *v = [line stringByReplacingOccurrencesOfString:@"#EXT-X-TARGETDURATION:" withString:@""];
          target = v.doubleValue > 0 ? v.doubleValue : target;

        } else if ([line hasPrefix:@"#EXT-X-KEY:"]) {
          NSString *params = [line substringFromIndex:11];
          NSString *method=nil,*uriStr=nil,*ivStr=nil;
          for (NSString *kv in [params componentsSeparatedByString:@","]) {
            NSArray *pair = [kv componentsSeparatedByString:@"="]; if (pair.count < 2) continue;
            NSString *k = [pair[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *v = [[pair subarrayWithRange:NSMakeRange(1, pair.count-1)] componentsJoinedByString:@"="];
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([v hasPrefix:@"\""] && [v hasSuffix:@"\""]) v = [v substringWithRange:NSMakeRange(1, v.length-2)];
            if      ([k isEqualToString:@"METHOD"]) method = v;
            else if ([k isEqualToString:@"URI"])    uriStr = v;
            else if ([k isEqualToString:@"IV"])     ivStr  = v;
          }
          if ([method isEqualToString:@"AES-128"] && uriStr.length) {
            NSURL *abs = [NSURL URLWithString:uriStr relativeToURL:base].absoluteURL;
            if (!abs.query.length && base.query.length && abs.host && [abs.host caseInsensitiveCompare:base.host] == NSOrderedSame) {
              NSURLComponents *cc = [NSURLComponents componentsWithURL:abs resolvingAgainstBaseURL:NO];
              cc.query = base.query; abs = cc.URL;
            }
            currentKeyURL = abs; currentIV = ivStr.length ? IPTVHexToData(ivStr) : nil;
          } else { currentKeyURL = nil; currentIV = nil; }

        } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
          pendingByteRangeLine = [line substringFromIndex:17];

        } else if ([line hasPrefix:@"#EXTINF:"]) {
          NSString *dStr = [[[line substringFromIndex:8] componentsSeparatedByString:@","].firstObject
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
          pending = @(dStr.doubleValue);

        } else if (![line hasPrefix:@"#"]) {
          if (pending) {
            NSURL *abs = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
            NSURL *finalURL = inheritQueryIfMissing(abs, base);

            uint64_t brLen = 0, brOff = 0; BOOL hasBR = NO;
            if (pendingByteRangeLine.length) {
              NSArray *parts = [pendingByteRangeLine componentsSeparatedByString:@"@"];
              brLen = (uint64_t)[parts[0] longLongValue];
              if (parts.count > 1) {
                brOff = (uint64_t)[parts[1] longLongValue];
                lastByteOffsetForURI = brOff + brLen;
              } else {
                brOff = lastByteOffsetForURI;
                lastByteOffsetForURI += brLen;
              }
              hasBR = (brLen > 0);
              pendingByteRangeLine = nil;
            }

            IPTVSeg *s = [IPTVSeg new];
            s.url = finalURL; s.dur = pending.doubleValue; s.seq = mediaSeq;
            s.keyURL = currentKeyURL; s.iv = currentIV;
            s.hasByteRange = hasBR; s.brLength = brLen; s.brOffset = brOff;

            // Stable identity for selection & disk cache (ignore query; include BYTERANGE)
              // Stable identity. For CMAF (same path, different ?query), include seq and qs hash.
              BOOL isCMAFLeaf = [[finalURL.pathExtension lowercaseString] isEqualToString:@"mp4"] ||
                                [finalURL.lastPathComponent.lowercaseString hasSuffix:@".m4s"];

              NSString *stableKey = IPTVStableKeyForURL(finalURL, hasBR, brLen, brOff);
              if (isCMAFLeaf && !hasBR) {
                NSString *qsHash = IPTVHash64(finalURL.query ?: @"");
                stableKey = [NSString stringWithFormat:@"%@#seq=%ld#q=%@", stableKey, (long)mediaSeq, qsHash];
              }
              s.name = [NSString stringWithFormat:@"seg_%@.ts", IPTVHash64(stableKey)];
              // NOTE: don't store per-segment duration in a dictionary; it grows on long VODs.
              [arr addObject:s];

            mediaSeq += 1;
          }
          pending = nil;
        }
      }
      if (targetOut) *targetOut = target;
      return arr;
    };

    NSURL* (^localPath)(NSString *) = ^NSURL* (NSString *name) { return [cacheDir URLByAppendingPathComponent:name]; };
      
      // === Lightweight TS validator (checks sync byte at 188*offsets for a few packets) ===
      BOOL (^isLikelyTS)(NSData *) = ^BOOL(NSData *d) {
        const NSUInteger TS_PKT = 188;
        if (d.length < TS_PKT) return NO;
        const uint8_t *p = d.bytes;
        NSUInteger checks = MIN((NSUInteger)5, d.length / TS_PKT);
        for (NSUInteger i = 0; i < checks; i++) {
          if (p[i * TS_PKT] != 0x47) return NO;
        }
        return YES;
      };


    // Range-aware downloader + EWMA
      NSURL* (^syncDownload)(IPTVSeg *) = ^NSURL* (IPTVSeg *seg) {
          if (isCancelled() || sessionClosed || session == nil) return nil;
        NSURL *dst = localPath(seg.name);
        if ([NSFileManager.defaultManager fileExistsAtPath:dst.path]) return dst;

        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:seg.url];
        // Carry important headers explicitly (even if cfg.HTTPAdditionalHeaders exists)
          // Carry headers, deriving Referer/Origin from the CURRENT playlistURL
          NSString *ua  = headers[@"User-Agent"] ?: @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1";
          NSString *ck  = headers[@"Cookie"];
          NSString *refNow = playlistURL.absoluteString ?: headers[@"Referer"];
          NSString *originNow = (playlistURL.host.length
            ? [NSString stringWithFormat:@"%@://%@", playlistURL.scheme ?: @"https", playlistURL.host]
            : nil);

          if (ua.length)       [rq setValue:ua        forHTTPHeaderField:@"User-Agent"];
          if (refNow.length)   [rq setValue:refNow    forHTTPHeaderField:@"Referer"];
          if (originNow.length)[rq setValue:originNow forHTTPHeaderField:@"Origin"];
          if (ck.length)       [rq setValue:ck        forHTTPHeaderField:@"Cookie"];
          [rq setValue:@"*/*"        forHTTPHeaderField:@"Accept"];
          [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
          [rq setValue:@"identity"   forHTTPHeaderField:@"Accept-Encoding"]; // avoid gzip on TS

        if (seg.hasByteRange) {
          uint64_t start = seg.brOffset;
          uint64_t end   = seg.brOffset + seg.brLength - 1;
          [rq setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", start, end]
      forHTTPHeaderField:@"Range"];
          NSLog(@"⬇️  Download (Range %@): %@", [rq valueForHTTPHeaderField:@"Range"], seg.url.absoluteString);
        } else {
          NSLog(@"⬇️  Download: %@", seg.url.absoluteString);
        }

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSURL *out = nil;

        [[session downloadTaskWithRequest:rq completionHandler:^(NSURL * _Nullable tmp,
                                                                NSURLResponse * _Nullable r,
                                                                NSError * _Nullable e) {
          NSHTTPURLResponse *hr = (NSHTTPURLResponse *)r;
          NSInteger code = hr.statusCode;
          NSString *leaf = seg.url.lastPathComponent ?: @"(no-leaf)";

          if (e) {
            NSLog(@"❌ Download error for %@: %@", leaf, e.localizedDescription);
            dispatch_semaphore_signal(sema);
            return;
          }

          if (![r isKindOfClass:NSHTTPURLResponse.class]) {
            NSLog(@"❌ No HTTP response for %@", leaf);
            dispatch_semaphore_signal(sema);
            return;
          }

          if (!(code >= 200 && code < 400)) {
            // 404/403/410 etc. → log and skip
            NSLog(@"⛔️ HTTP %ld on segment %@ (won’t save)", (long)code, leaf);
            dispatch_semaphore_signal(sema);
            return;
          }

          if (!tmp || isCancelled()) {
            dispatch_semaphore_signal(sema);
            return;
          }

          unsigned long long bytes = [[[NSFileManager defaultManager]
                                        attributesOfItemAtPath:tmp.path error:nil] fileSize];

          // Move to destination
          [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
          if ([NSFileManager.defaultManager moveItemAtURL:tmp toURL:dst error:nil]) {
            out = dst;

            CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
            double sec = MAX(0.001, t1 - t0);
            double inst_bps = ((double)bytes * 8.0) / sec;
            if (inst_bps > 0)
              tput_bps = (tput_bps <= 0) ? inst_bps : (abr_alpha * inst_bps + (1.0 - abr_alpha) * tput_bps);

            NSLog(@"📈 tput inst=%.0f, ewma=%.0f (bytes=%llu, sec=%.3f, file=%@)",
                  inst_bps, tput_bps, bytes, sec, leaf);
          } else {
            NSLog(@"❌ Failed to move tmp file for %@", leaf);
          }

          dispatch_semaphore_signal(sema);
        }] resume];

        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        return out;
      };


      NSData* (^loadSegmentBytes)(IPTVSeg *) = ^NSData* (IPTVSeg *seg) {
        if (isCancelled()) return nil;

        // 1) memory hit
        NSData *cached = memCache[seg.name];
        if (cached) {
          [memCache removeObjectForKey:seg.name];
            NSLog(@"💾 MEMHIT seq=%ld name=%@ bytes=%lu", (long)seg.seq, seg.name, (unsigned long)cached.length); // 👈 ADD LOG
          if (!isLikelyTS(cached)) {
            NSLog(@"⚠️ MEMCACHE: bytes for %@ don’t look like TS (sync byte fail)", seg.url.lastPathComponent);
          }
          return cached;
        }

        // 2) disk download (or hit)
        NSURL *fileURL = syncDownload(seg);
        if (!fileURL || isCancelled()) return nil;

          NSData *cipher = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:nil];
        [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
          
          NSLog(@"📀 DISKREAD seq=%ld name=%@ bytes=%lu", (long)seg.seq, seg.name, (unsigned long)cipher.length); // 👈 ADD LOG

          
        if (cipher.length == 0) {
          NSLog(@"⚠️ Empty segment file for %@", seg.url.lastPathComponent);
          return nil;
        }

        // 3) Decrypt if needed
        NSData *outBytes = cipher;
        if (seg.keyURL) {
            NSString *kKey = seg.keyURL.absoluteString;
            NSData *keyData = KeyCacheGet(kKey);

          if (!keyData) {
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            __block NSData *fetched = nil;
              if (isCancelled() || sessionClosed || session == nil) {
                  dispatch_semaphore_signal(sema);
                  NSLog(@"🔓 DECRYPT out bytes=%lu (hadKey=%d)", (unsigned long)outBytes.length, (seg.keyURL!=nil)); // 👈 ADD LOG
                  return outBytes; }

            [[session dataTaskWithURL:seg.keyURL completionHandler:^(NSData * _Nullable d,
                                                                     NSURLResponse * _Nullable r,
                                                                     NSError * _Nullable e) {
              fetched = d; dispatch_semaphore_signal(sema);
            }] resume];
            dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

              if (fetched.length == 16) { KeyCachePut(kKey, fetched); keyData = fetched; }
            else NSLog(@"⚠️ Key size invalid for %@: %lu", seg.keyURL.absoluteString, (unsigned long)fetched.length);
          }

          NSData *iv = seg.iv ?: IPTVIVFromSeq(seg.seq);
          if (keyData.length == 16 && iv.length == 16) {
            NSError *decErr = nil;
            NSData *plain = IPTVAES128CBCDecrypt(cipher, keyData, iv, &decErr);
            if (plain.length) outBytes = plain;
            else NSLog(@"❌ Decrypt failed for seq=%ld (%@): %@", (long)seg.seq, seg.url.lastPathComponent, decErr);
          } else {
            NSLog(@"⚠️ Missing key/iv for seq=%ld (%@); sending ciphertext", (long)seg.seq, seg.url.lastPathComponent);
          }
        }

        // 4) Validate it looks like TS and log outcome (don’t hard-fail; just log)
          // 4) Log validation appropriately for TS vs CMAF
          if (/* CMAF */ [seg.url.pathExtension.lowercaseString hasSuffix:@"mp4"] ||
              [seg.url.lastPathComponent.lowercaseString hasSuffix:@".m4s"]) {
            NSLog(@"✅ CMAF segment seq=%ld file=%@ len=%lu",
                  (long)seg.seq, seg.url.lastPathComponent, (unsigned long)outBytes.length);
          } else {
            if (!isLikelyTS(outBytes)) {
              NSLog(@"⚠️ Non-TS looking segment seq=%ld file=%@ (len=%lu) — will still send",
                    (long)seg.seq, seg.url.lastPathComponent, (unsigned long)outBytes.length);
            } else {
              NSLog(@"✅ TS OK seq=%ld file=%@ len=%lu",
                    (long)seg.seq, seg.url.lastPathComponent, (unsigned long)outBytes.length);
            }
          }


        return outBytes;
      };


    void (^prefetchIntoMemory)(IPTVSeg *) = ^(IPTVSeg *seg) {
        
        if (lastKnownIsVOD) return; // hard gate — remove after you confirm // 👈 TEMP GUARD
        
        if (!seg || isCancelled()) return;
        if (memCache[seg.name]) return;
        if ([prefetching containsObject:seg.name]) return;
        [prefetching addObject:seg.name];
        NSLog(@"🚚 PREFETCH schedule seq=%ld name=%@ (vod=%d)", (long)seg.seq, seg.name, lastKnownIsVOD);  // 👈 ADD LOG
        @autoreleasepool {
            dispatch_async(prefetchQ, ^{
                @autoreleasepool {
                    if (isCancelled()) { dispatch_async(streamQ, ^{ [prefetching removeObject:seg.name]; }); return; }
                    NSURL *fileURL = syncDownload(seg);
                    NSData *cipher = fileURL ? [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:nil] : nil;
                    if (fileURL) [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
                    
                    NSData *bytes = nil;
                    if (cipher.length) {
                        if (!seg.keyURL) {
                            bytes = cipher;
                        } else {
                            NSString *kKey = seg.keyURL.absoluteString;
                            NSData *keyData = KeyCacheGet(kKey);
                            
                            if (!keyData) {
                                dispatch_semaphore_t sema = dispatch_semaphore_create(0);
                                __block NSData *fetched = nil;
                                if (isCancelled() || sessionClosed || session == nil) { dispatch_semaphore_signal(sema); return; }
                                
                                [[session dataTaskWithURL:seg.keyURL completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
                                    fetched = d; dispatch_semaphore_signal(sema);
                                }] resume];
                                dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
                                if (fetched.length == 16) { KeyCachePut(kKey, fetched); keyData = fetched; }
                            }
                            NSData *iv = seg.iv ?: IPTVIVFromSeq(seg.seq);
                            if (keyData.length == 16 && iv.length == 16) {
                                NSError *decErr = nil;
                                NSData *plain = IPTVAES128CBCDecrypt(cipher, keyData, iv, &decErr);
                                bytes = plain.length ? plain : cipher;
                            } else {
                                bytes = cipher;
                            }
                        }
                    }
                    
                    dispatch_async(streamQ, ^{
                        NSLog(@"📥 PREFETCH done seq=%ld name=%@ bytes=%lu (willStore=%d)",
                              (long)seg.seq, seg.name, (unsigned long)bytes.length,
                              (!isCancelled() && bytes.length && !memCache[seg.name])); // 👈 ADD LOG
                        if (!isCancelled() && bytes.length && !memCache[seg.name]) {
                            memCache[seg.name] = bytes;
                            trimMemCache();
                            NSLog(@"🧹 trimMemCache → items=%lu", (unsigned long)memCache.count); // 👈 ADD LOG
                        }
                        [prefetching removeObject:seg.name];
                    });
                }
            });
        }
    };

    void (^sweepCache)(NSSet<NSString *> *) = ^(NSSet<NSString *> *keep) {
      dispatch_async(prefetchQ, ^{
        NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:cacheDir includingPropertiesForKeys:nil options:0 error:nil] ?: @[];
        for (NSURL *u in files) {
          if (![[u.pathExtension lowercaseString] isEqualToString:@"ts"]) continue;
          if (![keep containsObject:u.lastPathComponent]) {
            [NSFileManager.defaultManager removeItemAtURL:u error:nil];
          }
        }
      });
    };

    // ===== Streamed response (chunked, forward-only, cancellable) =====
      __block GCDWebServerStreamedResponse *resp =
      [GCDWebServerStreamedResponse responseWithContentType:@"video/vnd.dlna.mpeg-tts"
                                         asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock body) {

      __block BOOL ended = NO;
      __block int64_t pollNs = (int64_t)(0.15 * NSEC_PER_SEC);
      __block void (^pump)(void) = nil;
      __weak __block void (^weakPump)(void) = nil; // avoid retain cycle
        
//        // Detects a segment whose leaf name ends with "-00000.ts" OR "_00000.ts"
//        BOOL (^isZeroStartFile)(IPTVSeg *) = ^BOOL(IPTVSeg *seg) {
//          if (!seg || !seg.url) return NO;
//          NSString *leaf = seg.url.lastPathComponent.lowercaseString ?: @"";
//            NSLog(@"leaf: %@", leaf);
//          return ([leaf hasSuffix:@"-00000.ts"] || [leaf hasSuffix:@"_00000.ts"] || [leaf hasSuffix:@"00000.ts"]);
//        };
        
        // Treats ...-00000.ts and ...-00001.ts (and _ variants) as boundary starters.
        // Bump kZeroStartMax to 2 if you ever see providers skipping 00000 and 00001.
        static const NSInteger kZeroStartMax = 1;

        BOOL (^isZeroStartFile)(IPTVSeg *) = ^BOOL(IPTVSeg *seg) {
          if (!seg || !seg.url) return NO;
          NSString *leaf = seg.url.lastPathComponent.lowercaseString ?: @"";

          // Match trailing "-NNNNN.ts" or "_NNNNN.ts"
          static NSRegularExpression *re;
          static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
              re = [NSRegularExpression regularExpressionWithPattern:@"[\\-_](\\d{5})\\.(ts|m4s)$"
                                                             options:0
                                                               error:NULL];
            });

          NSTextCheckingResult *m = [re firstMatchInString:leaf options:0 range:NSMakeRange(0, leaf.length)];
          if (!m) return NO;

          NSRange numRange = [m rangeAtIndex:1];
          NSString *numStr = [leaf substringWithRange:numRange];
          NSInteger n = numStr.integerValue;

          BOOL boundary = (n <= kZeroStartMax);
          if (boundary) {
            NSLog(@"🧭 Boundary via zero-start filename: leaf=%@ n=%ld (≤ %ld)", leaf, (long)n, (long)kZeroStartMax);
          } else {
            NSLog(@"leaf: %@ (n=%ld)", leaf, (long)n);
          }
          return boundary;
        };
          
          void (^endStream)(void) = ^{
            if (ended) return;
            ended = YES;

            // Stop future scheduling immediately
            weakPump = nil;           // <- this is enough
            // pumpScheduled = NO;     // <- remove this line

            if (!sessionClosed && session) {
              sessionClosed = YES;
              [session getAllTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *tasks) {
                for (NSURLSessionTask *t in tasks) { [t cancel]; }
              }];
              [session invalidateAndCancel];
              session = nil;
            }

            curSegData = nil;
            [memCache removeAllObjects];
            [prefetching removeAllObjects];

            if (lastKnownIsVOD) {
              KeyCacheRemoveAll();
            }

            body([NSData data], nil);
            IPTVUnregisterCanceller(sid);
            dispatch_async(gSidQ, ^{ [gSidGen removeObjectForKey:sid]; });

            NSLog(@"⏹️  HLS session end sid=%@ gen=%ld", sid, (long)myGen);
          };



//          void (^endStream)(void) = ^{
//                  if (!ended) {
//                    ended = YES;
//                    [session invalidateAndCancel];
//                    body([NSData data], nil); // graceful end
//                    IPTVUnregisterCanceller(sid);
//
//                    NSLog(@"⏹️  HLS session end sid=%@ gen=%ld", sid, (long)myGen);
//                  }
//                };
          
          // Make a canceller that ends THIS stream immediately when /hls/stop arrives
          void (^cancelThisStream)(void) = ^{
            // Ensure we run on the connection’s stream queue to respect your state
            dispatch_async(streamQ, ^{
              // Flip generation too (belt-and-suspenders) so any future checks see cancellation
              dispatch_async(gSidQ, ^{
                NSInteger next = gSidGen[sid] ? gSidGen[sid].integerValue + 1 : 1;
                gSidGen[sid] = @(next);
              });
              // End gracefully
              endStream();
            });
          };
          IPTVRegisterCanceller(sid, cancelThisStream);


//          void (^endStream)(void) = ^{
//            if (!ended) {
//              ended = YES;
//
//              // Stop future scheduling immediately
//              weakPump = nil;
//
//              // Cancel/close the session so late network calls no-op
//                if (!sessionClosed && session) {
//                  sessionClosed = YES;
//                  [session getAllTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *tasks) {
//                    NSLog(@"🛑 endStream: outstandingTasks=%lu", (unsigned long)tasks.count); // 👈 ADD LOG
//                  }];
//                  [session invalidateAndCancel];
//                  session = nil;
//                }
//
//
//              // Drop big buffers so ARC can free now
//                // Drop big buffers so ARC can free now
//                curSegData = nil;
//                [memCache removeAllObjects];
//                [prefetching removeAllObjects];
//
//                // VOD tends to have unique key URLs — purge between sessions
//                if (lastKnownIsVOD) {
//                  KeyCacheRemoveAll();
//                }
//
////                body(nil, nil);
//                body([NSData data], nil); // graceful end
//                NSLog(@"⏹️  HLS session end sid=%@ gen=%ld", sid, (long)myGen);
//
//                // Avoid gSidGen growing forever
//                dispatch_async(gSidQ, ^{ [gSidGen removeObjectForKey:sid]; });
//            }
//          };

          
          // Pace the next pump, but guarantee only ONE pending wake-up at a time.
          // LIVE → delaySec=0.0 (immediate). VOD → small paced delays per chunk.
          __block BOOL pumpScheduled = NO;
          void (^scheduleNext)(NSTimeInterval) = ^(NSTimeInterval delaySec) {
            if (!weakPump) return;
            if (pumpScheduled) return;               // prevent back-pressure by timer piling
            pumpScheduled = YES;

            int64_t ns = (int64_t)(MAX(0.0, delaySec) * NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), streamQ, ^{
              pumpScheduled = NO;
              if (weakPump) weakPump();
            });
          };




      pump = ^{
        @autoreleasepool {
            
            static uint64_t loopNo = 0; loopNo++;
            NSUInteger memItems = memCache.count;
            __block size_t memBytes = 0;
            [memCache enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSData *v, BOOL *stop){
              memBytes += v.length;
            }];
            NSLog(@"🧠 MEM SNAPSHOT loop=%llu curSeg=%@ pos=%lu len=%lu memCache=%lu items=%lu bytes prefetching=%lu vod=%d",
                  loopNo, lastServedName, (unsigned long)curSegPos, (unsigned long)curSegData.length,
                  (unsigned long)memItems, (unsigned long)memBytes, (unsigned long)prefetching.count, lastKnownIsVOD);   // 👈 ADD LOG

            
            // CMAF/fMP4 constants (locals)
            const NSUInteger MP4_CHUNK    = 64 * 1024; // 64 KiB
            const NSUInteger TS_PKT_LOCAL = 188;       // for TS alignment
            
            // For VOD only: delay a tiny bit per chunk so the whole segment takes ~dur to send.
            // This prevents socket/cfnetwork buffers from growing without adding big latency.
            NSTimeInterval (^vodChunkDelay)(NSUInteger, NSUInteger, NSTimeInterval) =
            ^NSTimeInterval(NSUInteger chunkBytes, NSUInteger segBytes, NSTimeInterval segDur) {
              if (segDur <= 0.0 || segBytes == 0 || chunkBytes == 0) return 0.0;
              double d = segDur * ((double)chunkBytes / (double)segBytes);
              if (d < 0.001) d = 0.001;    // 1 ms floor (keeps the pump breathing)
              if (d > 0.050) d = 0.050;    // 50 ms cap (keeps it responsive)
              return (NSTimeInterval)d;
            };


            
          if (isCancelled()) { NSLog(@"🚫 cancelled sid=%@ gen=%ld", sid, (long)myGen); endStream(); return; }

          // 1) Drain current segment (TS-aligned)
          if (curSegData && curSegPos < curSegData.length) {
            NSUInteger remain = curSegData.length - curSegPos;
              NSUInteger toSend = MIN((isCMAFStream ? MP4_CHUNK : chunkSize), remain);
              if (!isCMAFStream) {
                if (toSend >= TS_PKT_LOCAL) toSend -= (toSend % TS_PKT_LOCAL);
                if (toSend == 0 && remain < TS_PKT_LOCAL) toSend = remain;
              }


              @autoreleasepool {
                NSData *chunk = [curSegData subdataWithRange:NSMakeRange(curSegPos, toSend)];
                curSegPos += toSend;
                if (isCancelled()) { endStream(); return; }
                body(chunk, nil);
              }


            NSLog(@"🏁 CHUNK: seg=%@ seq=%ld sent=%luB pos=%lu/%lu",
                  lastServedName, (long)lastSeq,
                  (unsigned long)toSend, (unsigned long)curSegPos, (unsigned long)curSegData.length);

              if (curSegPos >= curSegData.length) {
                  NSLog(@"🏁 SEG END name=%@ seq=%ld (bytes=%lu)",
                        lastServedName, (long)lastSeq, (unsigned long)curSegData.length);

                  curSegData = nil;
                  curSegPos  = 0;

                  if (servedLastOfVOD) {
                    NSLog(@"🏁 VOD complete — last segment drained; ending stream");
                    endStream();
                    return;
                  }

                  // For VOD: move immediately to the next segment (no extra sleep).
                  // For LIVE: you can keep a tiny delay if you want, but don’t tie it to full seg duration.
                  NSTimeInterval boundaryDelay = lastKnownIsVOD ? 0.0 : 0.0; // or 0.1 for live if you prefer
                  scheduleNext(boundaryDelay);
                  return;
              }


              // Still draining the same segment:
              //  - LIVE: immediate
              //  - VOD:  small per-chunk delay so the whole seg takes ~dur to send
//              if (lastKnownIsVOD) {
//                scheduleNext(vodChunkDelay(toSend, curSegData.length, lastSegDur));
//              } else {
//                scheduleNext(0.0);
//              }
              scheduleNext(vodChunkDelay(toSend, curSegData.length, MAX(lastSegDur, 0.5)));

              return;

          }

          if (isCancelled()) { endStream(); return; }

          // 2) Resolve master → best variant
            // 2) Resolve master → best variant   (REPLACED)
            NSURL *finalAfterFetch = nil;
            // First fetch once; we’ll reuse this if it is already a media playlist
            NSString *firstFetch = fetchTextFinal(playlistURL, &finalAfterFetch);

            if (finalAfterFetch &&
                ![[finalAfterFetch.host lowercaseString] isEqualToString:[playlistURL.host lowercaseString]]) {
              NSLog(@"↪️ Playlist host changed via redirect: %@ → %@", playlistURL.host, finalAfterFetch.host);
              playlistURL = finalAfterFetch;
            }

            BOOL isMaster = (firstFetch.length && [firstFetch containsString:@"#EXT-X-STREAM-INF"]);
            if (isMaster && !variantLocked) {
              IPTVLogMasterAVSummary(firstFetch, playlistURL);

              double allowed = (tput_bps > 0.0) ? (tput_bps / 1.5) : 0.0;
              NSInteger best720BW = -1, bestAnyBW = -1;
              NSURL *best720URL = nil, *bestAnyURL = nil;

              NSArray<NSString *> *lines = [firstFetch componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
              NSLog(@"──────── Master variants @ host=%@ ────────", playlistURL.host ?: @"(nil)");
              for (NSInteger i = 0; i < lines.count; i++) {
                NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;

                NSInteger bw = -1, height = -1;
                NSRange abr = [line rangeOfString:@"AVERAGE-BANDWIDTH="];
                if (abr.location != NSNotFound) {
                  NSString *rest = [line substringFromIndex:abr.location + abr.length];
                  NSString *num  = [[rest componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]] firstObject];
                  bw = num.integerValue;
                } else {
                  NSRange br = [line rangeOfString:@"BANDWIDTH="];
                  if (br.location != NSNotFound) {
                    NSString *rest = [line substringFromIndex:br.location + br.length];
                    NSString *num  = [[rest componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]] firstObject];
                    bw = num.integerValue;
                  }
                }
                NSRange rr = [line rangeOfString:@"RESOLUTION="];
                if (rr.location != NSNotFound) {
                  NSString *rest = [line substringFromIndex:rr.location + rr.length];  // "WxH,…"
                  NSString *val  = [[rest componentsSeparatedByString:@","] firstObject];
                  NSArray *wh = [val componentsSeparatedByString:@"x"];
                  if (wh.count == 2) height = [wh[1] integerValue];
                }

                if (i + 1 >= lines.count) continue;
                NSString *nextLine = [lines[i+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([nextLine hasPrefix:@"#"]) continue;

                NSURL *abs = [NSURL URLWithString:nextLine relativeToURL:playlistURL].absoluteURL;
                abs = inheritQueryIfMissing(abs, playlistURL);

                if (height < 0) {
                  NSString *leaf = abs.lastPathComponent.lowercaseString ?: @"";
                  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(^|[^0-9])720([^0-9]|$)" options:0 error:NULL];
                  if ([re firstMatchInString:leaf options:0 range:NSMakeRange(0, leaf.length)]) height = 720;
                }

                if (hardCapBw > 0 && bw > hardCapBw) continue;
                if (allowed > 0 && bw > (NSInteger)llround(allowed)) continue;

                if (height == 720 && bw > best720BW) { best720BW = bw; best720URL = abs; }
                if (bw > bestAnyBW) { bestAnyBW = bw; bestAnyURL = abs; }
              }

              NSURL *varURL = best720URL ?: bestAnyURL;
              if (!varURL) varURL = IPTVVariantBestForBw(firstFetch, playlistURL, hardCapBw, allowed);

              if (varURL) {
                NSLog(@"🎚️ Variant selected (prefer 720, else highest): %@", varURL.absoluteString);
                playlistURL   = varURL;
                variantLocked = YES;
              }
            }

            // 3) Fetch & parse media   (REUSED firstFetch when not master)
            finalAfterFetch = nil;
            NSString *txt = isMaster ? fetchTextFinal(playlistURL, &finalAfterFetch) : firstFetch;
            if (finalAfterFetch &&
                ![[finalAfterFetch.host lowercaseString] isEqualToString:[playlistURL.host lowercaseString]]) {
              NSLog(@"↪️ Media host changed via redirect: %@ → %@", playlistURL.host, finalAfterFetch.host);
              playlistURL = finalAfterFetch;
            }

            
            // Detect VOD vs LIVE; allow manual override via ?mode=
            BOOL isVOD = ([txt rangeOfString:@"#EXT-X-ENDLIST"].location != NSNotFound);
            NSString *mode = IPTVQueryValue(req, @"mode");
            if ([mode isEqualToString:@"vod"])  isVOD = YES;
            if ([mode isEqualToString:@"live"]) isVOD = NO;

            lastKnownIsVOD = isVOD;

            // ✅ Prevent memory growth on VOD
            if (lastKnownIsVOD) {
              NSInteger old = prefetchAhead;
              prefetchAhead = 0;
              if (old != 0) NSLog(@"🧊 VOD: forcing prefetchAhead=0 (was %ld)", (long)old); // 👈 ADD LOG
            }


            
            if (finalAfterFetch && ![[finalAfterFetch.host lowercaseString] isEqualToString:[playlistURL.host lowercaseString]]) {
              NSLog(@"↪️ Media host changed via redirect: %@ → %@", playlistURL.host, finalAfterFetch.host);
              playlistURL = finalAfterFetch; // use final media URL as Referer/Origin for segments
            }

          if (isCancelled()) { endStream(); return; }
          if (txt.length == 0) { if (weakPump) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollNs), streamQ, weakPump); return; }

          
            IPTVPlaylistFlags flags = IPTVDetectFlags(txt);
            if ((flags & IPTVFlagCMAF) && !isCMAFStream) {
              isCMAFStream = YES;
              mapURL = parseMapURI(txt, playlistURL);
              mapSent = NO;
              // flip response content-type to mp4 for CMAF
              dispatch_async(dispatch_get_main_queue(), ^{
                resp.contentType = @"video/mp4";
              });
              NSLog(@"🎞️ CMAF detected on %@ (MAP=%@)", playlistURL, mapURL.absoluteString);
            }


          // Do not eagerly reset on discontinuity; only re-anchor when forward selection fails.
          NSTimeInterval target = 2.0;
          NSArray<IPTVSeg *> *segs = parseMedia(txt, playlistURL, &target);
          if (segs.count == 0) { if (weakPump) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollNs), streamQ, weakPump); return; }

          // Locate first segment AFTER the last discontinuity in this text (if any)
          NSInteger anchorIdx = firstSegIndexAfterLastDiscontinuity(txt);

          // --- LOG playlist window & tail candidacy (safe: anchorIdx defined here)
          NSInteger lastServedIdx = NSNotFound;
          if (lastServedName) {
            lastServedIdx = [segs indexOfObjectPassingTest:^BOOL(IPTVSeg * _Nonnull s, NSUInteger i, BOOL * _Nonnull stop) {
              return [s.name isEqualToString:lastServedName];
            }];
          }
          BOOL lastServedIsTail = (lastServedIdx != NSNotFound && lastServedIdx == (NSInteger)segs.count - 1);
          NSInteger windowFirst = segs.firstObject ? segs.firstObject.seq : -1;
          NSInteger windowLast  = segs.lastObject  ? segs.lastObject.seq  : -1;

          NSLog(@"▶️ WINDOW: firstSeq=%ld lastSeq=%ld count=%lu anchorIdx=%ld lastServedIdx=%ld atTail=%d lastSeqMark=%ld",
                (long)windowFirst, (long)windowLast, (unsigned long)segs.count,
                (long)anchorIdx, (long)lastServedIdx, lastServedIsTail, (long)lastSeq);

            // This is For 2 behind tail, may be we have to change for Pluto
            
            NSInteger tailIdx = (NSInteger)segs.count - 1;
            NSInteger liveStartIdx = MAX(tailIdx - MAX(lagSegments, 2), 0); // start ~2 behind tail
            
            // If CMAF: ensure init segment is sent once before media
            if (isCMAFStream && !mapSent) {
              if (mapURL) {
                NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:mapURL];
                [rq setValue:effUA forHTTPHeaderField:@"User-Agent"];
                [rq setValue:playlistURL.absoluteString forHTTPHeaderField:@"Referer"];
                if (effCookie.length) [rq setValue:effCookie forHTTPHeaderField:@"Cookie"];
                [rq setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

                dispatch_semaphore_t sema = dispatch_semaphore_create(0);
                __block NSData *initData = nil;
                [[session dataTaskWithRequest:rq completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
                  if (!e && d.length) initData = d;
                  dispatch_semaphore_signal(sema);
                }] resume];
                dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
                  
                  NSDictionary *probe = IPTVQuickISOBMFFProbe(initData);
                  BOOL hasV = [probe[@"hasVideo"] boolValue];
                  BOOL hasA = [probe[@"hasAudio"] boolValue];
                  NSArray *vcs = probe[@"videoCodecs"];
                  NSArray *acs = probe[@"audioCodecs"];
                  NSLog(@"🔎 CMAF init probe: video=%d (%@) audio=%d (%@)",
                        hasV, (vcs.count ? [vcs componentsJoinedByString:@","] : @"-"),
                        hasA, (acs.count ? [acs componentsJoinedByString:@","] : @"-"));


                if (initData.length) {
                  NSUInteger pos = 0;
                  while (pos < initData.length) {
                    NSUInteger toSend = MIN(MP4_CHUNK, initData.length - pos);
                    if (isCancelled()) { endStream(); return; }
                    body([initData subdataWithRange:NSMakeRange(pos, toSend)], nil);
                    pos += toSend;
                  }
                  NSLog(@"🧩 Sent CMAF init (MAP) bytes=%lu", (unsigned long)initData.length);
                    NSLog(@"🧩 CMAF MAP sent bytes=%lu (mapSent=%d)", (unsigned long)initData.length, mapSent); // 👈 ADD LOG

                } else {
                  NSLog(@"⚠️ CMAF init (MAP) missing/empty");
                }
              } else {
                NSLog(@"⚠️ CMAF detected but no #EXT-X-MAP found");
              }
              mapSent = YES;
            }



          // 4) Forward-only selection
          NSLog(@"🔎 PICK attempt: lastServedName=%@ lastSeq=%ld memCache=%lu prefetching=%lu lag=%ld",
                lastServedName, (long)lastSeq,
                (unsigned long)memCache.count, (unsigned long)prefetching.count, (long)lagSegments);

          IPTVSeg *serve = nil; NSInteger serveIdx = -1;

          // (A) Continue from lastServedName → next index in the current list
          if (lastServedName) {
            NSInteger idx = [segs indexOfObjectPassingTest:^BOOL(IPTVSeg * _Nonnull s, NSUInteger i, BOOL * _Nonnull stop) {
              return [s.name isEqualToString:lastServedName];
            }];
              if (idx != NSNotFound && idx + 1 < (NSInteger)segs.count) {
                IPTVSeg *nextSeg = segs[idx + 1];

                // If the "next" URI is a new window starter like *-00000.ts, do a micro-reset
                if (isZeroStartFile(nextSeg)) {
                  NSLog(@"🧭 Boundary detected via zero-start filename → micro-reset before serving %@", nextSeg.url.absoluteString);

                  // --- micro-reset (do NOT touch keyCache, session, playlistURL, etc.)
                  curSegData = nil;
                  curSegPos  = 0;
                  [memCache removeAllObjects];
                  [prefetching removeAllObjects];
                    trimMemCache();
                  lastServedName = nil;
                  lastSeq = -1;

                  // Optional but recommended:
                  tput_bps = 0.0;

                  // Now begin exactly at the boundary segment
                  serveIdx = idx + 1;
                  serve = nextSeg;
                } else {
                  // Normal happy path
                  serveIdx = idx + 1;
                  serve = nextSeg;
                }
              }

          }

            // (B) Fresh start: start from very first segment or discontinuity anchor
//            if (!serve && lastSeq < 0 && !lastServedName) {
//                NSInteger startIdx = (anchorIdx >= 0) ? anchorIdx : 0;
//                serveIdx = startIdx; serve = segs[serveIdx];
//                NSLog(@"🎯 Starting at idx=%ld name=%@ seq=%ld url=%@",
//                      (long)serveIdx, serve.name, (long)serve.seq, serve.url.absoluteString);
//            }
            
            // For live - 2
            
            // (B) Fresh start: LIVE → near tail; VOD → from start (or after last DISCONTINUITY)
            if (!serve && lastSeq < 0 && !lastServedName) {
                NSInteger startIdx;
                if (isVOD) {
                    startIdx = (anchorIdx >= 0) ? anchorIdx : 0;  // VOD from top
                } else {
                    startIdx = liveStartIdx;                       // LIVE a bit behind tail
                }
                serveIdx = startIdx; serve = segs[serveIdx];

                // Prime strict-forward for next loop
                lastSeq = segs[serveIdx].seq - 1;

                NSLog(@"🎯 Starting %@ at idx=%ld name=%@ seq=%ld url=%@",
                      (isVOD ? @"VOD" : @"LIVE"),
                      (long)serveIdx, serve.name, (long)serve.seq, serve.url.absoluteString);
            }




//            // (C) Strict forward by sequence watermark — with zero-start boundary override
//            if (!serve && lastSeq >= 0) {
//              NSInteger wantSeq = lastSeq + 1;
//
//              // strict-forward candidate (by seq)
//              NSInteger candIdx = -1;
//              for (NSInteger i = 0; i < (NSInteger)segs.count; i++) {
//                if (segs[i].seq == wantSeq) { candIdx = i; break; }
//              }
//
//              // look for a zero-start filename (e.g., *-00000.ts or *_00000.ts)
//              NSInteger zeroIdx = -1;
//              for (NSInteger i = 0; i < (NSInteger)segs.count; i++) {
//                if (isZeroStartFile(segs[i])) { zeroIdx = i; break; }
//              }
//
//              // If we see a new window start, prefer it when:
//              //  - strict-forward isn't available (candIdx < 0), or
//              //  - zero-start precedes the strict-forward candidate (window rollover), or
//              //  - we were at the tail (typical boundary rollover case).
//              BOOL didBoundaryReset = NO;
//              if (zeroIdx >= 0 && (candIdx < 0 || zeroIdx < candIdx || lastServedIsTail)) {
//                NSLog(@"🧭 Boundary detected via zero-start filename → micro-reset before serving %@", segs[zeroIdx].url.absoluteString);
//
//                // micro-reset (do NOT touch keyCache/session/playlistURL)
//                curSegData = nil; curSegPos = 0;
//                [memCache removeAllObjects];
//                [prefetching removeAllObjects];
//                lastServedName = nil; lastSeq = -1;
//                tput_bps = 0.0; [durByName removeAllObjects];
//
//                serveIdx = zeroIdx; serve = segs[serveIdx];
//                didBoundaryReset = YES;
//              }
//
//              if (!didBoundaryReset) {
//                if (candIdx >= 0) {
//                  serveIdx = candIdx; serve = segs[serveIdx];
//                  NSLog(@"[C] Taking strict-forward candidate i=%ld (%@)",
//                        (long)serveIdx, segs[serveIdx].url.lastPathComponent);
//                } else {
//                  // wanted seq not yet in the window → wait
//                  if (weakPump) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollNs), IPTVStreamQueue, weakPump);
//                  return;
//                }
//              }
//            }
            
            
            // (C) Strict forward by sequence watermark — with zero-start boundary override
            if (!serve && lastSeq >= 0) {
              NSInteger wantSeq = lastSeq + 1;

              // strict-forward candidate (by seq)
              NSInteger candIdx = -1;
              for (NSInteger i = 0; i < (NSInteger)segs.count; i++) {
                if (segs[i].seq == wantSeq) { candIdx = i; break; }
              }

              // look for a zero-start filename (e.g., *-00000.ts or *_00000.ts)
              NSInteger zeroIdx = -1;
              for (NSInteger i = 0; i < (NSInteger)segs.count; i++) {
                if (isZeroStartFile(segs[i])) { zeroIdx = i; break; }
              }

              // If we see a new window start, prefer it…
              BOOL didBoundaryReset = NO;
              if (zeroIdx >= 0 && (candIdx < 0 || zeroIdx < candIdx || lastServedIsTail)) {
                NSLog(@"🧭 Boundary detected via zero-start filename → micro-reset before serving %@", segs[zeroIdx].url.absoluteString);
                curSegData = nil; curSegPos = 0;
                [memCache removeAllObjects];
                [prefetching removeAllObjects];
                  trimMemCache();
                lastServedName = nil; lastSeq = -1;
                tput_bps = 0.0;
                serveIdx = zeroIdx; serve = segs[serveIdx];
                didBoundaryReset = YES;
              }

              // 🔽🔽🔽 INSERT THIS BLOCK 🔽🔽🔽
              // If the sequence we want is already older than the live window,
              // snap forward near the tail instead of waiting forever.
                // Snap forward only for LIVE/event (never for VOD)
                if (!didBoundaryReset && !isVOD && candIdx < 0 && wantSeq < windowFirst) {
                  serveIdx = liveStartIdx;
                  serve = segs[serveIdx];
                  lastSeq = segs[serveIdx].seq - 1;
                  NSLog(@"⚡ SNAP (LIVE): wantSeq=%ld < firstSeq=%ld → re-anchor at idx=%ld (seq=%ld)",
                        (long)wantSeq, (long)windowFirst, (long)serveIdx, (long)segs[serveIdx].seq);
                }
              // 🔼🔼🔼 INSERTION ENDS 🔼🔼🔼

              if (!didBoundaryReset) {
                if (serve) {
                  // we snapped above; continue
                } else if (candIdx >= 0) {
                  serveIdx = candIdx; serve = segs[serveIdx];
                  NSLog(@"[C] Taking strict-forward candidate i=%ld (%@)",
                        (long)serveIdx, segs[serveIdx].url.lastPathComponent);
                } else {
                  // wanted seq not yet in the window → wait
                  if (weakPump) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollNs), streamQ, weakPump);
                  return;
                }
              }
            }




            // (D) Re-anchor at boundary if needed (only at tail + boundary)
//            if (!serve) {
//                BOOL prevNameMissing = NO;
//                if (lastServedName) {
//                    NSInteger idxPrev = [segs indexOfObjectPassingTest:^BOOL(IPTVSeg * _Nonnull s, NSUInteger i, BOOL * _Nonnull stop) {
//                        return [s.name isEqualToString:lastServedName];
//                    }];
//                    prevNameMissing = (idxPrev == NSNotFound);
//                }
//
//                if (lastServedIsTail && (anchorIdx >= 0 || prevNameMissing)) {
//                    // Reset forward-only markers and drop in-flight buffers
//                    curSegData = nil; curSegPos = 0;
//                    [memCache removeAllObjects];
//                    [prefetching removeAllObjects];
//                    lastSeq = -1; lastServedName = nil;
//
//                    NSInteger idxPick = (anchorIdx >= 0) ? anchorIdx : 0;
//                    if (idxPick < 0 || idxPick >= (NSInteger)segs.count) idxPick = 0;
//
//                    serveIdx = idxPick; serve = segs[serveIdx];
//                    NSLog(@"⚡ RESET: reason=boundary anchorIdx=%ld prevNameMissing=%d → idx=%ld seq=%ld url=%@",
//                          (long)anchorIdx, prevNameMissing, (long)serveIdx, (long)serve.seq, serve.url.absoluteString);
//                }
//            }


          if (!serve) { if (weakPump) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollNs), streamQ, weakPump); return; }

            NSLog(@"🎬 PICKED: idx=%ld seq=%ld name=%@ dur=%.3f key=%@",
                  (long)serveIdx, (long)serve.seq, serve.name, serve.dur,
                  serve.keyURL.absoluteString ?: @"-");

            lastSegDur = (serve.dur > 0.0) ? serve.dur : 0.4;  // <<< capture once per picked segment
            
            NSLog(@"⏱️ PACE nextDelay=%0.3f (vod=%d)", (lastKnownIsVOD ? lastSegDur : 0.0), lastKnownIsVOD); // 👈 ADD LOG

            
            lastPickIdx = serveIdx;
            servedLastOfVOD = (isVOD && serveIdx == (NSInteger)segs.count - 1);


          // 5) Prefetch ahead
          if (prefetchAhead > 0) {
            NSMutableArray<NSNumber *> *plan = [NSMutableArray array];
            for (NSInteger k = 1; k <= prefetchAhead; k++) {
              NSInteger nxt = serveIdx + k;
              if (nxt < (NSInteger)segs.count) {
                [plan addObject:@(segs[nxt].seq)];
                prefetchIntoMemory(segs[nxt]);
              }
            }
            if (plan.count) {
              NSLog(@"📦 PREFETCH plan nextSeqs=%@", plan);
            }
          }

          // 6) Load & assign
          NSData *bytes = loadSegmentBytes(serve);
          if (!bytes.length) { if (weakPump) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, pollNs), streamQ, weakPump); return; }

          curSegData = bytes; curSegPos = 0; lastServedName = serve.name; lastSeq = serve.seq;
          NSLog(@"📤 SERVE start name=%@ seq=%ld dur=%.3f %@%@ (memCache=%lu prefetching=%lu)",
                serve.name, (long)serve.seq, serve.dur,
                serve.hasByteRange ? @"range=" : @"",
                serve.hasByteRange ? [NSString stringWithFormat:@"%llu@%llu",
                  (unsigned long long)serve.brLength,(unsigned long long)serve.brOffset] : @"",
                (unsigned long)memCache.count, (unsigned long)prefetching.count);

          // 7) First chunk
          NSUInteger remain = curSegData.length - curSegPos;
            NSUInteger toSend = MIN((isCMAFStream ? MP4_CHUNK : chunkSize), remain);
            if (!isCMAFStream) {
              if (toSend >= TS_PKT_LOCAL) toSend -= (toSend % TS_PKT_LOCAL);
              if (toSend == 0 && remain < TS_PKT_LOCAL) toSend = remain;
            }


          if (isCancelled()) { endStream(); return; }
            @autoreleasepool {
              NSData *chunk = [curSegData subdataWithRange:NSMakeRange(curSegPos, toSend)];
              curSegPos += toSend;
              body(chunk, nil);
            }


          NSLog(@"🏁 CHUNK: seg=%@ seq=%ld sent=%luB pos=%lu/%lu",
                lastServedName, (long)lastSeq,
                (unsigned long)toSend, (unsigned long)curSegPos, (unsigned long)curSegData.length);

            if (curSegPos >= curSegData.length) {
              NSLog(@"🏁 SEG END name=%@ seq=%ld (bytes=%lu)",
                    lastServedName, (long)lastSeq, (unsigned long)curSegData.length);
              curSegData = nil;
              curSegPos  = 0;

              if (servedLastOfVOD) {
                  NSLog(@"🏁 VOD complete — last segment drained; ending stream");
                  endStream();
                  return;
              }

              NSTimeInterval boundaryDelay = lastKnownIsVOD ? 0.0 : 0.0; // again, tiny delay for LIVE if you want
              scheduleNext(boundaryDelay);
              return;
            }

            // First chunk sent → for VOD don’t drip, just keep going; LIVE can still be paced.
            NSTimeInterval delay;
            if (lastKnownIsVOD) {   
              delay = 0.0;   // send next chunk immediately
            } else {
              delay = vodChunkDelay(toSend, curSegData.length, lastSegDur);
            }
            scheduleNext(delay);



          // Sweep disk cache
          NSMutableSet *keep = [NSMutableSet set];
          for (NSInteger k = 1; k <= prefetchAhead; k++) { NSInteger nxt = serveIdx + k; if (nxt < (NSInteger)segs.count) [keep addObject:segs[nxt].name]; }
          sweepCache(keep);
        }
      };

      weakPump = pump;
      dispatch_async(streamQ, pump);
    }];

    // DLNA / streaming friendly headers
    [resp setValue:@"Streaming" forAdditionalHeader:@"transferMode.dlna.org"];
    [resp setValue:@"DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000" forAdditionalHeader:@"contentFeatures.dlna.org"];
    [resp setValue:@"no-store, no-cache, must-revalidate" forAdditionalHeader:@"Cache-Control"];
    [resp setValue:@"no-cache" forAdditionalHeader:@"Pragma"];
    [resp setValue:@"0" forAdditionalHeader:@"Expires"];
    [resp setValue:@"keep-alive" forAdditionalHeader:@"Connection"];

    done(resp);
  }];
}


// === Global segment memcache (bytes) ===
static NSCache<NSString *, NSData *> *gSegMemCache;
static dispatch_queue_t gSegCacheQ;
static dispatch_once_t gSegCacheOnce;

static inline NSString *IPTVCacheKeyForURL(NSURL *u) {
  // key only on absolute URL (cookie/UA/ref affect fetch auth, not identity)
  return u.absoluteString ?: @"";
}

static void IPTVPrefetchURL(NSURL *u, NSString *ua, NSString *ref, NSString *cookie) {
  if (!u) return;
  dispatch_once(&gSegCacheOnce, ^{
    gSegMemCache = [NSCache new];
    gSegMemCache.totalCostLimit = 8 * 1024 * 1024; // ~8 MB
    gSegCacheQ = dispatch_queue_create("iptv.seg.cache.q", DISPATCH_QUEUE_CONCURRENT);
  });

  NSString *key = IPTVCacheKeyForURL(u);
  if (!key.length) return;

  // Dedup simple: if exists, skip
  if ([gSegMemCache objectForKey:key]) return;

  // Fire-and-forget prefetch in background with a separate session
  dispatch_async(gSegCacheQ, ^{
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPMaximumConnectionsPerHost = 8;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:20.0];
    NSString *uaDefault = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1";
    NSString *effUA = ua.length ? ua : uaDefault;

    // Referer/Origin from ref (if valid), else fall back to segment URL
    NSString *effRef = ref.length ? ref : u.absoluteString;
    NSString *effOrigin = nil;
    NSURL *refURL = [NSURL URLWithString:effRef];
    if (refURL.scheme.length && refURL.host.length) {
      effOrigin = [NSString stringWithFormat:@"%@://%@", refURL.scheme, refURL.host];
    }

    [rq setValue:effUA forHTTPHeaderField:@"User-Agent"];
    [rq setValue:effRef forHTTPHeaderField:@"Referer"];
    if (effOrigin.length) [rq setValue:effOrigin forHTTPHeaderField:@"Origin"];
    if (cookie.length) [rq setValue:cookie forHTTPHeaderField:@"Cookie"];
    [rq setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    [rq setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    NSLog(@"📥 PREFETCH %@", u.absoluteString);
    [[sess dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (data.length && !error) {
        [gSegMemCache setObject:data forKey:key cost:data.length];
        NSLog(@"✅ PREFETCH ok len=%lu %@", (unsigned long)data.length, u.lastPathComponent);
      } else {
        NSLog(@"⚠️ PREFETCH fail %@ (%@)", u.lastPathComponent, error.localizedDescription);
      }
      [sess finishTasksAndInvalidate];
    }] resume];
  });
}

static BOOL IPTVParseContentRangeHeader(NSString *cr,
                                        unsigned long long *start,
                                        unsigned long long *end,
                                        unsigned long long *total) {
  // Example: "bytes 123-456/7890"
  if (cr.length == 0) return NO;
  NSScanner *sc = [NSScanner scannerWithString:cr];
  [sc scanString:@"bytes " intoString:NULL];

  unsigned long long s=0,e=0,t=0;
  if (![sc scanUnsignedLongLong:&s]) return NO;
  if (![sc scanString:@"-" intoString:NULL]) return NO;
  if (![sc scanUnsignedLongLong:&e]) return NO;
  if (![sc scanString:@"/" intoString:NULL]) return NO;
  if (![sc scanUnsignedLongLong:&t]) return NO;

  if (start) *start = s;
  if (end)   *end   = e;
  if (total) *total = t;
  return (e >= s);
}


static BOOL IPTVParseRangeHeader(NSDictionary *headers,
                                 unsigned long long *outStart,
                                 unsigned long long *outEnd,
                                 NSString **outRawHeader) {
  // Grab header case-insensitively
  id v = headers[@"Range"];
  if (!v) v = headers[@"range"];
  if (outRawHeader) *outRawHeader = ([v isKindOfClass:NSString.class] ? (NSString *)v : nil);

  if (![v isKindOfClass:NSString.class]) return NO;
  NSString *range = (NSString *)v;

  if (range.length < 6 || ![range hasPrefix:@"bytes="]) return NO;
  NSString *spec = [range substringFromIndex:6]; // after "bytes="
  NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"-"];
  if (parts.count != 2) return NO;

  unsigned long long start = 0, end = 0;

  // Parse start
  NSScanner *s1 = [NSScanner scannerWithString:parts[0]];
  if (![s1 scanUnsignedLongLong:&start]) return NO;

  // Parse end (optional)
  if (parts[1].length > 0) {
    NSScanner *s2 = [NSScanner scannerWithString:parts[1]];
    if (![s2 scanUnsignedLongLong:&end]) return NO;
  } else {
    end = 0; // indicates "open-ended": bytes=start-
  }

  if (outStart) *outStart = start;
  if (outEnd)   *outEnd   = end;   // 0 means open-ended
  return YES;
}


- (void)addHLSProxyM3U8Handler {
  __weak typeof(self) weakSelf = self;

  [self.server addHandlerForMethod:@"GET"
                              path:@"/hls/proxy.m3u8"
                      requestClass:[GCDWebServerRequest class]
               asyncProcessBlock:^(__kindof GCDWebServerRequest *req, GCDWebServerCompletionBlock done) {

    __strong typeof(weakSelf) self = weakSelf;
    if (!self) { done([GCDWebServerDataResponse responseWithStatusCode:503]); return; }

      NSString *host = [self getIPAddress];

      // ===== Resolve sid and origin URL (sid-first, then query) =====
      NSString *sid = IPTVQueryValue(req, @"sid") ?: IPTVQueryValue(req, @"session");
      if (sid.length == 0) {
        // Fallback: tie this request to remote address or a random sid,
        // but in your current flow you SHOULD be sending ?sid=...
        NSString *remoteAddr = nil;
        @try { remoteAddr = [req valueForKey:@"remoteAddressString"]; } @catch (__unused NSException *e) {}
        sid = remoteAddr.length ? [@"tv-" stringByAppendingString:remoteAddr] : [NSUUID UUID].UUIDString;
      }

      // Whatever the client passed (legacy path)
      NSString *rawParam = IPTVQueryValue(req, @"url") ?: IPTVQueryValue(req, @"__hls_origin_url");

      // Prefer the origin we stored for this sid (same helper as TS handler)
      NSString *savedForSid = IPTVSidOriginURLForSid(sid);

      NSString *raw = savedForSid.length ? savedForSid : rawParam;
      if (raw.length == 0) {
        NSLog(@"❌ M3U8: Missing origin URL for sid=%@", sid);
        done([GCDWebServerDataResponse responseWithStatusCode:400]);
        return;
      }

      NSString *decoded = raw.stringByRemovingPercentEncoding ?: raw;
      NSURL *origin = [NSURL URLWithString:decoded];
      if (!origin || ![@[@"http", @"https"] containsObject:origin.scheme.lowercaseString]) {
        NSLog(@"❌ M3U8: Bad origin URL for sid=%@: %@", sid, decoded);
        done([GCDWebServerDataResponse responseWithStatusCode:400]);
        return;
      }

      NSLog(@"🔗 M3U8 origin for sid=%@: %@", sid, origin.absoluteString);


    // 2) Session w/ UA/Referer/Cookie
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPMaximumConnectionsPerHost = 8;

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSString *uaIn  = IPTVQueryValue(req, @"ua");
    NSString *refIn = IPTVQueryValue(req, @"ref");
    NSString *ckIn  = IPTVQueryValue(req, @"cookie");
    if (uaIn.length)  headers[@"User-Agent"] = uaIn;
    if (refIn.length) headers[@"Referer"]    = refIn;
    if (ckIn.length)  headers[@"Cookie"]     = ckIn;
    if (headers.count) cfg.HTTPAdditionalHeaders = headers;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSString *uaDefault = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1";
    __block NSString *effUA     = (headers[@"User-Agent"] ?: uaDefault);
    __block NSString *effCookie = headers[@"Cookie"]; // may be nil

    // GET text w/ final URL outparam (follows redirects)
    NSString* (^fetchTextFinal)(NSURL *, NSURL * __autoreleasing *) =
    ^NSString* (NSURL *u, NSURL * __autoreleasing *outFinalURL) {
      NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u
                                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                    timeoutInterval:20.0];
      NSString *refSeed = refIn.length ? refIn : u.absoluteString;
      [rq setValue:effUA     forHTTPHeaderField:@"User-Agent"];
      [rq setValue:refSeed   forHTTPHeaderField:@"Referer"];
      if (effCookie.length) [rq setValue:effCookie forHTTPHeaderField:@"Cookie"];
      [rq setValue:@"*/*"        forHTTPHeaderField:@"Accept"];
      [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
      [rq setValue:@"identity"   forHTTPHeaderField:@"Accept-Encoding"];

      dispatch_semaphore_t sema = dispatch_semaphore_create(0);
      __block NSData *data = nil; __block NSError *err = nil; __block NSURLResponse *resp = nil;
      [[session dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; resp = r; err = e; dispatch_semaphore_signal(sema);
      }] resume];
      dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

      if (err || !data.length) return (NSString *)nil;
      if (outFinalURL) *outFinalURL = (resp.URL ?: u);
      return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    };

    // 3) Fetch master/media (follow redirects)
    NSURL *finalURL = nil;
    NSString *txt = fetchTextFinal(origin, &finalURL);
    if (!txt.length) { [session finishTasksAndInvalidate]; done([GCDWebServerDataResponse responseWithStatusCode:502]); return; }

    // Log playlist content (snipped)
    NSUInteger maxPreview = 1200;
    NSString *preview = (txt.length > maxPreview) ? [txt substringToIndex:maxPreview] : txt;
    NSLog(@"📄 M3U8 (final=%@) len=%lu\n%@", finalURL.absoluteString, (unsigned long)txt.length, preview);

    if (finalURL && finalURL.host && [finalURL.host caseInsensitiveCompare:origin.host] != NSOrderedSame) {
      NSLog(@"↪️ Adopting redirected host: %@ → %@", origin.host, finalURL.host);
      origin = finalURL;
    }

    // 4) If master, prefer 720p variant (RESOLUTION height==720) else highest BANDWIDTH
    if ([txt rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound) {
      NSURL *pickURL = nil;
      NSInteger pickBW = -1;

      NSURL *pick720 = nil;
      NSInteger pick720BW = -1;

      NSArray<NSString *> *lines = [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
      for (NSInteger i = 0; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;

        // Parse attributes on this line
        NSInteger bw = -1;
        NSInteger height = -1;

        // BANDWIDTH
        NSRange br = [line rangeOfString:@"BANDWIDTH="];
        if (br.location != NSNotFound) {
          NSString *rest = [line substringFromIndex:br.location + br.length];
          NSString *num = [[rest componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]] firstObject];
          bw = num.integerValue;
        }

        // RESOLUTION=WxH
        NSRange rr = [line rangeOfString:@"RESOLUTION="];
        if (rr.location != NSNotFound) {
          NSString *rest = [line substringFromIndex:rr.location + rr.length];  // e.g. 1280x720,PROFILE=...
          NSString *val = [[rest componentsSeparatedByString:@","] firstObject];
          NSArray<NSString *> *wh = [val componentsSeparatedByString:@"x"];
          if (wh.count == 2) {
            NSString *hStr = [wh[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            height = hStr.integerValue;
          }
        }

        // The next non-tag line is the URI
        if (i + 1 >= lines.count) continue;
        NSString *nextLine = [lines[i+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([nextLine hasPrefix:@"#"]) continue;

        NSURL *abs = [NSURL URLWithString:nextLine relativeToURL:origin].absoluteURL;
        abs = IPTVInheritQueryIfMissing(abs, origin);

        // Track 720p best-by-bw
        if (height == 720 && bw > 0) {
          if (bw > pick720BW) { pick720BW = bw; pick720 = abs; }
        }

        // Track overall best-by-bw (for fallback)
        if (bw > pickBW) { pickBW = bw; pickURL = abs; }
      }

      NSURL *variant = pick720 ?: pickURL;
      if (variant) {
        origin = variant;
        NSURL *vFinal = nil;
        NSString *sub = fetchTextFinal(origin, &vFinal);
        if (sub.length) {
          NSString *vPrev = (sub.length > maxPreview) ? [sub substringToIndex:maxPreview] : sub;
          NSLog(@"📄 M3U8 (variant final=%@) len=%lu\n%@", vFinal.absoluteString, (unsigned long)sub.length, vPrev);
          txt = sub;
        }
        if (vFinal && vFinal.host && [vFinal.host caseInsensitiveCompare:origin.host] != NSOrderedSame) {
          NSLog(@"↪️ Variant redirected host: %@ → %@", origin.host, vFinal.host);
          origin = vFinal;
        }
      }
    }

    // 5) Rewrite media playlist → local proxy (no prefetch)
    NSArray<NSString *> *inLines = [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *outLines = [NSMutableArray arrayWithCapacity:inLines.count];

    BOOL hasRefOnReq = (IPTVQueryValue(req, @"ref").length > 0);
    NSString *refForDownstream = hasRefOnReq ? IPTVQueryValue(req, @"ref") : origin.absoluteString;

    for (NSString *rawLine in inLines) {
      NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (!line.length) { [outLines addObject:rawLine]; continue; }

      if ([line hasPrefix:@"#EXT-X-KEY:"]) {
        [outLines addObject:IPTVRewriteKeyLineWithHost(line, origin, host, req)];

      } else if ([line hasPrefix:@"#EXT-X-MAP:"]) {
        [outLines addObject:IPTVRewriteMapLineWithHost(line, origin, host, req)];

      } else if ([line hasPrefix:@"#"]) {
        [outLines addObject:line];

      } else {
        // segment URI (ts/m4s/mp4 etc.)
        NSURL *abs = [NSURL URLWithString:line relativeToURL:origin].absoluteURL;
        abs = IPTVInheritQueryIfMissing(abs, origin);

        NSString *leaf = abs.lastPathComponent.length ? abs.lastPathComponent : @"seg.bin";

        // Build qs and ensure ref
        NSString *qs = IPTVBuildQs(abs, req);
        if (!hasRefOnReq && refForDownstream.length) {
          NSString *refEsc = [refForDownstream stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
          qs = qs.length ? [qs stringByAppendingFormat:@"&ref=%@", refEsc] : [NSString stringWithFormat:@"ref=%@", refEsc];
        }

        NSString *local = [NSString stringWithFormat:@"http://%@:%d/hls/seg/%@?%@", host, kIPTVPort, leaf, qs];
        [outLines addObject:local];

        NSLog(@"🔗 SEG map: %@ → %@", abs.absoluteString, local);
      }
    }

    NSString *rewritten = [outLines componentsJoinedByString:@"\n"];
    GCDWebServerDataResponse *resp = [GCDWebServerDataResponse responseWithText:rewritten];
    resp.contentType = @"application/x-mpegURL";
    [resp setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
    [resp setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];

    [session finishTasksAndInvalidate];
    done(resp);
  }];
}

- (void)addHLSSegmentAndKeyHandlers {

  // SEGMENT proxy
  [self.server addHandlerForMethod:@"GET"
                         pathRegex:@"^/hls/seg/[^/]+$"
                     requestClass:[GCDWebServerRequest class]
              asyncProcessBlock:^(__kindof GCDWebServerRequest *req, GCDWebServerCompletionBlock done) {

    NSString *raw = IPTVQueryValue(req, @"url");
    if (!raw.length) { done([GCDWebServerDataResponse responseWithStatusCode:400]); return; }
    NSString *decoded = raw.stringByRemovingPercentEncoding ?: raw;
    NSURL *u = [NSURL URLWithString:decoded];
    if (!u) { done([GCDWebServerDataResponse responseWithStatusCode:400]); return; }

    // Inputs
    NSString *ua  = IPTVQueryValue(req, @"ua");
    NSString *ref = IPTVQueryValue(req, @"ref");
    NSString *ck  = IPTVQueryValue(req, @"cookie");

    NSLog(@"⬇️ SEG GET url=%@ ref=%@ ua=%@", u.absoluteString, ref ?: @"-", (ua.length ? ua : @"(default)"));

    // Try memcache first (ensure inited)
    dispatch_once(&gSegCacheOnce, ^{
      gSegMemCache = [NSCache new];
      gSegMemCache.totalCostLimit = 8 * 1024 * 1024;
      gSegCacheQ = dispatch_queue_create("iptv.seg.cache.q", DISPATCH_QUEUE_CONCURRENT);
    });

    NSString *key = IPTVCacheKeyForURL(u);
    NSData *cached = key.length ? [gSegMemCache objectForKey:key] : nil;

    // Safe Range parsing (uses your helper)
    unsigned long long rStart = 0, rEnd = 0;
    NSString *rangeHdrStr = nil;
    BOOL hasRange = IPTVParseRangeHeader(req.headers, &rStart, &rEnd, &rangeHdrStr);

    if (cached.length) {
      // Serve from cache (with Range slicing)
      NSString *leaf = req.path.lastPathComponent.lowercaseString;
      NSString *ctype = @"application/octet-stream";
      if ([leaf hasSuffix:@".ts"]) ctype = @"video/mp2t";
      else if ([leaf hasSuffix:@".m4s"] || [leaf hasSuffix:@".mp4"]) ctype = @"video/mp4";

      if (hasRange) {
        unsigned long long total = cached.length;
        unsigned long long start = MIN(rStart, (total ? total - 1 : 0));
        unsigned long long end   = (rEnd ? MIN(rEnd, total - 1) : (total - 1));
        if (end < start) end = start;

        NSRange slice = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1));
        NSData *sub = [cached subdataWithRange:slice];

        GCDWebServerDataResponse *out = [GCDWebServerDataResponse responseWithData:sub contentType:ctype];
        out.statusCode = 206;
        [out setValue:[NSString stringWithFormat:@"bytes %llu-%llu/%llu", start, end, total]
    forAdditionalHeader:@"Content-Range"];
        [out setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
        [out setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        [out setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];
        done(out);
        return;
      } else {
        GCDWebServerDataResponse *out = [GCDWebServerDataResponse responseWithData:cached contentType:ctype];
        [out setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
        [out setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];
        done(out);
        return;
      }
    }

    // No cache → fetch from origin (with Range passthrough)
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:25.0];
    NSString *uaDefault = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1";
    NSString *effUA = ua.length ? ua : uaDefault;

    NSString *effRef = ref.length ? ref : u.absoluteString;
    NSString *effOrigin = nil;
    NSURL *refURL = [NSURL URLWithString:effRef];
    if (refURL.scheme.length && refURL.host.length) {
      effOrigin = [NSString stringWithFormat:@"%@://%@", refURL.scheme, refURL.host];
    }

    [rq setValue:effUA     forHTTPHeaderField:@"User-Agent"];
    [rq setValue:effRef    forHTTPHeaderField:@"Referer"];
    if (effOrigin.length) [rq setValue:effOrigin forHTTPHeaderField:@"Origin"];
    if (ck.length)        [rq setValue:ck       forHTTPHeaderField:@"Cookie"];
    [rq setValue:@"*/*"        forHTTPHeaderField:@"Accept"];
    [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    [rq setValue:@"identity"   forHTTPHeaderField:@"Accept-Encoding"];

    if (rangeHdrStr.length) [rq setValue:rangeHdrStr forHTTPHeaderField:@"Range"];

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPMaximumConnectionsPerHost = 8;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (error || !data.length) {
        [session finishTasksAndInvalidate];
        done([GCDWebServerDataResponse responseWithStatusCode:502]);
        return;
      }

      // Store in cache only for whole-object responses
      NSHTTPURLResponse *hr = (NSHTTPURLResponse *)response;
      BOOL isPartial = (hr.statusCode == 206) || (rangeHdrStr.length > 0);
      if (!isPartial && key.length) {
        [gSegMemCache setObject:data forKey:key cost:data.length];
      }

      NSString *leaf = req.path.lastPathComponent.lowercaseString;
      NSString *ctype = @"application/octet-stream";
      if ([leaf hasSuffix:@".ts"]) ctype = @"video/mp2t";
      else if ([leaf hasSuffix:@".m4s"] || [leaf hasSuffix:@".mp4"]) ctype = @"video/mp4";

      GCDWebServerDataResponse *out = [GCDWebServerDataResponse responseWithData:data contentType:ctype];
      out.statusCode = hr.statusCode;

      NSString *cr = hr.allHeaderFields[@"Content-Range"];
      if (cr) [out setValue:cr forAdditionalHeader:@"Content-Range"];
      NSString *ar = hr.allHeaderFields[@"Accept-Ranges"];
      if (ar) [out setValue:ar forAdditionalHeader:@"Accept-Ranges"];

      [out setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
      [out setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];

      [session finishTasksAndInvalidate];
      done(out);
    }] resume];
  }];

  // AES-128 KEY proxy
  [self.server addHandlerForMethod:@"GET"
                               path:@"/hls/key"
                       requestClass:[GCDWebServerRequest class]
                asyncProcessBlock:^(__kindof GCDWebServerRequest *req, GCDWebServerCompletionBlock done) {

    NSString *raw = IPTVQueryValue(req, @"url");
    if (!raw.length) { done([GCDWebServerDataResponse responseWithStatusCode:400]); return; }
    NSString *decoded = raw.stringByRemovingPercentEncoding ?: raw;
    NSURL *u = [NSURL URLWithString:decoded];
    if (!u) { done([GCDWebServerDataResponse responseWithStatusCode:400]); return; }

    NSString *ua  = IPTVQueryValue(req, @"ua");
    NSString *ref = IPTVQueryValue(req, @"ref");
    NSString *ck  = IPTVQueryValue(req, @"cookie");

    NSLog(@"🔑 KEY GET url=%@ ref=%@ ua=%@", u.absoluteString, ref ?: @"-", (ua.length ? ua : @"(default)"));

    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:10.0];

    NSString *uaDefault = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1";
    NSString *effUA = ua.length ? ua : uaDefault;
    NSString *effRef = ref.length ? ref : u.absoluteString;
    NSString *effOrigin = nil;
    NSURL *refURL = [NSURL URLWithString:effRef];
    if (refURL.scheme.length && refURL.host.length) {
      effOrigin = [NSString stringWithFormat:@"%@://%@", refURL.scheme, refURL.host];
    }

    [rq setValue:effUA     forHTTPHeaderField:@"User-Agent"];
    [rq setValue:effRef    forHTTPHeaderField:@"Referer"];
    if (effOrigin.length) [rq setValue:effOrigin forHTTPHeaderField:@"Origin"];
    if (ck.length)        [rq setValue:ck       forHTTPHeaderField:@"Cookie"];
    [rq setValue:@"*/*"        forHTTPHeaderField:@"Accept"];
    [rq setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    [rq setValue:@"identity"   forHTTPHeaderField:@"Accept-Encoding"];

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPMaximumConnectionsPerHost = 8;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (error || !data.length) {
        [session finishTasksAndInvalidate];
        done([GCDWebServerDataResponse responseWithStatusCode:502]);
        return;
      }
      GCDWebServerDataResponse *out = [GCDWebServerDataResponse responseWithData:data contentType:@"application/octet-stream"];
      [out setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
      [out setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];

      [session finishTasksAndInvalidate];
      done(out);
    }] resume];
  }];
}


- (NSData *)fetchDataFromURL:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                       timeoutInterval:10.0];

    __block NSData *data = nil;
    __block NSURLResponse *resp = nil;
    __block NSError *err = nil;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; resp = r; err = e;
        dispatch_semaphore_signal(sema);
    }] resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    if (err) {
        NSLog(@"Proxy request failed: %@", err.localizedDescription);
        return nil;
    }
    if (!data.length) {
        NSLog(@"Warning: No data received from URL %@", url.absoluteString);
        return nil;
    }
    NSLog(@"Received %lu bytes from %@", (unsigned long)data.length, url.absoluteString);
    return data;
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
        
        if ([request.path containsString:@"proxy"]) {
            NSString *encodedURLString = request.query[@"url"];
                    if (!encodedURLString || [encodedURLString isEqualToString:@""]) {
                        NSLog(@"Error: Missing URL parameter in proxy request");
                        return [GCDWebServerDataResponse responseWithStatusCode:400];
                    }

                    // Decode and validate the URL
                    NSString *decodedURLString = [encodedURLString stringByRemovingPercentEncoding];
                    NSURL *originalURL = [NSURL URLWithString:decodedURLString];
            weakSelf.originalM3U8URL = originalURL.absoluteString;
                    
                    if (!originalURL) {
                        NSLog(@"Error: Invalid URL in proxy request - %@", decodedURLString);
                        return [GCDWebServerDataResponse responseWithStatusCode:400];
                    }

                    NSLog(@"[PROXY] Fetching: %@", decodedURLString);

                    // Check if it's a `.ts` file request
                    if ([decodedURLString containsString:@".ts"]) {
                        NSLog(@"[PROXY] Fetching TS file: %@", decodedURLString);
                        return [weakSelf proxyTSRequest:decodedURLString m3u8Url: originalURL.absoluteString];
                    }

                    // Fetch data from external URL
                    NSData *data = [weakSelf fetchDataFromURL:originalURL];
                    
                    if (!data) {
                        NSLog(@"Error: Failed to fetch data from %@", originalURL.absoluteString);
                        return [GCDWebServerDataResponse responseWithStatusCode:502]; // Bad Gateway
                    }

                    // Determine the correct content type
                    NSString *contentType = @"application/vnd.apple.mpegurl";
                    if ([decodedURLString containsString:@".m3u8"]) {
                        contentType = @"application/x-mpegURL";
                    } else if ([decodedURLString containsString:@".ts"]) {
                        contentType = @"video/mp2t";
                    }

                    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithData:data contentType:contentType];
                    response.statusCode = 200;
                    return response;
        }
        else if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"mp4"]) {
            NSString *remoteUrl = [NSUserDefaults.standardUserDefaults objectForKey:@"stream"];
            GCDWebServerResponse *response = [weakSelf sendRequest:request toExternalUrl:remoteUrl];
            return response;
        } else if ([NSUserDefaults.standardUserDefaults objectForKey:@"ResourceId"] == nil && [request.path containsString:@"ts"]) {
            weakSelf.isHLS = YES;
            NSString *remoteUrl = [NSUserDefaults.standardUserDefaults objectForKey:@"stream"];
            GCDWebServerResponse *response = [weakSelf sendRequest:request toExternalM3U8Url:remoteUrl];
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

// New function to handle TS file proxying using M3U8PlaylistModel
- (GCDWebServerResponse *)proxyTSRequest:(NSString *)segmentPath m3u8Url:(NSString *)m3u8Url {
    NSLog(@"Fetching TS file for segment: %@", segmentPath);
    
    // Step 1: Parse M3U8 and Get Complete URL for the Segment
    NSURL *completeSegmentURL = [self getSegmentURLForPath:segmentPath fromM3U8:m3u8Url];

    if (!completeSegmentURL) {
        NSLog(@"Error: Could not determine full segment URL for %@", segmentPath);
        return [GCDWebServerDataResponse responseWithStatusCode:404]; // Not Found
    }
    
    NSLog(@"Resolved Full TS URL: %@", completeSegmentURL.absoluteString);
    
    // Step 2: Fetch the TS Data
    NSData *tsData = [self fetchDataFromURL:completeSegmentURL];

    if (!tsData || tsData.length == 0) {
        NSLog(@"Error: TS file is empty or could not be fetched");
        return [GCDWebServerDataResponse responseWithStatusCode:404]; // Not Found
    }

    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithData:tsData contentType:@"video/mp2t"];
    response.statusCode = 200;
    return response;
}

// Helper function to fetch complete segment URL using M3U8PlaylistModel
- (NSURL *)getSegmentURLForPath:(NSString *)segmentPath fromM3U8:(NSString *)m3u8Url {
    NSURL *originURL = [NSURL URLWithString:m3u8Url];
    if (!originURL) {
        NSLog(@"[ERROR] Invalid M3U8 URL: %@", m3u8Url);
        return nil;
    }

    @try {
        NSError *m3u8Error = nil;
        M3U8PlaylistModel *m3u8Model = [[M3U8PlaylistModel alloc] initWithURL:originURL error:&m3u8Error];

        if (!m3u8Model || m3u8Error) {
            NSLog(@"[ERROR] Failed to parse M3U8: %@", m3u8Error.localizedDescription);
            return nil;
        }

        // Extract `frag(...)` and onward
        NSRange fragRange = [segmentPath rangeOfString:@"/frag("];
        NSString *normalizedSegmentPath = (fragRange.location != NSNotFound) ? [segmentPath substringFromIndex:fragRange.location] : segmentPath;

        NSLog(@"[DEBUG] Normalized segment path for matching: %@", normalizedSegmentPath);

        for (int i = 0; i < (int)m3u8Model.mainMediaPl.segmentList.count; i++) {
            M3U8SegmentInfo *segment = [m3u8Model.mainMediaPl.segmentList segmentInfoAtIndex:i];
            NSURL *segmentURL = [segment mediaURL];

            NSLog(@"[M3U8] Checking segment: %@", segmentURL.absoluteString);

            // ✅ Match based on `frag(...)` onward
            if ([segmentURL.absoluteString containsString:normalizedSegmentPath]) {
                NSLog(@"[MATCH] Found matching segment: %@", segmentURL.absoluteString);
                return segmentURL; // ✅ Return the correct full URL
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] Failed to parse M3U8: %@", exception.reason);
    }

    NSLog(@"[ERROR] No matching segment found for %@", segmentPath);
    return nil; // Return nil if no match found
}

// Function to fetch data from a URL
- (NSData *)fetchTSDataFromURL:(NSURL *)url {
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10.0];
    NSURLResponse *response;
    NSError *error;
    
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];

    if (error) {
        NSLog(@"Proxy request failed: %@", error.localizedDescription);
        return nil;
    }
    
    if (!data || data.length == 0) {
        NSLog(@"Warning: No data received from URL %@", url.absoluteString);
        return nil;
    }

    NSLog(@"Received %lu bytes from %@", (unsigned long)data.length, url.absoluteString);
    
    return data;
}


- (void)addPlaylistHandler {
    [self.server addHandlerForMethod:@"GET"
                           pathRegex:@"^/hls_stream/output\\.m3u8$"
                       requestClass:[GCDWebServerRequest self]
                asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths firstObject];
        NSString *playlistPath = [documentsDirectory stringByAppendingPathComponent:@"hls_stream/output.m3u8"];

        if (![[NSFileManager defaultManager] fileExistsAtPath:playlistPath]) {
            return completionBlock([GCDWebServerErrorResponse responseWithStatusCode:404]);
        }

        // Serve the M3U8 file
        GCDWebServerFileResponse *fileResponse = [GCDWebServerFileResponse responseWithFile:playlistPath];
        fileResponse.contentType = @"application/x-mpegURL";
        completionBlock(fileResponse);
    }];
}


- (void)addSegmentHandler {
    [self.server addHandlerForMethod:@"GET"
                           pathRegex:@"^/hls_stream/segment_[0-9]+\\.ts$"
                       requestClass:[GCDWebServerRequest self]
                asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        
        // Get the Documents directory path
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths firstObject];

        // Correctly append the segment filename
        NSString *segmentPath = [documentsDirectory stringByAppendingPathComponent:request.path];

        if (![[NSFileManager defaultManager] fileExistsAtPath:segmentPath]) {
            NSLog(@"Segment Not Found: %@", segmentPath);
            return completionBlock([GCDWebServerErrorResponse responseWithStatusCode:404]);
        }

        // Serve the requested TS file
        GCDWebServerFileResponse *fileResponse = [GCDWebServerFileResponse responseWithFile:segmentPath byteRange:request.byteRange];
        fileResponse.contentType = @"video/MP2T";
        completionBlock(fileResponse);

        // Delete segment after it has been served
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            NSError *error;
            if ([[NSFileManager defaultManager] fileExistsAtPath:segmentPath]) {
                [[NSFileManager defaultManager] removeItemAtPath:segmentPath error:&error];
                if (error) {
                    NSLog(@"Error deleting segment: %@", error.localizedDescription);
                } else {
                    NSLog(@"Deleted segment: %@", segmentPath);
                }
            }
        });
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
    return [NSString stringWithFormat:@"http://%@:%d/", [self getIPAddress], 8181];
}

-(NSString *)getIPAddress
{
    
    return GCDWebServerGetPrimaryIPAddress(false);
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
